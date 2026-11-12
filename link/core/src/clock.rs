//! A word in the log when this computer's clock is being slewed.
//!
//! The media layer's times come from `Instant`: on Linux CLOCK_MONOTONIC, which the kernel slews along with the wall
//! clock (a time service correcting it; `adjtimex`'s frequency and tick). A correction is small as a rule (well under
//! 0.1 %). A virtual machine can be far off: on a WSL2 host with two time services disciplining the one clock it ran
//! between 7 % slow and 2 % fast, changing every few seconds — and since one-way delay is the receiver's clock minus
//! the sender's, 5 % is 50 ms a second of delay that no queue made (the rate controller tells the two apart by the
//! round trip, `uu_link_media::RateConfig::rtt_queue_slack`). CLOCK_MONOTONIC_RAW is the same counter with nothing
//! applied: the two side by side show the slew.

use crate::log::warn;

/// A slew worth a word: more than a time service's ordinary correction.
const WORTH_A_WORD: f64 = 0.002;

/// CLOCK_MONOTONIC and CLOCK_MONOTONIC_RAW, in seconds (Linux; None elsewhere: nothing slews `Instant` there).
fn clocks() -> Option<(f64, f64)> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let read = |id: libc::clockid_t| {
            let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            // SAFETY: `t` is a valid timespec for the call to fill in
            (unsafe { libc::clock_gettime(id, &mut t) } == 0).then(|| t.tv_sec as f64 + t.tv_nsec as f64 / 1e9)
        };
        Some((read(libc::CLOCK_MONOTONIC)?, read(libc::CLOCK_MONOTONIC_RAW)?))
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    None
}

/// How much faster (+) or slower (−) the clock ran than the raw one between two readings, as a fraction.
fn slew(from: (f64, f64), to: (f64, f64)) -> Option<f64> {
    let (clock, raw) = (to.0 - from.0, to.1 - from.1);
    (raw >= 1.0).then(|| clock / raw - 1.0)
}

/// The log line for a slew of `s` (None: not worth a word).
fn line(s: f64) -> Option<String> {
    (s.abs() >= WORTH_A_WORD).then(|| {
        format!(
            "link: this computer's clock ran {:.1} % {} (it is being slewed: a large correction, or two time services \
             correcting each other); delays measured against the other side's clock drift with it",
            s.abs() * 100.0,
            if s < 0.0 { "slow" } else { "fast" }
        )
    })
}

/// Watches the clock from one call to the next.
#[derive(Default)]
pub(crate) struct SlewWatch(Option<(f64, f64)>);

impl SlewWatch {
    /// Call every so often (a session does, with its stats line): warns when the clock was slewed since the last call.
    pub(crate) fn check(&mut self) {
        let Some(now) = clocks() else { return };
        if let Some(l) = self.0.replace(now).and_then(|last| slew(last, now)).and_then(line) {
            warn!("{l}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_slewed_clock_gets_a_word_an_ordinary_correction_does_not() {
        // 10 s of the raw clock, 9.58 s of the slewed one
        let s = slew((100.0, 200.0), (109.58, 210.0)).unwrap();
        assert!((s + 0.042).abs() < 1e-9, "{s}");
        assert!(line(s).unwrap().contains("4.2 % slow"), "{:?}", line(s));
        assert!(line(0.021).unwrap().contains("2.1 % fast"));
        // 500 ppm: what a time service does all day
        assert_eq!(line(slew((0.0, 0.0), (10.005, 10.0)).unwrap()), None);
        // too short to tell
        assert_eq!(slew((0.0, 0.0), (0.5, 0.5)), None);
    }

    #[test]
    fn the_clocks_read_where_there_are_two() {
        let mut w = SlewWatch::default();
        w.check();
        assert_eq!(w.0.is_some(), cfg!(any(target_os = "linux", target_os = "android")));
    }
}
