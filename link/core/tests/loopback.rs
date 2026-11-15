// Loopback integration: a server endpoint and clients on 127.0.0.1 — handshake (accepted / denied), the client key
// binding hook, RPC streaming, control messages, datagram channels, the guard's limits, the congestion controller.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use bytes::Bytes;
use serde_json::{Value, json};
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, CloseCode, DenyCode, DialOptions, DialTarget, DuplexMessage, Endpoint,
    EndpointConfig, GuardConfig, Headers, Hello, LinkError, PathKind, RpcHandler, RpcRequest, RpcResponder, ServerInfo,
    ServerOptions, Session,
    binding::{generate_link_key, identity_fingerprint},
    cc::MediaCc,
};

// Channels 1–5 belong to the media layer (tests/media.rs); the app's own channels here.
const APP_A: u8 = 7;
const APP_B: u8 = 8;
const APP_C: u8 = 9;
const APP_D: u8 = 10;

/// Accepts `Bearer good`; binds each token to the first client key that used it (as the device store does).
#[derive(Default)]
struct Tokens {
    bound: Mutex<HashMap<String, String>>,
    asked: Mutex<Vec<AuthRequest>>,
}

#[async_trait]
impl Authenticator for Tokens {
    async fn authenticate(&self, r: AuthRequest) -> AuthDecision {
        self.asked.lock().unwrap().push(r.clone());
        let Some(token) = r.hello.credential.strip_prefix("Bearer ") else {
            return AuthDecision::Deny { code: DenyCode::Unauthorized, message: "no token".into() };
        };
        // `good-slow…`: an authenticator that takes its time (a server asking its owner)
        if token.starts_with("good-slower") {
            tokio::time::sleep(Duration::from_millis(5000)).await;
        } else if token.starts_with("good-slow") {
            tokio::time::sleep(Duration::from_millis(1500)).await;
        }
        if !token.starts_with("good") {
            return AuthDecision::Deny { code: DenyCode::Unauthorized, message: "unknown token".into() };
        }
        let mut bound = self.bound.lock().unwrap();
        let key = bound.entry(token.to_string()).or_insert_with(|| r.client_key.clone());
        if *key != r.client_key {
            return AuthDecision::Deny { code: DenyCode::Unauthorized, message: "token bound to another key".into() };
        }
        AuthDecision::Accept {
            principal: json!({"device": {"id": r.hello.device.id, "name": r.hello.device.name}}),
            features: None,
        }
    }
}

/// `/echo` echoes the body; `/count?n=3` streams n lines.
struct Routes;

#[async_trait]
impl RpcHandler for Routes {
    async fn handle(&self, session: Session, req: RpcRequest, body: Bytes, mut res: RpcResponder) {
        let mut h = Headers::new();
        h.insert("x-principal".into(), session.principal()["device"]["id"].as_str().unwrap_or("").into());
        if req.duplex {
            match req.path.as_str() {
                // echoes every message; a close is echoed and then this side finishes
                "/ws" => {
                    let mut h = Headers::new();
                    h.insert("x-ws".into(), "yes".into());
                    let Ok(mut d) = res.accept_duplex(&h).await else { return };
                    while let Ok(Some(m)) = d.receiver.recv().await {
                        let close = matches!(m, DuplexMessage::Close { .. });
                        if d.sender.send(&m).await.is_err() {
                            return;
                        }
                        if close {
                            let _ = d.sender.finish().await;
                            return;
                        }
                    }
                    let _ = d.sender.finish().await;
                }
                _ => res.respond(403, &h, b"{\"error\":\"no\"}").await.unwrap(),
            }
            return;
        }
        match req.path.split('?').next().unwrap() {
            "/echo" => {
                h.insert("x-method".into(), req.method.clone());
                res.respond(200, &h, &body).await.unwrap();
            }
            "/count" => {
                let n: u32 = req.path.split("n=").nth(1).and_then(|s| s.parse().ok()).unwrap_or(1);
                res.head(200, &h).await.unwrap();
                for i in 0..n {
                    res.write(format!("{{\"i\":{i}}}\n").as_bytes()).await.unwrap();
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                res.finish().await.unwrap();
            }
            "/forever" => {
                res.head(200, &h).await.unwrap();
                while res.write(b"tick\n").await.is_ok() {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            }
            _ => res.respond(404, &h, b"{}").await.unwrap(),
        }
    }
}

struct Server {
    ep: Endpoint,
    tokens: Arc<Tokens>,
    sessions: tokio::sync::mpsc::UnboundedReceiver<Session>,
}

async fn server(guard: GuardConfig, hello_timeout: Duration) -> Server {
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    cfg.guard = guard;
    let ep = Endpoint::bind(cfg).await.unwrap();
    let tokens = Arc::new(Tokens::default());
    let mut opts = ServerOptions::new(
        ServerInfo { id: "srv-1".into(), name: "Test Mac".into(), platform: "macos".into() },
        tokens.clone(),
    );
    opts.features = vec!["link".into(), "clipboard".into()];
    opts.rpc = Some(Arc::new(Routes));
    opts.duplex = true;
    opts.hello_timeout = hello_timeout;
    let listener = ep.listen(opts).unwrap();
    let (tx, sessions) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Some(s) = listener.accept().await {
            if tx.send(s).is_err() {
                break;
            }
        }
    });
    Server { ep, tokens, sessions }
}

async fn default_server() -> Server {
    server(GuardConfig::default(), Duration::from_secs(5)).await
}

fn target(s: &Server) -> DialTarget {
    DialTarget { id: s.ep.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", s.ep.port())] }
}

fn hello(token: &str, device: &str) -> Hello {
    Hello {
        credential: format!("Bearer {token}"),
        device: uu_link::Device { id: device.into(), name: format!("{device}'s iPhone") },
        app: uu_link::AppInfo { name: "uu".into(), version: "1.0".into() },
        features: vec!["link".into()],
    }
}

async fn client() -> Endpoint {
    Endpoint::bind(EndpointConfig::client(generate_link_key())).await.unwrap()
}

async fn dial(s: &Server, token: &str, device: &str) -> Result<Session, LinkError> {
    client().await.dial(&target(s), &hello(token, device), &DialOptions::default()).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn handshake_accepted() {
    let mut s = default_server().await;
    let c = dial(&s, "good-1", "phone-a").await.unwrap();
    let srv = s.sessions.recv().await.unwrap();

    assert_eq!(c.welcome().server.name, "Test Mac");
    assert_eq!(c.welcome().features, vec!["link", "clipboard", "duplex"]);
    assert_eq!(c.principal()["device"]["id"], "phone-a");
    assert!(c.welcome().max_datagram > 1000, "max datagram {}", c.welcome().max_datagram);
    assert_eq!(srv.hello().device.name, "phone-a's iPhone");
    assert_eq!(srv.hello().app.version, "1.0");
    assert_eq!(c.remote_id(), s.ep.id());
    assert_eq!(srv.remote_id(), s.tokens.asked.lock().unwrap()[0].client_key);
    let asked = s.tokens.asked.lock().unwrap()[0].clone();
    assert_eq!(asked.source.path, PathKind::Lan);
    assert_eq!(asked.source.addr.unwrap().ip().to_string(), "127.0.0.1");
    assert_eq!(c.path().kind, PathKind::Lan);
    assert_eq!(srv.path().kind, PathKind::Lan);
    assert_eq!(s.ep.guard().counts(), (1, 0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_unauthorized() {
    let s = default_server().await;
    match dial(&s, "bad", "phone-b").await {
        Err(LinkError::Denied { code: DenyCode::Unauthorized, message }) => assert_eq!(message, "unknown token"),
        other => panic!("expected denied, got {other:?}"),
    }
    // no credential at all
    let ep = client().await;
    let mut h = hello("x", "phone-b");
    h.credential.clear();
    let r = ep.dial(&target(&s), &h, &DialOptions::default()).await;
    assert!(matches!(r, Err(LinkError::Denied { code: DenyCode::Unauthorized, .. })), "{r:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn client_key_binding() {
    let mut s = default_server().await;
    // first key binds the token
    let ep = client().await;
    let first = ep.dial(&target(&s), &hello("good-bind", "phone-c"), &DialOptions::default()).await.unwrap();
    let _ = s.sessions.recv().await.unwrap();
    // the same key again: fine
    let again = ep.dial(&target(&s), &hello("good-bind", "phone-c"), &DialOptions::default()).await;
    assert!(again.is_ok());
    // another key with the same token: denied
    let stolen = dial(&s, "good-bind", "phone-c").await;
    assert!(matches!(stolen, Err(LinkError::Denied { code: DenyCode::Unauthorized, .. })), "{stolen:?}");
    drop(first);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rpc_streaming() {
    let mut s = default_server().await;
    let c = dial(&s, "good-rpc", "phone-d").await.unwrap();
    let _srv = s.sessions.recv().await.unwrap();

    let mut r =
        c.request(&RpcRequest::new("POST", "/echo").header("Content-Type", "text/plain"), b"hi there").await.unwrap();
    assert_eq!(r.status, 200);
    assert_eq!(r.headers["x-method"], "POST");
    assert_eq!(r.headers["x-principal"], "phone-d");
    assert_eq!(&r.body.read_all(1 << 20).await.unwrap()[..], b"hi there");

    // a streamed body arrives in pieces
    let mut r = c.request(&RpcRequest::new("GET", "/count?n=20"), b"").await.unwrap();
    let mut text = Vec::new();
    while let Some(chunk) = r.body.chunk().await.unwrap() {
        text.extend_from_slice(&chunk);
    }
    let lines: Vec<&str> = std::str::from_utf8(&text).unwrap().lines().collect();
    assert_eq!(lines.len(), 20);
    assert_eq!(lines[19], r#"{"i":19}"#);

    // a large body both ways
    let big = vec![7u8; 3 << 20];
    let mut r = c.request(&RpcRequest::new("POST", "/echo"), &big).await.unwrap();
    assert_eq!(r.body.read_all(8 << 20).await.unwrap().len(), big.len());

    // channels are not RPC
    for p in ["/stream?display=1", "/audio", "/input", "/control", "/stream/ack"] {
        let r = c.request(&RpcRequest::new("GET", p), b"").await.unwrap();
        assert_eq!(r.status, 404, "{p}");
    }
    // too large
    let huge = vec![0u8; 9 << 20];
    let r = c.request(&RpcRequest::new("POST", "/echo"), &huge).await;
    if let Ok(r) = r {
        assert_eq!(r.status, 413);
    }

    // a cancelled stream ends on the server; many at once
    let mut r = c.request(&RpcRequest::new("GET", "/forever"), b"").await.unwrap();
    assert!(r.body.chunk().await.unwrap().is_some());
    r.body.cancel();
    let mut joins = Vec::new();
    for i in 0..40 {
        let c = c.clone();
        joins.push(tokio::spawn(async move {
            let body = format!("req {i}");
            let mut r = c.request(&RpcRequest::new("POST", "/echo"), body.as_bytes()).await.unwrap();
            assert_eq!(&r.body.read_all(1024).await.unwrap()[..], body.as_bytes());
        }));
    }
    for j in joins {
        j.await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_messages() {
    let mut s = default_server().await;
    let c = dial(&s, "good-ctl", "phone-e").await.unwrap();
    let srv = s.sessions.recv().await.unwrap();

    c.send_control(&json!({"t": "control.take", "rid": 1})).await.unwrap();
    let m = srv.recv_control().await.unwrap();
    assert_eq!(m, json!({"t": "control.take", "rid": 1}));
    srv.send_control(&json!({"t": "control", "rid": 1, "granted": true, "holder": {"id": "phone-e"}})).await.unwrap();
    let m = c.recv_control().await.unwrap();
    assert_eq!(m["granted"], true);
    // not a message
    assert!(c.send_control(&json!({"rid": 1})).await.is_err());
    assert!(c.send_control(&json!({"t": "hello"})).await.is_err());
    // order is kept
    for i in 0..100 {
        srv.send_control(&json!({"t": "video.status", "id": 1, "n": i})).await.unwrap();
    }
    for i in 0..100 {
        assert_eq!(c.recv_control().await.unwrap()["n"], i);
    }
    // close with a code: the other side sees bye, then the code
    srv.close(CloseCode::Replaced, "another session").await;
    let bye = c.recv_control().await.unwrap();
    assert_eq!(bye, json!({"t": "bye", "reason": "another session"}));
    let info = c.closed().await;
    assert_eq!(info.code, Some(CloseCode::Replaced));
    assert!(info.remote);
    assert_eq!(info.reason, "another session");
    assert!(c.recv_control().await.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn datagram_channels() {
    let mut s = default_server().await;
    let c = dial(&s, "good-dg", "phone-f").await.unwrap();
    let srv = s.sessions.recv().await.unwrap();
    assert!(c.max_datagram_size() > 1000);

    for i in 0u8..50 {
        c.send_datagram(APP_A, &[i]).unwrap();
        srv.send_datagram(APP_B, &[i, i]).unwrap();
        srv.send_datagram(APP_C, &[i, i, i]).unwrap();
    }
    let mut got = 0;
    while got < 50 {
        let d = tokio::time::timeout(Duration::from_secs(2), srv.recv_datagram(APP_A)).await.unwrap().unwrap().unwrap();
        assert_eq!(d[0], 0x71);
        assert_eq!(d.len(), 2);
        got += 1;
    }
    for _ in 0..50 {
        let v = c.recv_datagram(APP_B).await.unwrap().unwrap();
        assert_eq!((v[0], v.len()), (0x81, 3));
        let k = c.recv_datagram(APP_C).await.unwrap().unwrap();
        assert_eq!((k[0], k.len()), (0x91, 4));
    }
    assert!(c.try_recv_datagram(APP_D).unwrap().is_none());
    assert!(c.send_datagram(0, b"x").is_err());
    // a raw datagram on a media channel goes to the media layer, not to a queue
    c.send_datagram(1, b"not video").unwrap();
    assert!(srv.try_recv_datagram(1).unwrap().is_none());
    assert!(c.send_datagram_raw(Bytes::from_static(&[0x12, 1])).is_err());
    assert!(c.send_datagram(APP_B, &vec![0u8; 70_000]).is_err());

    // the session ends: receivers see the end
    drop(srv);
    let end = tokio::time::timeout(Duration::from_secs(3), c.recv_datagram(APP_B)).await.unwrap().unwrap();
    assert!(end.is_none());
    assert_eq!(c.closed().await.code, Some(CloseCode::Normal));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn media_cc_drives_every_path() {
    let mut s = default_server().await;
    let c = dial(&s, "good-cc", "phone-g").await.unwrap();
    let srv = s.sessions.recv().await.unwrap();
    // some traffic for an RTT sample
    for _ in 0..5 {
        let mut r = c.request(&RpcRequest::new("GET", "/echo"), b"x").await.unwrap();
        r.body.read_all(10).await.unwrap();
    }
    for sess in [&c, &srv] {
        let conn = sess.connection().unwrap();
        let path_id = conn.paths().iter().find(|p| p.is_selected()).unwrap().id();
        let cc = conn.congestion_state(path_id).unwrap();
        let cc = cc.into_any().downcast::<MediaCc>().expect("MediaCc on the path");
        sess.target_bitrate().set(16_000_000);
        let w = iroh::endpoint::Controller::window(&*cc);
        assert!(w >= 16 * 1200, "window {w}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guard_limits() {
    let guard = GuardConfig {
        failure_limit: 3,
        max_unauthenticated: 2,
        max_sessions: 3,
        exempt_loopback: false,
        ..GuardConfig::default()
    };
    let mut s = server(guard, Duration::from_millis(1500)).await;
    let quick = DialOptions { connect_timeout: Duration::from_secs(2), ..DialOptions::default() };

    // two connections past their handshake that never say hello hold this address's share and the pool: a new one
    // makes room (the oldest is sent away, with Busy) instead of being refused
    let raw1 = raw_connect(&s).await.unwrap();
    let _raw2 = raw_connect(&s).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(s.ep.guard().counts(), (2, 2));
    let a = dial(&s, "good-g0", "g0").await.unwrap();
    let srv_a = s.sessions.recv().await.unwrap();
    assert_busy(raw1.closed().await);
    // being sent away counts as nothing: no block
    assert!(!s.ep.guard().is_blocked("127.0.0.1".parse().unwrap()));

    // at most 3 sessions (one is `a`; the other raw one still waits for its hello)
    let b = dial(&s, "good-g1", "g1").await.unwrap();
    let srv_b = s.sessions.recv().await.unwrap();
    drop((a, b, srv_a, srv_b));
    tokio::time::sleep(Duration::from_millis(1600)).await;

    // failures after the handshake (the address is proven) — the raw one's hello timeout, denied hellos — reach the
    // limit of 3: 127.0.0.1 is blocked, and then ignored
    let lo: std::net::IpAddr = "127.0.0.1".parse().unwrap();
    for i in 0..3 {
        if s.ep.guard().is_blocked(lo) {
            break;
        }
        let denied = dial(&s, "bad", &format!("bad{i}")).await;
        assert!(matches!(denied, Err(LinkError::Denied { .. })), "{denied:?}");
    }
    assert!(s.ep.guard().is_blocked(lo));
    let blocked = client().await.dial(&target(&s), &hello("good-g6", "g6"), &quick).await;
    assert!(blocked.is_err(), "{blocked:?}");
}

/// One address keeping connections waiting for their hello (never failing) fills the pool: another address still
/// gets in (the oldest waiting one is sent away, with Busy), and so does a newcomer of its own (its own oldest goes).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_address_cannot_shut_out_another() {
    // (a failure limit of 1: being sent away counting as a failure would block at once)
    let guard =
        GuardConfig { exempt_loopback: false, max_unauthenticated: 2, failure_limit: 1, ..GuardConfig::default() };
    let mut s = server(guard, Duration::from_millis(5000)).await;
    let Some(v6port) = s.ep.bound_sockets().iter().find(|a| a.is_ipv6()).map(|a| a.port()) else {
        eprintln!("no IPv6 socket here: skipped");
        return;
    };
    let raw1 = raw_connect(&s).await.unwrap();
    let raw2 = raw_connect(&s).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(s.ep.guard().pools(), (0, 2), "the pool is full");
    // the same address: in, by sending its own oldest away
    let same = dial(&s, "good-h0", "h0").await;
    assert!(same.is_ok(), "{same:?}");
    let _s0 = s.sessions.recv().await.unwrap();
    assert_busy(raw1.closed().await);
    let raw3 = raw_connect(&s).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(s.ep.guard().pools(), (0, 2), "full again");
    let v6 = DialTarget { id: s.ep.id(), relays: vec![], direct: vec![format!("[::1]:{v6port}")] };
    let quick = DialOptions { connect_timeout: Duration::from_secs(2), ..DialOptions::default() };
    let other = client().await.dial(&v6, &hello("good-h1", "h1"), &quick).await;
    assert!(other.is_ok(), "{other:?}");
    let _s1 = s.sessions.recv().await.unwrap();
    // it sent the oldest waiting one away
    assert_busy(raw2.closed().await);
    assert!(raw3.close_reason().is_none());
    // and none of that counted
    assert!(!s.ep.guard().is_blocked("127.0.0.1".parse().unwrap()) && !s.ep.guard().is_blocked("::1".parse().unwrap()));
}

/// A client given two addresses of the server (a LAN one and a Tailscale one, say) sends its first packet to both:
/// it connects, and the stray copy holds nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_client_with_two_addresses_connects() {
    let guard = GuardConfig { exempt_loopback: false, ..GuardConfig::default() };
    let mut s = server(guard, Duration::from_millis(3000)).await;
    let Some(v6port) = s.ep.bound_sockets().iter().find(|a| a.is_ipv6()).map(|a| a.port()) else {
        eprintln!("no IPv6 socket here: skipped");
        return;
    };
    let both = DialTarget {
        id: s.ep.id(),
        relays: vec![],
        direct: vec![format!("127.0.0.1:{}", s.ep.port()), format!("[::1]:{v6port}")],
    };
    let sess = client().await.dial(&both, &hello("good-d0", "d0"), &DialOptions::default()).await;
    assert!(sess.is_ok(), "{sess:?}");
    let _srv = s.sessions.recv().await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let (_, pending) = s.ep.guard().counts();
    assert!(pending <= 1, "no strays left waiting (pending {pending})");
}

/// A connection the guard sent away: closed with Busy.
fn assert_busy(e: iroh::endpoint::ConnectionError) {
    match &e {
        iroh::endpoint::ConnectionError::ApplicationClosed(c) => {
            assert_eq!(u64::from(c.error_code), CloseCode::Busy.code(), "{e:?}")
        }
        _ => panic!("not closed with Busy: {e:?}"),
    }
}

/// A connection that has sent its hello and waits on a slow authenticator is never sent away: connections of
/// another address that never say hello fill the pool one after another, and the full pool sends the oldest of
/// those away each time, never the older one in the authenticator.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_in_the_authenticator_stays() {
    let guard = GuardConfig { exempt_loopback: false, max_unauthenticated: 2, ..GuardConfig::default() };
    let mut s = server(guard, Duration::from_millis(5000)).await;
    let Some(v6port) = s.ep.bound_sockets().iter().find(|a| a.is_ipv6()).map(|a| a.port()) else {
        eprintln!("no IPv6 socket here: skipped");
        return;
    };
    let ep = s.ep.clone();
    let slow = tokio::spawn(async move {
        let t = DialTarget { id: ep.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", ep.port())] };
        client().await.dial(&t, &hello("good-slow-1", "slow1"), &DialOptions::default()).await
    });
    // it is in the authenticator now (for 1.5 s)
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(s.ep.guard().pools(), (0, 1));
    assert_eq!(s.tokens.asked.lock().unwrap().len(), 1);
    let mut raws = Vec::new();
    for _ in 0..4 {
        raws.push(raw_connect_to(&s, format!("[::1]:{v6port}")).await.unwrap());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // (all of that while the slow one was still waiting on its authenticator)
    assert!(!slow.is_finished(), "the slow one is still in the authenticator");
    assert_eq!(s.ep.guard().pools(), (0, 2));
    for r in &raws[..3] {
        assert_busy(r.closed().await);
    }
    assert!(raws[3].close_reason().is_none());
    let sess = slow.await.unwrap();
    assert!(sess.is_ok(), "{sess:?}");
    let _srv = s.sessions.recv().await.unwrap();
}

/// A client that goes away while the (slow) authenticator still thinks frees its place at once, not only when the
/// authenticator answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_client_gone_in_the_authenticator_frees_its_place() {
    let guard = GuardConfig { exempt_loopback: false, ..GuardConfig::default() };
    let s = server(guard, Duration::from_millis(5000)).await;
    let c = client().await;
    let t0 = std::time::Instant::now();
    let dialing = {
        let (c, t) = (c.clone(), target(&s));
        tokio::spawn(async move { c.dial(&t, &hello("good-slower-2", "slow2"), &DialOptions::default()).await })
    };
    // it gives up in the authenticator: the dial dropped, its endpoint closed
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(s.tokens.asked.lock().unwrap().len(), 1, "it reached the authenticator");
    assert_eq!(s.ep.guard().pools(), (0, 1));
    dialing.abort();
    c.close().await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(t0.elapsed() < Duration::from_millis(4500), "still within the authenticator's 5 s");
    assert_eq!(s.ep.guard().counts(), (0, 0), "its place is free");
}

/// A handshake pool kept full of handshakes that never finish (their packets go nowhere), refreshed all along: a real
/// client still completes its handshake and its hello.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_client_gets_through_a_flood_of_handshakes() {
    let guard = GuardConfig { exempt_loopback: false, max_handshaking: 4, ..GuardConfig::default() };
    let mut s = server(guard, Duration::from_millis(5000)).await;
    // a one-way relay: what a client sends reaches the server, nothing comes back
    let sink = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let sink_addr = sink.local_addr().unwrap();
    let fwd = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let server_addr: std::net::SocketAddr = format!("127.0.0.1:{}", s.ep.port()).parse().unwrap();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, _)) = sink.recv_from(&mut buf).await {
            let _ = fwd.send_to(&buf[..n], server_addr).await;
        }
    });
    let id = iroh::PublicKey::from_bytes(&uu_link::binding::parse_endpoint_id(&s.ep.id()).unwrap()).unwrap();
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flood = {
        let stop = stop.clone();
        tokio::spawn(async move {
            let ep = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
                .relay_mode(iroh::RelayMode::Disabled)
                .clear_address_lookup()
                .bind()
                .await
                .unwrap();
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let ep = ep.clone();
                let addr = iroh::EndpointAddr::from_parts(id, [iroh::TransportAddr::Ip(sink_addr)]);
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(8), ep.connect(addr, uu_link::ALPN)).await;
                });
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            ep
        })
    };
    // the pool fills
    let mut full = false;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(20)).await;
        if s.ep.guard().pools().0 == 4 {
            full = true;
            break;
        }
    }
    assert!(full, "the handshake pool filled: {:?}", s.ep.guard().pools());
    let sess = dial(&s, "good-f0", "f0").await;
    assert!(sess.is_ok(), "{sess:?}");
    let _srv = s.sessions.recv().await.unwrap();
    assert!(s.ep.guard().pools().0 >= 3, "and the flood went on all along: {:?}", s.ep.guard().pools());
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    drop(flood.await.unwrap());
}

/// A relay on 127.0.0.1 (plain http): its URL.
async fn relay() -> (iroh_relay::server::Server, String) {
    let mut config = iroh_relay::server::testing::server_config();
    config.quic = None;
    if let Some(r) = config.relay.as_mut() {
        r.tls = None;
    }
    let server = iroh_relay::server::Server::spawn(config).await.unwrap();
    let url = format!("http://{}", server.http_addr().unwrap());
    (server, url)
}

/// Through a relay, failures count by the client's endpoint id: its id is blocked (refused right after the
/// handshake), no address is, and another id still gets in. And a client whose address is blocked still connects
/// through the relay: the straight copy of its first packet is ignored, not refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relayed_failures_count_by_endpoint_id() {
    let (_relay, url) = relay().await;
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    cfg.relays = vec![url.clone()];
    cfg.guard = GuardConfig { failure_limit: 3, exempt_loopback: false, ..GuardConfig::default() };
    let ep = Endpoint::bind(cfg).await.unwrap();
    let tokens = Arc::new(Tokens::default());
    let opts = ServerOptions::new(
        ServerInfo { id: "srv-1".into(), name: "Test Mac".into(), platform: "macos".into() },
        tokens.clone(),
    );
    let listener = ep.listen(opts).unwrap();
    // (sessions kept: one dropped would close at once)
    tokio::spawn(async move {
        let mut kept = Vec::new();
        while let Some(s) = listener.accept().await {
            kept.push(s);
        }
    });
    let relayed = DialTarget { id: ep.id(), relays: vec![url.clone()], direct: vec![] };
    let client_with = |key: [u8; 32]| {
        let url = url.clone();
        async move {
            let mut c = EndpointConfig::client(key);
            c.relays = vec![url];
            Endpoint::bind(c).await.unwrap()
        }
    };

    let key = generate_link_key();
    let c = client_with(key).await;
    let peer = uu_link::guard::Source::Peer(uu_link::binding::parse_endpoint_id(&c.id()).unwrap().to_vec());
    for i in 0..3 {
        let r = c.dial(&relayed, &hello("bad", &format!("r{i}")), &DialOptions::default()).await;
        assert!(matches!(r, Err(LinkError::Denied { code: DenyCode::Unauthorized, .. })), "{r:?}");
    }
    assert!(ep.guard().is_blocked_as(uu_link::guard::Kind::Quic, &peer), "its endpoint id is blocked");
    assert!(!ep.guard().is_blocked("127.0.0.1".parse().unwrap()), "no address is");
    let r = client_with(key).await.dial(&relayed, &hello("good-r", "r"), &DialOptions::default()).await;
    assert!(matches!(r, Err(LinkError::Denied { code: DenyCode::RateLimited, .. })), "{r:?}");
    let other =
        client_with(generate_link_key()).await.dial(&relayed, &hello("good-o", "o"), &DialOptions::default()).await;
    assert!(other.is_ok(), "another id gets in: {other:?}");

    // 127.0.0.1 blocked (failures over the direct path)…
    let direct = DialTarget { id: ep.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", ep.port())] };
    let lo: std::net::IpAddr = "127.0.0.1".parse().unwrap();
    for i in 0..3 {
        if ep.guard().is_blocked(lo) {
            break;
        }
        let r = client().await.dial(&direct, &hello("bad", &format!("d{i}")), &DialOptions::default()).await;
        assert!(matches!(r, Err(LinkError::Denied { code: DenyCode::Unauthorized, .. })), "{r:?}");
    }
    assert!(ep.guard().is_blocked(lo));
    // …a client given both ways still connects, through the relay
    let both = DialTarget { id: ep.id(), relays: vec![url.clone()], direct: vec![format!("127.0.0.1:{}", ep.port())] };
    let sess = client_with(generate_link_key()).await.dial(&both, &hello("good-b", "b"), &DialOptions::default()).await;
    assert!(sess.is_ok(), "{sess:?}");
}

/// A QUIC connection with the link's ALPN that never opens the control stream.
async fn raw_connect(s: &Server) -> Result<iroh::endpoint::Connection, String> {
    raw_connect_to(s, format!("127.0.0.1:{}", s.ep.port())).await
}

/// The same, to `addr` (`ip:port`).
async fn raw_connect_to(s: &Server, addr: String) -> Result<iroh::endpoint::Connection, String> {
    let ep = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .relay_mode(iroh::RelayMode::Disabled)
        .clear_address_lookup()
        .bind()
        .await
        .map_err(|e| e.to_string())?;
    let id = iroh::PublicKey::from_bytes(&uu_link::binding::parse_endpoint_id(&s.ep.id()).unwrap()).unwrap();
    let addr = iroh::EndpointAddr::from_parts(id, [iroh::TransportAddr::Ip(addr.parse().unwrap())]);
    let conn = ep.connect(addr, uu_link::ALPN).await.map_err(|e| e.to_string())?;
    // keep the endpoint alive as long as the connection
    std::mem::forget(ep);
    Ok(conn)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dial_with_a_verified_binding() {
    let mut s = default_server().await;
    let identity = test_identity();
    let fp = identity_fingerprint(&identity).unwrap();
    let b = s.ep.binding(&identity).unwrap();
    let direct = vec![format!("127.0.0.1:{}", s.ep.port())];
    let t = DialTarget::from_binding(&b, &fp, vec![], direct.clone()).unwrap();
    assert_eq!(t.id, s.ep.id());
    let c = client().await.dial(&t, &hello("good-b", "phone-h"), &DialOptions::default()).await.unwrap();
    let _ = s.sessions.recv().await.unwrap();
    assert_eq!(c.remote_id(), s.ep.id());
    // the wrong pin fails before dialing
    let other = identity_fingerprint(&test_identity()).unwrap();
    assert!(DialTarget::from_binding(&b, &other, vec![], direct).is_err());
    // the endpoint publishes its addresses
    let info = s.ep.addr_info();
    assert_eq!(info.id, s.ep.id());
    assert!(info.direct.iter().any(|a| a.ends_with(&format!(":{}", s.ep.port()))), "{info:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stats_exchange() {
    let mut s = default_server().await;
    let c = dial(&s, "good-st", "phone-i").await.unwrap();
    let srv = s.sessions.recv().await.unwrap();
    c.set_media_stats(uu_link::MediaStats { fps: Some(60.0), ..Default::default() });
    tokio::time::sleep(Duration::from_millis(2600)).await;
    let peer = srv.peer_stats().expect("the client's link.stats");
    assert_eq!(peer.path, PathKind::Lan);
    assert_eq!(peer.media.fps, Some(60.0));
    let own = srv.stats();
    assert!(own.rtt_p50_ms > 0.0 && own.rtt_p50_ms < 50.0, "{own:?}");
    assert!(own.line().starts_with("lan other rtt "), "{}", own.line());
    // link.stats is the session's, not the app's
    assert!(tokio::time::timeout(Duration::from_millis(100), c.recv_control()).await.is_err());
    let _: Value = json!(null);
}

fn test_identity() -> Vec<u8> {
    use ring::{
        rand::SystemRandom,
        signature::{self, EcdsaKeyPair, KeyPair},
    };
    let rng = SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let pair = EcdsaKeyPair::from_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
    let doc = pkcs8.as_ref();
    let at = doc.windows(2).position(|w| w == [0x04, 0x20]).unwrap() + 2;
    let mut key = pair.public_key().as_ref().to_vec();
    key.extend_from_slice(&doc[at..at + 32]);
    key
}

/// Duplex requests (a WebSocket's upgrade over the link): messages both ways at once, the size limit, the close
/// message and FIN, a refusal (any status but 101, with its body), a path the link keeps for itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplex_requests() {
    let mut s = default_server().await;
    let c = dial(&s, "good-ws", "ws").await.unwrap();
    let _srv = s.sessions.recv().await.unwrap();
    assert!(c.welcome().features.iter().any(|f| f == "duplex"), "{:?}", c.welcome().features);

    let r = c.request_duplex(&RpcRequest::new("GET", "/ws")).await.unwrap();
    assert_eq!(r.status, 101);
    assert_eq!(r.headers.get("x-ws").map(String::as_str), Some("yes"));
    let uu_link::Duplex { mut sender, mut receiver } = r.duplex.unwrap();

    // both directions at once: 200 messages out while their echoes come back
    let writer = tokio::spawn(async move {
        for i in 0..200u32 {
            let m = if i % 2 == 0 {
                DuplexMessage::Text(format!("m{i}"))
            } else {
                DuplexMessage::Binary(Bytes::from(i.to_be_bytes().to_vec()))
            };
            sender.send(&m).await.unwrap();
        }
        // the largest message, then one byte over
        sender.send(&DuplexMessage::Binary(vec![7u8; uu_link::MAX_DUPLEX_MESSAGE].into())).await.unwrap();
        assert!(sender.send(&DuplexMessage::Binary(vec![7u8; uu_link::MAX_DUPLEX_MESSAGE + 1].into())).await.is_err());
        sender.send(&DuplexMessage::Close { code: 4001, reason: "bye".into() }).await.unwrap();
        sender
    });
    for i in 0..200u32 {
        let m = tokio::time::timeout(Duration::from_secs(5), receiver.recv()).await.unwrap().unwrap().unwrap();
        let want = if i % 2 == 0 {
            DuplexMessage::Text(format!("m{i}"))
        } else {
            DuplexMessage::Binary(Bytes::from(i.to_be_bytes().to_vec()))
        };
        assert_eq!(m, want);
    }
    match receiver.recv().await.unwrap().unwrap() {
        DuplexMessage::Binary(b) => assert_eq!(b.len(), uu_link::MAX_DUPLEX_MESSAGE),
        other => panic!("{other:?}"),
    }
    assert_eq!(receiver.recv().await.unwrap().unwrap(), DuplexMessage::Close { code: 4001, reason: "bye".into() });
    // the server finished after echoing the close: the stream ends
    assert_eq!(receiver.recv().await.unwrap(), None);
    let mut sender = writer.await.unwrap();
    sender.finish().await.unwrap();

    // refused: its status and body, no stream
    let mut no = c.request_duplex(&RpcRequest::new("GET", "/nope")).await.unwrap();
    assert_eq!(no.status, 403);
    assert!(no.duplex.is_none());
    assert_eq!(&no.body.read_all(1024).await.unwrap()[..], b"{\"error\":\"no\"}");
    // the link's own paths stay closed to duplex requests too
    let blocked = c.request_duplex(&RpcRequest::new("GET", "/control")).await.unwrap();
    assert_eq!(blocked.status, 404);
    // plain requests still work on the same session
    let mut e = c.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
}

/// A server with no RPC handler says nothing of duplex in its welcome: the client sends no duplex request to it (an
/// older server would wait for a body that never comes).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_duplex_request_to_a_server_without_it() {
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    let ep = Endpoint::bind(cfg).await.unwrap();
    let opts = ServerOptions::new(
        ServerInfo { id: "srv-2".into(), name: "No RPC".into(), platform: "macos".into() },
        Arc::new(Tokens::default()),
    );
    let listener = ep.listen(opts).unwrap();
    tokio::spawn(async move {
        let mut kept = Vec::new();
        while let Some(s) = listener.accept().await {
            kept.push(s);
        }
    });
    let t = DialTarget { id: ep.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", ep.port())] };
    let c = client().await.dial(&t, &hello("good-n", "n"), &DialOptions::default()).await.unwrap();
    assert!(!c.welcome().features.iter().any(|f| f == "duplex"));
    let r =
        tokio::time::timeout(Duration::from_secs(2), c.request_duplex(&RpcRequest::new("GET", "/ws"))).await.unwrap();
    assert!(matches!(r, Err(LinkError::InvalidArgument(_))), "{r:?}");
}
