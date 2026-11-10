//! Video sender for one stream: frame → blocks → data + parity shards, the retransmit cache answering NACKs, and
//! the frame reports → encoder hooks (LTR acks, recovery, key frames).

use std::collections::VecDeque;

use crate::fec::{self, FecPolicy};
use crate::time::Micros;
use crate::wire::{FrameKind, FrameMeta, FrameReport, NackItem, VideoHeader, report_flags, video_flags};

/// Video sender settings.
#[derive(Clone, Debug)]
pub struct VideoSendConfig {
    /// The stream's highest frame rate; a frame budget is `target / fps` (backpressure).
    pub fps: f64,
    /// Sent shards are kept this long for retransmits.
    pub retransmit_cache: Micros,
    /// `can_send_frame` is false while more than this many frame budgets wait unsent.
    pub queued_budgets: f64,
    pub fec: FecPolicy,
    /// A recovery / key frame request is repeated if the app hasn't answered it in this long.
    pub rerequest_after: Micros,
    /// A NACK also asks the app for a recovery frame at once (`RecoveryNeeded`), in parallel with the retransmit:
    /// if the retransmit fails, the recovery frame is already on its way and the picture resumes about one RTT
    /// after the loss was noticed instead of two. Costs a recovery frame per NACK episode, cheap with long-term
    /// references (VideoToolbox LTR) but a key frame per episode where recovery means a key frame (x264 today) —
    /// so off by default; the Mac sender turns it on. A NACK for a frame no longer in the cache always asks.
    pub recovery_on_nack: bool,
    /// NACK-triggered recovery requests at most this often (a lossy path NACKs nearly every frame).
    pub recovery_on_nack_every: Micros,
    /// The frame-rate cap by encoder rate: `(encoder bits/s at least, frames/s)`, highest first, never above
    /// `fps`. At a low rate many frames each get few bits — text a scroll moves is a smear, and the key frames that
    /// recover a loss are blurry; fewer frames get more bits each (an encoder that budgets per frame needs to be
    /// told: [`crate::ServerMedia::frame_rate_cap`]). A step up needs `fps_step_up ×` its rate (no flapping at a
    /// boundary). [`crate::ServerMedia::can_send_frame`] holds a frame that would come sooner than
    /// `fps_early × 1 / cap` after the previous one.
    pub fps_steps: Vec<(u64, f64)>,
    pub fps_step_up: f64,
    pub fps_early: f64,
}

impl Default for VideoSendConfig {
    fn default() -> VideoSendConfig {
        VideoSendConfig {
            fps: 60.0,
            retransmit_cache: Micros::from_millis(600),
            queued_budgets: 1.5,
            fec: FecPolicy::default(),
            rerequest_after: Micros::from_secs(1),
            recovery_on_nack: false,
            recovery_on_nack_every: Micros::from_millis(500),
            fps_steps: vec![(3_500_000, 60.0), (1_300_000, 30.0), (700_000, 20.0), (400_000, 15.0), (0, 10.0)],
            fps_step_up: 1.2,
            fps_early: 0.85,
        }
    }
}

/// Why a frame could not be sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SendError {
    /// The stream isn't open.
    UnknownStream,
    /// Empty, or larger than 256 blocks of 32 shards.
    BadSize,
    /// The datagram size leaves no room for a shard.
    DatagramTooSmall,
}

impl std::fmt::Display for SendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SendError::UnknownStream => write!(f, "unknown stream"),
            SendError::BadSize => write!(f, "frame size out of range"),
            SendError::DatagramTooSmall => write!(f, "datagram size too small"),
        }
    }
}

impl std::error::Error for SendError {}

/// What the sender tells the app about one stream (the composite turns these into events).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TxNotice {
    Delivered(u32),
    RecoveryNeeded(Option<u32>),
    KeyframeNeeded,
}

struct SentBlock {
    k: u16,
    m: u16,
    shard_size: u16,
    /// Data then parity payloads.
    shards: Vec<Vec<u8>>,
    last_retx: Vec<Option<Micros>>,
}

struct SentFrame {
    frame: u32,
    at: Micros,
    flags: u8,
    blocks: Vec<SentBlock>,
}

/// Per-stream sender counters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VideoTxStats {
    pub frames: u64,
    pub key_frames: u64,
    pub recovery_frames: u64,
    pub data_shards: u64,
    pub parity_shards: u64,
    pub bytes: u64,
    /// Shards re-sent for NACKs.
    pub retransmits: u64,
    /// NACKed shards no longer (or never) in the cache.
    pub nack_misses: u64,
    /// Frames the receiver reported lost (distinct).
    pub lost_reported: u64,
}

pub(crate) struct VideoStreamSender {
    pub(crate) id: u8,
    cfg: VideoSendConfig,
    next_frame: u32,
    history: VecDeque<SentFrame>,
    /// Exponential average of on-wire delta frame sizes (bytes, parity included).
    pub(crate) frame_estimate: f64,
    last_delivered: u32,
    /// The newest frame number of a key or recovery frame sent: losses before it are old news.
    recovery_epoch: u32,
    recovery_asked: Option<Micros>,
    last_speculative: Option<Micros>,
    key_asked: Option<Micros>,
    recent_lost: VecDeque<u32>,
    pub(crate) stats: VideoTxStats,
    /// FEC ratio used for the newest frame (stats / encoder budget).
    pub(crate) fec_ratio: f64,
    /// The frame-rate cap (`fps_steps`) and when the newest frame was sent.
    fps_cap: f64,
    last_frame_at: Option<Micros>,
}

impl VideoStreamSender {
    pub(crate) fn new(id: u8, cfg: VideoSendConfig) -> VideoStreamSender {
        VideoStreamSender {
            id,
            next_frame: 1,
            history: VecDeque::new(),
            frame_estimate: 0.0,
            last_delivered: 0,
            recovery_epoch: 0,
            recovery_asked: None,
            last_speculative: None,
            key_asked: None,
            recent_lost: VecDeque::new(),
            stats: VideoTxStats::default(),
            fec_ratio: FecPolicy::default().ratio(0.0),
            fps_cap: cfg.fps,
            last_frame_at: None,
            cfg,
        }
    }

    /// The frame-rate cap.
    pub(crate) fn fps_cap(&self) -> f64 {
        self.fps_cap
    }

    /// Update the cap for an encoder rate of `encoder_bps` (`fps_steps`, with the step-up margin).
    pub(crate) fn set_encoder_rate(&mut self, encoder_bps: u64) {
        let fps = self.cfg.fps.max(1.0);
        let step =
            |bps: f64| -> f64 { self.cfg.fps_steps.iter().find(|s| bps >= s.0 as f64).map_or(fps, |s| s.1).min(fps) };
        let down = step(encoder_bps as f64);
        let up = step(encoder_bps as f64 / self.cfg.fps_step_up);
        // lower at once; higher only with the margin
        self.fps_cap = if down < self.fps_cap { down } else { self.fps_cap.max(up) };
    }

    /// A frame now would come sooner after the previous one than the cap allows.
    pub(crate) fn too_soon(&self, now: Micros) -> bool {
        self.fps_cap < self.cfg.fps
            && self.last_frame_at.is_some_and(|t| now - t < Micros::from_secs_f64(self.cfg.fps_early / self.fps_cap))
    }

    pub(crate) fn config(&self) -> &VideoSendConfig {
        &self.cfg
    }

    /// Cut a frame into shard datagrams (tseq = 0, stamped when handed out) appended to `out`. Returns the frame
    /// number.
    pub(crate) fn send_frame(
        &mut self,
        now: Micros,
        meta: FrameMeta,
        au: &[u8],
        loss: f64,
        max_datagram: usize,
        out: &mut VecDeque<Vec<u8>>,
    ) -> Result<u32, SendError> {
        let max_shard = fec::max_shard_size(max_datagram).min(u16::MAX as usize & !1);
        if max_shard < 2 {
            return Err(SendError::DatagramTooSmall);
        }
        let mut bytes = Vec::with_capacity(FrameMeta::LEN + au.len());
        let meta = FrameMeta { au_len: au.len() as u32, ..meta };
        if au.len() > u32::MAX as usize {
            return Err(SendError::BadSize);
        }
        meta.write(&mut bytes);
        bytes.extend_from_slice(au);
        let plan = fec::plan_blocks(bytes.len(), max_shard).ok_or(SendError::BadSize)?;
        let frame = self.next_frame;
        self.next_frame = self.next_frame.wrapping_add(1).max(1);
        self.last_frame_at = Some(now);

        let key = meta.kind == FrameKind::Key;
        let recovery = meta.kind == FrameKind::Recovery;
        let mut flags = 0;
        if key {
            flags |= video_flags::KEY;
        }
        if recovery {
            flags |= video_flags::RECOVERY;
        }
        let single = plan.len() == 1 && plan[0].k == 1;
        self.fec_ratio = self.cfg.fec.ratio(loss);
        let mut blocks = Vec::with_capacity(plan.len());
        let mut wire_bytes = 0usize;
        for (bi, b) in plan.iter().enumerate() {
            let mut data: Vec<Vec<u8>> = (0..b.k)
                .map(|i| {
                    let start = b.offset + i * b.shard_size;
                    let end = (start + b.shard_size).min(b.offset + b.len);
                    let mut s = bytes[start..end].to_vec();
                    s.resize(b.shard_size, 0);
                    s
                })
                .collect();
            let m = self.cfg.fec.parity(b.k, loss, key, recovery, single);
            let parity = fec::encode_parity(&data, m);
            let m = parity.len();
            let last = bi + 1 == plan.len();
            let block_flags = flags | if last { video_flags::LAST_BLOCK } else { 0 };
            data.extend(parity);
            for (si, shard) in data.iter().enumerate() {
                let h = VideoHeader {
                    stream: self.id,
                    flags: block_flags | if si >= b.k { video_flags::PARITY } else { 0 },
                    block: bi as u8,
                    tseq: 0,
                    frame,
                    shard: si as u16,
                    k: b.k as u16,
                    m: m as u16,
                    shard_size: b.shard_size as u16,
                };
                let mut d = Vec::with_capacity(VideoHeader::LEN + shard.len());
                h.write(&mut d);
                d.extend_from_slice(shard);
                wire_bytes += d.len();
                out.push_back(d);
            }
            self.stats.data_shards += b.k as u64;
            self.stats.parity_shards += m as u64;
            blocks.push(SentBlock {
                k: b.k as u16,
                m: m as u16,
                shard_size: b.shard_size as u16,
                last_retx: vec![None; data.len()],
                shards: data,
            });
        }
        self.stats.frames += 1;
        self.stats.bytes += wire_bytes as u64;
        if key {
            self.stats.key_frames += 1;
        }
        if recovery {
            self.stats.recovery_frames += 1;
        }
        if key || recovery {
            self.recovery_epoch = frame;
            self.recovery_asked = None;
            if key {
                self.key_asked = None;
            }
        } else {
            let w = wire_bytes as f64;
            self.frame_estimate = if self.frame_estimate == 0.0 { w } else { 0.8 * self.frame_estimate + 0.2 * w };
        }
        self.history.push_back(SentFrame { frame, at: now, flags, blocks });
        self.trim(now);
        Ok(frame)
    }

    fn trim(&mut self, now: Micros) {
        while self.history.front().is_some_and(|f| now - f.at > self.cfg.retransmit_cache) {
            self.history.pop_front();
        }
    }

    fn find(&mut self, frame: u32) -> Option<&mut SentFrame> {
        let first = self.history.front()?.frame;
        let i = frame.checked_sub(first)? as usize;
        let f = self.history.get_mut(i)?;
        (f.frame == frame).then_some(f)
    }

    /// NACKed shards → retransmit datagrams (flag 0x02) appended to `out`. A shard re-sent within the last
    /// `min_gap` is not sent again (a duplicate NACK).
    pub(crate) fn on_nack(
        &mut self,
        now: Micros,
        items: &[NackItem],
        min_gap: Micros,
        out: &mut VecDeque<Vec<u8>>,
        notices: &mut Vec<TxNotice>,
    ) {
        self.trim(now);
        let id = self.id;
        let mut sent = 0u64;
        let mut misses = 0u64;
        let (epoch, next) = (self.recovery_epoch, self.next_frame);
        // a NACK for a frame after the newest key / recovery frame: the chain is at risk
        let at_risk = |f: u32| f >= epoch && f < next && f != 0;
        let speculative = self.cfg.recovery_on_nack
            && self.last_speculative.is_none_or(|t| now - t >= self.cfg.recovery_on_nack_every)
            && items.iter().any(|i| at_risk(i.frame));
        let mut ask = speculative;
        for item in items {
            let Some(f) = self.find(item.frame) else {
                misses += 1;
                // can't be retransmitted: the receiver will lose it
                ask |= at_risk(item.frame);
                continue;
            };
            let nblocks = f.blocks.len();
            let (frame, flags) = (f.frame, f.flags);
            let mut wanted: Vec<(usize, usize)> = Vec::new();
            let b = item.block as usize;
            match item.shard {
                NackItem::WHOLE_BLOCK | NackItem::BLOCK_AND_LATER => {
                    let end = if item.shard == NackItem::WHOLE_BLOCK { (b + 1).min(nblocks) } else { nblocks };
                    // data and parity: one lost retransmit doesn't sink the block
                    for bi in b..end {
                        for si in 0..f.blocks[bi].shards.len() {
                            wanted.push((bi, si));
                        }
                    }
                    if b >= nblocks {
                        misses += 1;
                    }
                }
                s => {
                    if b < nblocks && (s as usize) < f.blocks[b].shards.len() {
                        wanted.push((b, s as usize));
                    } else {
                        misses += 1;
                    }
                }
            }
            for (bi, si) in wanted {
                let blk = &mut f.blocks[bi];
                if blk.last_retx[si].is_some_and(|t| now - t < min_gap) {
                    continue;
                }
                blk.last_retx[si] = Some(now);
                let last = bi + 1 == nblocks;
                let h = VideoHeader {
                    stream: id,
                    flags: flags
                        | video_flags::RETRANSMIT
                        | if last { video_flags::LAST_BLOCK } else { 0 }
                        | if si >= blk.k as usize { video_flags::PARITY } else { 0 },
                    block: bi as u8,
                    tseq: 0,
                    frame,
                    shard: si as u16,
                    k: blk.k,
                    m: blk.m,
                    shard_size: blk.shard_size,
                };
                let mut d = Vec::with_capacity(VideoHeader::LEN + blk.shards[si].len());
                h.write(&mut d);
                d.extend_from_slice(&blk.shards[si]);
                out.push_back(d);
                sent += 1;
            }
        }
        self.stats.retransmits += sent;
        self.stats.nack_misses += misses;
        if ask {
            if speculative {
                self.last_speculative = Some(now);
            }
            self.ask_recovery(now, notices);
        }
    }

    /// Ask the app for a recovery frame, at most once per `rerequest_after` until one is sent.
    fn ask_recovery(&mut self, now: Micros, out: &mut Vec<TxNotice>) {
        if self.recovery_asked.is_none_or(|t| now - t >= self.cfg.rerequest_after) {
            self.recovery_asked = Some(now);
            out.push(TxNotice::RecoveryNeeded((self.last_delivered != 0).then_some(self.last_delivered)));
        }
    }

    /// A frame report → notices for the app.
    pub(crate) fn on_report(&mut self, now: Micros, r: &FrameReport, out: &mut Vec<TxNotice>) {
        if r.last_delivered > self.last_delivered && r.last_delivered < self.next_frame {
            self.last_delivered = r.last_delivered;
            out.push(TxNotice::Delivered(r.last_delivered));
        }
        let mut new_loss = false;
        for &f in &r.lost {
            if f == 0 || f >= self.next_frame || self.recent_lost.contains(&f) {
                continue;
            }
            self.recent_lost.push_back(f);
            if self.recent_lost.len() > 128 {
                self.recent_lost.pop_front();
            }
            self.stats.lost_reported += 1;
            if f >= self.recovery_epoch {
                new_loss = true;
            }
        }
        // a repeated loss (still unanswered) is re-requested after a while
        let pending_loss = r.lost.iter().any(|&f| f >= self.recovery_epoch && f < self.next_frame && f != 0);
        if new_loss || pending_loss {
            self.ask_recovery(now, out);
        }
        if r.flags & report_flags::KEYFRAME_NEEDED != 0 {
            self.request_key(now, out);
        }
    }

    /// The receiver (control message or report flag) needs a key frame.
    pub(crate) fn request_key(&mut self, now: Micros, out: &mut Vec<TxNotice>) {
        if self.key_asked.is_none_or(|t| now - t >= self.cfg.rerequest_after) {
            self.key_asked = Some(now);
            out.push(TxNotice::KeyframeNeeded);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Codec;

    fn meta(kind: FrameKind) -> FrameMeta {
        FrameMeta { codec: Codec::H264, kind, width: 100, height: 100, capture_us: 0, recovery_base: 0, au_len: 0 }
    }

    #[test]
    fn shards_and_retransmits() {
        let mut s = VideoStreamSender::new(1, VideoSendConfig::default());
        let mut q = VecDeque::new();
        let au = vec![7u8; 5000];
        let f = s.send_frame(Micros(0), meta(FrameKind::Key), &au, 0.0, 1200, &mut q).unwrap();
        assert_eq!(f, 1);
        // 5024 bytes / 1180 → 5 data shards + ceil(5 × 0.15) = 1 parity
        assert_eq!(q.len(), 6);
        let (h, _) = VideoHeader::parse(&q[0]).unwrap();
        assert_eq!((h.k, h.m), (5, 1));
        assert!(h.flags & video_flags::KEY != 0 && h.flags & video_flags::LAST_BLOCK != 0);
        assert!(q.iter().all(|d| d.len() <= 1200));
        q.clear();
        s.on_nack(Micros(1000), &[NackItem { frame: 1, block: 0, shard: 2 }], Micros(10_000), &mut q, &mut Vec::new());
        assert_eq!(q.len(), 1);
        let (h, _) = VideoHeader::parse(&q[0]).unwrap();
        assert!(h.flags & video_flags::RETRANSMIT != 0 && h.shard == 2);
        // duplicate NACK within the gap: nothing
        s.on_nack(Micros(2000), &[NackItem { frame: 1, block: 0, shard: 2 }], Micros(10_000), &mut q, &mut Vec::new());
        assert_eq!(q.len(), 1);
        // whole frame
        q.clear();
        s.on_nack(
            Micros(20_000),
            &[NackItem { frame: 1, block: 0, shard: NackItem::BLOCK_AND_LATER }],
            Micros(10_000),
            &mut q,
            &mut Vec::new(),
        );
        assert_eq!(q.len(), 6);
        // expired
        q.clear();
        s.on_nack(
            Micros::from_millis(700),
            &[NackItem { frame: 1, block: 0, shard: 0 }],
            Micros(0),
            &mut q,
            &mut Vec::new(),
        );
        assert!(q.is_empty());
        assert_eq!(s.stats.nack_misses, 1);
    }

    #[test]
    fn nack_asks_for_recovery_when_configured_or_hopeless() {
        let ms = Micros::from_millis;
        let nack = |f| [NackItem { frame: f, block: 0, shard: 0 }];
        let mut q = VecDeque::new();
        // off (default): a NACK is only answered with retransmits …
        let mut s = VideoStreamSender::new(0, VideoSendConfig::default());
        for i in 0..3 {
            let kind = if i == 0 { FrameKind::Key } else { FrameKind::Delta };
            s.send_frame(ms(0), meta(kind), &[1; 100], 0.0, 1200, &mut q).unwrap();
        }
        let mut n = Vec::new();
        s.on_nack(ms(10), &nack(2), ms(1), &mut q, &mut n);
        assert!(n.is_empty());
        // … unless the frame is gone from the cache: then the receiver will lose it
        s.on_nack(ms(700), &nack(3), ms(1), &mut q, &mut n);
        assert_eq!(n, vec![TxNotice::RecoveryNeeded(None)]);
        // on: every NACK episode asks at once, at most every 500 ms
        let mut s = VideoStreamSender::new(0, VideoSendConfig { recovery_on_nack: true, ..Default::default() });
        for i in 0..3 {
            let kind = if i == 0 { FrameKind::Key } else { FrameKind::Delta };
            s.send_frame(ms(0), meta(kind), &[1; 100], 0.0, 1200, &mut q).unwrap();
        }
        let mut n = Vec::new();
        s.on_nack(ms(10), &nack(2), ms(1), &mut q, &mut n);
        assert_eq!(n, vec![TxNotice::RecoveryNeeded(None)]);
        s.send_frame(ms(20), FrameMeta { recovery_base: 1, ..meta(FrameKind::Recovery) }, &[1], 0.0, 1200, &mut q)
            .unwrap();
        s.on_nack(ms(30), &nack(4), ms(1), &mut q, &mut n);
        assert_eq!(n.len(), 1);
        s.on_nack(ms(600), &nack(4), ms(1), &mut q, &mut n);
        assert_eq!(n.len(), 2);
    }

    #[test]
    fn recovery_notices() {
        let mut s = VideoStreamSender::new(0, VideoSendConfig::default());
        let mut q = VecDeque::new();
        for i in 0..5 {
            let kind = if i == 0 { FrameKind::Key } else { FrameKind::Delta };
            s.send_frame(Micros(0), meta(kind), &[1, 2, 3], 0.0, 1200, &mut q).unwrap();
        }
        let mut out = Vec::new();
        let r = FrameReport { stream: 0, last_delivered: 2, lost: vec![3], flags: 0 };
        s.on_report(Micros(0), &r, &mut out);
        assert_eq!(out, vec![TxNotice::Delivered(2), TxNotice::RecoveryNeeded(Some(2))]);
        out.clear();
        // repeated report: nothing new until the re-request time
        s.on_report(Micros(1000), &r, &mut out);
        assert!(out.is_empty());
        // the app sends a recovery frame (6); the old loss is old news
        s.send_frame(
            Micros(2000),
            FrameMeta { recovery_base: 2, ..meta(FrameKind::Recovery) },
            &[1],
            0.0,
            1200,
            &mut q,
        )
        .unwrap();
        s.on_report(Micros::from_secs(2), &r, &mut out);
        assert!(out.is_empty());
        // the recovery frame itself got lost
        s.on_report(Micros::from_secs(2), &FrameReport { lost: vec![3, 6], ..r.clone() }, &mut out);
        assert_eq!(out, vec![TxNotice::RecoveryNeeded(Some(2))]);
    }
}
