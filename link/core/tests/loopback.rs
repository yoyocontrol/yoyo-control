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
    AuthDecision, AuthRequest, Authenticator, CloseCode, DenyCode, DialOptions, DialTarget, Endpoint, EndpointConfig,
    GuardConfig, Headers, Hello, LinkError, PathKind, RpcHandler, RpcRequest, RpcResponder, ServerInfo, ServerOptions,
    Session,
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
    assert_eq!(c.welcome().features, vec!["link", "clipboard"]);
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

    // two connections that never say hello fill the unauthenticated slots: a third connection is refused
    let raw1 = raw_connect(&s).await.unwrap();
    let raw2 = raw_connect(&s).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(s.ep.guard().counts(), (2, 2));
    let refused = client().await.dial(&target(&s), &hello("good-g0", "g0"), &quick).await;
    assert!(refused.is_err(), "{refused:?}");
    // the silent ones are closed with code 4 after the hello timeout (two failures)
    let closed = raw1.closed().await;
    assert!(
        matches!(&closed, iroh::endpoint::ConnectionError::ApplicationClosed(c) if c.error_code.into_inner() == 4),
        "{closed:?}"
    );
    let _ = raw2.closed().await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(s.ep.guard().counts(), (0, 0));

    // at most 3 sessions
    let a = dial(&s, "good-g1", "g1").await.unwrap();
    let b = dial(&s, "good-g2", "g2").await.unwrap();
    let c = dial(&s, "good-g3", "g3").await.unwrap();
    let srv: Vec<Session> =
        vec![s.sessions.recv().await.unwrap(), s.sessions.recv().await.unwrap(), s.sessions.recv().await.unwrap()];
    assert_eq!(s.ep.guard().counts(), (3, 0));
    let full = client().await.dial(&target(&s), &hello("good-g4", "g4"), &quick).await;
    assert!(full.is_err(), "{full:?}");
    drop((a, b, c));
    for x in &srv {
        x.closed().await;
    }
    drop(srv);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(s.ep.guard().counts(), (0, 0));

    // two failures so far + one denied hello = 3: 127.0.0.1 is blocked before any handshake
    let denied = dial(&s, "bad", "g5").await;
    assert!(matches!(denied, Err(LinkError::Denied { .. })));
    assert!(s.ep.guard().is_blocked("127.0.0.1".parse().unwrap()));
    let blocked = client().await.dial(&target(&s), &hello("good-g6", "g6"), &quick).await;
    assert!(blocked.is_err(), "{blocked:?}");
}

/// A QUIC connection with the link's ALPN that never opens the control stream.
async fn raw_connect(s: &Server) -> Result<iroh::endpoint::Connection, String> {
    let ep = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .relay_mode(iroh::RelayMode::Disabled)
        .clear_address_lookup()
        .bind()
        .await
        .map_err(|e| e.to_string())?;
    let id = iroh::PublicKey::from_bytes(&uu_link::binding::parse_endpoint_id(&s.ep.id()).unwrap()).unwrap();
    let addr = iroh::EndpointAddr::from_parts(
        id,
        [iroh::TransportAddr::Ip(format!("127.0.0.1:{}", s.ep.port()).parse().unwrap())],
    );
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
