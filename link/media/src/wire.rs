//! Datagram wire formats (LINK.md §4.3). Byte 0 = `channel << 4 | 1`; integers big-endian.
//!
//! Every parser takes untrusted bytes and returns `Err(WireError)` on anything malformed; none panics.

use std::fmt;

/// Wire version carried in the low nibble of byte 0.
pub const VERSION: u8 = 1;

/// Datagram channels (high nibble of byte 0).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Channel {
    Video = 1,
    Audio = 2,
    Input = 3,
    Feedback = 4,
    Cursor = 5,
}

impl Channel {
    pub const fn header_byte(self) -> u8 {
        (self as u8) << 4 | VERSION
    }

    fn from_nibble(n: u8) -> Option<Channel> {
        Some(match n {
            1 => Channel::Video,
            2 => Channel::Audio,
            3 => Channel::Input,
            4 => Channel::Feedback,
            5 => Channel::Cursor,
            _ => return None,
        })
    }

    /// Video, audio and cursor datagrams carry a transport sequence (`tseq`) and feed the rate controller.
    pub const fn is_media(self) -> bool {
        matches!(self, Channel::Video | Channel::Audio | Channel::Cursor)
    }
}

/// Why a datagram was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    /// Fewer bytes than the format needs.
    Short,
    /// Byte 0's version nibble isn't [`VERSION`].
    Version(u8),
    /// Byte 0's channel nibble is unknown, or not the channel the parser expected.
    Channel(u8),
    /// A field has an impossible value.
    Invalid(&'static str),
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WireError::Short => write!(f, "datagram too short"),
            WireError::Version(v) => write!(f, "unsupported datagram version {v}"),
            WireError::Channel(c) => write!(f, "unexpected datagram channel {c}"),
            WireError::Invalid(what) => write!(f, "invalid datagram: {what}"),
        }
    }
}

impl std::error::Error for WireError {}

pub type WireResult<T> = Result<T, WireError>;

/// The channel of a datagram (checks the version nibble).
pub fn channel_of(datagram: &[u8]) -> WireResult<Channel> {
    let b = *datagram.first().ok_or(WireError::Short)?;
    if b & 0x0F != VERSION {
        return Err(WireError::Version(b & 0x0F));
    }
    Channel::from_nibble(b >> 4).ok_or(WireError::Channel(b >> 4))
}

fn expect(datagram: &[u8], channel: Channel) -> WireResult<()> {
    let c = channel_of(datagram)?;
    if c != channel {
        return Err(WireError::Channel(c as u8));
    }
    Ok(())
}

/// A bounds-checked big-endian reader.
pub(crate) struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(buf: &'a [u8]) -> Reader<'a> {
        Reader { buf, pos: 0 }
    }
    pub(crate) fn bytes(&mut self, n: usize) -> WireResult<&'a [u8]> {
        let end = self.pos.checked_add(n).ok_or(WireError::Short)?;
        let s = self.buf.get(self.pos..end).ok_or(WireError::Short)?;
        self.pos = end;
        Ok(s)
    }
    pub(crate) fn u8(&mut self) -> WireResult<u8> {
        Ok(self.bytes(1)?[0])
    }
    pub(crate) fn u16(&mut self) -> WireResult<u16> {
        let b = self.bytes(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }
    pub(crate) fn u32(&mut self) -> WireResult<u32> {
        let b = self.bytes(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub(crate) fn u64(&mut self) -> WireResult<u64> {
        let b = self.bytes(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        Ok(u64::from_be_bytes(a))
    }
    pub(crate) fn rest(&mut self) -> &'a [u8] {
        let s = &self.buf[self.pos..];
        self.pos = self.buf.len();
        s
    }
    pub(crate) fn remaining(&self) -> usize {
        self.buf.len() - self.pos
    }
}

fn put_u16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}
fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}
fn put_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}

/// Byte offset of `tseq` in video and audio datagrams.
pub(crate) const MEDIA_TSEQ_OFFSET: usize = 4;
/// Byte offset of `tseq` in cursor datagrams.
pub(crate) const CURSOR_TSEQ_OFFSET: usize = 2;

/// The `tseq` of a media-class datagram (video, audio, cursor); None for other channels or short datagrams.
pub fn media_tseq(datagram: &[u8]) -> Option<u32> {
    let off = match channel_of(datagram).ok()? {
        Channel::Video | Channel::Audio => MEDIA_TSEQ_OFFSET,
        Channel::Cursor => CURSOR_TSEQ_OFFSET,
        _ => return None,
    };
    let b = datagram.get(off..off + 4)?;
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

/// Stamp `tseq` into a media-class datagram built with a placeholder.
pub(crate) fn set_media_tseq(datagram: &mut [u8], tseq: u32) {
    let off = match channel_of(datagram) {
        Ok(Channel::Video | Channel::Audio) => MEDIA_TSEQ_OFFSET,
        Ok(Channel::Cursor) => CURSOR_TSEQ_OFFSET,
        _ => return,
    };
    if let Some(b) = datagram.get_mut(off..off + 4) {
        b.copy_from_slice(&tseq.to_be_bytes());
    }
}

// MARK: video (1)

/// Video datagram flags.
pub mod video_flags {
    pub const PARITY: u8 = 0x01;
    pub const RETRANSMIT: u8 = 0x02;
    pub const KEY: u8 = 0x04;
    pub const RECOVERY: u8 = 0x08;
    pub const LAST_BLOCK: u8 = 0x10;
}

/// The 20-byte header of a video shard datagram.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoHeader {
    pub stream: u8,
    pub flags: u8,
    pub block: u8,
    pub tseq: u32,
    pub frame: u32,
    /// Shard index in the block: `0..k` data, `k..k+m` parity.
    pub shard: u16,
    pub k: u16,
    pub m: u16,
    pub shard_size: u16,
}

impl VideoHeader {
    pub const LEN: usize = 20;

    pub fn write(&self, out: &mut Vec<u8>) {
        out.push(Channel::Video.header_byte());
        out.push(self.stream);
        out.push(self.flags);
        out.push(self.block);
        put_u32(out, self.tseq);
        put_u32(out, self.frame);
        put_u16(out, self.shard);
        put_u16(out, self.k);
        put_u16(out, self.m);
        put_u16(out, self.shard_size);
    }

    /// Header + shard bytes. Checks that the shard is `shard_size` long, `shard < k + m`, `k ≥ 1` and the size is
    /// even and non-zero (Reed-Solomon needs it).
    pub fn parse(datagram: &[u8]) -> WireResult<(VideoHeader, &[u8])> {
        expect(datagram, Channel::Video)?;
        let mut r = Reader::new(datagram);
        r.u8()?;
        let h = VideoHeader {
            stream: r.u8()?,
            flags: r.u8()?,
            block: r.u8()?,
            tseq: r.u32()?,
            frame: r.u32()?,
            shard: r.u16()?,
            k: r.u16()?,
            m: r.u16()?,
            shard_size: r.u16()?,
        };
        let shard = r.rest();
        if h.k == 0 || h.k as usize > MAX_DATA_SHARDS {
            return Err(WireError::Invalid("k"));
        }
        if h.m as usize > MAX_PARITY_SHARDS {
            return Err(WireError::Invalid("m"));
        }
        if h.shard >= h.k + h.m {
            return Err(WireError::Invalid("shard index"));
        }
        if h.shard_size == 0 || !h.shard_size.is_multiple_of(2) || shard.len() != h.shard_size as usize {
            return Err(WireError::Invalid("shard size"));
        }
        if (h.flags & video_flags::PARITY != 0) != (h.shard >= h.k) {
            return Err(WireError::Invalid("parity flag"));
        }
        Ok((h, shard))
    }
}

/// Data shards per block at most (LINK.md §4.3).
pub const MAX_DATA_SHARDS: usize = 32;
/// Parity shards per block at most (the FEC policy needs ≤ 0.6 × 32; the wire allows a little more).
pub const MAX_PARITY_SHARDS: usize = 32;

/// Video codecs in the frame meta.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Codec {
    H264 = 1,
    Hevc = 2,
}

/// What a frame is, for the reference chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameKind {
    /// References the previous frame.
    Delta = 0,
    /// Independent.
    Key = 1,
    /// A sharper re-encode of the unchanged picture; references the previous frame.
    Refine = 2,
    /// A tiny re-encode so the stream shows life; references the previous frame.
    Keepalive = 3,
    /// References only `recovery_base` (a long-term reference the receiver acknowledged).
    Recovery = 4,
}

impl FrameKind {
    fn from_u8(v: u8) -> Option<FrameKind> {
        Some(match v {
            0 => FrameKind::Delta,
            1 => FrameKind::Key,
            2 => FrameKind::Refine,
            3 => FrameKind::Keepalive,
            4 => FrameKind::Recovery,
            _ => return None,
        })
    }
}

/// The 24 bytes in front of every frame's Annex-B access unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameMeta {
    pub codec: Codec,
    pub kind: FrameKind,
    pub width: u16,
    pub height: u16,
    /// Capture time, µs since the Unix epoch (sender's wall clock; for latency stats only).
    pub capture_us: u64,
    /// Recovery frames: the frame they reference (0 = none).
    pub recovery_base: u32,
    /// Length of the access unit that follows.
    pub au_len: u32,
}

impl FrameMeta {
    pub const LEN: usize = 24;

    pub fn write(&self, out: &mut Vec<u8>) {
        out.push(1);
        out.push(self.codec as u8);
        out.push(self.kind as u8);
        out.push(0);
        put_u16(out, self.width);
        put_u16(out, self.height);
        put_u64(out, self.capture_us);
        put_u32(out, self.recovery_base);
        put_u32(out, self.au_len);
    }

    /// The meta and the AU from a reassembled frame (trailing padding ignored).
    pub fn parse(frame: &[u8]) -> WireResult<(FrameMeta, &[u8])> {
        let mut r = Reader::new(frame);
        if r.u8()? != 1 {
            return Err(WireError::Invalid("meta version"));
        }
        let codec = match r.u8()? {
            1 => Codec::H264,
            2 => Codec::Hevc,
            _ => return Err(WireError::Invalid("codec")),
        };
        let kind = FrameKind::from_u8(r.u8()?).ok_or(WireError::Invalid("frame kind"))?;
        r.u8()?;
        let meta = FrameMeta {
            codec,
            kind,
            width: r.u16()?,
            height: r.u16()?,
            capture_us: r.u64()?,
            recovery_base: r.u32()?,
            au_len: r.u32()?,
        };
        let au = r.bytes(meta.au_len as usize)?;
        Ok((meta, au))
    }
}

// MARK: audio (2)

/// An audio datagram: the newest Opus packet plus `redundant` older ones (newest first).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioDatagram<'a> {
    pub stream: u8,
    pub flags: u8,
    pub tseq: u32,
    pub aseq: u32,
    pub time_us: u64,
    pub data: &'a [u8],
    /// `(aseq delta, opus)`: packet `aseq − delta`.
    pub redundant: Vec<(u16, &'a [u8])>,
}

impl<'a> AudioDatagram<'a> {
    pub const HEADER_LEN: usize = 22;

    pub fn write(&self, out: &mut Vec<u8>) {
        out.push(Channel::Audio.header_byte());
        out.push(self.stream);
        out.push(self.redundant.len() as u8);
        out.push(self.flags);
        put_u32(out, self.tseq);
        put_u32(out, self.aseq);
        put_u64(out, self.time_us);
        put_u16(out, self.data.len() as u16);
        out.extend_from_slice(self.data);
        for (delta, d) in &self.redundant {
            put_u16(out, *delta);
            put_u16(out, d.len() as u16);
            out.extend_from_slice(d);
        }
    }

    pub fn parse(datagram: &'a [u8]) -> WireResult<AudioDatagram<'a>> {
        expect(datagram, Channel::Audio)?;
        let mut r = Reader::new(datagram);
        r.u8()?;
        let stream = r.u8()?;
        let n = r.u8()?;
        let flags = r.u8()?;
        let tseq = r.u32()?;
        let aseq = r.u32()?;
        let time_us = r.u64()?;
        let len = r.u16()? as usize;
        let data = r.bytes(len)?;
        let mut redundant = Vec::with_capacity(n as usize);
        for _ in 0..n {
            let delta = r.u16()?;
            if delta == 0 {
                return Err(WireError::Invalid("aseq delta"));
            }
            let len = r.u16()? as usize;
            redundant.push((delta, r.bytes(len)?));
        }
        if r.remaining() != 0 {
            return Err(WireError::Invalid("trailing bytes"));
        }
        Ok(AudioDatagram { stream, flags, tseq, aseq, time_us, data, redundant })
    }
}

// MARK: input (3)

/// Input event kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum InputKind {
    /// Down / up / click / key / text / scroll: exactly once, in order.
    Discrete = 0,
    /// Pointer moves (drags too): latest wins.
    Move = 1,
}

/// One input event on the wire: today's `/input` JSON body with a sequence number.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputEventWire<'a> {
    pub seq: u32,
    pub kind: InputKind,
    pub json: &'a [u8],
}

impl InputEventWire<'_> {
    /// Bytes on the wire.
    pub fn wire_len(&self) -> usize {
        7 + self.json.len()
    }
}

/// An input datagram.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputDatagram<'a> {
    pub flags: u8,
    pub events: Vec<InputEventWire<'a>>,
}

impl<'a> InputDatagram<'a> {
    pub const HEADER_LEN: usize = 4;

    pub fn write(&self, out: &mut Vec<u8>) {
        out.push(Channel::Input.header_byte());
        out.push(self.flags);
        put_u16(out, self.events.len() as u16);
        for e in &self.events {
            put_u32(out, e.seq);
            out.push(e.kind as u8);
            put_u16(out, e.json.len() as u16);
            out.extend_from_slice(e.json);
        }
    }

    pub fn parse(datagram: &'a [u8]) -> WireResult<InputDatagram<'a>> {
        expect(datagram, Channel::Input)?;
        let mut r = Reader::new(datagram);
        r.u8()?;
        let flags = r.u8()?;
        let n = r.u16()? as usize;
        let mut events = Vec::with_capacity(n.min(256));
        for _ in 0..n {
            let seq = r.u32()?;
            let kind = match r.u8()? {
                0 => InputKind::Discrete,
                1 => InputKind::Move,
                _ => return Err(WireError::Invalid("input kind")),
            };
            let len = r.u16()? as usize;
            events.push(InputEventWire { seq, kind, json: r.bytes(len)? });
        }
        if r.remaining() != 0 {
            return Err(WireError::Invalid("trailing bytes"));
        }
        Ok(InputDatagram { flags, events })
    }
}

// MARK: feedback (4)

/// Transport-wide feedback: arrival times of `count` consecutive tseqs from `base_tseq`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransportCc {
    pub base_tseq: u32,
    /// Receiver clock (µs, mod 2^32) that the deltas count from.
    pub ref_time_us: u32,
    /// Per tseq: arrival − ref in 250 µs units, or [`TransportCc::NOT_RECEIVED`].
    pub deltas: Vec<u16>,
}

impl TransportCc {
    pub const NOT_RECEIVED: u16 = 0xFFFF;
    pub const UNIT_US: u64 = 250;
    /// Largest encodable delta.
    pub const MAX_DELTA: u16 = 0xFFFE;
}

/// One NACKed shard. `shard` [`NackItem::WHOLE_BLOCK`] asks for every shard (data and parity) of `block`;
/// [`NackItem::BLOCK_AND_LATER`] for every shard of `block` and of each later block (a wholly missing frame is
/// `(frame, 0, BLOCK_AND_LATER)`). Real shard indices are < 64, so these values never collide with one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NackItem {
    pub frame: u32,
    pub block: u8,
    pub shard: u16,
}

impl NackItem {
    pub const WHOLE_BLOCK: u16 = 0xFFFF;
    pub const BLOCK_AND_LATER: u16 = 0xFFFE;
}

/// Frame report flags.
pub mod report_flags {
    pub const KEYFRAME_NEEDED: u8 = 0x01;
}

/// The receiver's view of one video stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameReport {
    pub stream: u8,
    /// Newest frame handed to the decoder and decoded OK (0 = none yet).
    pub last_delivered: u32,
    /// Frames declared lost lately (repeated across a few reports).
    pub lost: Vec<u32>,
    pub flags: u8,
}

/// One feedback section.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FeedbackSection {
    TransportCc(TransportCc),
    Nack {
        stream: u8,
        items: Vec<NackItem>,
    },
    FrameReport(FrameReport),
    /// Highest seq up to which every discrete input event was applied.
    InputAck(u32),
    AudioReport {
        stream: u8,
        loss_permille: u16,
    },
}

impl FeedbackSection {
    fn type_byte(&self) -> u8 {
        match self {
            FeedbackSection::TransportCc(_) => 1,
            FeedbackSection::Nack { .. } => 2,
            FeedbackSection::FrameReport(_) => 3,
            FeedbackSection::InputAck(_) => 4,
            FeedbackSection::AudioReport { .. } => 5,
        }
    }

    /// Encoded size including the 3-byte section header.
    pub fn wire_len(&self) -> usize {
        3 + match self {
            FeedbackSection::TransportCc(t) => 10 + 2 * t.deltas.len(),
            FeedbackSection::Nack { items, .. } => 3 + 7 * items.len(),
            FeedbackSection::FrameReport(r) => 8 + 4 * r.lost.len(),
            FeedbackSection::InputAck(_) => 4,
            FeedbackSection::AudioReport { .. } => 3,
        }
    }

    fn write_payload(&self, out: &mut Vec<u8>) {
        match self {
            FeedbackSection::TransportCc(t) => {
                put_u32(out, t.base_tseq);
                put_u16(out, t.deltas.len() as u16);
                put_u32(out, t.ref_time_us);
                for d in &t.deltas {
                    put_u16(out, *d);
                }
            }
            FeedbackSection::Nack { stream, items } => {
                out.push(*stream);
                put_u16(out, items.len() as u16);
                for i in items {
                    put_u32(out, i.frame);
                    out.push(i.block);
                    put_u16(out, i.shard);
                }
            }
            FeedbackSection::FrameReport(r) => {
                out.push(r.stream);
                put_u32(out, r.last_delivered);
                put_u16(out, r.lost.len() as u16);
                for f in &r.lost {
                    put_u32(out, *f);
                }
                out.push(r.flags);
            }
            FeedbackSection::InputAck(seq) => put_u32(out, *seq),
            FeedbackSection::AudioReport { stream, loss_permille } => {
                out.push(*stream);
                put_u16(out, *loss_permille);
            }
        }
    }

    fn parse(ty: u8, payload: &[u8]) -> WireResult<Option<FeedbackSection>> {
        let mut r = Reader::new(payload);
        let s = match ty {
            1 => {
                let base_tseq = r.u32()?;
                let count = r.u16()? as usize;
                let ref_time_us = r.u32()?;
                let mut deltas = Vec::with_capacity(count);
                for _ in 0..count {
                    deltas.push(r.u16()?);
                }
                FeedbackSection::TransportCc(TransportCc { base_tseq, ref_time_us, deltas })
            }
            2 => {
                let stream = r.u8()?;
                let n = r.u16()? as usize;
                let mut items = Vec::with_capacity(n.min(1024));
                for _ in 0..n {
                    items.push(NackItem { frame: r.u32()?, block: r.u8()?, shard: r.u16()? });
                }
                FeedbackSection::Nack { stream, items }
            }
            3 => {
                let stream = r.u8()?;
                let last_delivered = r.u32()?;
                let n = r.u16()? as usize;
                let mut lost = Vec::with_capacity(n.min(1024));
                for _ in 0..n {
                    lost.push(r.u32()?);
                }
                let flags = r.u8()?;
                FeedbackSection::FrameReport(FrameReport { stream, last_delivered, lost, flags })
            }
            4 => FeedbackSection::InputAck(r.u32()?),
            5 => FeedbackSection::AudioReport { stream: r.u8()?, loss_permille: r.u16()? },
            // unknown section types are skipped (newer peers)
            _ => return Ok(None),
        };
        if r.remaining() != 0 {
            return Err(WireError::Invalid("section length"));
        }
        Ok(Some(s))
    }
}

/// Encode sections into one feedback datagram. The caller keeps it within the datagram size
/// ([`FeedbackSection::wire_len`] + 2 bytes of header); at most 255 sections.
pub fn encode_feedback(sections: &[FeedbackSection]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + sections.iter().map(|s| s.wire_len()).sum::<usize>());
    out.push(Channel::Feedback.header_byte());
    out.push(sections.len().min(255) as u8);
    for s in sections.iter().take(255) {
        out.push(s.type_byte());
        let len_at = out.len();
        put_u16(&mut out, 0);
        let start = out.len();
        s.write_payload(&mut out);
        let len = (out.len() - start) as u16;
        out[len_at..len_at + 2].copy_from_slice(&len.to_be_bytes());
    }
    out
}

/// Parse a feedback datagram; unknown section types are skipped.
pub fn parse_feedback(datagram: &[u8]) -> WireResult<Vec<FeedbackSection>> {
    expect(datagram, Channel::Feedback)?;
    let mut r = Reader::new(datagram);
    r.u8()?;
    let n = r.u8()?;
    let mut out = Vec::with_capacity(n as usize);
    for _ in 0..n {
        let ty = r.u8()?;
        let len = r.u16()? as usize;
        let payload = r.bytes(len)?;
        if let Some(s) = FeedbackSection::parse(ty, payload)? {
            out.push(s);
        }
    }
    if r.remaining() != 0 {
        return Err(WireError::Invalid("trailing bytes"));
    }
    Ok(out)
}

/// Feedback datagram header bytes.
pub const FEEDBACK_HEADER_LEN: usize = 2;

// MARK: cursor (5)

/// A cursor position datagram (JSON `{x,y,visible,shapeId}`); latest `cseq` wins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorDatagram<'a> {
    pub stream: u8,
    pub tseq: u32,
    pub cseq: u32,
    pub json: &'a [u8],
}

impl<'a> CursorDatagram<'a> {
    pub const HEADER_LEN: usize = 10;

    pub fn write(&self, out: &mut Vec<u8>) {
        out.push(Channel::Cursor.header_byte());
        out.push(self.stream);
        put_u32(out, self.tseq);
        put_u32(out, self.cseq);
        out.extend_from_slice(self.json);
    }

    pub fn parse(datagram: &'a [u8]) -> WireResult<CursorDatagram<'a>> {
        expect(datagram, Channel::Cursor)?;
        let mut r = Reader::new(datagram);
        r.u8()?;
        Ok(CursorDatagram { stream: r.u8()?, tseq: r.u32()?, cseq: r.u32()?, json: r.rest() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lcg(seed: &mut u64) -> u64 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *seed >> 33
    }

    #[test]
    fn header_byte() {
        assert_eq!(Channel::Video.header_byte(), 0x11);
        assert_eq!(Channel::Cursor.header_byte(), 0x51);
        assert_eq!(channel_of(&[0x41]).unwrap(), Channel::Feedback);
        assert_eq!(channel_of(&[0x42]), Err(WireError::Version(2)));
        assert_eq!(channel_of(&[0x91]), Err(WireError::Channel(9)));
        assert_eq!(channel_of(&[]), Err(WireError::Short));
    }

    #[test]
    fn video_round_trip() {
        let h = VideoHeader {
            stream: 3,
            flags: video_flags::PARITY | video_flags::LAST_BLOCK,
            block: 2,
            tseq: 0xDEADBEEF,
            frame: 77,
            shard: 5,
            k: 4,
            m: 2,
            shard_size: 6,
        };
        let mut d = Vec::new();
        h.write(&mut d);
        assert_eq!(d.len(), VideoHeader::LEN);
        d.extend_from_slice(&[1, 2, 3, 4, 5, 6]);
        let (p, shard) = VideoHeader::parse(&d).unwrap();
        assert_eq!(p, h);
        assert_eq!(shard, &[1, 2, 3, 4, 5, 6]);
        assert_eq!(media_tseq(&d), Some(0xDEADBEEF));
        set_media_tseq(&mut d, 9);
        assert_eq!(VideoHeader::parse(&d).unwrap().0.tseq, 9);
        // wrong size, bad index, parity flag mismatch
        assert!(VideoHeader::parse(&d[..d.len() - 1]).is_err());
        let mut bad = h;
        bad.shard = 6;
        let mut d2 = Vec::new();
        bad.write(&mut d2);
        d2.extend_from_slice(&[0; 6]);
        assert_eq!(VideoHeader::parse(&d2), Err(WireError::Invalid("shard index")));
        let mut bad = h;
        bad.flags = 0;
        let mut d3 = Vec::new();
        bad.write(&mut d3);
        d3.extend_from_slice(&[0; 6]);
        assert_eq!(VideoHeader::parse(&d3), Err(WireError::Invalid("parity flag")));
    }

    #[test]
    fn meta_round_trip() {
        let m = FrameMeta {
            codec: Codec::Hevc,
            kind: FrameKind::Recovery,
            width: 2304,
            height: 1440,
            capture_us: 1_700_000_000_000_000,
            recovery_base: 41,
            au_len: 3,
        };
        let mut d = Vec::new();
        m.write(&mut d);
        assert_eq!(d.len(), FrameMeta::LEN);
        d.extend_from_slice(&[9, 8, 7, 0, 0]);
        let (p, au) = FrameMeta::parse(&d).unwrap();
        assert_eq!(p, m);
        assert_eq!(au, &[9, 8, 7]);
        assert!(FrameMeta::parse(&d[..FrameMeta::LEN + 2]).is_err());
    }

    #[test]
    fn audio_round_trip() {
        let a = AudioDatagram {
            stream: 1,
            flags: 0,
            tseq: 5,
            aseq: 100,
            time_us: 123456,
            data: &[1, 2, 3],
            redundant: vec![(1, &[4, 5][..]), (2, &[6][..])],
        };
        let mut d = Vec::new();
        a.write(&mut d);
        assert_eq!(d.len(), AudioDatagram::HEADER_LEN + 3 + 4 + 2 + 4 + 1);
        assert_eq!(AudioDatagram::parse(&d).unwrap(), a);
        assert_eq!(media_tseq(&d), Some(5));
        d.push(0);
        assert!(AudioDatagram::parse(&d).is_err());
    }

    #[test]
    fn input_round_trip() {
        let i = InputDatagram {
            flags: 0,
            events: vec![
                InputEventWire { seq: 1, kind: InputKind::Discrete, json: br#"{"type":"down"}"# },
                InputEventWire { seq: 2, kind: InputKind::Move, json: br#"{"type":"move"}"# },
            ],
        };
        let mut d = Vec::new();
        i.write(&mut d);
        assert_eq!(InputDatagram::parse(&d).unwrap(), i);
        assert_eq!(d.len(), 4 + i.events.iter().map(|e| e.wire_len()).sum::<usize>());
        assert_eq!(media_tseq(&d), None);
    }

    #[test]
    fn feedback_round_trip() {
        let sections = vec![
            FeedbackSection::TransportCc(TransportCc {
                base_tseq: u32::MAX - 1,
                ref_time_us: 42,
                deltas: vec![0, TransportCc::NOT_RECEIVED, 7],
            }),
            FeedbackSection::Nack {
                stream: 1,
                items: vec![
                    NackItem { frame: 9, block: 0, shard: 3 },
                    NackItem { frame: 10, block: 0, shard: NackItem::BLOCK_AND_LATER },
                ],
            },
            FeedbackSection::FrameReport(FrameReport {
                stream: 1,
                last_delivered: 8,
                lost: vec![9],
                flags: report_flags::KEYFRAME_NEEDED,
            }),
            FeedbackSection::InputAck(77),
            FeedbackSection::AudioReport { stream: 0, loss_permille: 12 },
        ];
        let d = encode_feedback(&sections);
        assert_eq!(d.len(), FEEDBACK_HEADER_LEN + sections.iter().map(|s| s.wire_len()).sum::<usize>());
        assert_eq!(parse_feedback(&d).unwrap(), sections);
        // an unknown section type is skipped
        let mut d2 = vec![Channel::Feedback.header_byte(), 2, 99, 0, 2, 0xAA, 0xBB];
        let off = 2 + sections[..3].iter().map(|s| s.wire_len()).sum::<usize>();
        d2.extend_from_slice(&d[off..off + sections[3].wire_len()]);
        assert_eq!(parse_feedback(&d2).unwrap(), vec![FeedbackSection::InputAck(77)]);
    }

    #[test]
    fn cursor_round_trip() {
        let c = CursorDatagram { stream: 0, tseq: 3, cseq: 4, json: br#"{"x":1}"# };
        let mut d = Vec::new();
        c.write(&mut d);
        assert_eq!(CursorDatagram::parse(&d).unwrap(), c);
        assert_eq!(media_tseq(&d), Some(3));
    }

    /// Random bytes and every truncation of valid datagrams: errors, never panics.
    #[test]
    fn malformed_never_panics() {
        let mut seed = 7u64;
        let mut samples: Vec<Vec<u8>> = Vec::new();
        let mut v = Vec::new();
        VideoHeader { stream: 0, flags: 0, block: 0, tseq: 1, frame: 1, shard: 0, k: 1, m: 0, shard_size: 2 }
            .write(&mut v);
        v.extend_from_slice(&[1, 2]);
        samples.push(v);
        samples.push(encode_feedback(&[FeedbackSection::Nack {
            stream: 0,
            items: vec![NackItem { frame: 1, block: 0, shard: 0 }],
        }]));
        let mut a = Vec::new();
        AudioDatagram { stream: 0, flags: 0, tseq: 0, aseq: 0, time_us: 0, data: &[1], redundant: vec![(1, &[2][..])] }
            .write(&mut a);
        samples.push(a);
        let mut i = Vec::new();
        InputDatagram { flags: 0, events: vec![InputEventWire { seq: 1, kind: InputKind::Discrete, json: b"{}" }] }
            .write(&mut i);
        samples.push(i);
        for s in &samples {
            for n in 0..s.len() {
                let t = &s[..n];
                let _ = VideoHeader::parse(t);
                let _ = AudioDatagram::parse(t);
                let _ = InputDatagram::parse(t);
                let _ = parse_feedback(t);
                let _ = CursorDatagram::parse(t);
                let _ = FrameMeta::parse(t);
            }
        }
        for _ in 0..20_000 {
            let len = (lcg(&mut seed) % 64) as usize;
            let mut b: Vec<u8> = (0..len).map(|_| lcg(&mut seed) as u8).collect();
            if !b.is_empty() {
                b[0] = ((lcg(&mut seed) % 6) as u8) << 4 | 1;
            }
            let _ = VideoHeader::parse(&b);
            let _ = AudioDatagram::parse(&b);
            let _ = InputDatagram::parse(&b);
            let _ = parse_feedback(&b);
            let _ = CursorDatagram::parse(&b);
            let _ = FrameMeta::parse(&b);
            let _ = media_tseq(&b);
            set_media_tseq(&mut b, 1);
        }
    }
}
