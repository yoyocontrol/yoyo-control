//! The server's guard: failures per source IP (10 within 60 s → refused for 5 min, before any TLS) and session caps
//! (32 at once, of which at most 4 not yet authenticated). Loopback and the configured exemptions are never counted
//! (a NAT in front makes every client look the same).

use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[derive(Debug, Clone)]
pub struct GuardConfig {
    pub failure_limit: u32,
    pub failure_window: Duration,
    pub cooldown: Duration,
    pub max_sessions: usize,
    pub max_unauthenticated: usize,
    /// Addresses never limited besides loopback.
    pub exempt: Vec<IpAddr>,
    /// Loopback is never limited (default; tests turn it off).
    pub exempt_loopback: bool,
}

impl Default for GuardConfig {
    fn default() -> Self {
        GuardConfig {
            failure_limit: 10,
            failure_window: Duration::from_secs(60),
            cooldown: Duration::from_secs(300),
            max_sessions: 32,
            max_unauthenticated: 4,
            exempt: Vec::new(),
            exempt_loopback: true,
        }
    }
}

/// At most this many addresses are tracked (the oldest are forgotten).
const MAX_TRACKED: usize = 1024;

#[derive(Debug)]
pub struct Guard {
    config: GuardConfig,
    state: Mutex<State>,
}

#[derive(Debug, Default)]
struct State {
    failures: HashMap<IpAddr, Vec<Instant>>,
    blocked: HashMap<IpAddr, Instant>,
    sessions: usize,
    unauthenticated: usize,
}

/// Why an incoming connection was refused before its handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Blocked,
    TooManySessions,
    TooManyUnauthenticated,
}

impl Guard {
    pub fn new(config: GuardConfig) -> Arc<Self> {
        Arc::new(Guard { config, state: Mutex::new(State::default()) })
    }

    pub fn config(&self) -> &GuardConfig {
        &self.config
    }

    pub fn is_exempt(&self, ip: IpAddr) -> bool {
        (self.config.exempt_loopback && ip.to_canonical().is_loopback()) || self.config.exempt.contains(&ip)
    }

    pub fn is_blocked(&self, ip: IpAddr) -> bool {
        self.is_blocked_at(ip, Instant::now())
    }

    pub fn is_blocked_at(&self, ip: IpAddr, now: Instant) -> bool {
        if self.is_exempt(ip) {
            return false;
        }
        let mut s = self.state.lock().unwrap();
        match s.blocked.get(&ip) {
            Some(until) if *until > now => true,
            Some(_) => {
                s.blocked.remove(&ip);
                false
            }
            None => false,
        }
    }

    /// Counts a failure from `ip`; true when it starts a cooldown.
    pub fn failed(&self, ip: IpAddr) -> bool {
        self.failed_at(ip, Instant::now())
    }

    pub fn failed_at(&self, ip: IpAddr, now: Instant) -> bool {
        if self.is_exempt(ip) {
            return false;
        }
        let window = self.config.failure_window;
        let mut s = self.state.lock().unwrap();
        let list = s.failures.entry(ip).or_default();
        list.retain(|t| now.duration_since(*t) < window);
        list.push(now);
        if list.len() as u32 >= self.config.failure_limit {
            s.failures.remove(&ip);
            s.blocked.insert(ip, now + self.config.cooldown);
            if s.blocked.len() > MAX_TRACKED {
                s.blocked.retain(|_, until| *until > now);
            }
            return true;
        }
        if s.failures.len() > MAX_TRACKED {
            let oldest = s.failures.iter().min_by_key(|(_, l)| l.last().copied()).map(|(ip, _)| *ip);
            if let Some(o) = oldest {
                s.failures.remove(&o);
            }
        }
        false
    }

    /// Admission of a new connection (before its handshake): a permit that counts it as unauthenticated.
    pub fn admit(self: &Arc<Self>, ip: Option<IpAddr>) -> Result<Permit, Refusal> {
        if let Some(ip) = ip
            && self.is_blocked(ip)
        {
            return Err(Refusal::Blocked);
        }
        let mut s = self.state.lock().unwrap();
        if s.sessions >= self.config.max_sessions {
            return Err(Refusal::TooManySessions);
        }
        if s.unauthenticated >= self.config.max_unauthenticated {
            return Err(Refusal::TooManyUnauthenticated);
        }
        s.sessions += 1;
        s.unauthenticated += 1;
        Ok(Permit { guard: self.clone(), authenticated: false })
    }

    /// (sessions, unauthenticated) right now.
    pub fn counts(&self) -> (usize, usize) {
        let s = self.state.lock().unwrap();
        (s.sessions, s.unauthenticated)
    }
}

/// One admitted connection; dropping it frees its slot.
#[derive(Debug)]
pub struct Permit {
    guard: Arc<Guard>,
    authenticated: bool,
}

impl Permit {
    /// The connection got its `welcome`: it no longer counts as unauthenticated.
    pub fn authenticated(&mut self) {
        if !self.authenticated {
            self.authenticated = true;
            self.guard.state.lock().unwrap().unauthenticated -= 1;
        }
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut s = self.guard.state.lock().unwrap();
        s.sessions -= 1;
        if !self.authenticated {
            s.unauthenticated -= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn ten_failures_in_a_minute_block_for_five() {
        let g = Guard::new(GuardConfig::default());
        let t0 = Instant::now();
        let a = ip("203.0.113.5");
        for i in 0..9 {
            assert!(!g.failed_at(a, t0 + Duration::from_secs(i)));
        }
        assert!(!g.is_blocked_at(a, t0 + Duration::from_secs(9)));
        assert!(g.failed_at(a, t0 + Duration::from_secs(9)));
        assert!(g.is_blocked_at(a, t0 + Duration::from_secs(10)));
        assert!(g.is_blocked_at(a, t0 + Duration::from_secs(308)));
        assert!(!g.is_blocked_at(a, t0 + Duration::from_secs(310)));
        // another address is unaffected
        assert!(!g.is_blocked_at(ip("203.0.113.6"), t0 + Duration::from_secs(10)));
    }

    #[test]
    fn failures_outside_the_window_do_not_add_up() {
        let g = Guard::new(GuardConfig::default());
        let t0 = Instant::now();
        let a = ip("198.51.100.1");
        for i in 0..20 {
            assert!(!g.failed_at(a, t0 + Duration::from_secs(i * 7)));
        }
    }

    #[test]
    fn loopback_and_exempt_never_count() {
        let g = Guard::new(GuardConfig { exempt: vec![ip("172.17.0.1")], ..GuardConfig::default() });
        for _ in 0..50 {
            assert!(!g.failed(ip("127.0.0.1")));
            assert!(!g.failed(ip("::1")));
            assert!(!g.failed(ip("::ffff:127.0.0.1")));
            assert!(!g.failed(ip("172.17.0.1")));
        }
    }

    #[test]
    fn session_caps() {
        let g = Guard::new(GuardConfig { max_sessions: 6, max_unauthenticated: 4, ..GuardConfig::default() });
        let mut held: Vec<Permit> = (0..4).map(|_| g.admit(None).unwrap()).collect();
        assert_eq!(g.admit(None).unwrap_err(), Refusal::TooManyUnauthenticated);
        for p in held.iter_mut() {
            p.authenticated();
        }
        assert_eq!(g.counts(), (4, 0));
        held.push(g.admit(None).unwrap());
        held.push(g.admit(None).unwrap());
        assert_eq!(g.admit(None).unwrap_err(), Refusal::TooManySessions);
        held.pop();
        assert_eq!(g.counts(), (5, 1));
        drop(held);
        assert_eq!(g.counts(), (0, 0));

        let a = ip("192.0.2.9");
        for _ in 0..10 {
            g.failed(a);
        }
        assert_eq!(g.admit(Some(a)).unwrap_err(), Refusal::Blocked);
    }
}
