//! The server's guard (docs/LINK.md「守卫（服务端）」).
//!
//! Failures per source and kind (QUIC, WebRTC: a WebRTC failure blocks WebRTC only; 10 within 60 s → refused for
//! 5 min), counted only where the source is proven: after the QUIC handshake (a forged source address never completes
//! one), or a WebRTC offer's signaling request (TCP) — so no one gets another's address blocked. A source is an IPv4
//! address, a public IPv6 /64, a LAN IPv6 address, or (through a relay, no address) the peer's endpoint id. A blocked
//! address is ignored before any TLS; a blocked endpoint id is refused right after the handshake (only then is it
//! known). Loopback and the configured exemptions are never counted.
//!
//! Connections not yet authenticated sit in two pools, and a full pool makes room by sending its oldest away:
//! - **handshaking** (the address not proven yet): up to 32 (`max_handshaking`). A newcomer here sends away the oldest
//!   handshaking one, never one of the second pool — so forged packets compete only among themselves and with handshakes
//!   under way, and an attacker has to refresh all 32 within one round trip to keep a real client from finishing its
//!   handshake: a flood, which only the network in front can stop.
//! - **after the handshake, waiting for `hello` and the authenticator**: up to 4 for each way in (straight, relayed,
//!   WebRTC), at most 2 from one source in each. A source at its share sends away its own oldest; a full pool, its
//!   oldest — but only ever one still waiting for its `hello`: one that sent a sound `hello` is the authenticator's to
//!   end (its answer, its timeout, or the connection closing), and when there is none to send away the newcomer is
//!   refused (Busy). A WebRTC offer is never sent away (it waits seconds for ICE, DTLS and SCTP before its `hello`): it
//!   connects and goes on like any other (its `hello`, the authenticator), or ends by its connect timeout (a failure) or
//!   by closing.
//!
//! Sessions (authenticated, plus the second pool) at most 32 (`max_sessions`). Known limits: docs/LINK.md「已知的限度」.

use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use tokio::sync::Notify;

#[derive(Debug, Clone)]
pub struct GuardConfig {
    pub failure_limit: u32,
    pub failure_window: Duration,
    pub cooldown: Duration,
    pub max_sessions: usize,
    /// After the handshake, not yet authenticated: at most this many for each way in (straight, relayed).
    pub max_unauthenticated: usize,
    /// After the handshake, not yet authenticated: at most this many from one source.
    pub max_unauthenticated_per_ip: usize,
    /// Handshakes under way (addresses not proven yet).
    pub max_handshaking: usize,
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
            max_unauthenticated_per_ip: 2,
            max_handshaking: 32,
            exempt: Vec::new(),
            exempt_loopback: true,
        }
    }
}

/// At most this many sources are tracked for failures and blocks (the oldest are forgotten).
const MAX_TRACKED: usize = 1024;

/// What a source is counted as: its IPv4 address; a public IPv6 address's /64 (one household's network, as IPv4's NAT
/// makes one address of it: a host can take any of 2^64 addresses in it); a link-local or unique-local IPv6 address as
/// itself (machines of one LAN, each its own).
pub fn source_key(ip: IpAddr) -> IpAddr {
    match ip.to_canonical() {
        IpAddr::V6(v6) => {
            let seg = v6.segments();
            let local = (seg[0] & 0xffc0) == 0xfe80 || (seg[0] & 0xfe00) == 0xfc00;
            if local {
                return IpAddr::V6(v6);
            }
            let mut o = v6.octets();
            o[8..].fill(0);
            IpAddr::V6(o.into())
        }
        v4 => v4,
    }
}

/// Where a connection came in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Way {
    /// From an IP address (a direct path).
    Straight,
    /// Through a relay (no address).
    Relayed,
    /// A WebRTC offer (its own pool: an offer waits seconds for ICE, DTLS and SCTP before its `hello`, so it is never
    /// sent away, and offers never take the place of QUIC connections).
    Rtc,
}

/// Which kind of connection a failure or a block is about: a WebRTC failure blocks WebRTC only (a browser whose ICE
/// never connects, retrying, must not get the app on the same address blocked).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Quic,
    WebRtc,
}

/// Whose share a connection after its handshake counts against.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Source {
    Ip(IpAddr),
    /// A relayed connection's peer: its endpoint id (the relay checked its key).
    Peer(Vec<u8>),
    /// Not counted per source (exempt).
    Exempt,
}

#[derive(Debug)]
pub struct Guard {
    config: GuardConfig,
    state: Mutex<State>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tier {
    Handshaking,
    Pending,
}

#[derive(Debug)]
struct Entry {
    since: Instant,
    tier: Tier,
    way: Way,
    source: Source,
    /// Sent a sound `hello` (in the authenticator now): never sent away.
    hello: bool,
    gone: Arc<Notify>,
}

impl Entry {
    /// In the second pool, still waiting for its `hello`: the only kind sent away from it.
    fn waiting(&self) -> bool {
        self.tier == Tier::Pending && !self.hello
    }
}

#[derive(Debug, Default)]
struct State {
    /// By source (never `Source::Exempt`).
    failures: HashMap<(Kind, Source), Vec<Instant>>,
    blocked: HashMap<(Kind, Source), Instant>,
    /// Authenticated sessions and the second pool.
    sessions: usize,
    /// Not authenticated yet, both pools, by permit id.
    entries: HashMap<u64, Entry>,
    next_id: u64,
}

/// Why an incoming connection was refused before its handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Blocked,
    TooManySessions,
    TooManyUnauthenticated,
}

impl State {
    /// Makes room in the second pool for a newcomer of `way` and `source` (the rules: `Permit::handshake_done`), or
    /// refuses it — checking everything before sending anyone away, so a refused newcomer sends no one away.
    fn place(&mut self, config: &GuardConfig, way: Way, source: &Source) -> Result<(), Refusal> {
        let at_cap = self.sessions >= config.max_sessions;
        let own =
            |e: &Entry| e.tier == Tier::Pending && e.way == way && *source != Source::Exempt && e.source == *source;
        let at_share = self.entries.values().filter(|e| own(e)).count() >= config.max_unauthenticated_per_ip;
        let pool_full = self.entries.values().filter(|e| e.tier == Tier::Pending && e.way == way).count()
            >= config.max_unauthenticated;
        let can_go = |f: &dyn Fn(&Entry) -> bool| self.entries.values().any(|e| e.waiting() && f(e));
        if at_cap && !can_go(&|e| e.way == way) {
            return Err(Refusal::TooManySessions);
        }
        if (at_share && !can_go(&own)) || (pool_full && !can_go(&|e| e.way == way)) {
            return Err(Refusal::TooManyUnauthenticated);
        }
        if at_share {
            self.send_away(|e| e.waiting() && own(e));
        }
        let pool_full = self.entries.values().filter(|e| e.tier == Tier::Pending && e.way == way).count()
            >= config.max_unauthenticated;
        if pool_full {
            self.send_away(|e| e.waiting() && e.way == way);
        }
        if self.sessions >= config.max_sessions {
            self.send_away(|e| e.waiting() && e.way == way);
        }
        Ok(())
    }

    /// The oldest entry matching `f`, sent away: removed here, told through its `gone`.
    fn send_away(&mut self, f: impl Fn(&Entry) -> bool) -> bool {
        let oldest = self.entries.iter().filter(|(_, e)| f(e)).min_by_key(|(_, e)| e.since).map(|(id, _)| *id);
        let Some(id) = oldest else { return false };
        let e = self.entries.remove(&id).expect("listed");
        if e.tier == Tier::Pending {
            self.sessions -= 1;
        }
        e.gone.notify_one();
        true
    }
}

impl Guard {
    pub fn new(config: GuardConfig) -> Arc<Self> {
        Arc::new(Guard { config, state: Mutex::new(State::default()) })
    }

    pub fn config(&self) -> &GuardConfig {
        &self.config
    }

    pub fn is_exempt(&self, ip: IpAddr) -> bool {
        let ip = ip.to_canonical();
        (self.config.exempt_loopback && ip.is_loopback()) || self.config.exempt.iter().any(|e| e.to_canonical() == ip)
    }

    /// What `ip` counts as: its source (`source_key`), or `Source::Exempt` (loopback, the configured exemptions).
    pub fn source_of(&self, ip: IpAddr) -> Source {
        if self.is_exempt(ip) { Source::Exempt } else { Source::Ip(source_key(ip)) }
    }

    pub fn is_blocked(&self, ip: IpAddr) -> bool {
        self.is_blocked_at(ip, Instant::now())
    }

    /// Whether QUIC from `ip` is in its cooldown.
    pub fn is_blocked_at(&self, ip: IpAddr, now: Instant) -> bool {
        self.is_blocked_as_at(Kind::Quic, &self.source_of(ip), now)
    }

    /// Whether `source` (an address's or an endpoint id's) is in its cooldown for `kind`.
    pub fn is_blocked_as(&self, kind: Kind, source: &Source) -> bool {
        self.is_blocked_as_at(kind, source, Instant::now())
    }

    pub fn is_blocked_as_at(&self, kind: Kind, source: &Source, now: Instant) -> bool {
        if *source == Source::Exempt {
            return false;
        }
        let key = (kind, source.clone());
        let mut s = self.state.lock().unwrap();
        match s.blocked.get(&key) {
            Some(until) if *until > now => true,
            Some(_) => {
                s.blocked.remove(&key);
                false
            }
            None => false,
        }
    }

    /// Counts a QUIC failure from `ip` — only once its address is proven (after the handshake); true when it starts a
    /// cooldown.
    pub fn failed(&self, ip: IpAddr) -> bool {
        self.failed_at(ip, Instant::now())
    }

    pub fn failed_at(&self, ip: IpAddr, now: Instant) -> bool {
        self.failed_as_at(Kind::Quic, &self.source_of(ip), now)
    }

    /// Counts a failure of `kind` from `source` (proven: an address after the handshake or from a signaling request,
    /// or a relayed peer's endpoint id); true when it starts a cooldown. `Source::Exempt` is never counted.
    pub fn failed_as(&self, kind: Kind, source: &Source) -> bool {
        self.failed_as_at(kind, source, Instant::now())
    }

    pub fn failed_as_at(&self, kind: Kind, source: &Source, now: Instant) -> bool {
        if *source == Source::Exempt {
            return false;
        }
        let key = (kind, source.clone());
        let window = self.config.failure_window;
        let mut s = self.state.lock().unwrap();
        let list = s.failures.entry(key.clone()).or_default();
        list.retain(|t| now.duration_since(*t) < window);
        list.push(now);
        if list.len() as u32 >= self.config.failure_limit {
            s.failures.remove(&key);
            s.blocked.insert(key, now + self.config.cooldown);
            if s.blocked.len() > MAX_TRACKED {
                s.blocked.retain(|_, until| *until > now);
            }
            return true;
        }
        if s.failures.len() > MAX_TRACKED {
            let oldest = s.failures.iter().min_by_key(|(_, l)| l.last().copied()).map(|(k, _)| k.clone());
            if let Some(o) = oldest {
                s.failures.remove(&o);
            }
        }
        false
    }

    /// A new connection, before its handshake: a permit in the first pool (a full pool sends its oldest handshaking
    /// connection away). Refused only when `ip` is blocked.
    pub fn admit(self: &Arc<Self>, ip: Option<IpAddr>) -> Result<Permit, Refusal> {
        self.admit_at(ip, Instant::now())
    }

    pub fn admit_at(self: &Arc<Self>, ip: Option<IpAddr>, now: Instant) -> Result<Permit, Refusal> {
        if let Some(ip) = ip
            && self.is_blocked_at(ip, now)
        {
            return Err(Refusal::Blocked);
        }
        let way = if ip.is_some() { Way::Straight } else { Way::Relayed };
        let mut s = self.state.lock().unwrap();
        let handshaking = s.entries.values().filter(|e| e.tier == Tier::Handshaking).count();
        if handshaking >= self.config.max_handshaking {
            s.send_away(|e| e.tier == Tier::Handshaking);
        }
        let id = s.next_id;
        s.next_id += 1;
        let gone = Arc::new(Notify::new());
        s.entries.insert(
            id,
            Entry {
                since: now,
                tier: Tier::Handshaking,
                way,
                source: Source::Exempt,
                hello: false,
                gone: gone.clone(),
            },
        );
        Ok(Permit { guard: self.clone(), id, gone, stage: Stage::Handshaking })
    }

    /// A WebRTC offer, checked (its signaling request's address, if any, is a real one: it came over TCP): straight
    /// into the second pool's WebRTC pool under `source`, without passing the handshaking pool, and never sent away —
    /// from connecting through its `hello` to the authenticator's answer (so it holds its place up to the connect
    /// timeout + the hello timeout + the authenticator's): it ends by an answer, a timeout or a bad `hello` (failures),
    /// or by closing. A full pool refuses it. Refused too while `ip` is blocked for WebRTC.
    pub fn admit_offer(self: &Arc<Self>, ip: Option<IpAddr>, source: Source) -> Result<Permit, Refusal> {
        let now = Instant::now();
        let way = Way::Rtc;
        if let Some(ip) = ip
            && self.is_blocked_as_at(Kind::WebRtc, &self.source_of(ip), now)
        {
            return Err(Refusal::Blocked);
        }
        // (under one lock: placed like a connection whose handshake just completed, never passing the handshaking pool)
        let mut s = self.state.lock().unwrap();
        s.place(&self.config, way, &source)?;
        let id = s.next_id;
        s.next_id += 1;
        let gone = Arc::new(Notify::new());
        s.entries.insert(id, Entry { since: now, tier: Tier::Pending, way, source, hello: true, gone: gone.clone() });
        s.sessions += 1;
        drop(s);
        let p = Permit { guard: self.clone(), id, gone, stage: Stage::Pending };
        Ok(p)
    }

    /// (sessions, not authenticated yet) right now.
    pub fn counts(&self) -> (usize, usize) {
        let s = self.state.lock().unwrap();
        (s.sessions, s.entries.len())
    }

    /// How many of each pool right now: (handshaking, after the handshake).
    pub fn pools(&self) -> (usize, usize) {
        let s = self.state.lock().unwrap();
        let h = s.entries.values().filter(|e| e.tier == Tier::Handshaking).count();
        (h, s.entries.len() - h)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Handshaking,
    Pending,
    Authenticated,
}

/// One admitted connection; dropping it frees its place.
#[derive(Debug)]
pub struct Permit {
    guard: Arc<Guard>,
    id: u64,
    gone: Arc<Notify>,
    stage: Stage,
}

impl Permit {
    /// Resolves when the guard sent this connection away to make room (it closes then, and that counts as nothing).
    pub async fn sent_away(&self) {
        self.gone.notified().await
    }

    /// Whether it was sent away already.
    pub fn was_sent_away(&self) -> bool {
        self.stage != Stage::Authenticated && !self.guard.state.lock().unwrap().entries.contains_key(&self.id)
    }

    /// Its handshake completed: its address is proven. Into the second pool under `way` and `source`: a source at its
    /// share sends its own oldest away, a full pool its oldest — of those still waiting for their `hello` only; with
    /// none such, refused (`TooManyUnauthenticated`). At the sessions cap, one of its way still waiting for its `hello`
    /// is sent away, else refused (`TooManySessions`).
    pub fn handshake_done(&mut self, way: Way, source: Source) -> Result<(), Refusal> {
        self.handshake_done_at(way, source, Instant::now())
    }

    pub fn handshake_done_at(&mut self, way: Way, source: Source, now: Instant) -> Result<(), Refusal> {
        let config = self.guard.config.clone();
        let mut s = self.guard.state.lock().unwrap();
        if !s.entries.contains_key(&self.id) || self.stage != Stage::Handshaking {
            return Err(Refusal::TooManyUnauthenticated);
        }
        s.place(&config, way, &source)?;
        let e = s.entries.get_mut(&self.id).expect("checked");
        e.tier = Tier::Pending;
        e.way = way;
        e.source = source;
        e.since = now;
        s.sessions += 1;
        self.stage = Stage::Pending;
        Ok(())
    }

    /// It sent a sound `hello` (in the authenticator now): from here on never sent away. false: it was sent away
    /// already (it gets `denied` Busy then).
    #[must_use]
    pub fn hello_received(&mut self) -> bool {
        let mut s = self.guard.state.lock().unwrap();
        match s.entries.get_mut(&self.id) {
            Some(e) if self.stage == Stage::Pending => {
                e.hello = true;
                true
            }
            _ => false,
        }
    }

    /// The connection is about to get its `welcome`: no longer in a pool, a session. false: it was sent away meanwhile
    /// (it gets `denied` Busy instead, and holds nothing).
    #[must_use]
    pub fn authenticated(&mut self) -> bool {
        let mut s = self.guard.state.lock().unwrap();
        if self.stage == Stage::Pending && s.entries.remove(&self.id).is_some() {
            self.stage = Stage::Authenticated;
            return true;
        }
        self.stage == Stage::Authenticated
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut s = self.guard.state.lock().unwrap();
        match self.stage {
            Stage::Authenticated => s.sessions -= 1,
            Stage::Pending => {
                // (sent away: its place was given back then)
                if s.entries.remove(&self.id).is_some() {
                    s.sessions -= 1;
                }
            }
            Stage::Handshaking => {
                s.entries.remove(&self.id);
            }
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
        let g = Guard::new(GuardConfig { exempt: vec![ip("::ffff:172.17.0.1")], ..GuardConfig::default() });
        for _ in 0..50 {
            assert!(!g.failed(ip("127.0.0.1")));
            assert!(!g.failed(ip("::1")));
            assert!(!g.failed(ip("::ffff:127.0.0.1")));
            assert!(!g.failed(ip("172.17.0.1")));
        }
    }

    #[test]
    fn a_full_handshake_pool_sends_its_oldest_away_and_never_the_second_pool() {
        let g = Guard::new(GuardConfig { max_handshaking: 3, ..GuardConfig::default() });
        let t0 = Instant::now();
        let a = ip("203.0.113.1");
        // one connection past its handshake, waiting for hello
        let mut done = g.admit_at(Some(a), t0).unwrap();
        done.handshake_done_at(Way::Straight, Source::Ip(source_key(a)), t0).unwrap();
        // the handshake pool fills (forged packets, say) and keeps filling
        let mut floods: Vec<Permit> =
            (0..3).map(|i| g.admit_at(Some(ip("198.51.100.9")), t0 + Duration::from_millis(i + 1)).unwrap()).collect();
        assert_eq!(g.pools(), (3, 1));
        let newcomer = g.admit_at(Some(ip("192.0.2.77")), t0 + Duration::from_millis(10)).unwrap();
        assert!(floods[0].was_sent_away(), "the oldest handshake went");
        assert!(!floods[1].was_sent_away() && !newcomer.was_sent_away());
        assert!(!done.was_sent_away(), "the second pool is never touched by the first");
        assert_eq!(g.pools(), (3, 1));
        floods.clear();
        drop(newcomer);
        assert_eq!(g.pools(), (0, 1));
        assert!(done.authenticated());
        assert_eq!(g.counts(), (1, 0));
        drop(done);
        assert_eq!(g.counts(), (0, 0));
    }

    #[test]
    fn a_source_at_its_share_sends_its_own_away_and_a_full_pool_its_oldest() {
        let g = Guard::new(GuardConfig::default());
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        let src = |s: &str| Source::Ip(source_key(ip(s)));
        let pending = |g: &Arc<Guard>, s: &str, t: Instant| {
            let mut p = g.admit_at(Some(ip(s)), t).unwrap();
            p.handshake_done_at(Way::Straight, src(s), t).unwrap();
            p
        };
        let a1 = pending(&g, "203.0.113.1", at(1));
        let a2 = pending(&g, "203.0.113.1", at(2));
        let a3 = pending(&g, "203.0.113.1", at(3));
        assert!(a1.was_sent_away(), "its own oldest");
        assert!(!a2.was_sent_away() && !a3.was_sent_away());
        let b1 = pending(&g, "198.51.100.1", at(4));
        let b2 = pending(&g, "198.51.100.1", at(5));
        assert_eq!(g.pools(), (0, 4));
        // the pool is full: a newcomer of a third source sends the oldest of all away
        let c1 = pending(&g, "192.0.2.1", at(6));
        assert!(a2.was_sent_away());
        assert!(!a3.was_sent_away() && !b1.was_sent_away() && !b2.was_sent_away() && !c1.was_sent_away());
        // relayed ones are their own pool: they never send a straight one away
        let mut r = g.admit_at(None, at(7)).unwrap();
        r.handshake_done_at(Way::Relayed, Source::Peer(vec![1; 32]), at(7)).unwrap();
        assert!(!a3.was_sent_away() && !b1.was_sent_away());
        assert_eq!(g.pools(), (0, 5));
        drop((a1, a2, a3, b1, b2, c1, r));
        assert_eq!(g.counts(), (0, 0));
    }

    #[test]
    fn one_in_the_authenticator_is_never_sent_away() {
        let g = Guard::new(GuardConfig { max_unauthenticated: 2, ..GuardConfig::default() });
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        let pending = |g: &Arc<Guard>, s: &str, t: Instant| {
            let mut p = g.admit_at(Some(ip(s)), t).unwrap();
            p.handshake_done_at(Way::Straight, Source::Ip(source_key(ip(s))), t).map(|_| p)
        };
        // a real client sent its hello; then connections that never say hello keep coming
        let mut real = pending(&g, "192.0.2.10", at(1)).unwrap();
        assert!(real.hello_received());
        let f1 = pending(&g, "198.51.100.1", at(2)).unwrap();
        let f2 = pending(&g, "198.51.100.2", at(3)).unwrap();
        assert!(f1.was_sent_away(), "the oldest still waiting for hello went, not the older one in the authenticator");
        let f3 = pending(&g, "198.51.100.3", at(4)).unwrap();
        assert!(f2.was_sent_away() && !f3.was_sent_away());
        assert!(!real.was_sent_away());
        // the pool is all in the authenticator: a newcomer is refused, sending no one away
        let mut b1 = pending(&g, "203.0.113.1", at(5)).unwrap();
        assert!(f3.was_sent_away());
        assert!(b1.hello_received());
        assert_eq!(pending(&g, "203.0.113.1", at(6)).unwrap_err(), Refusal::TooManyUnauthenticated);
        assert_eq!(pending(&g, "192.0.2.99", at(7)).unwrap_err(), Refusal::TooManyUnauthenticated);
        assert!(!real.was_sent_away() && !b1.was_sent_away());
        assert!(real.authenticated());
        assert!(pending(&g, "192.0.2.99", at(8)).is_ok(), "a place again");
        drop((real, b1, f1, f2, f3));
        assert_eq!(g.counts(), (0, 0));
    }

    #[test]
    fn a_source_whose_share_is_in_the_authenticator_is_refused() {
        let g = Guard::new(GuardConfig::default());
        let a = ip("203.0.113.1");
        let mut held = Vec::new();
        for _ in 0..2 {
            let mut p = g.admit(Some(a)).unwrap();
            p.handshake_done(Way::Straight, Source::Ip(source_key(a))).unwrap();
            assert!(p.hello_received());
            held.push(p);
        }
        let mut third = g.admit(Some(a)).unwrap();
        assert_eq!(
            third.handshake_done(Way::Straight, Source::Ip(source_key(a))).unwrap_err(),
            Refusal::TooManyUnauthenticated
        );
        assert!(held.iter().all(|p| !p.was_sent_away()));
        let mut other = g.admit(Some(ip("198.51.100.1"))).unwrap();
        assert!(
            other.handshake_done(Way::Straight, Source::Ip(ip("198.51.100.1"))).is_ok(),
            "another source still gets in"
        );
    }

    #[test]
    fn relayed_failures_count_by_endpoint_id() {
        let g = Guard::new(GuardConfig { failure_limit: 3, ..GuardConfig::default() });
        let peer = Source::Peer(vec![7; 32]);
        assert!(!g.failed_as(Kind::Quic, &peer) && !g.failed_as(Kind::Quic, &peer));
        assert!(g.failed_as(Kind::Quic, &peer));
        assert!(g.is_blocked_as(Kind::Quic, &peer));
        assert!(!g.is_blocked_as(Kind::Quic, &Source::Peer(vec![8; 32])), "another id is not");
        assert!(!g.is_blocked(ip("127.0.0.1")) && !g.is_blocked(ip("203.0.113.1")), "nor any address");
        for _ in 0..10 {
            assert!(!g.failed_as(Kind::Quic, &Source::Exempt));
        }
    }

    #[test]
    fn offers_have_their_own_pool_never_sent_away_and_block_only_webrtc() {
        let g = Guard::new(GuardConfig { max_unauthenticated: 2, failure_limit: 1, ..GuardConfig::default() });
        let a = ip("203.0.113.1");
        let o1 = g.admit_offer(Some(a), g.source_of(a)).unwrap();
        let o2 = g.admit_offer(Some(ip("198.51.100.1")), g.source_of(ip("198.51.100.1"))).unwrap();
        // the pool is full of offers: a new one is refused, none sent away
        assert_eq!(
            g.admit_offer(Some(ip("192.0.2.1")), g.source_of(ip("192.0.2.1"))).unwrap_err(),
            Refusal::TooManyUnauthenticated
        );
        assert!(!o1.was_sent_away() && !o2.was_sent_away());
        assert_eq!(g.counts(), (2, 2));
        // QUIC from the same address still has its places: offers never take them
        for _ in 0..2 {
            let mut q = g.admit(Some(a)).unwrap();
            q.handshake_done(Way::Straight, g.source_of(a)).unwrap();
            std::mem::forget(q);
        }
        assert!(!o1.was_sent_away());
        // a WebRTC failure blocks WebRTC only
        assert!(g.failed_as(Kind::WebRtc, &g.source_of(a)));
        assert!(g.is_blocked_as(Kind::WebRtc, &g.source_of(a)));
        assert!(!g.is_blocked(a), "QUIC from it is not blocked");
        assert_eq!(g.admit_offer(Some(a), g.source_of(a)).unwrap_err(), Refusal::Blocked);
        assert!(g.admit(Some(a)).is_ok());
    }

    #[test]
    fn sessions_are_capped() {
        let g = Guard::new(GuardConfig { max_sessions: 2, ..GuardConfig::default() });
        let mut held = Vec::new();
        for i in 0..2 {
            let mut p = g.admit(Some(ip(&format!("192.0.2.{}", i + 1)))).unwrap();
            p.handshake_done(Way::Straight, Source::Ip(ip(&format!("192.0.2.{}", i + 1)))).unwrap();
            assert!(p.authenticated());
            held.push(p);
        }
        let mut third = g.admit(Some(ip("192.0.2.9"))).unwrap();
        assert_eq!(
            third.handshake_done(Way::Straight, Source::Ip(ip("192.0.2.9"))).unwrap_err(),
            Refusal::TooManySessions
        );
        drop(third);
        drop(held);
        assert_eq!(g.counts(), (0, 0));
        let a = ip("192.0.2.9");
        for _ in 0..10 {
            g.failed(a);
        }
        assert_eq!(g.admit(Some(a)).unwrap_err(), Refusal::Blocked);
    }

    #[test]
    fn sources_ipv6_per_64_lan_per_address_mapped_as_itself() {
        assert_eq!(source_key(ip("2001:db8:1:2::10")), source_key(ip("2001:db8:1:2:ffff::99")));
        assert_ne!(source_key(ip("2001:db8:1:2::10")), source_key(ip("2001:db8:1:3::10")));
        assert_ne!(source_key(ip("fe80::1")), source_key(ip("fe80::2")), "link-local: each its own");
        assert_ne!(
            source_key(ip("fdf4:9c0f:8392:4a54::1")),
            source_key(ip("fdf4:9c0f:8392:4a54::2")),
            "unique-local: each its own"
        );
        assert_eq!(source_key(ip("::ffff:192.0.2.1")), ip("192.0.2.1"));
        let g = Guard::new(GuardConfig::default());
        let t0 = Instant::now();
        for i in 0..10u16 {
            g.failed_at(ip(&format!("2001:db8:9:9::{i}")), t0);
        }
        assert!(g.is_blocked_at(ip("2001:db8:9:9:abcd::1"), t0), "the block covers the /64");
    }
}
