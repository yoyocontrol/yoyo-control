//! The server (computer) side: sends video, audio and cursor datagrams, receives feedback and input.

use std::collections::{BTreeMap, VecDeque};

use crate::audio::AudioStreamSender;
use crate::cursor::CursorSender;
use crate::input::{InputEvent, InputReceiver};
use crate::rate::{NetworkProfile, RateConfig, RateController, TargetRate};
use crate::stats::MediaStats;
use crate::tcc::SendHistory;
use crate::time::{Micros, RttWindow, earliest};
use crate::trace::{TraceQueue, TxTrace};
use crate::video_tx::{SendError, TxNotice, VideoSendConfig, VideoStreamSender, VideoTxStats};
use crate::wire::{
    self, Channel, FeedbackSection, FrameMeta, InputDatagram, VideoHeader, WireError, encode_feedback, parse_feedback,
    video_flags,
};

/// Server-side settings.
#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub rate: RateConfig,
    pub video: VideoSendConfig,
    /// Largest datagram the transport takes now (update with [`ServerMedia::set_max_datagram`]).
    pub max_datagram: usize,
    /// `TargetBitrate` increases are reported at most this often (decreases at once).
    pub target_increase_interval: Micros,
}

impl Default for ServerConfig {
    fn default() -> ServerConfig {
        ServerConfig {
            rate: RateConfig::default(),
            video: VideoSendConfig::default(),
            max_datagram: 1200,
            target_increase_interval: Micros::from_millis(200),
        }
    }
}

/// What the server app must act on. Drain with [`ServerMedia::poll_event`] after every `handle_*` call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServerEvent {
    /// The rate controller's target changed. `encoder_bps` is what the video encoder should aim at per video
    /// stream: `(target − audio) × (1 − FEC ratio) × 0.95` (headers), split evenly over the open video streams.
    TargetBitrate { target_bps: u64, encoder_bps: u64 },
    /// The receiver decoded `frame` OK (newest so far): pass its LTR token as acknowledged on later encodes.
    FrameDelivered { stream: u8, frame: u32 },
    /// The receiver lost a frame. Encode the next frame as a recovery frame (kind 4, `recovery_base` = the newest
    /// `FrameDelivered` frame whose LTR is acknowledged) or, with nothing delivered / no LTR, as a key frame.
    /// Repeated after 1 s if unanswered.
    RecoveryNeeded { stream: u8, last_delivered: Option<u32> },
    /// The receiver's decoder needs a key frame (at most one per 500 ms is the app's rule).
    KeyframeNeeded { stream: u8 },
    /// An input event, in order, exactly once (discrete) / latest only (moves).
    Input(InputEvent),
}

/// Why [`ServerMedia::can_send_frame`] says what it says, with the numbers it decided on (bytes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SendGate {
    pub open: bool,
    /// Closed because the bytes waiting exceed `limit`.
    pub over_queue: bool,
    /// Closed because the transport's free buffer can't hold `estimate`.
    pub over_space: bool,
    /// Closed because the previous frame went out less than the frame-rate cap's interval ago.
    pub too_soon: bool,
    /// The frame-rate cap ([`crate::VideoSendConfig::fps_steps`]).
    pub fps_cap: f64,
    /// This crate's video, retransmit and audio queues.
    pub own_queued: u64,
    pub transport_queued: u64,
    pub transport_space: Option<u64>,
    /// One frame's share of the target (`target / fps cap / streams`) and `queued_budgets ×` it.
    pub budget: u64,
    pub limit: u64,
    /// The next frame's expected size.
    pub estimate: u64,
    pub target_bps: u64,
    pub pacing_bps: u64,
}

/// A frame's trace waits this long for its report at most.
const TRACE_KEEP: Micros = Micros::from_secs(3);

/// The server side of a session's media. Sans-IO: see the crate docs for the calling convention.
pub struct ServerMedia {
    cfg: ServerConfig,
    max_datagram: usize,
    rate: RateController,
    history: SendHistory,
    rtt: RttWindow,
    video: BTreeMap<u8, VideoStreamSender>,
    audio: BTreeMap<u8, AudioStreamSender>,
    cursor: BTreeMap<u8, CursorSender>,
    input: InputReceiver,
    q_feedback: VecDeque<Vec<u8>>,
    q_audio: VecDeque<Vec<u8>>,
    q_retx: VecDeque<Vec<u8>>,
    q_video: VecDeque<Vec<u8>>,
    queued_video_bytes: usize,
    events: VecDeque<ServerEvent>,
    emitted: Option<(u64, u64, Micros)>,
    /// Video release pacing: byte credit and when it was last topped up.
    pace_credit: f64,
    pace_at: Option<Micros>,
    /// The video queues were empty at the last poll: the next frame starts with a full burst.
    pace_idle: bool,
    sent_bytes: u64,
    target_due: Option<Micros>,
    notices: Vec<TxNotice>,
    malformed: u64,
    /// Frames on their way (per-frame traces), oldest first, and the finished ones.
    tx_pending: VecDeque<TxTrace>,
    tx_done: TraceQueue<TxTrace>,
}

impl ServerMedia {
    pub fn new(cfg: ServerConfig) -> ServerMedia {
        ServerMedia {
            max_datagram: cfg.max_datagram,
            rate: RateController::new(cfg.rate.clone()),
            cfg,
            history: SendHistory::default(),
            rtt: RttWindow::new(Micros::from_secs(10)),
            video: BTreeMap::new(),
            audio: BTreeMap::new(),
            cursor: BTreeMap::new(),
            input: InputReceiver::default(),
            q_feedback: VecDeque::new(),
            q_audio: VecDeque::new(),
            q_retx: VecDeque::new(),
            q_video: VecDeque::new(),
            queued_video_bytes: 0,
            events: VecDeque::new(),
            emitted: None,
            pace_credit: 0.0,
            pace_at: None,
            pace_idle: true,
            sent_bytes: 0,
            target_due: Some(Micros::ZERO),
            notices: Vec::new(),
            malformed: 0,
            tx_pending: VecDeque::new(),
            tx_done: TraceQueue::default(),
        }
    }

    /// The live target for the transport's congestion controller.
    pub fn target_rate(&self) -> TargetRate {
        self.rate.handle()
    }

    pub fn rate_controller(&self) -> &RateController {
        &self.rate
    }

    pub fn set_max_datagram(&mut self, n: usize) {
        self.max_datagram = n;
    }

    /// A round-trip sample from the transport (e.g. QUIC's smoothed RTT, every few hundred ms or on change).
    pub fn set_rtt(&mut self, now: Micros, rtt: Micros) {
        self.rtt.add(now, rtt);
        self.rate.set_rtt(rtt);
    }

    /// Optional: the lowest round trip among the transport's acks since the last call (QUIC's `now − sent` of every
    /// acked packet; every 100 ms or so, only when there were acks). It bounds the queue the rate controller reads
    /// from one-way delays, which two clocks running at different rates fake ([`RateConfig::rtt_queue_slack`]).
    /// Not for a round trip probed now and then (ICE's).
    pub fn set_rtt_floor(&mut self, now: Micros, rtt: Micros) {
        self.rate.set_rtt_floor(now, rtt);
    }

    /// The client's network profile (path class + interface + Low Data Mode).
    pub fn set_network(&mut self, now: Micros, profile: NetworkProfile) {
        self.rate.set_profile(now, profile);
        self.check_target(now);
    }

    /// The transport declared persistent congestion: rate to the floor.
    pub fn on_persistent_congestion(&mut self, now: Micros) {
        self.rate.on_persistent_congestion(now);
        self.check_target(now);
    }

    /// Optional: the transport knows when a datagram really left (after its pacer). Refines delay estimates.
    pub fn note_sent(&mut self, tseq: u32, at: Micros) {
        self.history.set_send_time(tseq, at);
    }

    // MARK: video

    /// Open (or reopen, from frame 1) video stream `stream`.
    pub fn open_video(&mut self, stream: u8) {
        let mut v = VideoStreamSender::new(stream, self.cfg.video.clone());
        if let Some((_, enc, _)) = self.emitted {
            v.set_encoder_rate(enc);
        }
        self.video.insert(stream, v);
    }

    pub fn close_video(&mut self, stream: u8) {
        self.video.remove(&stream);
        self.cursor.remove(&stream);
    }

    /// Whether video stream `stream` is open.
    pub fn has_video(&self, stream: u8) -> bool {
        self.video.contains_key(&stream)
    }

    /// The encoder rate last reported in [`ServerEvent::TargetBitrate`] (per video stream; None before the first).
    pub fn encoder_target_bps(&self) -> Option<u64> {
        self.emitted.map(|(_, enc, _)| enc)
    }

    /// Send one encoded frame (`meta.au_len` is filled in). Returns its frame number (1, 2, …). Its datagrams wait
    /// in [`ServerMedia::poll_transmit`].
    pub fn send_frame(&mut self, now: Micros, stream: u8, meta: FrameMeta, au: &[u8]) -> Result<u32, SendError> {
        let loss = self.rate.fec_loss(now);
        let v = self.video.get_mut(&stream).ok_or(SendError::UnknownStream)?;
        let before = self.q_video.len();
        let queued_ahead = self.queued_video_bytes;
        let frame = v.send_frame(now, meta, au, loss, self.max_datagram, &mut self.q_video)?;
        let fec_ratio = v.fec_ratio as f32;
        let (mut wire_bytes, mut datagrams, mut parity) = (0usize, 0u16, 0u16);
        for d in self.q_video.iter().skip(before) {
            wire_bytes += d.len();
            datagrams = datagrams.saturating_add(1);
            if VideoHeader::parse(d).is_ok_and(|(h, _)| h.shard >= h.k) {
                parity = parity.saturating_add(1);
            }
        }
        self.queued_video_bytes += wire_bytes;
        self.tx_pending.push_back(TxTrace {
            stream,
            frame,
            kind: meta.kind as u8,
            au_bytes: au.len() as u32,
            wire_bytes: wire_bytes as u32,
            datagrams,
            parity,
            enqueued_at: now,
            queued_ahead: queued_ahead as u32,
            first_out: None,
            last_out: None,
            retransmits: 0,
            delivered_at: None,
            lost: false,
            target_bps: self.rate.target_bps(),
            pacing_bps: self.pacing_bps(now),
            fec_ratio,
            queue_delay_us: self.rate.queue_delay().map(|q| q.0),
            rtt_us: self.rtt.latest().map(|r| r.0),
        });
        self.finish_traces(now);
        if meta.kind == wire::FrameKind::Key {
            self.rate.on_key_frame(now);
        }
        Ok(frame)
    }

    /// Backpressure: false while the bytes waiting to go out (this crate's queue + `transport_queued` in the
    /// transport's datagram buffer) exceed 1.5 frame budgets at the target rate, the transport's free datagram
    /// buffer (`transport_space`, if known) can't hold the next frame estimate, or the previous frame went out
    /// sooner than the frame-rate cap allows ([`ServerMedia::frame_rate_cap`]). False → skip encoding this
    /// picture (the newest one wins later).
    pub fn can_send_frame(
        &self,
        now: Micros,
        stream: u8,
        transport_queued: usize,
        transport_space: Option<usize>,
    ) -> bool {
        self.send_gate(now, stream, transport_queued, transport_space).is_some_and(|g| g.open)
    }

    /// How fast video is released: the rate controller's pacing, its excess over the target scaled by the frame-rate
    /// cap (`√(cap / fps)`, the lowest of the streams'): a capped stream's frames are bigger, and at 1.8 × the target a
    /// frame three times the size would sit in the bottleneck's queue three times as long (at 20 fps: 1.46 × the
    /// target; never below 1.1 ×).
    fn pacing_bps(&self, now: Micros) -> u64 {
        let pacing = self.rate.pacing_bps(now) as f64;
        let target = self.rate.target_bps() as f64;
        let share = self.video.values().map(|v| (v.fps_cap() / v.config().fps.max(1.0)).sqrt()).fold(1.0, f64::min);
        (target + (pacing - target).max(0.0) * share).max(1.1 * target).min(pacing.max(1.1 * target)) as u64
    }

    /// The frame-rate cap of `stream` (frames/s, never above its `fps`; None: no such stream). It follows the
    /// encoder rate ([`crate::VideoSendConfig::fps_steps`]). An encoder whose rate control budgets per frame at a
    /// fixed frame rate should be told the rate for this many frames a second (`encoder_bps × fps / cap`), or
    /// the frames it is held to won't get the bits.
    pub fn frame_rate_cap(&self, stream: u8) -> Option<f64> {
        self.video.get(&stream).map(|v| v.fps_cap())
    }

    /// [`ServerMedia::can_send_frame`] with its numbers (None: no such stream).
    pub fn send_gate(
        &self,
        now: Micros,
        stream: u8,
        transport_queued: usize,
        transport_space: Option<usize>,
    ) -> Option<SendGate> {
        let v = self.video.get(&stream)?;
        let n = self.video.len().max(1) as f64;
        let budget = self.rate.target_bps() as f64 / 8.0 / v.fps_cap().max(1.0) / n;
        let own = self.queued_video_bytes + self.queued_other_bytes();
        let queued = (transport_queued + own) as f64;
        let limit = v.config().queued_budgets * budget;
        let over_queue = queued > limit;
        let estimate = if v.frame_estimate > 0.0 { v.frame_estimate } else { budget };
        let over_space = !over_queue && transport_space.is_some_and(|space| (space as f64) < estimate);
        let too_soon = v.too_soon(now);
        Some(SendGate {
            open: !over_queue && !over_space && !too_soon,
            over_queue,
            over_space,
            too_soon,
            fps_cap: v.fps_cap(),
            own_queued: own as u64,
            transport_queued: transport_queued as u64,
            transport_space: transport_space.map(|s| s as u64),
            budget: budget as u64,
            limit: limit as u64,
            estimate: estimate as u64,
            target_bps: self.rate.target_bps(),
            pacing_bps: self.pacing_bps(now),
        })
    }

    /// The per-frame traces finished since the last call (reported, or 3 s old), oldest first.
    pub fn take_tx_traces(&mut self, now: Micros) -> Vec<TxTrace> {
        self.finish_traces(now);
        self.tx_done.take()
    }

    /// Moves reported (and stale) traces from the pending list to the finished one.
    fn finish_traces(&mut self, now: Micros) {
        while let Some(t) = self.tx_pending.front() {
            let reported = (t.delivered_at.is_some() || t.lost) && t.last_out.is_some();
            if !reported && now - t.enqueued_at < TRACE_KEEP && self.tx_pending.len() <= 2048 {
                break;
            }
            let t = self.tx_pending.pop_front().unwrap();
            self.tx_done.push(t);
        }
    }

    fn trace_mut(&mut self, stream: u8, frame: u32) -> Option<&mut TxTrace> {
        self.tx_pending.iter_mut().rev().find(|t| t.stream == stream && t.frame == frame)
    }

    /// A video datagram left: its frame's first / last out, or a retransmit.
    fn trace_out(&mut self, now: Micros, d: &[u8]) {
        let Ok((h, _)) = VideoHeader::parse(d) else { return };
        let Some(t) = self.trace_mut(h.stream, h.frame) else { return };
        if h.flags & video_flags::RETRANSMIT != 0 {
            t.retransmits = t.retransmits.saturating_add(1);
        } else {
            t.first_out.get_or_insert(now);
            t.last_out = Some(now);
        }
    }

    /// A frame report: frames up to `last_delivered` were delivered, `lost` ones lost.
    fn trace_report(&mut self, now: Micros, stream: u8, last_delivered: u32, lost: &[u32]) {
        for t in self.tx_pending.iter_mut().filter(|t| t.stream == stream) {
            if t.frame <= last_delivered && t.delivered_at.is_none() && !t.lost {
                t.delivered_at = Some(now);
            }
            if lost.contains(&t.frame) {
                t.lost = true;
            }
        }
    }

    fn queued_other_bytes(&self) -> usize {
        self.q_audio.iter().map(|d| d.len()).sum()
    }

    /// The client asked for a key frame on the control stream.
    pub fn request_keyframe(&mut self, now: Micros, stream: u8) {
        if let Some(v) = self.video.get_mut(&stream) {
            v.request_key(now, &mut self.notices);
        }
        self.flush_notices(stream);
    }

    pub fn video_stats(&self, stream: u8) -> Option<VideoTxStats> {
        self.video.get(&stream).map(|v| v.stats)
    }

    // MARK: audio / cursor

    pub fn open_audio(&mut self, stream: u8) {
        self.audio.insert(stream, AudioStreamSender::new(stream));
    }

    pub fn close_audio(&mut self, stream: u8) {
        self.audio.remove(&stream);
    }

    /// One Opus packet (captured at `time_us`). Returns its `aseq`.
    pub fn send_audio(&mut self, now: Micros, stream: u8, time_us: u64, opus: &[u8]) -> Result<u32, SendError> {
        if wire::AudioDatagram::HEADER_LEN + opus.len() > self.max_datagram {
            return Err(SendError::BadSize);
        }
        let a = self.audio.get_mut(&stream).ok_or(SendError::UnknownStream)?;
        let (aseq, d) = a.packet(now, time_us, opus, self.max_datagram);
        self.q_audio.push_back(d);
        Ok(aseq)
    }

    /// The cursor position of video stream `stream` (JSON `{x,y,visible,shapeId}`); only the newest unsent one goes.
    pub fn send_cursor(&mut self, stream: u8, json: &[u8]) {
        if wire::CursorDatagram::HEADER_LEN + json.len() > self.max_datagram {
            return;
        }
        self.cursor.entry(stream).or_insert_with(|| CursorSender::new(stream)).update(json);
    }

    // MARK: datagrams

    /// A datagram from the client (input or feedback).
    pub fn handle_datagram(&mut self, now: Micros, d: &[u8]) -> Result<(), WireError> {
        let r = self.handle_inner(now, d);
        if r.is_err() {
            self.malformed += 1;
        }
        r
    }

    fn handle_inner(&mut self, now: Micros, d: &[u8]) -> Result<(), WireError> {
        match wire::channel_of(d)? {
            Channel::Input => {
                let dg = InputDatagram::parse(d)?;
                let mut out = Vec::new();
                self.input.on_datagram(&dg, &mut out);
                self.events.extend(out.into_iter().map(ServerEvent::Input));
                if self.input.ack_due {
                    let ack = self.input.ack();
                    self.q_feedback.push_back(encode_feedback(&[FeedbackSection::InputAck(ack)]));
                }
                Ok(())
            }
            Channel::Feedback => {
                let sections = parse_feedback(d)?;
                for s in sections {
                    self.on_section(now, s);
                }
                self.check_target(now);
                Ok(())
            }
            c => Err(WireError::Channel(c as u8)),
        }
    }

    fn on_section(&mut self, now: Micros, s: FeedbackSection) {
        match s {
            FeedbackSection::TransportCc(t) => {
                let results = self.history.on_feedback(&t);
                if !results.is_empty() {
                    self.rate.on_feedback(now, &results);
                }
            }
            FeedbackSection::Nack { stream, items } => {
                let gap =
                    Micros(self.rtt.latest().unwrap_or(Micros::from_millis(50)).0 / 2).max(Micros::from_millis(5));
                if let Some(v) = self.video.get_mut(&stream) {
                    let before = self.q_retx.len();
                    v.on_nack(now, &items, gap, &mut self.q_retx, &mut self.notices);
                    self.queued_video_bytes += self.q_retx.iter().skip(before).map(|d| d.len()).sum::<usize>();
                }
                self.flush_notices(stream);
            }
            FeedbackSection::FrameReport(r) => {
                self.trace_report(now, r.stream, r.last_delivered, &r.lost);
                if let Some(v) = self.video.get_mut(&r.stream) {
                    v.on_report(now, &r, &mut self.notices);
                }
                self.flush_notices(r.stream);
            }
            FeedbackSection::AudioReport { stream, loss_permille } => {
                if let Some(a) = self.audio.get_mut(&stream) {
                    a.redundancy = crate::audio::redundancy_for(loss_permille);
                }
            }
            FeedbackSection::InputAck(_) => {}
        }
    }

    fn flush_notices(&mut self, stream: u8) {
        for n in self.notices.drain(..) {
            self.events.push_back(match n {
                TxNotice::Delivered(frame) => ServerEvent::FrameDelivered { stream, frame },
                TxNotice::RecoveryNeeded(last_delivered) => ServerEvent::RecoveryNeeded { stream, last_delivered },
                TxNotice::KeyframeNeeded => ServerEvent::KeyframeNeeded { stream },
            });
        }
    }

    /// The next datagram to hand to the transport, or None. Call until None after every `send_*` / `handle_*`
    /// and when the [`ServerMedia::poll_timeout`] timer fires. Order: input acks, audio, cursor, then
    /// retransmits and video — those paced (`RateConfig::pacing_factor`), so a big key frame trickles out and the
    /// audio and cursor datagrams queued meanwhile go ahead of its rest.
    pub fn poll_transmit(&mut self, now: Micros) -> Option<Vec<u8>> {
        if let Some(d) = self.q_feedback.pop_front() {
            return Some(d);
        }
        self.top_up_pacing(now);
        let mut d = if let Some(d) = self.q_audio.pop_front() {
            d
        } else if let Some(d) = self.cursor.values_mut().find_map(|c| c.poll(now)) {
            d
        } else if self.pace_credit > 0.0
            && let Some(d) = self.q_retx.pop_front().or_else(|| self.q_video.pop_front())
        {
            self.queued_video_bytes = self.queued_video_bytes.saturating_sub(d.len());
            self.pace_credit -= d.len() as f64;
            self.trace_out(now, &d);
            d
        } else {
            return None;
        };
        let size = d.len() as u32;
        let tseq = self.history.on_send(now, size);
        wire::set_media_tseq(&mut d, tseq);
        self.rate.on_sent(now, size);
        self.sent_bytes += size as u64;
        Some(d)
    }

    /// Video pacing credit: grows at the pacing rate, at most a short burst (5 ms, ≥ 2 datagrams) banked.
    fn top_up_pacing(&mut self, now: Micros) {
        let rate = self.pacing_bps(now) as f64 / 8.0;
        let burst = (rate * 0.005).max(2.0 * self.max_datagram as f64);
        let elapsed = self.pace_at.map_or(Micros::ZERO, |t| now - t).as_secs_f64();
        self.pace_at = Some(now);
        self.pace_credit = (self.pace_credit + elapsed * rate).min(burst);
        if self.pace_idle {
            self.pace_credit = burst;
        }
        self.pace_idle = self.q_retx.is_empty() && self.q_video.is_empty();
    }

    /// When the paced video queue may release its next datagram.
    fn next_release(&self, now: Micros) -> Option<Micros> {
        if self.q_retx.is_empty() && self.q_video.is_empty() {
            return None;
        }
        if self.pace_credit > 0.0 {
            return Some(now);
        }
        let rate = self.pacing_bps(now) as f64 / 8.0;
        let wait_us = ((1.0 - self.pace_credit) / rate.max(1.0) * 1e6).ceil().max(1.0) as u64;
        Some((self.pace_at.unwrap_or(now) + Micros(wait_us)).max(now + Micros(1)))
    }

    pub fn poll_event(&mut self) -> Option<ServerEvent> {
        self.events.pop_front()
    }

    /// When to call [`ServerMedia::handle_timeout`] next (None: no timer needed).
    pub fn poll_timeout(&self, now: Micros) -> Option<Micros> {
        let mut t = earliest(self.target_due, self.next_release(now));
        if !self.q_feedback.is_empty() || !self.q_audio.is_empty() {
            t = Some(now);
        }
        for c in self.cursor.values() {
            t = earliest(t, c.poll_timeout(now));
        }
        t
    }

    pub fn handle_timeout(&mut self, now: Micros) {
        if self.target_due.is_some_and(|t| t <= now) {
            self.check_target(now);
        }
    }

    fn encoder_bps(&self, now: Micros, target: u64) -> u64 {
        let audio: u64 = self.audio.values().map(|a| a.rate_bps()).sum();
        let fec = self.cfg.video.fec.ratio(self.rate.fec_loss(now));
        let n = self.video.len().max(1) as f64;
        ((target.saturating_sub(audio)) as f64 * (1.0 - fec) * 0.95 / n) as u64
    }

    fn check_target(&mut self, now: Micros) {
        let target = self.rate.target_bps();
        let enc = self.encoder_bps(now, target);
        self.target_due = None;
        let emit = match self.emitted {
            None => true,
            Some((t, e, at)) => {
                let lower = target < t || (enc as f64) < 0.95 * e as f64;
                let higher = target > t || (enc as f64) > 1.05 * e as f64;
                if lower {
                    true
                } else if higher {
                    let due = at + self.cfg.target_increase_interval;
                    if now >= due {
                        true
                    } else {
                        self.target_due = Some(due);
                        false
                    }
                } else {
                    false
                }
            }
        };
        if emit {
            for v in self.video.values_mut() {
                v.set_encoder_rate(enc);
            }
            self.emitted = Some((target, enc, now));
            self.target_due = None;
            self.events.push_back(ServerEvent::TargetBitrate { target_bps: target, encoder_bps: enc });
        }
    }

    /// The media side of the stats line.
    pub fn stats(&mut self, now: Micros) -> MediaStats {
        let mut s = MediaStats {
            at_us: now.0,
            sent_bytes: self.sent_bytes,
            rtt_min_ms: self.rtt.min().map(|r| r.as_millis_f64()),
            rtt_p50_ms: self.rtt.percentile(0.5).map(|r| r.as_millis_f64()),
            rtt_p90_ms: self.rtt.percentile(0.9).map(|r| r.as_millis_f64()),
            loss_pct: Some(self.rate.fec_loss(now) * 100.0),
            media_received: self.rate.loss_totals().0,
            media_missing: self.rate.loss_totals().1,
            target_bps: Some(self.rate.target_bps()),
            sent_bps: Some(self.rate.sent_bps(now)),
            rate_cuts: self.rate.decreases().0 - self.rate.decreases().1,
            rate_loss_cuts: self.rate.decreases().1,
            jitter_ms: Some(self.rate.jitter().as_millis_f64()),
            redundancy: self.audio.values().map(|a| a.redundancy).max(),
            ..Default::default()
        };
        for v in self.video.values() {
            s.frames_sent += v.stats.frames;
            s.key_frames += v.stats.key_frames;
            s.recovery_frames += v.stats.recovery_frames;
            s.retransmits += v.stats.retransmits;
            s.frames_lost += v.stats.lost_reported;
        }
        s
    }

    /// Datagrams refused as malformed or arriving on a channel this side doesn't receive.
    pub fn malformed(&self) -> u64 {
        self.malformed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Codec, FrameKind};

    #[test]
    fn a_heavy_key_frame_is_paced_and_audio_goes_ahead_of_its_rest() {
        // no frame-rate cap: the pacing at 1.8 × the target (a capped stream's is lower, see below)
        let mut cfg = ServerConfig::default();
        cfg.video.fps_steps = vec![(0, 60.0)];
        let mut s = ServerMedia::new(cfg);
        s.open_video(1);
        s.open_audio(1);
        let now = Micros::from_secs(1);
        let meta = FrameMeta {
            codec: Codec::H264,
            kind: FrameKind::Key,
            width: 100,
            height: 100,
            capture_us: 0,
            recovery_base: 0,
            au_len: 0,
        };
        s.handle_timeout(now); // the first TargetBitrate
        s.send_frame(now, 1, meta, &vec![0u8; 150_000]).unwrap();
        let first: Vec<Vec<u8>> = std::iter::from_fn(|| s.poll_transmit(now)).collect();
        // a burst goes, the rest waits for the pacing timer
        assert!(!first.is_empty() && first.len() < 20, "{}", first.len());
        let release = s.poll_timeout(now).unwrap();
        assert!(release > now && release < now + Micros::from_millis(5));
        // audio queued now goes before the key frame's rest
        let later = now + Micros::from_millis(2);
        s.send_audio(later, 1, 0, &[1; 100]).unwrap();
        assert_eq!(wire::channel_of(&s.poll_transmit(later).unwrap()), Ok(Channel::Audio));
        // the whole frame is out at the pacing rate (1.8 × 3.5 Mbps ≈ 0.8 MB/s): ~190 ms for ~155 KB
        let mut t = later;
        let mut n = first.len();
        while n < 140 {
            t = s.poll_timeout(t).unwrap().max(t);
            while let Some(d) = s.poll_transmit(t) {
                assert_eq!(wire::channel_of(&d), Ok(Channel::Video));
                n += 1;
            }
        }
        let took = (t - now).as_millis_f64();
        assert!((150.0..260.0).contains(&took), "{took}");
    }

    /// The frame-rate cap follows the encoder rate (lower at once, higher with a margin), holds a frame that comes
    /// too soon, and slows the pacing of the (bigger) frames.
    #[test]
    fn the_frame_rate_cap_follows_the_rate() {
        let mut s = ServerMedia::new(ServerConfig::default());
        s.open_video(1);
        let now = Micros::from_secs(1);
        s.handle_timeout(now);
        // 3.5 Mbps start: the encoder gets ~3 Mbps → 30 fps, paced at 1 + 0.8 × √½
        assert_eq!(s.frame_rate_cap(1), Some(30.0));
        let pacing = s.pacing_bps(now) as f64 / s.target_rate().bps() as f64;
        assert!((pacing - 1.566).abs() < 0.01, "{pacing}");
        let meta = FrameMeta {
            codec: Codec::H264,
            kind: FrameKind::Delta,
            width: 100,
            height: 100,
            capture_us: 0,
            recovery_base: 0,
            au_len: 0,
        };
        assert!(s.can_send_frame(now, 1, 0, None));
        s.send_frame(now, 1, meta, &[0u8; 500]).unwrap();
        while s.poll_transmit(now).is_some() {}
        // 30 fps: not again 20 ms later, 30 ms later yes (0.85 × 33 ms)
        assert!(!s.can_send_frame(now + Micros::from_millis(20), 1, 0, None));
        assert!(s.send_gate(now + Micros::from_millis(20), 1, 0, None).unwrap().too_soon);
        assert!(s.can_send_frame(now + Micros::from_millis(30), 1, 0, None));
        let v = s.video.get_mut(&1).unwrap();
        v.set_encoder_rate(500_000);
        assert_eq!(v.fps_cap(), 15.0);
        // 0.75 Mbps would be 20 fps, but a step up needs 1.2 × 0.7
        v.set_encoder_rate(750_000);
        assert_eq!(v.fps_cap(), 15.0);
        v.set_encoder_rate(850_000);
        assert_eq!(v.fps_cap(), 20.0);
        v.set_encoder_rate(20_000_000);
        assert_eq!(v.fps_cap(), 60.0);
    }

    #[test]
    fn a_frame_is_traced_from_its_queue_to_its_report() {
        let mut s = ServerMedia::new(ServerConfig::default());
        s.open_video(1);
        let now = Micros::from_secs(1);
        s.handle_timeout(now);
        let meta = FrameMeta {
            codec: Codec::H264,
            kind: FrameKind::Delta,
            width: 100,
            height: 100,
            capture_us: 0,
            recovery_base: 0,
            au_len: 0,
        };
        let gate = s.send_gate(now, 1, 0, Some(1 << 20)).unwrap();
        assert!(gate.open && !gate.over_queue && !gate.over_space);
        let f = s.send_frame(now, 1, meta, &vec![0u8; 30_000]).unwrap();
        // a big frame waiting: the gate closes on the queue
        let gate = s.send_gate(now, 1, 0, Some(1 << 20)).unwrap();
        assert!(!gate.open && gate.over_queue && gate.own_queued > gate.limit, "{gate:?}");
        let mut t = now;
        while s.poll_timeout(t).is_some() {
            t = s.poll_timeout(t).unwrap().max(t);
            while s.poll_transmit(t).is_some() {}
        }
        assert!(s.take_tx_traces(t).is_empty(), "not reported yet");
        let report =
            FeedbackSection::FrameReport(wire::FrameReport { stream: 1, last_delivered: f, lost: vec![], flags: 0 });
        let later = t + Micros::from_millis(30);
        s.handle_datagram(later, &encode_feedback(&[report])).unwrap();
        let traces = s.take_tx_traces(later);
        assert_eq!(traces.len(), 1);
        let tr = &traces[0];
        assert_eq!((tr.frame, tr.au_bytes, tr.queued_ahead), (f, 30_000, 0));
        assert!(tr.wire_bytes > 30_000 && tr.datagrams > 25, "{tr:?}");
        assert_eq!(tr.enqueued_at, now);
        let first = tr.first_out.unwrap();
        assert!(first < now + Micros::from_millis(1) && tr.last_out.unwrap() > first, "{tr:?}");
        assert_eq!(tr.delivered_at, Some(later));
        assert!(!tr.lost);
    }
}
