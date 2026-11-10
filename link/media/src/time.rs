//! Time for the sans-IO state machines: the caller passes `now` into every call.

use std::ops::{Add, AddAssign, Sub};

/// A point on the caller's monotonic clock, or a duration, in microseconds. The epoch is the caller's (any
/// monotonic clock works; only differences matter). Subtraction saturates at zero, so a stale `now` never panics.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Micros(pub u64);

impl Micros {
    pub const ZERO: Micros = Micros(0);
    pub const MAX: Micros = Micros(u64::MAX);

    pub const fn from_millis(ms: u64) -> Micros {
        Micros(ms * 1000)
    }

    pub const fn from_secs(s: u64) -> Micros {
        Micros(s * 1_000_000)
    }

    pub fn from_secs_f64(s: f64) -> Micros {
        Micros((s.max(0.0) * 1e6).round() as u64)
    }

    pub fn from_millis_f64(ms: f64) -> Micros {
        Micros((ms.max(0.0) * 1e3).round() as u64)
    }

    pub fn as_secs_f64(self) -> f64 {
        self.0 as f64 / 1e6
    }

    pub fn as_millis_f64(self) -> f64 {
        self.0 as f64 / 1e3
    }

    pub fn saturating_sub(self, other: Micros) -> Micros {
        Micros(self.0.saturating_sub(other.0))
    }

    /// `self × f`, rounded (f ≥ 0).
    pub fn mul_f64(self, f: f64) -> Micros {
        Micros((self.0 as f64 * f.max(0.0)).round() as u64)
    }

    /// `self − earlier` as signed microseconds.
    pub fn signed_since(self, earlier: Micros) -> i64 {
        self.0 as i64 - earlier.0 as i64
    }
}

impl Add for Micros {
    type Output = Micros;
    fn add(self, rhs: Micros) -> Micros {
        Micros(self.0.saturating_add(rhs.0))
    }
}

impl AddAssign for Micros {
    fn add_assign(&mut self, rhs: Micros) {
        *self = *self + rhs;
    }
}

impl Sub for Micros {
    type Output = Micros;
    /// Saturating: an earlier minus a later time is zero.
    fn sub(self, rhs: Micros) -> Micros {
        self.saturating_sub(rhs)
    }
}

/// The earliest of optional deadlines.
pub(crate) fn earliest(a: Option<Micros>, b: Option<Micros>) -> Option<Micros> {
    match (a, b) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (x, None) => x,
        (None, y) => y,
    }
}

/// Round-trip time samples over a sliding window: min / p50 / p90 for the deadlines and the stats line.
#[derive(Clone, Debug)]
pub struct RttWindow {
    window: Micros,
    samples: std::collections::VecDeque<(Micros, Micros)>,
    latest: Option<Micros>,
}

impl RttWindow {
    pub fn new(window: Micros) -> RttWindow {
        RttWindow { window, samples: Default::default(), latest: None }
    }

    pub fn add(&mut self, now: Micros, rtt: Micros) {
        self.latest = Some(rtt);
        self.samples.push_back((now, rtt));
        while let Some(&(at, _)) = self.samples.front() {
            if now - at > self.window && self.samples.len() > 1 {
                self.samples.pop_front();
            } else {
                break;
            }
        }
        // bound memory when the caller feeds samples very often
        while self.samples.len() > 4096 {
            self.samples.pop_front();
        }
    }

    pub fn latest(&self) -> Option<Micros> {
        self.latest
    }

    /// Nearest-rank percentile (0…1) of the window; None without samples.
    pub fn percentile(&self, p: f64) -> Option<Micros> {
        if self.samples.is_empty() {
            return None;
        }
        let mut v: Vec<Micros> = self.samples.iter().map(|s| s.1).collect();
        v.sort_unstable();
        let rank = ((v.len() as f64 * p).ceil() as usize).clamp(1, v.len()) - 1;
        Some(v[rank])
    }

    pub fn min(&self) -> Option<Micros> {
        self.samples.iter().map(|s| s.1).min()
    }
}
