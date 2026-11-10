//! # uu Link media layer
//!
//! Sans-IO state machines for the real-time part of uu Link (`docs/LINK.md` §4.3 wire formats, §5 media rules):
//! per-frame Reed-Solomon FEC, deadline-aware NACK, frame skip with recovery-frame resync, GCC-style rate control
//! that also drives the transport's congestion window, audio redundancy and exactly-once input. No sockets, no
//! threads, no async runtime, no clock: every call takes `now: Micros` from the caller's monotonic clock, so the
//! same code runs in the deterministic [`sim`] and in production.
//!
//! ## The two sides
//!
//! A session has one [`ServerMedia`] on the computer and one [`ClientMedia`] on the phone. Each one owns every
//! datagram channel of its side:
//!
//! | | server → client | client → server |
//! |---|---|---|
//! | 1 video, 2 audio, 5 cursor | [`ServerMedia`] sends | [`ClientMedia`] receives |
//! | 3 input | — | [`ClientMedia`] sends, [`ServerMedia`] receives |
//! | 4 feedback | input acks | transport-cc, NACK, frame reports, audio reports |
//!
//! The transport routes every incoming datagram (byte 0 = `channel << 4 | 1`) of the session to
//! `handle_datagram`; it never parses media itself.
//!
//! ## Calling convention
//!
//! The same loop for both sides (quinn-proto style):
//!
//! 1. Feed inputs: `handle_datagram(now, bytes)` for each datagram from the peer; app calls (`send_frame`,
//!    `send_audio`, `send_cursor`, `send_input`, `frame_decoded`, …); transport facts (`set_rtt`,
//!    `set_max_datagram`, `set_network`, `on_persistent_congestion`).
//! 2. Drain `poll_transmit(now)` until `None` and hand each datagram to the QUIC datagram queue, in order. (The
//!    server paces video, so a frame may come out over several timer turns.)
//! 3. Drain `poll_event()` until `None` and act on each event.
//! 4. Arm one timer at `poll_timeout(now)`; when it fires call `handle_timeout(now)` and go to 2.
//!
//! `poll_timeout` may return `now` (work is waiting in `poll_transmit`); `None` means no timer. Calls are cheap and
//! never block; the types are `Send` but not shared — keep each behind the session's own lock or task.
//!
//! ```
//! use uu_link_media::{ClientConfig, ClientEvent, ClientMedia, Codec, FrameKind, FrameMeta, Micros, ServerConfig,
//!     ServerEvent, ServerMedia};
//!
//! let mut server = ServerMedia::new(ServerConfig::default());
//! let mut client = ClientMedia::new(ClientConfig::default());
//! server.open_video(1);
//! client.open_video(1);
//! let now = Micros::from_millis(10);
//! let meta = FrameMeta { codec: Codec::H264, kind: FrameKind::Key, width: 1920, height: 1080,
//!     capture_us: 0, recovery_base: 0, au_len: 0 };
//! assert!(server.can_send_frame(now, 1, 0, None));
//! server.send_frame(now, 1, meta, &[0, 0, 0, 1, 0x65, 0x88]).unwrap();
//! while let Some(d) = server.poll_transmit(now) {
//!     client.handle_datagram(now, &d).unwrap();
//! }
//! while let Some(ev) = client.poll_event() {
//!     if let ClientEvent::Frame(f) = ev {
//!         client.frame_decoded(f.stream, f.frame, true);
//!     }
//! }
//! // the client's feedback goes back the same way
//! client.handle_timeout(Micros::from_millis(40));
//! while let Some(d) = client.poll_transmit(Micros::from_millis(40)) {
//!     server.handle_datagram(Micros::from_millis(40), &d).unwrap();
//! }
//! assert!(std::iter::from_fn(|| server.poll_event())
//!     .any(|e| e == ServerEvent::FrameDelivered { stream: 1, frame: 1 }));
//! ```
//!
//! ## Server (computer) side
//!
//! - `open_video(stream)` per `video.open`; `send_frame(now, stream, meta, au)` per encoded frame — but only when
//!   `can_send_frame(now, stream, transport_queued_bytes, transport_space)` says so (otherwise skip that
//!   picture). It also holds frames to the frame-rate cap (`frame_rate_cap(stream)`, from the encoder rate).
//! - Events: [`ServerEvent::TargetBitrate`] (set the encoder to `encoder_bps`), [`ServerEvent::FrameDelivered`]
//!   (LTR acks), [`ServerEvent::RecoveryNeeded`] (next frame = recovery frame on the newest acked LTR, or a key
//!   frame), [`ServerEvent::KeyframeNeeded`], [`ServerEvent::Input`] (feed the existing input handler).
//! - `target_rate()` returns a [`TargetRate`] the transport's congestion controller reads on every ack
//!   (`cwnd = max(2 × target × srtt, 16 × MTU)`).
//! - Frame numbers start at 1 per opened stream; `tseq` covers every video, audio and cursor datagram of the
//!   session and is stamped when `poll_transmit` hands the datagram out (`note_sent` may refine its send time).
//!
//! ## Client (phone) side
//!
//! - `open_video(stream)` / `open_audio(stream)` per `video.opened` / `audio.opened` (an early datagram opens the
//!   stream itself).
//! - Events: [`ClientEvent::Frame`] (decode, then `frame_decoded(stream, frame, ok)` — `lastDelivered` in reports
//!   only advances on `ok`, a failure asks for a key frame), [`ClientEvent::Audio`] (into the jitter buffer,
//!   concealing `gap_before`), [`ClientEvent::Cursor`], [`ClientEvent::InputAcked`] / [`ClientEvent::InputFailed`].
//! - `send_input(now, kind, json)`: [`InputKind::Discrete`] for down / up / click / key / text / scroll,
//!   [`InputKind::Move`] for pointer moves; an `Err(Overflow)` is a local 429.
//!
//! ## Stats
//!
//! Both sides' `stats(now)` return a [`MediaStats`]; [`MediaStats::line`] formats the `link:` line and
//! [`MediaStats::since`] makes interval counters.
//!
//! ## Where this differs from or fills in the spec
//!
//! Wire:
//! - NACK shard `0xFFFF` = every shard (data and parity) of the block, `0xFFFE` = of the block and every later
//!   block. A wholly missing frame (known only because a later one arrived) is asked for as `(frame, 0, 0xFFFE)`,
//!   a frame whose last blocks never came as `(frame, next, 0xFFFE)`.
//! - Multi-block frames: every block but the last is exactly full (`k × maxShard` bytes), so blocks concatenate
//!   without padding; the last block has even shards and its padding is cut by the meta's AU length.
//! - Input datagram `flags` is 0; the receiver relies on every datagram carrying all unacked discrete events
//!   (see [`input`]).
//!
//! Video receiver:
//! - A NACK asks for up to twice the shards still needed (usually all that are missing), so one lost retransmit
//!   doesn't cost the frame. The one retry goes when the first answer is overdue — the slowest recently measured
//!   NACK → retransmit time, at least 1.2 × rtt — if it can still be answered before the deadline (with the spec's
//!   deadline that is paths up to ~25 ms RTT; on 5g a second round trip doesn't fit 1.5 × rtt). So every NACK
//!   also goes again 10 ms later in a datagram of its own ([`ClientConfig::nack_repeat`]): one lost uplink datagram
//!   no longer costs the frame (the sender ignores the repeat for shards it re-sent within half an RTT).
//! - A frame is lost as soon as nothing can complete it any more, not at its deadline: a part is still missing
//!   after the reorder window, FEC can't finish it, no NACK answer is still due and no new NACK could be answered
//!   in time (15 ms of grace for a late reordered shard). A frame behind a still-hopeful head is reported then too,
//!   so the sender asks for a recovery frame at once.
//! - A block's sending counts as over when a later *original* shard of the same stream arrives (a stream's
//!   originals go in order), its own last shard arrives, or nothing came for 3 × the usual gap between a frame's
//!   shards (4–30 ms). Other datagrams prove nothing: video is paced and audio, cursor and retransmits go between
//!   its shards. The NACK margin uses the same RTT estimate as the deadline (the 10 s median).
//! - While a frame is still streaming in, its deadline follows its newest original shard (capped 1 s after the
//!   first): a key frame larger than `deadline × rate` would otherwise never be deliverable at low rates.
//! - More than 8 wholly missing frames in one gap (a blackout) are declared lost at once instead of fetched.
//! - With the chain broken, a known delta is skipped at once; a complete key frame (or usable recovery frame)
//!   behind an incomplete head is delivered without waiting, the frames before it counted as skipped.
//!
//! Rate control (all kept rules as specified, plus):
//! - Startup: until the first decrease (no remembered ceiling yet) the target grows 50 %/s instead of 8 %/s, and
//!   sending a quarter of it (not half) is enough to grow ([`RateConfig::startup_increase_per_sec`]); loss above
//!   the loss threshold pauses it. A screen sends in bursts: at 8 %/s a 5g session took ~100 s from 3.5 Mbps to its
//!   20 Mbps cap. In the simulator the 5g rate averages 15–18 Mbps over 30 s instead of 5–12.
//! - A delay-based decrease also needs a standing queue: the lowest one-way delay of the last 200 ms more than
//!   15 ms above the 10 s minimum (jitter spikes don't lift a window's minimum; the old flow control's rule).
//!   Without it 40 ms of jitter walked the rate to the floor.
//! - A standing queue above 30 ms for 400 ms is overuse even when the trend is flat (a full bottleneck queue
//!   stops growing, so the trendline reads normal); no increase while it stands.
//! - One delay-based decrease per overuse verdict (the detector must leave overuse first), at most one per rtt.
//! - Overuse → the stream should *send* `0.85 ×` the link capacity: the best 200 ms delivered rate of the last
//!   3 s (a burst drains at the link's rate, so this is the link's, not the rate around the burst), and the target
//!   is scaled by the measured sent / target overshoot (key, recovery and large frames, parity rounding,
//!   retransmits, audio). A standing queue decreases toward 0.85 × the delivered rate (the link is busy then).
//!   Delay-based decreases are also held while content-limited (as the old flow control did); the key-frame grace
//!   holds trend-based decreases only.
//! - A standing queue that is draining (a burst over a path with little headroom) isn't overuse.
//! - The 0.9× ceiling is `0.9 × max(rate before, capacity)`, taken once per congestion episode (decreases within
//!   2 s keep the first ceiling), so a cascade doesn't ratchet it down for 120 s.
//! - `RecoveryNeeded` / `KeyframeNeeded` are repeated after 1 s if the app hasn't answered. With
//!   [`VideoSendConfig::recovery_on_nack`] (off by default; meant for LTR encoders) a NACK also asks for a
//!   recovery frame at once (at most every 500 ms); a NACK for a frame no longer cached always does.
//!
//! Sending: [`ServerMedia::poll_transmit`] paces retransmits and video at 1.8 × the target (under the transport's
//! `cwnd / srtt` = 2 × target), and no faster than 1.1 × the bottleneck capacity measured at the last real queue
//! (for 30 s), with a 5 ms burst. Input acks, audio and cursor go unpaced and first, so a heavy key frame can't
//! hold them up; the transport's queue stays short. The spec's "all handed to QUIC at once" became this.
//!
//! Others: the newest input move rides in its first two datagrams (immediately and 5 ms later) and in resends
//! while discrete events are unacked; a settled cursor position is repeated once after 50 ms; the audio report's
//! loss is pre-redundancy over the last 100 packets; `tseq` is stamped when `poll_transmit` hands a datagram out
//! (sizes are datagram bytes, no QUIC overhead). [`MediaStats::since`] makes the `link:` line's sent rate and fps
//! the interval's averages.

pub mod audio;
pub mod client;
pub mod cursor;
pub mod fec;
pub mod input;
pub mod probe;
pub mod rate;
pub mod server;
pub mod sim;
pub mod stats;
mod tcc;
pub mod time;
pub mod trace;
pub mod video_rx;
pub mod video_tx;
pub mod wire;

pub use audio::AudioPacket;
pub use client::{ClientConfig, ClientEvent, ClientMedia};
pub use fec::FecPolicy;
pub use input::{InputConfig, InputError, InputEvent};
pub use probe::ProbeRxStats;
pub use rate::{LossKind, NetworkProfile, RateConfig, RateController, TargetRate};
pub use server::{SendGate, ServerConfig, ServerEvent, ServerMedia};
pub use stats::MediaStats;
pub use time::Micros;
pub use trace::{RxFate, RxTrace, TxTrace};
pub use video_rx::{ReceivedFrame, VideoReceiveConfig, VideoRxStats};
pub use video_tx::{SendError, VideoSendConfig, VideoTxStats};
pub use wire::{Channel, Codec, FrameKind, FrameMeta, InputKind, WireError};
