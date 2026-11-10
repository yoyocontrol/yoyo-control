//! The client (phone) side: receives video, audio and cursor datagrams, sends feedback and input.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::audio::{AudioPacket, AudioStreamReceiver};
use crate::cursor::CursorReceiver;
use crate::input::{InputConfig, InputError, InputNotice, InputSender};
use crate::probe::{ProbeReceiver, ProbeRxStats};
use crate::stats::{MediaStats, percentile};
use crate::tcc::ArrivalRecorder;
use crate::time::{Micros, RttWindow, earliest};
use crate::video_rx::{ReceivedFrame, VideoReceiveConfig, VideoRxStats, VideoStreamReceiver};
use crate::wire::{
    self, AudioDatagram, Channel, CursorDatagram, FEEDBACK_HEADER_LEN, FeedbackSection, InputKind, VideoHeader,
    WireError, encode_feedback, parse_feedback,
};

/// Client-side settings.
#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub video: VideoReceiveConfig,
    pub input: InputConfig,
    /// Largest datagram the transport takes now (update with [`ClientMedia::set_max_datagram`]).
    pub max_datagram: usize,
    /// Feedback cadence while media flows.
    pub feedback_interval: Micros,
    /// Feedback stops this long after the last media datagram.
    pub feedback_idle: Micros,
    pub audio_report_interval: Micros,
    /// Every NACK goes again this long after the first (its own datagram; None: once). On 5g a lost NACK can't be
    /// retried before the frame's deadline, so one lost uplink datagram cost the frame and ~250 ms of picture; the
    /// sender ignores a repeat for shards it re-sent within half an RTT.
    pub nack_repeat: Option<Micros>,
}

impl Default for ClientConfig {
    fn default() -> ClientConfig {
        ClientConfig {
            video: VideoReceiveConfig::default(),
            input: InputConfig::default(),
            max_datagram: 1200,
            feedback_interval: Micros::from_millis(25),
            feedback_idle: Micros::from_secs(1),
            audio_report_interval: Micros::from_millis(250),
            nack_repeat: Some(Micros::from_millis(10)),
        }
    }
}

/// What the client app must act on. Drain with [`ClientMedia::poll_event`] after every `handle_*` call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientEvent {
    /// A frame for the decoder, in order, its reference chain intact. Answer with
    /// [`ClientMedia::frame_decoded`].
    Frame(ReceivedFrame),
    /// An Opus packet for the jitter buffer, in `aseq` order (`gap_before` packets are missing before it).
    Audio(AudioPacket),
    /// A newer cursor position (JSON `{x,y,visible,shapeId}`).
    Cursor { stream: u8, cseq: u32, json: Vec<u8> },
    /// Every discrete input event up to `through` arrived at the server.
    InputAcked { through: u32 },
    /// A discrete input event was not acknowledged within 2 s and was dropped.
    InputFailed { seq: u32 },
}

/// The client side of a session's media. Sans-IO: see the crate docs for the calling convention.
pub struct ClientMedia {
    cfg: ClientConfig,
    max_datagram: usize,
    arrivals: ArrivalRecorder,
    /// The 2 s pre-FEC loss, sampled every 500 ms over the last 10 s: its lowest is the path's lasting random
    /// loss (a congestion burst doesn't lift it), for the video deadline (`nack_deadline_loss`).
    loss_samples: VecDeque<(Micros, f64)>,
    video: BTreeMap<u8, VideoStreamReceiver>,
    audio: BTreeMap<u8, AudioStreamReceiver>,
    cursor: BTreeMap<u8, CursorReceiver>,
    closed_video: BTreeSet<u8>,
    closed_audio: BTreeSet<u8>,
    input: InputSender,
    rtt: RttWindow,
    rtt_p50: Micros,
    events: VecDeque<ClientEvent>,
    last_media: Option<Micros>,
    next_feedback: Option<Micros>,
    feedback_now: bool,
    next_audio_report: Micros,
    q_out: VecDeque<Vec<u8>>,
    /// NACK sections to send again, and when (`ClientConfig::nack_repeat`).
    nack_repeat: Option<(Micros, Vec<FeedbackSection>)>,
    frames: Vec<ReceivedFrame>,
    notices: Vec<InputNotice>,
    malformed: u64,
    /// Speed-test streams ([`ClientMedia::open_probe`]): their frames are counted here, not handed out.
    probes: BTreeMap<u8, ProbeReceiver>,
}

impl ClientMedia {
    pub fn new(cfg: ClientConfig) -> ClientMedia {
        ClientMedia {
            max_datagram: cfg.max_datagram,
            input: InputSender::new(cfg.input.clone()),
            cfg,
            arrivals: ArrivalRecorder::default(),
            loss_samples: VecDeque::new(),
            video: BTreeMap::new(),
            audio: BTreeMap::new(),
            cursor: BTreeMap::new(),
            closed_video: BTreeSet::new(),
            closed_audio: BTreeSet::new(),
            rtt: RttWindow::new(Micros::from_secs(10)),
            rtt_p50: Micros::from_millis(100),
            events: VecDeque::new(),
            last_media: None,
            next_feedback: None,
            feedback_now: false,
            next_audio_report: Micros::ZERO,
            q_out: VecDeque::new(),
            nack_repeat: None,
            frames: Vec::new(),
            notices: Vec::new(),
            malformed: 0,
            probes: BTreeMap::new(),
        }
    }

    pub fn set_max_datagram(&mut self, n: usize) {
        self.max_datagram = n;
    }

    /// A round-trip sample from the transport (e.g. QUIC's smoothed RTT, every few hundred ms or on change).
    pub fn set_rtt(&mut self, now: Micros, rtt: Micros) {
        self.rtt.add(now, rtt);
        self.rtt_p50 = self.rtt.percentile(0.5).unwrap_or(rtt);
        self.input.set_rtt(rtt);
        let loss = self.path_loss(now);
        for v in self.video.values_mut() {
            v.set_rtt(rtt, self.rtt_p50);
            v.set_path_loss(loss);
        }
    }

    /// The lowest 2 s loss of the last 10 s (0 until 5 s of samples).
    fn path_loss(&mut self, now: Micros) -> f64 {
        const EVERY: Micros = Micros::from_millis(500);
        const KEEP: Micros = Micros::from_secs(10);
        if self.loss_samples.back().is_none_or(|s| now - s.0 >= EVERY) {
            self.loss_samples.push_back((now, self.arrivals.loss()));
        }
        while self.loss_samples.front().is_some_and(|s| now - s.0 > KEEP) {
            self.loss_samples.pop_front();
        }
        match self.loss_samples.front() {
            Some(first) if now - first.0 >= Micros::from_secs(5) => {
                self.loss_samples.iter().map(|s| s.1).fold(f64::MAX, f64::min)
            }
            _ => 0.0,
        }
    }

    fn rtt_now(&self) -> Micros {
        self.rtt.latest().unwrap_or(self.rtt_p50)
    }

    /// Start receiving video stream `stream` from frame 1 (datagrams of a stream never opened or closed open it
    /// too, so a datagram that beats `video.opened` isn't lost).
    pub fn open_video(&mut self, stream: u8) {
        self.closed_video.remove(&stream);
        let mut v = VideoStreamReceiver::new(stream, self.cfg.video.clone());
        v.set_rtt(self.rtt_now(), self.rtt_p50);
        self.video.insert(stream, v);
        self.cursor.insert(stream, CursorReceiver::default());
    }

    pub fn close_video(&mut self, stream: u8) {
        self.video.remove(&stream);
        self.cursor.remove(&stream);
        self.closed_video.insert(stream);
        self.probes.remove(&stream);
    }

    /// Whether video stream `stream` is open (by `open_video`, `open_probe` or an early datagram).
    pub fn has_video(&self, stream: u8) -> bool {
        self.video.contains_key(&stream)
    }

    /// Opens `stream` for a speed test (docs/LINK.md「测速」): like `open_video`, but its frames never become
    /// [`ClientEvent::Frame`]s — each one is acknowledged as decoded at once and counted
    /// ([`ClientMedia::probe_stats`]). `close_video` ends it.
    pub fn open_probe(&mut self, now: Micros, stream: u8) {
        self.open_video(stream);
        self.probes.insert(stream, ProbeReceiver::new(now));
    }

    /// A speed-test stream's counters so far (None: not a probe stream).
    pub fn probe_stats(&self, now: Micros, stream: u8) -> Option<ProbeRxStats> {
        self.probes.get(&stream).map(|p| p.stats(now))
    }

    pub fn open_audio(&mut self, stream: u8) {
        self.closed_audio.remove(&stream);
        self.audio.insert(stream, AudioStreamReceiver::new(stream));
    }

    pub fn close_audio(&mut self, stream: u8) {
        self.audio.remove(&stream);
        self.closed_audio.insert(stream);
    }

    /// The decoder's verdict on a delivered frame. `ok = false` asks for a key frame.
    /// Every frame's fate since the last call (all streams, in the order they were decided).
    pub fn take_rx_traces(&mut self) -> Vec<crate::trace::RxTrace> {
        let mut out: Vec<_> = self.video.values_mut().flat_map(|v| v.traces.take()).collect();
        out.sort_by_key(|t| t.decided_at);
        out
    }

    pub fn frame_decoded(&mut self, stream: u8, frame: u32, ok: bool) {
        if let Some(v) = self.video.get_mut(&stream) {
            v.decoded(frame, ok);
            if v.urgent {
                self.feedback_now = true;
            }
        }
    }

    /// The decoder can't continue (also tell the server with the control message `keyframe`).
    pub fn request_keyframe(&mut self, stream: u8) {
        if let Some(v) = self.video.get_mut(&stream) {
            v.request_keyframe();
            self.feedback_now = true;
        }
    }

    /// Queue an input event (today's `/input` JSON). Returns its seq. `Overflow` → answer like HTTP 429.
    pub fn send_input(&mut self, now: Micros, kind: InputKind, json: &[u8]) -> Result<u32, InputError> {
        self.input.send(now, kind, json, self.max_datagram)
    }

    pub fn video_stats(&self, stream: u8) -> Option<VideoRxStats> {
        self.video.get(&stream).map(|v| v.stats)
    }

    // MARK: datagrams

    /// A datagram from the server (video, audio, cursor or feedback).
    pub fn handle_datagram(&mut self, now: Micros, d: &[u8]) -> Result<(), WireError> {
        let r = self.handle_inner(now, d);
        if r.is_err() {
            self.malformed += 1;
        }
        self.flush(now);
        r
    }

    fn handle_inner(&mut self, now: Micros, d: &[u8]) -> Result<(), WireError> {
        let ch = wire::channel_of(d)?;
        if ch.is_media() {
            // count every media datagram for the rate controller, even one this side can't use
            if let Some(t) = wire::media_tseq(d) {
                self.arrivals.on_arrival(t, now);
                self.last_media = Some(now);
                self.next_feedback.get_or_insert(now + self.cfg.feedback_interval);
                return self.on_media(now, ch, d);
            }
            return Err(WireError::Short);
        }
        match ch {
            Channel::Feedback => {
                for s in parse_feedback(d)? {
                    if let FeedbackSection::InputAck(through) = s {
                        self.input.on_ack(now, through, &mut self.notices);
                    }
                }
                Ok(())
            }
            c => Err(WireError::Channel(c as u8)),
        }
    }

    fn on_media(&mut self, now: Micros, ch: Channel, d: &[u8]) -> Result<(), WireError> {
        match ch {
            Channel::Video => {
                let (h, payload) = VideoHeader::parse(d)?;
                if self.closed_video.contains(&h.stream) {
                    return Ok(());
                }
                let cfg = &self.cfg.video;
                let (rtt, p50) = (self.rtt.latest().unwrap_or(self.rtt_p50), self.rtt_p50);
                let v = self.video.entry(h.stream).or_insert_with(|| {
                    let mut v = VideoStreamReceiver::new(h.stream, cfg.clone());
                    v.set_rtt(rtt, p50);
                    v
                });
                v.on_shard(now, &h, payload, self.rtt_p50, &mut self.frames);
                Ok(())
            }
            Channel::Audio => {
                let a = AudioDatagram::parse(d)?;
                if self.closed_audio.contains(&a.stream) {
                    return Ok(());
                }
                let rx = self.audio.entry(a.stream).or_insert_with(|| AudioStreamReceiver::new(a.stream));
                let mut out = Vec::new();
                rx.on_datagram(&a, &mut out);
                self.events.extend(out.into_iter().map(ClientEvent::Audio));
                Ok(())
            }
            Channel::Cursor => {
                let c = CursorDatagram::parse(d)?;
                if self.closed_video.contains(&c.stream) {
                    return Ok(());
                }
                if self.cursor.entry(c.stream).or_default().accept(c.cseq) {
                    self.events.push_back(ClientEvent::Cursor {
                        stream: c.stream,
                        cseq: c.cseq,
                        json: c.json.to_vec(),
                    });
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// Move delivered frames / input notices into events; NACKs or a loss make feedback go at once.
    fn flush(&mut self, now: Micros) {
        for v in self.video.values_mut() {
            if v.collect_nacks(now) || v.urgent {
                self.feedback_now = true;
            }
        }
        for f in std::mem::take(&mut self.frames) {
            match self.probes.get_mut(&f.stream) {
                Some(p) => {
                    p.on_frame(&f);
                    if let Some(v) = self.video.get_mut(&f.stream) {
                        v.decoded(f.frame, true);
                        if v.urgent {
                            self.feedback_now = true;
                        }
                    }
                }
                None => self.events.push_back(ClientEvent::Frame(f)),
            }
        }
        for n in self.notices.drain(..) {
            self.events.push_back(match n {
                InputNotice::Acked { through } => ClientEvent::InputAcked { through },
                InputNotice::Failed { seq } => ClientEvent::InputFailed { seq },
            });
        }
    }

    /// The next datagram to hand to the transport, or None. Call until None after every `send_input` /
    /// `handle_*`. Input goes first, then feedback.
    pub fn poll_transmit(&mut self, now: Micros) -> Option<Vec<u8>> {
        let input = self.input.poll_transmit(now, self.max_datagram, &mut self.notices);
        if !self.notices.is_empty() {
            self.flush(now);
        }
        if input.is_some() {
            return input;
        }
        if let Some(d) = self.q_out.pop_front() {
            return Some(d);
        }
        if self.nack_repeat.as_ref().is_some_and(|r| r.0 <= now) {
            let (_, sections) = self.nack_repeat.take().unwrap_or_default();
            self.pack(sections);
        }
        if self.feedback_now || self.next_feedback.is_some_and(|t| t <= now) {
            self.build_feedback(now);
        }
        self.q_out.pop_front()
    }

    fn build_feedback(&mut self, now: Micros) {
        self.feedback_now = false;
        let max = self.max_datagram.max(64);
        let mut sections: Vec<FeedbackSection> = Vec::new();
        let per_nack = (max - FEEDBACK_HEADER_LEN - 6) / 7;
        for v in self.video.values_mut() {
            let nacks = v.take_nacks();
            for chunk in nacks.chunks(per_nack.max(1)) {
                sections.push(FeedbackSection::Nack { stream: v.id, items: chunk.to_vec() });
            }
        }
        if let Some(after) = self.cfg.nack_repeat {
            let nacks: Vec<FeedbackSection> =
                sections.iter().filter(|s| matches!(s, FeedbackSection::Nack { .. })).cloned().collect();
            if !nacks.is_empty() {
                let r = self.nack_repeat.get_or_insert((now + after, Vec::new()));
                r.1.extend(nacks);
            }
        }
        for v in self.video.values_mut() {
            let mut r = v.report(now);
            r.lost.truncate((max - FEEDBACK_HEADER_LEN - 11) / 4);
            sections.push(FeedbackSection::FrameReport(r));
        }
        if now >= self.next_audio_report && !self.audio.is_empty() {
            self.next_audio_report = now + self.cfg.audio_report_interval;
            for a in self.audio.values() {
                sections.push(FeedbackSection::AudioReport { stream: a.id, loss_permille: a.loss_permille() });
            }
        }
        if self.arrivals.has_pending() {
            for t in self.arrivals.take_sections(now, max - FEEDBACK_HEADER_LEN) {
                sections.push(FeedbackSection::TransportCc(t));
            }
        }
        self.pack(sections);
        self.next_feedback =
            self.last_media.filter(|&t| now - t < self.cfg.feedback_idle).map(|_| now + self.cfg.feedback_interval);
    }

    /// Feedback sections into datagrams (greedily) on the outgoing queue.
    fn pack(&mut self, sections: Vec<FeedbackSection>) {
        let max = self.max_datagram.max(64);
        let mut cur: Vec<FeedbackSection> = Vec::new();
        let mut size = FEEDBACK_HEADER_LEN;
        for s in sections {
            let l = s.wire_len();
            if !cur.is_empty() && (size + l > max || cur.len() == 255) {
                self.q_out.push_back(encode_feedback(&cur));
                cur.clear();
                size = FEEDBACK_HEADER_LEN;
            }
            size += l;
            cur.push(s);
        }
        if !cur.is_empty() {
            self.q_out.push_back(encode_feedback(&cur));
        }
    }

    pub fn poll_event(&mut self) -> Option<ClientEvent> {
        self.events.pop_front()
    }

    /// When to call [`ClientMedia::handle_timeout`] next (None: no timer needed).
    pub fn poll_timeout(&self, now: Micros) -> Option<Micros> {
        if self.feedback_now || !self.q_out.is_empty() {
            return Some(now);
        }
        let mut t = earliest(self.input.poll_timeout(now), self.next_feedback);
        t = earliest(t, self.nack_repeat.as_ref().map(|r| r.0));
        for v in self.video.values() {
            t = earliest(t, v.next_timeout(now));
        }
        t
    }

    pub fn handle_timeout(&mut self, now: Micros) {
        for v in self.video.values_mut() {
            v.advance(now, &mut self.frames);
        }
        self.flush(now);
    }

    /// The media side of the stats line.
    pub fn stats(&self, now: Micros) -> MediaStats {
        let mut s = MediaStats {
            at_us: now.0,
            rtt_min_ms: self.rtt.min().map(|r| r.as_millis_f64()),
            rtt_p50_ms: self.rtt.percentile(0.5).map(|r| r.as_millis_f64()),
            rtt_p90_ms: self.rtt.percentile(0.9).map(|r| r.as_millis_f64()),
            loss_pct: Some(self.arrivals.loss() * 100.0),
            media_received: self.arrivals.received,
            media_missing: self.arrivals.missing,
            input_p50_ms: percentile(self.input.rtts.iter().copied(), 0.5),
            input_p90_ms: percentile(self.input.rtts.iter().copied(), 0.9),
            input_events: self.input.acked_events,
            input_failed: self.input.failed,
            ..Default::default()
        };
        let mut fps = 0.0;
        for v in self.video.values() {
            let st = &v.stats;
            s.fec_recovered += st.fec_recovered;
            s.nack_recovered += st.nack_recovered;
            s.nack_sent += st.nack_sent;
            s.frames_delivered += st.frames_delivered;
            s.frames_lost += st.frames_lost;
            s.frames_skipped += st.frames_skipped;
            s.freezes += st.freezes;
            s.freeze_ms += st.freeze_us / 1000;
            if let Some(f) = v.ongoing_freeze(now) {
                s.freezes += 1;
                s.freeze_ms += f.0 / 1000;
            }
            fps += v.fps(now);
        }
        if !self.video.is_empty() {
            s.fps = Some(fps);
        }
        if !self.audio.is_empty() {
            s.audio_loss_pct = self.audio.values().map(|a| a.loss_permille() as f64 / 10.0).reduce(f64::max);
            s.audio_lost = self.audio.values().map(|a| a.stats.lost).sum();
            s.audio_recovered = self.audio.values().map(|a| a.stats.recovered).sum();
        }
        s
    }

    /// Datagrams refused as malformed or arriving on a channel this side doesn't receive.
    pub fn malformed(&self) -> u64 {
        self.malformed
    }

    /// Discrete input events waiting for an ack.
    pub fn input_unacked(&self) -> usize {
        self.input.unacked()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{ServerConfig, ServerMedia};
    use crate::wire::{Codec, FrameKind, FrameMeta};

    fn nack_times(d: &[u8], at: Micros, out: &mut Vec<Micros>) {
        if let Ok(sections) = parse_feedback(d)
            && sections.iter().any(|s| matches!(s, FeedbackSection::Nack { .. }))
        {
            out.push(at);
        }
    }

    #[test]
    fn a_nack_goes_twice() {
        let mut server = ServerMedia::new(ServerConfig::default());
        let mut client = ClientMedia::new(ClientConfig::default());
        server.open_video(1);
        client.open_video(1);
        let mut now = Micros::from_secs(1);
        client.set_rtt(now, Micros::from_millis(60));
        server.handle_timeout(now);
        let meta = FrameMeta {
            codec: Codec::H264,
            kind: FrameKind::Key,
            width: 100,
            height: 100,
            capture_us: 0,
            recovery_base: 0,
            au_len: 0,
        };
        server.send_frame(now, 1, meta, &vec![1u8; 40_000]).unwrap();
        // every datagram of the frame but four data shards in its first block (more than its parity can restore)
        let mut i = 0;
        let mut nacks = Vec::new();
        while now < Micros::from_millis(1300) {
            while let Some(d) = server.poll_transmit(now) {
                if !(3..=6).contains(&i) {
                    let _ = client.handle_datagram(now, &d);
                }
                i += 1;
            }
            while let Some(d) = client.poll_transmit(now) {
                nack_times(&d, now, &mut nacks);
            }
            client.handle_timeout(now);
            now += Micros::from_millis(1);
        }
        assert!(nacks.len() >= 2, "{nacks:?}");
        let gap = nacks[1] - nacks[0];
        assert!(gap >= Micros::from_millis(9) && gap <= Micros::from_millis(12), "{nacks:?}");
    }
}
