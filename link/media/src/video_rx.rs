//! Video receiver for one stream (LINK.md §5.1): per-block reassembly with Reed-Solomon recovery, deadline-aware
//! NACKs, in-order delivery that never hands the decoder a frame whose reference chain is broken, frame reports,
//! freeze accounting.

use std::collections::{BTreeMap, VecDeque};

use crate::fec;
use crate::time::Micros;
use crate::trace::{RxFate, RxTrace, TraceQueue};
use crate::wire::{FrameKind, FrameMeta, FrameReport, NackItem, VideoHeader, report_flags, video_flags};

/// Video receiver settings (LINK.md §5.1).
#[derive(Clone, Debug)]
pub struct VideoReceiveConfig {
    /// Frame deadline = first shard arrival + `clamp(deadline_rtt × rtt_p50, min_deadline, max_deadline)` (on a long
    /// path at least `nack_deadline_rtt × rtt_p50`, see there), plus the
    /// longest pause between a frame's shards over the last `stall_window` (≤ `stall_allowance`): a cellular
    /// stall holds a frame's shards for 50–150 ms and then delivers them all, and a frame given up before then
    /// costs a recovery frame and a freeze though nothing was lost.
    pub min_deadline: Micros,
    pub max_deadline: Micros,
    pub deadline_rtt: f64,
    /// On a long path (RTT past ~130 ms) `max_deadline` leaves no time for a NACK (one needs `nack_margin_rtt`
    /// RTTs before the deadline): every frame FEC can't finish is lost, and the stream waits for a recovery
    /// frame — a round trip at least, a key frame where recovery means one (blurry at a low rate). There the
    /// deadline is at least `nack_deadline_rtt × rtt_p50` (one NACK round fits), up to `nack_deadline_max` —
    /// where the path loses packets at random, at least `nack_deadline_loss` over a while (the client's
    /// [`crate::ClientMedia`] lowest 2 s loss of the last 10 s): on a path that only queues, shards are late,
    /// not lost, and NACKs for them would pour retransmits into the full queue.
    pub nack_deadline_rtt: f64,
    pub nack_deadline_max: Micros,
    pub nack_deadline_loss: f64,
    pub stall_window: Micros,
    pub stall_allowance: Micros,
    /// A NACK only while `deadline − now > nack_margin_rtt × rtt`.
    pub nack_margin_rtt: f64,
    /// The answer to a NACK is due this many RTTs after it at least — or the measured p95 of NACK → retransmit
    /// times if longer (1.5 RTT before any was measured), plus the reorder wait. Then one retry, if it can still be
    /// answered before the deadline (with the default deadline that fits on paths up to ~25 ms RTT), else the
    /// frame is lost at once.
    pub retry_rtt: f64,
    /// A shard counts as missing this long after a later datagram arrived (reordering tolerance; NACKs go then).
    pub reorder_wait: Micros,
    /// A frame no NACK can save any more is given up this long after its missing part counted as missing (a
    /// late reordered shard may still complete it), not at its deadline.
    pub give_up_wait: Micros,
    /// Lost frames are repeated in reports for this long.
    pub lost_report_keep: Micros,
    /// More than this between delivered frames (with frames lost or skipped in between) is a freeze.
    pub freeze_gap: Micros,
    /// A block whose last shard didn't come and that no later shard of the stream followed counts as sent after
    /// `quiet_gaps ×` the usual gap between a frame's shards without one (the sender paces video), within
    /// `quiet_min`…`quiet_max` — tentatively: another original shard of it says it is still arriving.
    pub quiet_gaps: f64,
    pub quiet_min: Micros,
    pub quiet_max: Micros,
    /// A path that bunches packets (cellular jitter: a frame's shards stall for tens of ms, then come together)
    /// fools that wait: its NACKs ask for shards that are only late, the originals come, the retransmits are
    /// duplicates. Each quiet-timer NACK is judged by what fills the gap first (`quiet_judge` smooths the
    /// verdicts, 1 = late); the share of late ones stretches the wait toward the longest gap between a frame's
    /// shards over the last `quiet_window`, up to `quiet_late_max`. Where the losses are real (a lossy path) it
    /// stays short: a loss there costs the wait.
    pub quiet_judge: f64,
    pub quiet_window: Micros,
    pub quiet_late_max: Micros,
    /// More wholly-missing frames than this in one gap are declared lost at once instead of NACKed.
    pub max_missing_nack: u32,
    /// While a frame is still arriving its deadline follows its newest original shard (a big key frame at a low
    /// rate takes longer than `max_deadline` to stream in), up to this long after its first shard.
    pub max_streaming: Micros,
}

impl Default for VideoReceiveConfig {
    fn default() -> VideoReceiveConfig {
        VideoReceiveConfig {
            min_deadline: Micros::from_millis(60),
            max_deadline: Micros::from_millis(200),
            deadline_rtt: 1.5,
            nack_deadline_rtt: 1.5,
            nack_deadline_max: Micros::from_millis(600),
            nack_deadline_loss: 0.02,
            stall_window: Micros::from_secs(10),
            stall_allowance: Micros::from_millis(150),
            nack_margin_rtt: 1.2,
            retry_rtt: 1.2,
            reorder_wait: Micros::from_millis(3),
            give_up_wait: Micros::from_millis(15),
            lost_report_keep: Micros::from_millis(500),
            freeze_gap: Micros::from_millis(200),
            quiet_gaps: 3.0,
            quiet_min: Micros::from_millis(8),
            quiet_max: Micros::from_millis(30),
            quiet_judge: 0.2,
            quiet_window: Micros::from_secs(2),
            quiet_late_max: Micros::from_millis(60),
            max_missing_nack: 8,
            max_streaming: Micros::from_secs(1),
        }
    }
}

/// A frame for the decoder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReceivedFrame {
    pub stream: u8,
    pub frame: u32,
    pub meta: FrameMeta,
    /// The Annex-B access unit.
    pub au: Vec<u8>,
    /// When its first shard arrived.
    pub first_arrival: Micros,
    pub delivered_at: Micros,
}

/// Per-stream receiver counters (cumulative).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VideoRxStats {
    pub shards: u64,
    pub duplicate_shards: u64,
    /// Shards that came after their frame was decided.
    pub late_shards: u64,
    pub malformed: u64,
    /// Data shards restored by Reed-Solomon.
    pub fec_recovered: u64,
    /// Shards requested by NACK (a whole-block request counts the shards that came back for it).
    pub nack_sent: u64,
    /// Retransmitted shards that arrived in time and were used.
    pub nack_recovered: u64,
    pub frames_delivered: u64,
    pub frames_lost: u64,
    pub frames_skipped: u64,
    pub freezes: u64,
    pub freeze_us: u64,
    pub decode_failures: u64,
}

struct Block {
    k: u16,
    m: u16,
    shard_size: u16,
    shards: Vec<Option<Vec<u8>>>,
    received: usize,
    last_arrival: Micros,
    last_shard_seen: bool,
    passed_at: Option<Micros>,
    /// `passed_at` only from the quiet timer (undone by a later shard).
    passed_quiet: bool,
    data: Option<Vec<u8>>,
    nacks: u8,
    last_nack: Option<Micros>,
    /// Shards asked for one by one (bit per index).
    asked: u64,
    /// NACKed on the quiet timer; the first shard to come after says whether it was lost or late.
    quiet_nacked: bool,
}

struct Frame {
    first_arrival: Micros,
    deadline: Micros,
    blocks: Vec<Option<Block>>,
    last_block: Option<u8>,
    last_arrival: Micros,
    passed_at: Option<Micros>,
    passed_quiet: bool,
    /// When the newest block index first appeared (missing blocks before it count from then).
    blocks_noticed: Micros,
    flags: u8,
    /// No shard seen yet: known only because a later frame arrived.
    placeholder: bool,
    /// NACK state of whole-block / trailing requests, by (block, marker).
    special: BTreeMap<(u8, u16), (u8, Micros)>,
    complete: Option<(FrameMeta, Vec<u8>)>,
    /// Reported lost before it reached the head (it can't complete).
    lost_reported: bool,
    /// The newest NACK for any part of it.
    last_request: Option<Micros>,
    /// Its tail was NACKed on the quiet timer (see `Block::quiet_nacked`).
    quiet_nacked: bool,
    /// For its trace record.
    tally: Tally,
}

/// A frame's numbers for its [`RxTrace`].
#[derive(Clone, Copy, Default)]
struct Tally {
    first_shard: Option<Micros>,
    last_shard: Option<Micros>,
    completed_at: Option<Micros>,
    shards: u16,
    fec: u16,
    retx: u16,
    nack_items: u16,
}

impl Frame {
    fn new(now: Micros, deadline: Micros, placeholder: bool) -> Frame {
        Frame {
            first_arrival: now,
            deadline,
            blocks: Vec::new(),
            last_block: None,
            last_arrival: now,
            passed_at: placeholder.then_some(now),
            passed_quiet: false,
            quiet_nacked: false,
            blocks_noticed: now,
            flags: 0,
            placeholder,
            special: BTreeMap::new(),
            complete: None,
            lost_reported: false,
            last_request: None,
            tally: Tally::default(),
        }
    }

    /// Whether the frame can still complete before its deadline. Every missing part (a block short of `k`
    /// shards, a missing block, the missing tail, the whole frame) must still have a chance: it may still be in
    /// flight (inside the reorder window), the answer to a NACK for it is still due, or a NACK (or the one retry)
    /// sent now could still be answered before the deadline. FEC can't finish a block below `k` on its own.
    /// `answer`: how long after a NACK its retransmits are due (reorder wait included); `rtt`: the estimate the
    /// NACK margin is taken from.
    fn can_complete(&self, now: Micros, rtt: Micros, answer: Micros, cfg: &VideoReceiveConfig) -> bool {
        if self.complete.is_some() {
            return true;
        }
        if now >= self.deadline {
            return false;
        }
        let margin = rtt.mul_f64(cfg.nack_margin_rtt);
        let wait = cfg.reorder_wait;
        let part = |eligible: Micros, state: Option<(u8, Micros)>| -> bool {
            if now < eligible + cfg.give_up_wait {
                return true;
            }
            if let Some((_, last)) = state
                && now < last + answer + cfg.give_up_wait
            {
                return true;
            }
            let next = match state {
                None => now,
                Some((1, last)) => (last + answer).max(now),
                _ => return false,
            };
            self.deadline > next + margin
        };
        if self.placeholder {
            let p = self.passed_at.unwrap_or(now);
            return part(p + wait, self.special.get(&(0, NackItem::BLOCK_AND_LATER)).copied());
        }
        for (bi, b) in self.blocks.iter().enumerate() {
            let ok = match b {
                None => part(self.blocks_noticed + wait, self.special.get(&(bi as u8, NackItem::WHOLE_BLOCK)).copied()),
                Some(b) if b.data.is_none() => match b.passed_at {
                    None => true, // still arriving
                    Some(p) => part(if b.last_shard_seen { p } else { p + wait }, b.last_nack.map(|l| (b.nacks, l))),
                },
                Some(_) => true,
            };
            if !ok {
                return false;
            }
        }
        match (self.last_block, self.passed_at) {
            (None, Some(p)) => {
                let key = (self.blocks.len().min(255) as u8, NackItem::BLOCK_AND_LATER);
                part(p + wait, self.special.get(&key).copied())
            }
            _ => true,
        }
    }

    fn resync_flag(&self) -> bool {
        self.flags & (video_flags::KEY | video_flags::RECOVERY) != 0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Chain {
    Intact,
    /// Waiting for a key frame or a usable recovery frame.
    Broken,
    /// Waiting for a key frame (the decoder failed).
    NeedKey,
}

pub(crate) struct VideoStreamReceiver {
    pub(crate) id: u8,
    cfg: VideoReceiveConfig,
    frames: BTreeMap<u32, Frame>,
    /// The next frame to deliver or decide.
    next_frame: u32,
    chain: Chain,
    last_handed: u32,
    last_handed_at: Option<Micros>,
    /// Newest frame decoded OK (the app's confirmation).
    last_delivered: u32,
    lost: VecDeque<(u32, Micros)>,
    keyframe_needed: bool,
    /// Something a report should carry at once (a loss, a keyframe request).
    pub(crate) urgent: bool,
    pending_nacks: Vec<NackItem>,
    pub(crate) stats: VideoRxStats,
    /// Delivery times for the fps stat.
    delivered_times: VecDeque<Micros>,
    /// The transport's RTT (smoothed, latest) and its 10 s median: the median sets deadlines and the NACK margin
    /// (one estimate for both, so a rising RTT doesn't close the NACK window), the latest floors the answer wait.
    rtt: Micros,
    rtt_p50: Micros,
    /// The path's lasting random loss (`set_path_loss`).
    path_loss: f64,
    /// NACK → retransmit arrival times (recent), and their maximum.
    answers: VecDeque<Micros>,
    answer_max: Option<Micros>,
    /// Average gap between consecutive original shards of a frame (µs).
    shard_gap: f64,
    /// Those gaps over the last `quiet_window`, as a sliding maximum: (arrival, gap), gaps decreasing.
    gap_max: VecDeque<(Micros, Micros)>,
    /// The same over `stall_window`.
    stall_max: VecDeque<(Micros, Micros)>,
    /// Smoothed verdicts on quiet-timer NACKs: 1 = the shard was only late.
    quiet_late: f64,
    /// Every frame's fate, for the app's trace.
    pub(crate) traces: TraceQueue<RxTrace>,
}

impl VideoStreamReceiver {
    pub(crate) fn new(id: u8, cfg: VideoReceiveConfig) -> VideoStreamReceiver {
        VideoStreamReceiver {
            id,
            cfg,
            frames: BTreeMap::new(),
            next_frame: 1,
            chain: Chain::Broken,
            last_handed: 0,
            last_handed_at: None,
            last_delivered: 0,
            lost: VecDeque::new(),
            keyframe_needed: false,
            urgent: false,
            pending_nacks: Vec::new(),
            stats: VideoRxStats::default(),
            delivered_times: VecDeque::new(),
            rtt: Micros::from_millis(100),
            rtt_p50: Micros::from_millis(100),
            path_loss: 0.0,
            answers: VecDeque::new(),
            answer_max: None,
            shard_gap: 1000.0,
            gap_max: VecDeque::new(),
            stall_max: VecDeque::new(),
            quiet_late: 0.0,
            traces: TraceQueue::default(),
        }
    }

    fn quiet_wait(&self) -> Micros {
        let base = Micros((self.shard_gap * self.cfg.quiet_gaps) as u64).clamp(self.cfg.quiet_min, self.cfg.quiet_max);
        let longest = self.gap_max.front().map_or(Micros::ZERO, |g| g.1).min(self.cfg.quiet_late_max);
        if longest <= base {
            return base;
        }
        base + (longest - base).mul_f64(self.quiet_late)
    }

    fn judge_quiet(late: &mut f64, judge: f64, was_late: bool) {
        *late += judge * (if was_late { 1.0 } else { 0.0 } - *late);
    }

    fn note_gap(gaps: &mut VecDeque<(Micros, Micros)>, window: Micros, now: Micros, gap: Micros) {
        while gaps.front().is_some_and(|g| now - g.0 > window) {
            gaps.pop_front();
        }
        while gaps.back().is_some_and(|g| g.1 <= gap) {
            gaps.pop_back();
        }
        gaps.push_back((now, gap));
    }

    /// How long after a NACK its retransmits are due (see `retry_rtt`). Giving a frame up early only pays when
    /// it is clearly hopeless, so this is generous: the slowest recent answer.
    fn answer_wait(&self, rtt: Micros) -> Micros {
        let floor = rtt.mul_f64(self.cfg.retry_rtt);
        self.answer_max.unwrap_or(rtt.mul_f64(1.5)).max(floor) + self.cfg.reorder_wait
    }

    fn note_answer(&mut self, t: Micros) {
        self.answers.push_back(t);
        if self.answers.len() > 64 {
            self.answers.pop_front();
        }
        self.answer_max = self.answers.iter().copied().max();
    }

    pub(crate) fn set_rtt(&mut self, rtt: Micros, rtt_p50: Micros) {
        self.rtt = rtt;
        self.rtt_p50 = rtt_p50;
    }

    /// The path's lasting random loss (see `nack_deadline_loss`).
    pub(crate) fn set_path_loss(&mut self, loss: f64) {
        self.path_loss = loss;
    }

    fn budget(&self, rtt_p50: Micros) -> Micros {
        let stall = self.stall_max.front().map_or(Micros::ZERO, |g| g.1).min(self.cfg.stall_allowance);
        let short = rtt_p50.mul_f64(self.cfg.deadline_rtt).clamp(self.cfg.min_deadline, self.cfg.max_deadline);
        if self.path_loss < self.cfg.nack_deadline_loss {
            return short + stall;
        }
        let nack = rtt_p50.mul_f64(self.cfg.nack_deadline_rtt).min(self.cfg.nack_deadline_max);
        short.max(nack) + stall
    }

    /// An original (not retransmitted) shard of `(frame, block)` arrived. A stream's original shards go out in
    /// order, so every earlier block and frame is done on the wire. (Other datagrams prove nothing: the sender
    /// paces video and lets audio, cursor and retransmits go between a frame's shards.)
    fn note_progress(&mut self, now: Micros, frame: u32, block: u8) {
        for (&n, f) in self.frames.range_mut(..=frame) {
            if f.complete.is_some() || f.placeholder {
                continue;
            }
            if n < frame {
                f.passed_at.get_or_insert(now);
                f.passed_quiet = false;
            }
            for (bi, b) in f.blocks.iter_mut().enumerate() {
                if let Some(b) = b
                    && (n < frame || bi < block as usize)
                    && b.data.is_none()
                {
                    b.passed_at.get_or_insert(now);
                    b.passed_quiet = false;
                }
            }
        }
    }

    /// No shard of a frame (or block) for `quiet_wait`: its sending is over (the last frame before a pause has
    /// no later frame to show it).
    fn refresh_quiet(&mut self, now: Micros) {
        let quiet = self.quiet_wait();
        for f in self.frames.values_mut() {
            if f.complete.is_some() || f.placeholder {
                continue;
            }
            if f.passed_at.is_none() && now >= f.last_arrival + quiet {
                f.passed_at = Some(now);
                f.passed_quiet = true;
            }
            for b in f.blocks.iter_mut().flatten() {
                if b.passed_at.is_none() && b.data.is_none() && now >= b.last_arrival + quiet {
                    b.passed_at = Some(now);
                    b.passed_quiet = true;
                }
            }
        }
    }

    /// A shard of this stream (header already parsed).
    pub(crate) fn on_shard(
        &mut self,
        now: Micros,
        h: &VideoHeader,
        payload: &[u8],
        rtt_p50: Micros,
        out: &mut Vec<ReceivedFrame>,
    ) {
        self.stats.shards += 1;
        let fno = h.frame;
        if fno == 0 || fno < self.next_frame {
            self.stats.late_shards += 1;
            return;
        }
        if fno - self.next_frame > 100_000 {
            self.stats.malformed += 1;
            return;
        }
        let budget = self.budget(rtt_p50);
        // frames between the newest known one and this one that never showed a shard
        if !self.frames.contains_key(&fno) {
            let newest_known =
                self.frames.keys().next_back().copied().unwrap_or(self.next_frame - 1).max(self.next_frame - 1);
            if fno > newest_known + 1 {
                let missing = fno - newest_known - 1;
                if missing > self.cfg.max_missing_nack {
                    // A long gap (a blackout): those frames are gone, and fetching deltas after them is pointless.
                    // Deliver what is complete in order, declare the rest lost.
                    self.advance(now, out);
                    while self.next_frame < fno {
                        if self.frames.get(&self.next_frame).is_some_and(|f| f.complete.is_some()) {
                            self.take_head(now, out);
                        } else {
                            let f = self.next_frame;
                            let gone = self.frames.remove(&f);
                            self.trace(now, f, gone.as_ref(), RxFate::Lost);
                            self.next_frame += 1;
                            self.declare_lost(now, f);
                        }
                    }
                } else {
                    for f in newest_known + 1..fno {
                        self.frames.insert(f, Frame::new(now, now + budget, true));
                    }
                }
            }
        }
        if h.flags & video_flags::RETRANSMIT == 0 {
            self.note_progress(now, fno, h.block);
        }
        let mut answer: Option<Micros> = None;
        let frame = self.frames.entry(fno).or_insert_with(|| Frame::new(now, now + budget, false));
        if frame.placeholder {
            // keeps the placeholder's (earlier) deadline: it was sent before the frame that revealed it
            frame.placeholder = false;
            frame.passed_at = None;
        }
        if frame.complete.is_some() {
            self.stats.duplicate_shards += 1;
            return;
        }
        frame.flags |= h.flags & (video_flags::KEY | video_flags::RECOVERY);
        if h.flags & video_flags::RETRANSMIT == 0 && !frame.blocks.is_empty() {
            let gap = now - frame.last_arrival;
            self.shard_gap = 0.9 * self.shard_gap + 0.1 * gap.0 as f64;
            Self::note_gap(&mut self.gap_max, self.cfg.quiet_window, now, gap);
            Self::note_gap(&mut self.stall_max, self.cfg.stall_window, now, gap);
        }
        frame.last_arrival = now;
        frame.tally.first_shard.get_or_insert(now);
        frame.tally.last_shard = Some(now);
        if frame.passed_quiet && h.flags & video_flags::RETRANSMIT == 0 {
            frame.passed_at = None;
            frame.passed_quiet = false;
        }
        if frame.quiet_nacked && h.block as usize >= frame.blocks.len() {
            // the first shard of the tail the quiet timer asked for: an original says it was only late
            frame.quiet_nacked = false;
            Self::judge_quiet(&mut self.quiet_late, self.cfg.quiet_judge, h.flags & video_flags::RETRANSMIT == 0);
        }
        let bi = h.block as usize;
        if h.flags & video_flags::LAST_BLOCK != 0 {
            match frame.last_block {
                Some(l) if l != h.block => {
                    self.stats.malformed += 1;
                    return;
                }
                _ => frame.last_block = Some(h.block),
            }
        }
        if frame.last_block.is_some_and(|l| bi > l as usize) {
            self.stats.malformed += 1;
            return;
        }
        if frame.blocks.len() <= bi {
            frame.blocks.resize_with(bi + 1, || None);
            frame.blocks_noticed = now;
        }
        let total = (h.k + h.m) as usize;
        let block = frame.blocks[bi].get_or_insert_with(|| Block {
            k: h.k,
            m: h.m,
            shard_size: h.shard_size,
            shards: vec![None; total],
            received: 0,
            last_arrival: now,
            last_shard_seen: false,
            passed_at: None,
            passed_quiet: false,
            data: None,
            nacks: 0,
            last_nack: None,
            asked: 0,
            quiet_nacked: false,
        });
        if block.k != h.k || block.m != h.m || block.shard_size != h.shard_size {
            self.stats.malformed += 1;
            return;
        }
        if block.data.is_some() || block.shards[h.shard as usize].is_some() {
            self.stats.duplicate_shards += 1;
            return;
        }
        if block.quiet_nacked {
            block.quiet_nacked = false;
            Self::judge_quiet(&mut self.quiet_late, self.cfg.quiet_judge, h.flags & video_flags::RETRANSMIT == 0);
        }
        block.shards[h.shard as usize] = Some(payload.to_vec());
        block.received += 1;
        frame.tally.shards = frame.tally.shards.saturating_add(1);
        block.last_arrival = now;
        if block.passed_quiet && h.flags & video_flags::RETRANSMIT == 0 {
            block.passed_at = None;
            block.passed_quiet = false;
        }
        if h.shard as usize == total - 1 {
            block.last_shard_seen = true;
            block.passed_at.get_or_insert(now);
        }
        if h.flags & video_flags::RETRANSMIT != 0 {
            if let Some(t) = frame.last_request {
                answer = Some(now - t);
            }
            self.stats.nack_recovered += 1;
            frame.tally.retx = frame.tally.retx.saturating_add(1);
            if block.asked & (1u64 << h.shard.min(63)) == 0 {
                // answered a whole-block request: count it as asked for too
                self.stats.nack_sent += 1;
            }
        } else {
            let cap = frame.first_arrival + self.cfg.max_streaming;
            frame.deadline = frame.deadline.max((now + budget).min(cap));
        }
        if block.received >= block.k as usize {
            let k = block.k as usize;
            let missing_data = block.shards[..k].iter().filter(|s| s.is_none()).count();
            match fec::recover(k, block.m as usize, &block.shards) {
                Some(data) => {
                    self.stats.fec_recovered += missing_data as u64;
                    frame.tally.fec = frame.tally.fec.saturating_add(missing_data as u16);
                    let mut bytes = Vec::with_capacity(k * block.shard_size as usize);
                    for d in data {
                        bytes.extend_from_slice(&d);
                    }
                    block.data = Some(bytes);
                    block.shards = Vec::new();
                }
                None => self.stats.malformed += 1,
            }
        }
        // whole frame?
        if let Some(last) = frame.last_block
            && frame.blocks.len() == last as usize + 1
            && frame.blocks.iter().all(|b| b.as_ref().is_some_and(|b| b.data.is_some()))
        {
            let mut bytes = Vec::new();
            for b in frame.blocks.iter_mut().flatten() {
                bytes.append(b.data.as_mut().unwrap_or(&mut Vec::new()));
            }
            match FrameMeta::parse(&bytes) {
                Ok((meta, au)) => {
                    let au = au.to_vec();
                    frame.complete = Some((meta, au));
                    frame.tally.completed_at = Some(now);
                    frame.blocks = Vec::new();
                }
                Err(_) => {
                    // undecodable: treat as lost at its deadline
                    self.stats.malformed += 1;
                    frame.blocks = Vec::new();
                    frame.last_block = None;
                    frame.deadline = now;
                }
            }
        }
        if let Some(a) = answer {
            self.note_answer(a);
        }
        self.advance(now, out);
    }

    fn declare_lost(&mut self, now: Micros, f: u32) {
        self.report_lost(now, f);
        self.break_chain();
    }

    /// Count a lost frame and report it at once (the sender asks the encoder for a recovery frame).
    fn report_lost(&mut self, now: Micros, f: u32) {
        self.stats.frames_lost += 1;
        self.lost.push_back((f, now));
        if self.lost.len() > 32 {
            self.lost.pop_front();
        }
        self.urgent = true;
    }

    fn break_chain(&mut self) {
        if self.chain == Chain::Intact {
            self.chain = Chain::Broken;
        }
    }

    fn skip(&mut self) {
        self.stats.frames_skipped += 1;
    }

    /// Hand the complete head frame to the decoder, or skip it.
    fn take_head(&mut self, now: Micros, out: &mut Vec<ReceivedFrame>) {
        let fno = self.next_frame;
        let Some(f) = self.frames.remove(&fno) else { return };
        self.next_frame = fno + 1;
        let fate = if f.complete.is_none() {
            RxFate::Lost
        } else if self.usable(f.complete.as_ref().map(|c| &c.0)) {
            RxFate::Delivered
        } else {
            RxFate::Skipped
        };
        self.trace(now, fno, Some(&f), fate);
        let Some((meta, au)) = f.complete else {
            return;
        };
        if fate != RxFate::Delivered {
            self.skip();
            return;
        }
        self.chain = Chain::Intact;
        if meta.kind == FrameKind::Key {
            self.keyframe_needed = false;
        }
        if let Some(prev) = self.last_handed_at {
            let gap = now - prev;
            if gap > self.cfg.freeze_gap && fno > self.last_handed + 1 {
                self.stats.freezes += 1;
                self.stats.freeze_us += gap.0;
            }
        }
        self.last_handed = fno;
        self.last_handed_at = Some(now);
        self.stats.frames_delivered += 1;
        self.delivered_times.push_back(now);
        while self.delivered_times.front().is_some_and(|&t| now - t > Micros::from_secs(2)) {
            self.delivered_times.pop_front();
        }
        out.push(ReceivedFrame {
            stream: self.id,
            frame: fno,
            meta,
            au,
            first_arrival: f.first_arrival,
            delivered_at: now,
        });
    }

    /// Whether a complete frame of `meta` can go to the decoder now (the chain's rule in `take_head`).
    fn usable(&self, meta: Option<&FrameMeta>) -> bool {
        let Some(meta) = meta else { return false };
        match self.chain {
            Chain::Intact => true,
            Chain::Broken => {
                meta.kind == FrameKind::Key
                    || (meta.kind == FrameKind::Recovery
                        && meta.recovery_base != 0
                        && meta.recovery_base <= self.last_delivered)
            }
            Chain::NeedKey => meta.kind == FrameKind::Key,
        }
    }

    /// Frame `fno` left the receiver (`f`: what was known of it; None: nothing).
    fn trace(&mut self, now: Micros, fno: u32, f: Option<&Frame>, fate: RxFate) {
        let t = f.map(|f| f.tally).unwrap_or_default();
        let meta = f.and_then(|f| f.complete.as_ref());
        self.traces.push(RxTrace {
            stream: self.id,
            frame: fno,
            fate,
            kind: meta.map(|m| m.0.kind as u8),
            au_bytes: meta.map_or(0, |m| m.1.len() as u32),
            capture_us: meta.map(|m| m.0.capture_us),
            first_arrival: t.first_shard,
            last_arrival: t.last_shard,
            completed_at: t.completed_at,
            decided_at: now,
            shards: t.shards,
            fec: t.fec,
            retx: t.retx,
            nack_items: t.nack_items,
        });
    }

    /// The first complete frame after the head that restarts the chain, if any.
    fn resync_after_head(&self) -> Option<u32> {
        self.frames.range(self.next_frame + 1..).find_map(|(&n, f)| {
            let (meta, _) = f.complete.as_ref()?;
            let ok = match self.chain {
                Chain::NeedKey => meta.kind == FrameKind::Key,
                _ => {
                    meta.kind == FrameKind::Key
                        || (meta.kind == FrameKind::Recovery
                            && meta.recovery_base != 0
                            && meta.recovery_base <= self.last_delivered)
                }
            };
            ok.then_some(n)
        })
    }

    /// Deliver what can be delivered, declare frames past their deadline lost, skip what can't be used.
    pub(crate) fn advance(&mut self, now: Micros, out: &mut Vec<ReceivedFrame>) {
        self.refresh_quiet(now);
        // No head: it never showed up (a later frame would have made a placeholder for it), so nothing is known.
        while let Some(head) = self.frames.get(&self.next_frame) {
            if head.complete.is_some() {
                self.take_head(now, out);
                continue;
            }
            // a broken chain: a known delta can go at once (it can't be used anyway)
            if self.chain != Chain::Intact && !head.placeholder && !head.resync_flag() {
                let reported = head.lost_reported;
                let fno = self.next_frame;
                let gone = self.frames.remove(&fno);
                self.trace(now, fno, gone.as_ref(), if reported { RxFate::Lost } else { RxFate::Skipped });
                self.next_frame += 1;
                if !reported {
                    self.skip();
                }
                continue;
            }
            // a later key / usable recovery frame is complete: everything before it is moot
            if let Some(r) = self.resync_after_head() {
                while self.next_frame < r {
                    let fno = self.next_frame;
                    let gone = self.frames.remove(&fno);
                    let reported = gone.as_ref().is_some_and(|f| f.lost_reported);
                    self.trace(now, fno, gone.as_ref(), if reported { RxFate::Lost } else { RxFate::Skipped });
                    if !reported {
                        self.skip();
                    }
                    self.next_frame += 1;
                }
                continue;
            }
            // past its deadline, or it can't complete any more: lost now
            if head.deadline <= now || !head.can_complete(now, self.rtt_p50, self.answer_wait(self.rtt), &self.cfg) {
                let reported = head.lost_reported;
                let f = self.next_frame;
                let gone = self.frames.remove(&f);
                self.trace(now, f, gone.as_ref(), RxFate::Lost);
                self.next_frame += 1;
                if !reported {
                    self.report_lost(now, f);
                }
                self.break_chain();
                continue;
            }
            break;
        }
        // A frame behind the head that can't complete is reported at once, before the head is decided: the
        // recovery frame is then on its way while the head still finishes. (With the chain already broken a
        // delta doesn't matter; it is skipped when it gets there.)
        let chain_ok = self.chain == Chain::Intact;
        let answer = self.answer_wait(self.rtt);
        let doomed: Vec<u32> = self
            .frames
            .range(self.next_frame + 1..)
            .filter(|(_, f)| {
                !f.lost_reported
                    && (chain_ok || f.placeholder || f.resync_flag())
                    && !f.can_complete(now, self.rtt_p50, answer, &self.cfg)
            })
            .map(|(&n, _)| n)
            .collect();
        for n in doomed {
            if let Some(f) = self.frames.get_mut(&n) {
                f.lost_reported = true;
            }
            self.report_lost(now, n);
        }
    }

    /// Collect NACKs due at `now` (stored for the next feedback). Returns true if any.
    pub(crate) fn collect_nacks(&mut self, now: Micros) -> bool {
        self.refresh_quiet(now);
        let margin = self.rtt_p50.mul_f64(self.cfg.nack_margin_rtt);
        // the retry goes once the first answer is overdue
        let retry = self.answer_wait(self.rtt);
        let wait = self.cfg.reorder_wait;
        let chain_ok = self.chain == Chain::Intact;
        let mut items = Vec::new();
        let mut shards_asked = 0u64;
        for (&fno, f) in self.frames.iter_mut() {
            if f.complete.is_some() || f.lost_reported {
                continue;
            }
            let before = items.len();
            if !chain_ok && !f.placeholder && !f.resync_flag() {
                continue;
            }
            if f.deadline <= now || f.deadline - now <= margin {
                continue;
            }
            let due = |state: Option<(u8, Micros)>| match state {
                None => true,
                Some((1, last)) => now - last >= retry,
                _ => false,
            };
            if f.placeholder {
                let key = (0u8, NackItem::BLOCK_AND_LATER);
                let st = f.special.get(&key).copied();
                if f.passed_at.is_some_and(|p| now >= p + wait) && due(st) {
                    items.push(NackItem { frame: fno, block: 0, shard: NackItem::BLOCK_AND_LATER });
                    f.special.insert(key, (st.map_or(1, |s| s.0 + 1), now));
                    f.tally.nack_items = f.tally.nack_items.saturating_add(1);
                }
                continue;
            }
            let known_blocks = f.blocks.len();
            for bi in 0..known_blocks {
                match &mut f.blocks[bi] {
                    None => {
                        let key = (bi as u8, NackItem::WHOLE_BLOCK);
                        let st = f.special.get(&key).copied();
                        if now >= f.blocks_noticed + wait && due(st) {
                            items.push(NackItem { frame: fno, block: bi as u8, shard: NackItem::WHOLE_BLOCK });
                            f.special.insert(key, (st.map_or(1, |s| s.0 + 1), now));
                        }
                    }
                    Some(b) => {
                        if b.data.is_some() || b.received >= b.k as usize {
                            continue;
                        }
                        let Some(passed) = b.passed_at else { continue };
                        let eligible = if b.last_shard_seen { passed } else { passed + wait };
                        if now < eligible {
                            continue;
                        }
                        let st = b.last_nack.map(|t| (b.nacks, t));
                        if !due(st) {
                            continue;
                        }
                        // Ask for up to twice what is needed (all that is missing, usually): one lost retransmit
                        // then doesn't cost the frame. Data shards first, then parity.
                        let want = 2 * (b.k as usize - b.received);
                        let mut asked = 0;
                        for (si, s) in b.shards.iter().enumerate() {
                            if asked == want {
                                break;
                            }
                            if s.is_none() {
                                items.push(NackItem { frame: fno, block: bi as u8, shard: si as u16 });
                                if b.asked & (1u64 << si.min(63)) == 0 {
                                    shards_asked += 1;
                                }
                                b.asked |= 1u64 << si.min(63);
                                asked += 1;
                            }
                        }
                        b.nacks += 1;
                        b.last_nack = Some(now);
                        b.quiet_nacked |= b.passed_quiet;
                    }
                }
            }
            if f.last_block.is_none() && f.passed_at.is_some_and(|p| now >= p + wait) {
                let next = known_blocks.min(255) as u8;
                let key = (next, NackItem::BLOCK_AND_LATER);
                let st = f.special.get(&key).copied();
                if due(st) {
                    items.push(NackItem { frame: fno, block: next, shard: NackItem::BLOCK_AND_LATER });
                    f.special.insert(key, (st.map_or(1, |s| s.0 + 1), now));
                    f.quiet_nacked |= f.passed_quiet;
                }
            }
            if items.last().is_some_and(|i| i.frame == fno) {
                f.last_request = Some(now);
            }
            f.tally.nack_items = f.tally.nack_items.saturating_add((items.len() - before) as u16);
        }
        self.stats.nack_sent += shards_asked;
        let any = !items.is_empty();
        self.pending_nacks.extend(items);
        any
    }

    pub(crate) fn take_nacks(&mut self) -> Vec<NackItem> {
        std::mem::take(&mut self.pending_nacks)
    }

    /// When something may change by itself: a deadline, a NACK becoming eligible or a retry falling due.
    pub(crate) fn next_timeout(&self, now: Micros) -> Option<Micros> {
        let margin = self.rtt_p50.mul_f64(self.cfg.nack_margin_rtt);
        let retry = self.answer_wait(self.rtt);
        let wait = self.cfg.reorder_wait;
        let mut best: Option<Micros> = None;
        let chain_ok = self.chain == Chain::Intact;
        // `>= now`: a caller that re-polls at the fire time still sees it (handle_timeout acts on it)
        let mut consider = |t: Micros| {
            if t >= now {
                best = Some(best.map_or(t, |b: Micros| b.min(t)));
            }
        };
        // When a frame may stop being able to complete (strictly later: at `now` it was just checked): the NACK
        // window closing, an answer falling overdue.
        let mut hope_ends: Option<Micros> = None;
        let mut hope = |t: Micros| {
            if t > now {
                hope_ends = Some(hope_ends.map_or(t, |b: Micros| b.min(t)));
            }
        };
        for f in self.frames.values() {
            if f.complete.is_some() || f.lost_reported {
                continue;
            }
            hope(f.deadline - margin);
            let answer = retry;
            let give_up = wait + self.cfg.give_up_wait;
            for (_, last) in f.special.values() {
                hope(*last + answer + self.cfg.give_up_wait);
            }
            match f.passed_at {
                Some(p) => hope(p + give_up),
                None => hope(f.last_arrival + self.quiet_wait()),
            }
            hope(f.blocks_noticed + give_up);
            for b in f.blocks.iter().flatten() {
                if let Some(l) = b.last_nack {
                    hope(l + answer + self.cfg.give_up_wait);
                }
                match b.passed_at {
                    Some(p) => hope(p + give_up),
                    None if b.data.is_none() => hope(b.last_arrival + self.quiet_wait()),
                    None => {}
                }
            }
        }
        for (&n, f) in self.frames.iter() {
            if f.complete.is_some() {
                continue;
            }
            // At its deadline the head is declared lost; a frame behind it is reported lost (if it still matters
            // and wasn't already), else it waits for the head to pass it and nothing happens then.
            let matters = chain_ok || f.placeholder || f.resync_flag();
            if n == self.next_frame || (matters && !f.lost_reported) {
                consider(f.deadline);
            }
            if !matters {
                continue;
            }
            let nack_ok = |at: Micros| f.deadline > at + margin;
            let later = |state: Option<(u8, Micros)>, eligible: Micros| -> Option<Micros> {
                let t = match state {
                    None => eligible,
                    Some((1, last)) => (last + retry).max(eligible),
                    _ => return None,
                };
                nack_ok(t).then_some(t)
            };
            if f.placeholder {
                if let Some(p) = f.passed_at
                    && let Some(t) = later(f.special.get(&(0, NackItem::BLOCK_AND_LATER)).copied(), p + wait)
                {
                    consider(t);
                }
                continue;
            }
            for (bi, b) in f.blocks.iter().enumerate() {
                match b {
                    None => {
                        if let Some(t) =
                            later(f.special.get(&(bi as u8, NackItem::WHOLE_BLOCK)).copied(), f.blocks_noticed + wait)
                        {
                            consider(t);
                        }
                    }
                    Some(b) if b.data.is_none() => {
                        if let Some(p) = b.passed_at {
                            let eligible = if b.last_shard_seen { p } else { p + wait };
                            if let Some(t) = later(b.last_nack.map(|l| (b.nacks, l)), eligible) {
                                consider(t);
                            }
                        }
                    }
                    _ => {}
                }
            }
            if f.last_block.is_none()
                && let Some(p) = f.passed_at
            {
                let key = (f.blocks.len().min(255) as u8, NackItem::BLOCK_AND_LATER);
                if let Some(t) = later(f.special.get(&key).copied(), p + wait) {
                    consider(t);
                }
            }
        }
        crate::time::earliest(best, hope_ends)
    }

    /// The app's decoder result for a delivered frame.
    pub(crate) fn decoded(&mut self, frame: u32, ok: bool) {
        if ok {
            if frame > self.last_delivered && frame <= self.last_handed {
                self.last_delivered = frame;
            }
        } else {
            self.stats.decode_failures += 1;
            self.chain = Chain::NeedKey;
            self.keyframe_needed = true;
            self.urgent = true;
        }
    }

    /// The decoder can't continue (e.g. the app restarted it): ask for a key frame.
    pub(crate) fn request_keyframe(&mut self) {
        self.chain = Chain::NeedKey;
        self.keyframe_needed = true;
        self.urgent = true;
    }

    pub(crate) fn report(&mut self, now: Micros) -> FrameReport {
        while self.lost.front().is_some_and(|l| now - l.1 > self.cfg.lost_report_keep) {
            self.lost.pop_front();
        }
        self.urgent = false;
        FrameReport {
            stream: self.id,
            last_delivered: self.last_delivered,
            lost: self.lost.iter().map(|l| l.0).collect(),
            flags: if self.keyframe_needed { report_flags::KEYFRAME_NEEDED } else { 0 },
        }
    }

    /// Delivered frames per second over the last 2 s.
    pub(crate) fn fps(&self, now: Micros) -> f64 {
        self.delivered_times.iter().filter(|&&t| now - t <= Micros::from_secs(2)).count() as f64 / 2.0
    }

    /// An ongoing freeze (frames lost/skipped and nothing delivered for > freeze gap), for stats.
    pub(crate) fn ongoing_freeze(&self, now: Micros) -> Option<Micros> {
        let at = self.last_handed_at?;
        let gap = now - at;
        (gap > self.cfg.freeze_gap && self.chain != Chain::Intact).then_some(gap)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::video_tx::{VideoSendConfig, VideoStreamSender};
    use crate::wire::Codec;

    fn meta(kind: FrameKind, base: u32) -> FrameMeta {
        FrameMeta { codec: Codec::H264, kind, width: 10, height: 10, capture_us: 0, recovery_base: base, au_len: 0 }
    }

    struct Pair {
        tx: VideoStreamSender,
        rx: VideoStreamReceiver,
        tseq: u64,
        out: Vec<ReceivedFrame>,
    }

    impl Pair {
        fn take_nacks_is_empty(&mut self) -> bool {
            self.rx.take_nacks().is_empty()
        }
        fn new() -> Pair {
            Pair {
                tx: VideoStreamSender::new(0, VideoSendConfig::default()),
                rx: {
                    let mut rx = VideoStreamReceiver::new(0, VideoReceiveConfig::default());
                    rx.set_rtt(Micros::from_millis(50), Micros::from_millis(50));
                    rx
                },
                tseq: 0,
                out: Vec::new(),
            }
        }
        /// Send a frame; `drop` decides per shard index (in send order) whether it is lost.
        fn frame(&mut self, now: Micros, kind: FrameKind, base: u32, size: usize, drop: impl Fn(usize) -> bool) -> u32 {
            let mut q = VecDeque::new();
            let au: Vec<u8> = (0..size).map(|i| i as u8).collect();
            let f = self.tx.send_frame(now, meta(kind, base), &au, 0.0, 1200, &mut q).unwrap();
            for (i, d) in q.into_iter().enumerate() {
                self.tseq += 1;
                if drop(i) {
                    continue;
                }
                let (h, p) = VideoHeader::parse(&d).unwrap();
                self.rx.on_shard(now, &h, p, Micros::from_millis(50), &mut self.out);
            }
            f
        }
        /// Send a frame whose shard `i` arrives at `at(i)` (None: lost).
        fn frame_at(&mut self, size: usize, at: impl Fn(usize) -> Option<Micros>) -> u32 {
            let mut q = VecDeque::new();
            let f =
                self.tx.send_frame(Micros(0), meta(FrameKind::Delta, 0), &vec![7u8; size], 0.0, 1200, &mut q).unwrap();
            let mut arrivals: Vec<(Micros, Vec<u8>)> =
                q.into_iter().enumerate().filter_map(|(i, d)| at(i).map(|t| (t, d))).collect();
            arrivals.sort_by_key(|a| a.0);
            for (t, d) in arrivals {
                let (h, p) = VideoHeader::parse(&d).unwrap();
                let rtt = self.rx.rtt_p50;
                self.rx.on_shard(t, &h, p, rtt, &mut self.out);
            }
            f
        }
        fn delivered(&mut self) -> Vec<u32> {
            let v: Vec<u32> = self.out.drain(..).map(|f| f.frame).collect();
            for &f in &v {
                self.rx.decoded(f, true);
            }
            v
        }
    }

    #[test]
    fn delivers_in_order_and_recovers_with_fec() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 10_000, |_| false);
        // lose one data shard: parity recovers it
        p.frame(Micros(1000), FrameKind::Delta, 0, 10_000, |i| i == 2);
        assert_eq!(p.delivered(), vec![1, 2]);
        assert_eq!(p.rx.stats.fec_recovered, 1);
        assert_eq!(p.out.len(), 0);
    }

    #[test]
    fn every_frame_leaves_a_trace() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 10_000, |_| false);
        p.frame(Micros(1000), FrameKind::Delta, 0, 10_000, |i| i == 2);
        // frame 3 loses every shard; 4 arrives (3 is a placeholder), then 3's deadline passes
        p.frame(Micros(2000), FrameKind::Delta, 0, 10_000, |_| true);
        p.frame(Micros(3000), FrameKind::Delta, 0, 10_000, |_| false);
        p.rx.advance(Micros::from_secs(2), &mut p.out);
        let t = p.rx.traces.take();
        let fates: Vec<(u32, RxFate)> = t.iter().map(|t| (t.frame, t.fate)).collect();
        assert_eq!(
            fates,
            vec![(1, RxFate::Delivered), (2, RxFate::Delivered), (3, RxFate::Lost), (4, RxFate::Skipped)]
        );
        assert_eq!(t[0].kind, Some(FrameKind::Key as u8));
        assert_eq!(t[1].fec, 1);
        assert_eq!(t[1].au_bytes, 10_000);
        assert!(t[1].completed_at.is_some() && t[1].first_arrival == Some(Micros(1000)));
        assert_eq!(t[2].first_arrival, None);
        assert_eq!(t[2].completed_at, None);
    }

    #[test]
    fn lost_frame_breaks_the_chain_until_recovery() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        assert_eq!(p.delivered(), vec![1]);
        // frame 2 lost entirely (single shard, no parity)
        p.frame(Micros::from_millis(10), FrameKind::Delta, 0, 100, |_| true);
        p.frame(Micros::from_millis(20), FrameKind::Delta, 0, 100, |_| false);
        // frame 3 waits behind the placeholder for 2
        assert!(p.delivered().is_empty());
        p.rx.advance(Micros::from_millis(200), &mut p.out);
        assert!(p.delivered().is_empty());
        assert_eq!(p.rx.stats.frames_lost, 1);
        assert_eq!(p.rx.stats.frames_skipped, 1);
        assert_eq!(p.rx.report(Micros::from_millis(200)).lost, vec![2]);
        // a later delta is skipped at once; a recovery frame on frame 1 resumes
        p.frame(Micros::from_millis(210), FrameKind::Delta, 0, 100, |_| false);
        assert!(p.delivered().is_empty());
        p.frame(Micros::from_millis(220), FrameKind::Recovery, 1, 100, |_| false);
        assert_eq!(p.delivered(), vec![5]);
        p.frame(Micros::from_millis(230), FrameKind::Delta, 0, 100, |_| false);
        assert_eq!(p.delivered(), vec![6]);
        // a recovery frame on a base never delivered is not used
        p.frame(Micros::from_millis(240), FrameKind::Delta, 0, 100, |_| true);
        p.frame(Micros::from_millis(250), FrameKind::Delta, 0, 100, |_| false);
        p.rx.advance(Micros::from_millis(500), &mut p.out);
        p.frame(Micros::from_millis(510), FrameKind::Recovery, 99, 100, |_| false);
        assert!(p.delivered().is_empty());
        p.frame(Micros::from_millis(520), FrameKind::Key, 0, 100, |_| false);
        assert_eq!(p.delivered(), vec![10]);
    }

    #[test]
    fn nacks_missing_shards_and_uses_retransmits() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        // 3 data shards + 1 parity, lose two data shards
        p.frame(Micros::from_millis(10), FrameKind::Delta, 0, 3000, |i| i == 0 || i == 1);
        assert!(p.delivered().is_empty());
        // the last shard (parity) was seen: eligible at once
        assert!(p.rx.collect_nacks(Micros::from_millis(10)));
        let n = p.rx.take_nacks();
        // one needed, both missing asked for
        assert_eq!(n.len(), 2, "{n:?}");
        let mut q = VecDeque::new();
        p.tx.on_nack(Micros::from_millis(11), &n, Micros::from_millis(10), &mut q, &mut Vec::new());
        for d in q {
            p.tseq += 1;
            let (h, pl) = VideoHeader::parse(&d).unwrap();
            p.rx.on_shard(Micros::from_millis(60), &h, pl, Micros::from_millis(50), &mut p.out);
        }
        assert_eq!(p.delivered(), vec![2]);
        assert_eq!(p.rx.stats.nack_recovered, 1);
        assert_eq!(p.rx.stats.fec_recovered, 1);
    }

    #[test]
    fn no_nack_without_time() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        p.frame(Micros::from_millis(10), FrameKind::Delta, 0, 3000, |i| i == 0 || i == 1);
        // rtt 50 ms: deadline 75 ms after arrival (85), margin 60 ms → allowed until 25 ms
        assert!(!p.rx.collect_nacks(Micros::from_millis(30)));
        assert!(p.rx.collect_nacks(Micros::from_millis(20)));
        p.rx.take_nacks();
        // the retry (1.5 rtt later) would be past the margin: none, and no timer for it
        assert!(!p.rx.collect_nacks(Micros::from_millis(95)));
        // no timer for a retry; the next one is the NACK window closing (deadline − margin), then the deadline
        assert_eq!(p.rx.next_timeout(Micros::from_millis(20)), Some(Micros::from_millis(25)));
    }

    fn ms(v: u64) -> Micros {
        Micros::from_millis(v)
    }

    #[test]
    fn a_frame_no_nack_can_save_is_lost_before_its_deadline() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        // 3 data + 1 parity at 10 ms (deadline 85 ms), a data shard and the parity lost. Nothing follows, so the
        // gap shows after the quiet wait (25 ms, +3 reorder): 57 ms left, less than the 60 ms a NACK needs.
        p.frame_at(3000, |i| (i == 0 || i == 2).then_some(ms(10)));
        p.rx.advance(ms(25), &mut p.out);
        assert!(!p.rx.collect_nacks(ms(28)));
        p.rx.advance(ms(42), &mut p.out);
        assert_eq!(p.rx.stats.frames_lost, 0);
        // given up after the give-up wait, 41 ms before the deadline, and reported at once
        p.rx.advance(ms(44), &mut p.out);
        assert_eq!(p.rx.stats.frames_lost, 1);
        assert!(p.rx.urgent);
        assert_eq!(p.rx.report(ms(44)).lost, vec![2]);
    }

    #[test]
    fn a_doomed_frame_behind_a_pending_head_is_reported_at_once() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        // frame 2: two data shards lost, parity seen → NACKed at once, its answer still due
        p.frame_at(3000, |i| (i >= 2).then_some(ms(10)));
        assert!(p.rx.collect_nacks(ms(10)));
        p.rx.take_nacks();
        // frame 3: can't be saved (as above)
        p.frame_at(3000, |i| (i == 0 || i == 2).then_some(ms(12)));
        p.rx.advance(ms(27), &mut p.out);
        p.rx.collect_nacks(ms(30));
        p.rx.advance(ms(46), &mut p.out);
        // 3 is reported while 2 still waits for its retransmit
        assert_eq!(p.rx.report(ms(46)).lost, vec![3]);
        assert!(p.out.is_empty());
        // 2's retransmit comes: 2 is delivered, 3 is dropped without being counted twice
        let mut q = VecDeque::new();
        p.tx.on_nack(ms(50), &[NackItem { frame: 2, block: 0, shard: 0 }], ms(1), &mut q, &mut Vec::new());
        for d in q {
            let (h, pl) = VideoHeader::parse(&d).unwrap();
            p.rx.on_shard(ms(60), &h, pl, ms(50), &mut p.out);
        }
        assert_eq!(p.delivered(), vec![2]);
        p.rx.advance(ms(61), &mut p.out);
        assert_eq!(p.rx.stats.frames_lost, 1);
        assert_eq!(p.rx.next_frame, 4);
    }

    #[test]
    fn a_retry_goes_once_the_first_answer_is_overdue() {
        let mut p = Pair::new();
        p.rx.set_rtt(ms(20), ms(20));
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        // first arrival at 10 ms: deadline 70 ms (the 60 ms floor), margin 24 ms
        p.frame_at(3000, |i| (i >= 2).then_some(ms(10)));
        assert!(p.rx.collect_nacks(ms(10)));
        p.rx.take_nacks();
        // the answer is due 1.5 rtt + 3 ms later (nothing measured yet): no retry before
        assert!(!p.rx.collect_nacks(ms(30)));
        assert_eq!(p.rx.next_timeout(ms(30)), Some(ms(43)));
        // then the one retry, still answerable before the deadline (70 − 43 > 24)
        assert!(p.rx.collect_nacks(ms(43)));
        assert!(!p.take_nacks_is_empty());
        assert!(!p.rx.collect_nacks(ms(60)));
    }

    #[test]
    fn decoder_failure_needs_a_key_frame() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        p.frame(Micros(1), FrameKind::Delta, 0, 100, |_| false);
        p.out.clear();
        p.rx.decoded(2, false);
        assert_eq!(p.rx.report(Micros(2)).flags, report_flags::KEYFRAME_NEEDED);
        p.frame(Micros(3), FrameKind::Recovery, 1, 100, |_| false);
        assert!(p.delivered().is_empty());
        p.frame(Micros(4), FrameKind::Key, 0, 100, |_| false);
        assert_eq!(p.delivered(), vec![4]);
        assert_eq!(p.rx.report(Micros(5)).flags, 0);
    }

    #[test]
    fn complete_key_frame_jumps_an_incomplete_head() {
        let mut p = Pair::new();
        p.frame(Micros(0), FrameKind::Key, 0, 100, |_| false);
        p.delivered();
        p.frame(Micros(1000), FrameKind::Delta, 0, 3000, |i| i < 2);
        p.frame(Micros(2000), FrameKind::Key, 0, 100, |_| false);
        assert_eq!(p.delivered(), vec![3]);
        assert_eq!(p.rx.stats.frames_skipped, 1);
        assert_eq!(p.rx.stats.frames_lost, 0);
    }
}
