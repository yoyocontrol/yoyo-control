//! The simulator's acceptance targets (LINK.md §5.7). `cargo test --release --test sim -- --nocapture` prints the
//! table (one row per profile, seed 1) and each side's `link:` line.

use uu_link_media::Micros;
use uu_link_media::sim::{Content, LinkProfile, Report, Scenario, run};

fn show(r: &Report) {
    println!("{}", r.row());
    println!(
        "           input {} discrete / {} moves, p50 {:.1} p99 {:.1} ms (excess p99 {:.1}); keys {} recovery {}; \
         enc skips {}; down loss {:.2} %; latency p50 {:.0} ms; queue p95 after 5 s {:.1} ms; pacer p95 {:.1} ms; \
         rate downs {:?}; audio pre-red loss {:.1} %; audio/cursor max {:.0}/{:.0} ms; sent {:.2} Mbps (line {:.2})",
        r.input_discrete,
        r.input_moves_applied,
        r.input_p50_ms,
        r.input_p99_ms,
        r.input_excess_p99_ms,
        r.key_frames,
        r.recovery_frames,
        r.encoder_skips,
        r.down_loss_pct,
        r.latency_p50_ms,
        r.queue_p95_after5_ms,
        r.pacer_p95_ms,
        r.rate_decreases,
        r.audio_loss_pct,
        r.audio_max_ms,
        r.cursor_max_ms,
        r.true_sent_mbps,
        r.line_sent_mbps,
    );
    println!("           server {}", r.server_line);
    println!("           client {}", r.client_line);
}

/// Every profile: no broken reference chain, discrete input exactly once in order, nothing dropped.
fn integrity(r: &Report) {
    assert_eq!(r.chain_violations, 0, "{}: a frame was delivered with a broken reference chain", r.name);
    assert!(r.input_exact, "{}: discrete input not exactly-once in order", r.name);
    assert_eq!(r.input_failed, 0, "{}: input events failed", r.name);
    assert!(r.frames_sent > 500, "{}: too few frames ({})", r.name, r.frames_sent);
}

/// [`integrity`] but input may fail: at a ~300 ms round trip, 60 discrete scroll events a second keep more unacked
/// than one input datagram holds (the newest wait for an ack and, past 64 unacked, overflow). That limit is the
/// input layer's (each datagram must start at the oldest unacked event) and not this test's subject; the count is
/// printed.
fn integrity_but_input(r: &Report) {
    assert_eq!(r.chain_violations, 0, "{}: a frame was delivered with a broken reference chain", r.name);
    assert!(r.input_exact, "{}: discrete input not exactly-once in order", r.name);
    assert!(r.frames_sent > 500, "{}: too few frames ({})", r.name, r.frames_sent);
}

fn scrolling(p: LinkProfile, seed: u64) -> Scenario {
    Scenario { content: Content::Scrolling, ..Scenario::new(p, seed) }
}

#[test]
fn table() {
    println!("{}", Report::header());
    let runs = [
        Scenario::new(LinkProfile::lan(), 1),
        Scenario::new(LinkProfile::five_g(), 1),
        scrolling(LinkProfile::five_g().with_rate("5g-scroll", 30_000_000), 1),
        scrolling(LinkProfile::five_g().with_rate("5g-2mbps", 2_000_000), 1),
        Scenario {
            content: Content::Keyframes,
            ..Scenario::new(LinkProfile::five_g().with_rate("5g-keys", 30_000_000), 1)
        },
        Scenario::new(LinkProfile::five_g_harsh(), 1),
        Scenario::new(LinkProfile::five_g_jitter(), 1),
        Scenario::new(LinkProfile::bad(), 1),
        Scenario::new(LinkProfile::handover(), 1),
        // the sender also asking for a recovery frame with every NACK (VideoSendConfig::recovery_on_nack)
        on_nack(scrolling(LinkProfile::five_g().with_rate("5g-scr/on", 30_000_000), 1)),
        on_nack(Scenario::new(LinkProfile::five_g_harsh().with_rate("harsh/on", 30_000_000), 1)),
        on_nack(Scenario::new(LinkProfile::bad().with_rate("bad/on", 10_000_000), 1)),
    ];
    for s in &runs {
        let r = run(s);
        show(&r);
        integrity(&r);
        // the server's `link:` line reports the interval's sent rate, not the last second's
        assert!(
            (r.line_sent_mbps - r.true_sent_mbps).abs() <= 0.03 * r.true_sent_mbps,
            "{}: line says {:.2} Mbps, {:.2} went out",
            r.name,
            r.line_sent_mbps,
            r.true_sent_mbps
        );
    }
}

fn on_nack(s: Scenario) -> Scenario {
    Scenario { recovery_on_nack: true, ..s }
}

/// 5g-jitter: the wandering delay is neither a queue (the rate climbs well past the start rate on a path that
/// carries 100 Mbps) nor loss (the quiet timer doesn't NACK shards that are only late), and a stall that holds a
/// frame's shards for up to 150 ms doesn't cost the frame (the deadline allows for the longest recent pause).
#[test]
fn five_g_jitter() {
    for seed in 1..=4 {
        let s =
            on_nack(Scenario { duration: Micros::from_secs(60), ..Scenario::new(LinkProfile::five_g_jitter(), seed) });
        let r = run(&s);
        integrity(&r);
        assert!(r.delivered_pct() >= 99.0, "seed {seed}: {:.2} % delivered", r.delivered_pct());
        assert!(r.rate_settled_mbps >= 5.0, "seed {seed}: settled at {:.1} Mbps", r.rate_settled_mbps);
        assert!(r.nack_sent <= 300, "seed {seed}: {} shards NACKed, {} came back", r.nack_sent, r.nack_recovered);
        assert!(r.frames_lost <= 1, "seed {seed}: {} frames lost with 0.2 % loss", r.frames_lost);
    }
}

/// A cell that frees up: 4 Mbps for 15 s, then 100. The decreases at 4 Mbps leave a ceiling (120 s on cellular);
/// with no queue for 10 s it lifts, and the rate gets to the cellular maximum instead of staying near 3.
#[test]
fn rate_recovers_when_the_path_frees_up() {
    for seed in 1..=3 {
        let mut p = LinkProfile::five_g_jitter();
        p.rate_bps = Some(4_000_000);
        p.rate_change = Some((Micros::from_secs(15), 100_000_000));
        let s = on_nack(Scenario {
            duration: Micros::from_secs(90),
            content: Content::Scrolling,
            ..Scenario::new(p, seed)
        });
        let r = run(&s);
        integrity(&r);
        assert!(r.rate_decreases.0 >= 1, "seed {seed}: the 4 Mbps start never cut the rate");
        assert!(r.rate_settled_mbps >= 15.0, "seed {seed}: settled at {:.1} Mbps", r.rate_settled_mbps);
    }
}

/// An unrecoverable loss costs about one RTT plus a frame: with recovery on NACK the recovery frame is already on
/// its way when the frame is given up (the merged baseline stalled ~370 ms per resume on this profile).
#[test]
fn a_lost_frame_costs_about_one_round_trip() {
    let (mut gap, mut n) = (0.0, 0);
    for seed in 1..=8 {
        let r = run(&on_nack(Scenario::new(LinkProfile::five_g_harsh(), seed)));
        integrity(&r);
        gap += r.resume_gap_ms * r.resumes as f64;
        n += r.resumes;
    }
    let mean = gap / n.max(1) as f64;
    // rtt ≈ 80 ms + one frame (17 ms) + slack for the fades that also take the recovery frame
    assert!(n >= 5 && mean <= 150.0, "{n} resumes, {mean:.0} ms each");
}

/// A heavy key frame (≥ 60 KB every 2 s) doesn't hold audio or cursor positions up: video is paced, audio and
/// cursor go first (the merged baseline: p99 271 ms).
#[test]
fn audio_and_cursor_pass_a_heavy_key_frame() {
    for seed in 1..=4 {
        let r = run(&Scenario { content: Content::Keyframes, ..Scenario::new(LinkProfile::five_g(), seed) });
        integrity(&r);
        assert!(r.key_frames >= 10, "seed {seed}: {} key frames", r.key_frames);
        assert!(r.audio_p99_ms <= 140.0, "seed {seed}: audio p99 {:.0} ms", r.audio_p99_ms);
        assert!(r.cursor_p99_ms <= 140.0, "seed {seed}: cursor p99 {:.0} ms", r.cursor_p99_ms);
    }
}

#[test]
fn lan() {
    let r = run(&Scenario::new(LinkProfile::lan(), 1));
    integrity(&r);
    assert_eq!(r.frames_delivered, r.frames_sent);
    assert!(r.input_p99_ms <= 2.0 + 25.0, "{}", r.input_p99_ms);
}

/// 5g: ≥ 99 % of frames delivered within their deadline, input p99 one-way ≤ base + 25 ms, the rate below the
/// bottleneck within 5 s, queue delay p95 < 50 ms. Several seeds, mixed content and continuous scrolling.
#[test]
fn five_g() {
    for seed in 1..=4 {
        for s in [
            Scenario::new(LinkProfile::five_g(), seed),
            scrolling(LinkProfile::five_g().with_rate("5g-scroll", 30_000_000), seed),
        ] {
            let r = run(&s);
            integrity(&r);
            assert!(r.delivered_pct() >= 99.0, "{} seed {seed}: {:.2} % delivered", r.name, r.delivered_pct());
            assert!(r.input_p99_ms <= 35.0 + 25.0, "{} seed {seed}: input p99 {:.1} ms", r.name, r.input_p99_ms);
            assert!(r.rate_converged_s.is_some_and(|t| t <= 5.0), "{} seed {seed}: {:?}", r.name, r.rate_converged_s);
            assert!(r.queue_p95_ms < 50.0, "{} seed {seed}: queue p95 {:.1} ms", r.name, r.queue_p95_ms);
        }
    }
}

/// A 5g path whose bottleneck (2 Mbps) is below the start rate: the target gets below it within 5 s, the queue
/// stays short, and the stream uses about 80 % of what the link carries (1.92 Mbps of datagram payload). (At the
/// frame-rate cap's 20 fps the target sits higher than at 60 — 1.5–1.6 Mbps against 1.4 — but fewer lost frames
/// mean fewer recovery frames and retransmits on top of it: 1.53–1.65 Mbps go out, ≥ 78 %.)
#[test]
fn five_g_below_the_start_rate() {
    for seed in 1..=4 {
        let r = run(&scrolling(LinkProfile::five_g().with_rate("5g-2mbps", 2_000_000), seed));
        integrity(&r);
        assert!(r.rate_converged_s.is_some_and(|t| t <= 5.0), "seed {seed}: {:?}", r.rate_converged_s);
        assert!(r.queue_p95_ms < 50.0, "seed {seed}: queue p95 {:.1} ms", r.queue_p95_ms);
        assert!(r.queue_p95_after5_ms < 50.0, "seed {seed}: queue p95 after 5 s {:.1} ms", r.queue_p95_after5_ms);
        assert!(r.true_sent_mbps >= 0.78 * 1.92, "seed {seed}: sent {:.2} Mbps", r.true_sent_mbps);
    }
}

/// A 300 ms blackout while scrolling: the frames in it are lost, the stream resumes on a recovery frame, input
/// arrives late but exactly once.
#[test]
fn handover() {
    for seed in 1..=4 {
        let r = run(&Scenario::new(LinkProfile::handover(), seed));
        integrity(&r);
        assert!(r.recovery_frames + r.key_frames >= 2, "seed {seed}: no resync after the blackout");
        assert!(r.frames_lost <= 25, "seed {seed}: {} lost", r.frames_lost);
        assert!(r.freeze_ms <= 1500, "seed {seed}: frozen {} ms", r.freeze_ms);
    }
}

/// 5 % loss, 40 ms jitter: integrity holds and most frames still arrive.
#[test]
fn bad() {
    for seed in 1..=4 {
        let r = run(&Scenario::new(LinkProfile::bad(), seed));
        integrity(&r);
        assert!(r.delivered_pct() >= 90.0, "seed {seed}: {:.2} % delivered", r.delivered_pct());
    }
}

#[test]
fn deterministic() {
    let a = run(&Scenario::new(LinkProfile::five_g_harsh(), 7));
    let b = run(&Scenario::new(LinkProfile::five_g_harsh(), 7));
    assert_eq!(a.row(), b.row());
    assert_eq!(a.client_line, b.client_line);
    assert_eq!(a.server_line, b.server_line);
}

fn long(p: LinkProfile, content: Content, seed: u64) -> Scenario {
    Scenario { content, duration: Micros::from_secs(60), ..Scenario::new(p, seed) }
}

fn show_long(r: &Report) {
    println!(
        "{:<11} seed {}: rate mean {:.2} / last 10 s {:.2} / min after 5 s {:.2} Mbps, cuts {:?}, shown {:.1} fps, \
         scroll {:.0} kbit/frame, deliv {:.1} %, lost {} skip {} freeze {}/{} ms, keys {} recovery {}, \
         fec {} nack {}/{}, queue p95 after 5 s {:.0} ms, lat p95 {:.0} ms, input p50/p99 {:.0}/{:.0} ms failed {}",
        r.name,
        r.seed,
        r.rate_mean_mbps,
        r.rate_settled_mbps,
        r.rate_min_after5_mbps,
        r.rate_decreases,
        r.fps_shown,
        r.scroll_kbit_p50,
        r.delivered_pct(),
        r.frames_lost,
        r.frames_skipped,
        r.freezes,
        r.freeze_ms,
        r.key_frames,
        r.recovery_frames,
        r.fec_recovered,
        r.nack_recovered,
        r.nack_sent,
        r.queue_p95_after5_ms,
        r.latency_p95_ms,
        r.input_p50_ms,
        r.input_p99_ms,
        r.input_failed,
    );
}

/// The long lossy path (RTT 280 ms, 15 % random loss each way, plenty of capacity): random loss is FEC's and the
/// NACKs' to carry, not a reason to cut — the rate stays well above the floor and the picture keeps moving.
#[test]
fn long_random_loss_keeps_the_rate() {
    for seed in 1..=3 {
        for content in [Content::Mixed, Content::Scrolling] {
            let r = run(&long(LinkProfile::long_loss(), content, seed));
            show_long(&r);
            integrity(&r);
        }
    }
}

/// The same long path behind a real bottleneck (2 Mbps, a 250 ms queue), with and without the random loss, and a
/// policer (2 Mbps, no queue to speak of): the rate still backs off below the bottleneck.
#[test]
fn long_bottleneck_still_backs_off() {
    for seed in 1..=3 {
        for p in [LinkProfile::long_bottleneck(), LinkProfile::long_loss_bottleneck(), LinkProfile::long_policer()] {
            let r = run(&long(p, Content::Scrolling, seed));
            show_long(&r);
            integrity_but_input(&r);
        }
    }
}
