// The WebRTC transport on loopback: a server endpoint with an rtc socket, clients dialing it with `dial_rtc` (str0m as
// the offering side, the way a browser does), signaled straight into `Listener::accept_rtc_offer`. The same session
// protocol as on QUIC: handshake, the answer's signature, control messages, RPC, duplex requests, datagrams, media,
// close codes, the guard.

use std::{
    net::IpAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use bytes::Bytes;
use serde_json::json;
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, CloseCode, DenyCode, DialOptions, DuplexMessage, Endpoint,
    EndpointConfig, GuardConfig, Headers, Hello, IdentityKey, LinkError, Listener, PathKind, RpcHandler, RpcRequest,
    RpcResponder, RtcConfig, ServerInfo, ServerOptions, Session, Transport,
    binding::{generate_link_key, identity_fingerprint},
    media::{ClientEvent, Codec, FrameKind, FrameMeta, InputKind, ServerEvent},
    rtc::{RtcAnswer, RtcOffer},
};

/// Accepts `Bearer good…`, remembers what it was asked.
#[derive(Default)]
struct Tokens {
    asked: Mutex<Vec<AuthRequest>>,
}

#[async_trait]
impl Authenticator for Tokens {
    async fn authenticate(&self, r: AuthRequest) -> AuthDecision {
        self.asked.lock().unwrap().push(r.clone());
        match r.hello.credential.strip_prefix("Bearer ") {
            Some(t) if t.starts_with("good") => AuthDecision::Accept {
                principal: json!({"device": {"id": r.hello.device.id, "name": r.hello.device.name}}),
                features: None,
            },
            _ => AuthDecision::Deny { code: DenyCode::Unauthorized, message: "unknown token".into() },
        }
    }
}

struct Routes;

/// How far `/bytes` got writing (one test uses it).
static BYTES_WRITTEN: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

#[async_trait]
impl RpcHandler for Routes {
    async fn handle(&self, session: Session, req: RpcRequest, body: Bytes, mut res: RpcResponder) {
        let mut h = Headers::new();
        h.insert("x-principal".into(), session.principal()["device"]["id"].as_str().unwrap_or("").into());
        if req.duplex {
            match req.path.as_str() {
                // echoes every message; a close is echoed and then this side finishes
                "/ws" => {
                    let Ok(mut d) = res.accept_duplex(&h).await else { return };
                    while let Ok(Some(m)) = d.receiver.recv().await {
                        let close = matches!(m, DuplexMessage::Close { .. });
                        if d.sender.send(&m).await.is_err() {
                            return;
                        }
                        if close {
                            break;
                        }
                    }
                    let _ = d.sender.finish().await;
                }
                // accepts and never reads: what the client sends piles up to the stream's receive limit
                "/ws-deaf" => {
                    let Ok(d) = res.accept_duplex(&h).await else { return };
                    let stopped = d.sender.stopped();
                    let _ = tokio::time::timeout(Duration::from_secs(20), stopped).await;
                    session.send_control(&json!({"t": "deaf.done"})).await.ok();
                    drop(d);
                }
                // reads one message every 20 ms (a slow reader); at the FIN says how many payload bytes came
                "/ws-slow" => {
                    let Ok(mut d) = res.accept_duplex(&h).await else { return };
                    let mut n = 0usize;
                    while let Ok(Some(m)) = d.receiver.recv().await {
                        if let DuplexMessage::Binary(b) = m {
                            n += b.len();
                        }
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                    let _ = d.sender.send(&DuplexMessage::Text(n.to_string())).await;
                    let _ = d.sender.finish().await;
                }
                // reads everything; at the FIN says how many payload bytes came
                "/ws-sink" => {
                    let Ok(mut d) = res.accept_duplex(&h).await else { return };
                    let mut n = 0usize;
                    while let Ok(Some(m)) = d.receiver.recv().await {
                        if let DuplexMessage::Binary(b) = m {
                            n += b.len();
                        }
                    }
                    let _ = d.sender.send(&DuplexMessage::Text(n.to_string())).await;
                    let _ = d.sender.finish().await;
                }
                // reads one message, then never again (until the client goes)
                "/ws-sip" => {
                    let Ok(mut d) = res.accept_duplex(&h).await else { return };
                    let _ = d.receiver.recv().await;
                    let stopped = d.sender.stopped();
                    let _ = tokio::time::timeout(Duration::from_secs(20), stopped).await;
                }
                _ => res.respond(403, &h, b"{\"error\":\"no\"}").await.unwrap(),
            }
            return;
        }
        match req.path.split('?').next().unwrap() {
            "/echo" => res.respond(200, &h, &body).await.unwrap(),
            // n bytes in 64 KiB writes; with `track`, how far it got is in BYTES_WRITTEN
            "/bytes" => {
                let n: usize = req
                    .path
                    .split("n=")
                    .nth(1)
                    .and_then(|s| s.split('&').next())
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0);
                let track = req.path.contains("track");
                res.head(200, &h).await.unwrap();
                let piece = vec![7u8; 64 * 1024];
                let mut at = 0;
                while at < n {
                    let k = piece.len().min(n - at);
                    if res.write(&piece[..k]).await.is_err() {
                        return;
                    }
                    at += k;
                    if track {
                        BYTES_WRITTEN.store(at, std::sync::atomic::Ordering::SeqCst);
                    }
                }
                res.finish().await.unwrap();
            }
            "/count" => {
                let n: u32 = req.path.split("n=").nth(1).and_then(|s| s.parse().ok()).unwrap_or(1);
                res.head(200, &h).await.unwrap();
                for i in 0..n {
                    res.write(format!("{{\"i\":{i}}}\n").as_bytes()).await.unwrap();
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
                res.finish().await.unwrap();
            }
            "/forever" => {
                res.head(200, &h).await.unwrap();
                let stopped = res.stopped();
                tokio::pin!(stopped);
                loop {
                    tokio::select! {
                        _ = &mut stopped => break,
                        r = res.write(b"tick\n") => if r.is_err() { break },
                    }
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                session.send_control(&json!({"t": "forever.stopped"})).await.unwrap();
            }
            _ => res.respond(404, &h, b"{}").await.unwrap(),
        }
    }
}

struct Server {
    ep: Endpoint,
    listener: Arc<Listener>,
    tokens: Arc<Tokens>,
    fp: String,
}

async fn server(guard: GuardConfig) -> Server {
    server_with(guard, |_| {}).await
}

async fn server_with(guard: GuardConfig, adjust: impl FnOnce(&mut ServerOptions)) -> Server {
    server_on(guard, vec!["127.0.0.1".parse().unwrap()], adjust).await
}

/// A server on `bind` (empty: every interface, as a real computer's).
async fn server_on(guard: GuardConfig, bind: Vec<IpAddr>, adjust: impl FnOnce(&mut ServerOptions)) -> Server {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let identity = test_identity();
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    cfg.guard = guard;
    cfg.bind_ips = bind;
    cfg.rtc = Some(RtcConfig::default());
    let ep = Endpoint::bind(cfg).await.unwrap();
    let tokens = Arc::new(Tokens::default());
    let mut opts = ServerOptions::new(
        ServerInfo { id: "srv-1".into(), name: "Test Mac".into(), platform: "macos".into() },
        tokens.clone(),
    );
    opts.features = vec!["link".into()];
    opts.rpc = Some(Arc::new(Routes));
    opts.rtc_identity = Some(Arc::new(IdentityKey::new(&identity).unwrap()));
    // (it takes duplex requests: over WebRTC too, each stream's unread bytes bounded — `duplex_over_rtc`)
    opts.duplex = true;
    adjust(&mut opts);
    let listener = Arc::new(ep.listen(opts).unwrap());
    Server { ep, listener, tokens, fp: identity_fingerprint(&identity).unwrap() }
}

async fn client() -> Endpoint {
    client_on(vec!["127.0.0.1".parse().unwrap()]).await
}

async fn client_on(bind: Vec<IpAddr>) -> Endpoint {
    let mut cfg = EndpointConfig::client(generate_link_key());
    cfg.bind_ips = bind;
    cfg.rtc = Some(RtcConfig::default());
    Endpoint::bind(cfg).await.unwrap()
}

fn hello(token: &str, device: &str) -> Hello {
    Hello {
        credential: format!("Bearer {token}"),
        device: uu_link::Device { id: device.into(), name: format!("{device}'s browser") },
        app: uu_link::AppInfo { name: "uu web".into(), version: "1.0".into() },
        features: vec![],
    }
}

/// Dials `s` from `ep`; the server session comes from its listener.
async fn dial_from(ep: &Endpoint, s: &Server, token: &str) -> Result<(Session, Session), LinkError> {
    dial_from_with(ep, s, token, &DialOptions::default()).await
}

async fn dial_from_with(
    ep: &Endpoint,
    s: &Server,
    token: &str,
    opts: &DialOptions,
) -> Result<(Session, Session), LinkError> {
    let l = s.listener.clone();
    let c = ep
        .dial_rtc(
            |offer| async move { l.accept_rtc_offer(&offer, Some("127.0.0.1".parse().unwrap())).await },
            &s.fp,
            &hello(token, "web-1"),
            opts,
        )
        .await?;
    let srv = tokio::time::timeout(Duration::from_secs(5), s.listener.accept()).await.unwrap().unwrap();
    Ok((c, srv))
}

async fn dial(s: &Server, token: &str) -> Result<(Session, Session, Endpoint), LinkError> {
    let ep = client().await;
    let (c, srv) = dial_from(&ep, s, token).await?;
    Ok((c, srv, ep))
}

/// A client without the credit window (an older one): every stream held to the receive bounds, reset past them.
async fn dial_without_credit(s: &Server, token: &str) -> Result<(Session, Session, Endpoint), LinkError> {
    let ep = client().await;
    let (c, srv) = dial_from_with(&ep, s, token, &DialOptions { credit: false, ..DialOptions::default() }).await?;
    assert!(!c.welcome().features.iter().any(|f| f == "credit"));
    Ok((c, srv, ep))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn handshake_and_identity() {
    let s = server(GuardConfig::default()).await;
    let started = std::time::Instant::now();
    let (c, srv, _ep) = dial(&s, "good-1").await.unwrap();
    eprintln!("rtc welcome in {} ms", started.elapsed().as_millis());
    assert_eq!(c.transport(), Transport::Rtc);
    assert_eq!(srv.transport(), Transport::Rtc);
    assert!(c.connection().is_none());
    assert_eq!(c.welcome().server.name, "Test Mac");
    assert_eq!(c.principal()["device"]["id"], "web-1");
    assert_eq!(c.welcome().max_datagram, 1200);
    assert_eq!(c.remote_id(), s.ep.id(), "the client knows the server by its verified binding");
    let asked = s.tokens.asked.lock().unwrap()[0].clone();
    assert!(asked.client_key.starts_with("dtls-sha256:") && asked.client_key.len() == 12 + 64, "{}", asked.client_key);
    assert_eq!(srv.remote_id(), asked.client_key);
    assert_eq!(asked.source.addr.unwrap().ip().to_string(), "127.0.0.1");
    assert_eq!(s.ep.guard().counts(), (1, 0));
    // the path appears with the first stats (≤ 250 ms)
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(c.path().kind, PathKind::Lan);
    assert_eq!(srv.path().kind, PathKind::Lan);
    let st = c.stats();
    assert!(st.rtt_p50_ms >= 0.0 && st.rtt_p50_ms < 50.0, "{st:?}");
    assert!(st.bytes_sent > 0 && st.bytes_received > 0);

    // denied: the code arrives
    match dial(&s, "bad").await {
        Err(LinkError::Denied { code: DenyCode::Unauthorized, message }) => assert_eq!(message, "unknown token"),
        other => panic!("expected denied, got {:?}", other.map(|_| ())),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn answers_are_signed() {
    let s = server(GuardConfig::default()).await;
    let ep = client().await;
    // another pin: the answer is refused before connecting
    let l = s.listener.clone();
    let other = identity_fingerprint(&test_identity()).unwrap();
    let r = ep
        .dial_rtc(
            |o| async move { l.accept_rtc_offer(&o, None).await },
            &other,
            &hello("good-x", "w"),
            &DialOptions::default(),
        )
        .await;
    assert!(matches!(r, Err(LinkError::Binding(_))), "{:?}", r.map(|_| ()));
    // a tampered answer (another DTLS fingerprint in the SDP)
    let l = s.listener.clone();
    let r = ep
        .dial_rtc(
            |o| async move {
                let a = l.accept_rtc_offer(&o, None).await?;
                let mut a = RtcAnswer::parse(&a)?;
                let fp_line = a.answer.lines().find(|l| l.starts_with("a=fingerprint:")).unwrap().to_string();
                a.answer = a.answer.replace(&fp_line, &format!("a=fingerprint:sha-256 {}", vec!["00"; 32].join(":")));
                Ok(a.to_json())
            },
            &s.fp,
            &hello("good-x", "w"),
            &DialOptions::default(),
        )
        .await;
    assert!(matches!(r, Err(LinkError::Binding(_))), "{:?}", r.map(|_| ()));
    // bad offers
    for bad in ["{}", r#"{"v":1,"offer":"nope"}"#, r#"{"v":2,"offer":"v=0"}"#] {
        assert!(matches!(s.listener.accept_rtc_offer(bad, None).await, Err(LinkError::InvalidArgument(_))), "{bad}");
    }
    let no_fp = RtcOffer { v: 1, offer: "v=0\r\ns=-\r\n".into(), device: Default::default(), rk: None, restart: None }
        .to_json();
    assert!(s.listener.accept_rtc_offer(&no_fp, None).await.is_err());
}

/// ICE restarts (docs/LINK.md「WebRTC」「换网络」): an offer with a restart key gets `restarts: true`; a restart needs
/// the key's secret and the same client's DTLS fingerprint, and each key works once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restart_keys() {
    let s = server(GuardConfig::default()).await;
    let secret = "s3cret-for-the-test";
    let seen = Arc::new(Mutex::new(None::<(String, bool)>));
    let (l, kept) = (s.listener.clone(), seen.clone());
    let (_c, _srv) = {
        let ep = client().await;
        let c = ep
            .dial_rtc(
                |o| async move {
                    let mut offer = RtcOffer::parse(&o)?;
                    offer.rk = Some(uu_link::rtc::restart_key(secret));
                    let a = l.accept_rtc_offer(&offer.to_json(), None).await?;
                    *kept.lock().unwrap() = Some((offer.offer.clone(), RtcAnswer::parse(&a)?.restarts));
                    Ok(a)
                },
                &s.fp,
                &hello("good-rs", "w"),
                &DialOptions::default(),
            )
            .await
            .unwrap();
        let srv = tokio::time::timeout(Duration::from_secs(5), s.listener.accept()).await.unwrap().unwrap();
        (c, (srv, ep))
    };
    let (offer_sdp, restarts) = seen.lock().unwrap().clone().unwrap();
    assert!(restarts, "an offer with a restart key: the server takes restarts");
    let restart = |secret: &str, sdp: String| {
        RtcOffer { v: 1, offer: sdp, device: Default::default(), rk: None, restart: Some(secret.into()) }.to_json()
    };
    // a wrong secret
    assert!(matches!(
        s.listener.accept_rtc_offer(&restart("wrong", offer_sdp.clone()), None).await,
        Err(LinkError::InvalidArgument(_))
    ));
    // the right secret from another client (another DTLS fingerprint): refused, and the key is used up
    let fp_line = offer_sdp.lines().find(|l| l.starts_with("a=fingerprint:")).unwrap().to_string();
    let other = offer_sdp.replace(&fp_line, &format!("a=fingerprint:sha-256 {}", vec!["00"; 32].join(":")));
    assert!(matches!(
        s.listener.accept_rtc_offer(&restart(secret, other), None).await,
        Err(LinkError::InvalidArgument(_))
    ));
    assert!(matches!(
        s.listener.accept_rtc_offer(&restart(secret, offer_sdp), None).await,
        Err(LinkError::InvalidArgument(_))
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_and_close() {
    let s = server(GuardConfig::default()).await;
    let (c, srv, _ep) = dial(&s, "good-ctl").await.unwrap();
    c.send_control(&json!({"t": "control.take", "rid": 1})).await.unwrap();
    assert_eq!(srv.recv_control().await.unwrap(), json!({"t": "control.take", "rid": 1}));
    for i in 0..200 {
        srv.send_control(&json!({"t": "video.status", "id": 1, "n": i, "pad": "x".repeat(i * 10)})).await.unwrap();
    }
    for i in 0..200 {
        assert_eq!(c.recv_control().await.unwrap()["n"], i);
    }
    // a frame bigger than one message
    srv.send_control(&json!({"t": "cursor.shape", "png": "y".repeat(100_000)})).await.unwrap();
    assert_eq!(c.recv_control().await.unwrap()["png"].as_str().unwrap().len(), 100_000);

    srv.close(CloseCode::Replaced, "another session").await;
    let bye = c.recv_control().await.unwrap();
    assert_eq!(bye["t"], "bye");
    assert_eq!(bye["code"], 6);
    let info = tokio::time::timeout(Duration::from_secs(2), c.closed()).await.unwrap();
    assert_eq!(info.code, Some(CloseCode::Replaced));
    assert!(info.remote);
    assert_eq!(info.reason, "another session");
    assert!(c.recv_control().await.is_none());
    let mine = srv.closed().await;
    assert_eq!((mine.code, mine.remote), (Some(CloseCode::Replaced), false));
    // the peer connection goes away, the guard slot too
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(s.ep.rtc_peer_count(), 0);
    assert_eq!(s.ep.guard().counts(), (0, 0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rpc() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-rpc").await.unwrap();

    let mut r = c.request(&RpcRequest::new("POST", "/echo"), b"hi there").await.unwrap();
    assert_eq!(r.status, 200);
    assert_eq!(r.headers["x-principal"], "web-1");
    assert_eq!(&r.body.read_all(1 << 20).await.unwrap()[..], b"hi there");
    // an empty body
    let mut r = c.request(&RpcRequest::new("GET", "/echo"), b"").await.unwrap();
    assert!(r.body.read_all(10).await.unwrap().is_empty());

    let mut r = c.request(&RpcRequest::new("GET", "/count?n=30"), b"").await.unwrap();
    let text = r.body.read_all(1 << 20).await.unwrap();
    let lines: Vec<&str> = std::str::from_utf8(&text).unwrap().lines().collect();
    assert_eq!(lines.len(), 30);
    assert_eq!(lines[29], r#"{"i":29}"#);

    let big: Vec<u8> = (0..(3 << 20)).map(|i| (i % 251) as u8).collect();
    let started = std::time::Instant::now();
    let mut r = c.request(&RpcRequest::new("POST", "/echo"), &big).await.unwrap();
    assert_eq!(r.body.read_all(8 << 20).await.unwrap(), big);
    eprintln!("3 MiB echo in {} ms", started.elapsed().as_millis());

    for p in ["/stream?display=1", "/audio", "/input", "/control"] {
        let r = c.request(&RpcRequest::new("POST", p), b"ignored").await.unwrap();
        assert_eq!(r.status, 404, "{p}");
    }
    let huge = vec![0u8; 9 << 20];
    let r = c.request(&RpcRequest::new("POST", "/echo"), &huge).await.unwrap();
    assert_eq!(r.status, 413);

    // cancelling ends the server's stream
    let mut r = c.request(&RpcRequest::new("GET", "/forever"), b"").await.unwrap();
    assert!(r.body.chunk().await.unwrap().is_some());
    r.body.cancel();
    let m = tokio::time::timeout(Duration::from_secs(2), c.recv_control()).await.unwrap().unwrap();
    assert_eq!(m["t"], "forever.stopped");

    // many at once (more than the stream cap over time: channels are given back)
    let mut joins = Vec::new();
    for i in 0..60 {
        let c = c.clone();
        joins.push(tokio::spawn(async move {
            let body = format!("req {i}");
            let mut r = c.request(&RpcRequest::new("POST", "/echo"), body.as_bytes()).await.unwrap();
            assert_eq!(&r.body.read_all(1024).await.unwrap()[..], body.as_bytes());
        }));
        if i % 20 == 19 {
            for j in joins.drain(..) {
                j.await.unwrap();
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn datagrams() {
    let s = server(GuardConfig::default()).await;
    let (c, srv, _ep) = dial(&s, "good-dg").await.unwrap();
    assert_eq!(c.max_datagram_size(), 1200);
    for i in 0u8..50 {
        c.send_datagram(7, &[i]).unwrap();
        srv.send_datagram(8, &[i; 1100]).unwrap();
    }
    for _ in 0..50 {
        let d = tokio::time::timeout(Duration::from_secs(2), srv.recv_datagram(7)).await.unwrap().unwrap().unwrap();
        assert_eq!((d[0], d.len()), (0x71, 2));
        let d = tokio::time::timeout(Duration::from_secs(2), c.recv_datagram(8)).await.unwrap().unwrap().unwrap();
        assert_eq!((d[0], d.len()), (0x81, 1101));
    }
    assert!(c.send_datagram(8, &[0u8; 1200]).is_err(), "over 1200 with the header");
    assert!(srv.datagram_send_buffer_space() > 0);
    drop(srv);
    let end = tokio::time::timeout(Duration::from_secs(3), c.recv_datagram(8)).await.unwrap().unwrap();
    assert!(end.is_none());
    assert_eq!(c.closed().await.code, Some(CloseCode::Normal));
}

fn meta(kind: FrameKind) -> FrameMeta {
    FrameMeta { codec: Codec::H264, kind, width: 1280, height: 720, capture_us: 0, recovery_base: 0, au_len: 0 }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn media() {
    let s = server(GuardConfig::default()).await;
    let (c, srv, _ep) = dial(&s, "good-media").await.unwrap();
    tokio::time::sleep(Duration::from_millis(400)).await; // an RTT sample
    srv.open_video(1);
    c.open_video(1);
    srv.open_audio(2);
    c.open_audio(2);
    let mut sent = Vec::new();
    for i in 0..30u32 {
        let (kind, size) = if i == 0 { (FrameKind::Key, 150_000) } else { (FrameKind::Delta, 6_000) };
        let au: Vec<u8> = (0..size).map(|b| (b as u32 ^ i) as u8).collect();
        sent.push((srv.send_frame(1, meta(kind), &au).unwrap(), au));
        srv.send_audio(2, i as u64 * 20_000, &[i as u8; 100]).unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }
    let mut frames = Vec::new();
    let mut audio = 0;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while frames.len() < 30 {
        match tokio::time::timeout_at(deadline, c.recv_client_event()).await.expect("client events").unwrap() {
            ClientEvent::Frame(f) => {
                c.frame_decoded(f.stream, f.frame, true).unwrap();
                frames.push(f);
            }
            ClientEvent::Audio(_) => audio += 1,
            _ => {}
        }
    }
    for (f, (n, au)) in frames.iter().zip(&sent) {
        assert_eq!(f.frame, *n);
        assert_eq!(&f.au, au);
    }
    assert!(audio > 0);
    for i in 0..10 {
        c.send_input(InputKind::Discrete, format!(r#"{{"type":"key","n":{i}}}"#).as_bytes()).unwrap();
    }
    let mut got = 0;
    while got < 10 {
        if let ServerEvent::Input(_) =
            tokio::time::timeout(Duration::from_secs(2), srv.recv_server_event()).await.unwrap().unwrap()
        {
            got += 1;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn guard() {
    let guard =
        GuardConfig { max_unauthenticated: 2, failure_limit: 1, exempt_loopback: false, ..GuardConfig::default() };
    let s = server(guard).await;
    let offer = |n: u8| {
        // an offer from a client that will never connect: its own SDP is enough
        let s = &s;
        async move {
            let ep = client().await;
            let l = s.listener.clone();
            let src: IpAddr = format!("198.51.100.{n}").parse().unwrap();
            let r = ep
                .dial_rtc(
                    |o| async move {
                        let a = l.accept_rtc_offer(&o, Some(src)).await;
                        a.and_then(|_| Err(LinkError::Connect("dropped".into())))
                    },
                    &s.fp,
                    &hello("good", "w"),
                    &DialOptions::default(),
                )
                .await;
            r.err().unwrap()
        }
    };
    // two pending offers fill the WebRTC pool (checked, under their signaling request's address)
    assert!(matches!(offer(1).await, LinkError::Connect(_)));
    assert!(matches!(offer(1).await, LinkError::Connect(_)));
    assert_eq!(s.ep.guard().counts(), (2, 2));
    // a third is refused (Busy): an offer is never sent away (it waits seconds for ICE, DTLS and SCTP)
    match offer(2).await {
        LinkError::Denied { code: DenyCode::Busy, .. } => {}
        other => panic!("{other:?}"),
    }
    assert_eq!(s.ep.guard().counts(), (2, 2));
    // QUIC still gets in: offers have their own pool
    let quic =
        uu_link::DialTarget { id: s.ep.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", s.ep.port())] };
    let q = client().await.dial(&quic, &hello("good-q", "q"), &DialOptions::default()).await;
    assert!(q.is_ok(), "{q:?}");
    let qs = tokio::time::timeout(Duration::from_secs(5), s.listener.accept()).await.unwrap().unwrap();
    drop((q, qs));
    // the two time out (no ICE within 10 s): a WebRTC failure each, and with a limit of 1 198.51.100.1 is blocked —
    // for WebRTC only
    tokio::time::sleep(Duration::from_millis(10_800)).await;
    assert_eq!(s.ep.guard().counts(), (0, 0));
    let g = s.ep.guard();
    let one: IpAddr = "198.51.100.1".parse().unwrap();
    assert!(g.is_blocked_as(uu_link::guard::Kind::WebRtc, &g.source_of(one)));
    assert!(!g.is_blocked(one), "QUIC from it is not blocked");
    assert!(
        !g.is_blocked_as(uu_link::guard::Kind::WebRtc, &g.source_of("198.51.100.2".parse().unwrap())),
        "refused: no failure"
    );
    match offer(1).await {
        LinkError::Denied { code: DenyCode::RateLimited, .. } => {}
        other => panic!("{other:?}"),
    }
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

/// Duplex requests over WebRTC (a browser's WebSocket over the link): the welcome says `duplex`; messages both ways
/// (text, binary, the largest, a close with its code), the server's FIN; a refusal with its status and body; and a
/// peer that writes to a stream nobody reads gets it reset at the receive limit instead of filling the server's memory.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplex_over_rtc() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-dx").await.unwrap();
    assert!(c.welcome().features.iter().any(|f| f == "duplex"), "{:?}", c.welcome().features);

    let r = c.request_duplex(&RpcRequest::new("GET", "/ws")).await.unwrap();
    assert_eq!(r.status, 101);
    let uu_link::Duplex { mut sender, mut receiver } = r.duplex.unwrap();
    let writer = tokio::spawn(async move {
        for i in 0..100u32 {
            let m = if i % 2 == 0 {
                DuplexMessage::Text(format!("m{i}"))
            } else {
                DuplexMessage::Binary(Bytes::from(i.to_be_bytes().to_vec()))
            };
            sender.send(&m).await.unwrap();
        }
        sender.send(&DuplexMessage::Binary(vec![7u8; uu_link::MAX_DUPLEX_MESSAGE].into())).await.unwrap();
        sender.send(&DuplexMessage::Close { code: 4001, reason: "bye".into() }).await.unwrap();
        sender
    });
    for i in 0..100u32 {
        let m = tokio::time::timeout(Duration::from_secs(10), receiver.recv()).await.unwrap().unwrap().unwrap();
        let want = if i % 2 == 0 {
            DuplexMessage::Text(format!("m{i}"))
        } else {
            DuplexMessage::Binary(Bytes::from(i.to_be_bytes().to_vec()))
        };
        assert_eq!(m, want);
    }
    match tokio::time::timeout(Duration::from_secs(10), receiver.recv()).await.unwrap().unwrap().unwrap() {
        DuplexMessage::Binary(b) => assert_eq!(b.len(), uu_link::MAX_DUPLEX_MESSAGE),
        other => panic!("{other:?}"),
    }
    assert_eq!(receiver.recv().await.unwrap().unwrap(), DuplexMessage::Close { code: 4001, reason: "bye".into() });
    assert_eq!(receiver.recv().await.unwrap(), None, "the server finished");
    writer.await.unwrap().finish().await.unwrap();

    let mut no = c.request_duplex(&RpcRequest::new("GET", "/nope")).await.unwrap();
    assert_eq!(no.status, 403);
    assert!(no.duplex.is_none());
    assert_eq!(&no.body.read_all(1024).await.unwrap()[..], b"{\"error\":\"no\"}");

    // a client without the credit window, nobody reading: past RTC_DUPLEX_RECV_MAX unread the server resets the
    // stream, the client's sends fail
    let (old, _old_srv, _old_ep) = dial_without_credit(&s, "good-dx").await.unwrap();
    let r = old.request_duplex(&RpcRequest::new("GET", "/ws-deaf")).await.unwrap();
    let uu_link::Duplex { mut sender, receiver: _r } = r.duplex.unwrap();
    let chunk = DuplexMessage::Binary(vec![1u8; 256 * 1024].into());
    let mut sent = 0usize;
    let failed = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if sender.send(&chunk).await.is_err() {
                return true;
            }
            sent += 256 * 1024;
            if sent > 16 * uu_link::RTC_DUPLEX_RECV_MAX {
                return false;
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(failed, "the stream was reset after {sent} bytes");
    assert!(
        sent <= uu_link::RTC_DUPLEX_RECV_MAX + 4 * 1024 * 1024,
        "reset near the limit (what was in flight aside), not later: {sent}"
    );
    // and the session lives on
    let mut e = old.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
}

/// A flood of tiny messages to a stream nobody reads hits the same bound: each waiting data-channel message counts
/// its overhead too, not just its few bytes (1-byte messages would otherwise pile up ~10x the bound in memory).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_tiny_messages_hit_the_bound() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial_without_credit(&s, "good-tiny").await.unwrap();
    let r = c.request_duplex(&RpcRequest::new("GET", "/ws-deaf")).await.unwrap();
    let uu_link::Duplex { mut sender, receiver: _r } = r.duplex.unwrap();
    // each goes as one 6-byte data-channel message
    let tiny = DuplexMessage::Binary(Bytes::from_static(&[1]));
    let old_bound = uu_link::RTC_DUPLEX_RECV_MAX / 6;
    let mut sent = 0usize;
    let failed = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if sender.send(&tiny).await.is_err() {
                return true;
            }
            sent += 1;
            if sent > 2 * old_bound {
                return false;
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(failed, "the stream was reset after {sent} messages");
    assert!(
        sent < old_bound / 3,
        "reset at ~{} messages (overhead counted), not ~{old_bound}: {sent}",
        uu_link::RTC_DUPLEX_RECV_MAX / 70
    );
    let mut e = c.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
}

/// A session's duplex streams share one budget (RTC_SESSION_RECV_MAX): streams each under their own bound, nobody
/// reading, until together they'd hold more; the stream that pushes it over is reset, the others and the session go on.
/// (The one that goes over sends only a little past the budget: a reset with much in flight behind it can still cost
/// the whole association, sctp-proto's deferred-reset data — the credit window is what keeps resets rare.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_session_receive_budget() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial_without_credit(&s, "good-budget").await.unwrap();
    let msg = 64 * 1024;
    let per = 25 * msg; // 1600 KiB: under RTC_DUPLEX_RECV_MAX each
    assert!(per < uu_link::RTC_DUPLEX_RECV_MAX);
    let cost = per + (per / (16 * 1024)) * 64; // with each data-channel message's overhead
    let fit = uu_link::RTC_SESSION_RECV_MAX / cost;
    let left = uu_link::RTC_SESSION_RECV_MAX - fit * cost;
    let chunk = DuplexMessage::Binary(vec![1u8; msg].into());
    let mut streams = Vec::new();
    for i in 0..=fit {
        let r = c.request_duplex(&RpcRequest::new("GET", "/ws-deaf")).await.unwrap();
        let uu_link::Duplex { mut sender, receiver } = r.duplex.unwrap();
        // the last: just past what the budget has left
        let n = if i < fit { per / msg } else { left / msg + 2 };
        for _ in 0..n {
            if sender.send(&chunk).await.is_err() {
                break;
            }
        }
        let reset = tokio::time::timeout(Duration::from_millis(if i < fit { 300 } else { 3000 }), sender.stopped())
            .await
            .is_ok();
        assert_eq!(reset, i == fit, "stream {i} (of {fit} that fit): reset = {reset}");
        streams.push((sender, receiver));
    }
    // the session goes on
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut e = c.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
}

/// A reset with ~1 MiB still in flight behind it (a peer that writes and never waits, nobody reading) costs only that
/// stream: the session, a stream open beside it and new ones go on. Several in a row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_reset_with_data_in_flight() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial_without_credit(&s, "good-inflight").await.unwrap();
    let echo = c.request_duplex(&RpcRequest::new("GET", "/ws")).await.unwrap();
    let uu_link::Duplex { sender: mut es, receiver: mut er } = echo.duplex.unwrap();
    let chunk = DuplexMessage::Binary(vec![1u8; 256 * 1024].into());
    for round in 0..6 {
        let r = c.request_duplex(&RpcRequest::new("GET", "/ws-deaf")).await.unwrap();
        let uu_link::Duplex { mut sender, receiver: _r } = r.duplex.unwrap();
        let mut sent = 0usize;
        let failed = tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if sender.send(&chunk).await.is_err() {
                    return true;
                }
                sent += 256 * 1024;
            }
        })
        .await
        .unwrap_or(false);
        assert!(failed, "round {round}: the stream was reset");
        // (the client's sends go on past the bound until it hears the reset: SCTP keeps ~1 MiB in flight)
        assert!(sent >= 2 * uu_link::MAX_DUPLEX_MESSAGE, "round {round}: reset before the bound: {sent}");
        // the stream beside it and the session go on
        let m = DuplexMessage::Text(format!("round {round}"));
        es.send(&m).await.unwrap_or_else(|e| panic!("round {round}: {e:?} {:?}", c.close_info()));
        let back = tokio::time::timeout(Duration::from_secs(5), er.recv()).await.unwrap().unwrap().unwrap();
        assert_eq!(back, m);
    }
    let mut e = c.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
    assert!(c.close_info().is_none());
}

// MARK: the credit window (docs/LINK.md「信用窗口」)

/// Both sides take it over WebRTC: `credit` in the welcome. A slow duplex reader slows the writer (no reset, however
/// far ahead the writer would be): what the writer has out is the reader's window, not the whole of what it sends.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_slow_duplex_reader() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-slow").await.unwrap();
    assert!(c.welcome().features.iter().any(|f| f == "credit"), "{:?}", c.welcome().features);
    let r = c.request_duplex(&RpcRequest::new("GET", "/ws-slow")).await.unwrap();
    let uu_link::Duplex { mut sender, mut receiver } = r.duplex.unwrap();
    let total = 4 * 1024 * 1024; // twice RTC_DUPLEX_RECV_MAX: without the window, a reset
    let msg = 64 * 1024;
    let sent = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let progress = sent.clone();
    let writer = tokio::spawn(async move {
        for _ in 0..total / msg {
            sender.send(&DuplexMessage::Binary(vec![3u8; msg].into())).await.unwrap();
            progress.fetch_add(msg, std::sync::atomic::Ordering::SeqCst);
        }
        sender.finish().await.unwrap();
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    // ~20 messages read by now (1.25 MiB) + the window
    let ahead = sent.load(std::sync::atomic::Ordering::SeqCst);
    assert!(ahead < total / 2 + uu_link::RTC_CREDIT_WINDOW / 2, "the writer was held back: {ahead} sent after 400 ms");
    writer.await.unwrap();
    let n = tokio::time::timeout(Duration::from_secs(20), receiver.recv()).await.unwrap().unwrap().unwrap();
    assert_eq!(n, DuplexMessage::Text(total.to_string()), "every byte arrived");
    assert_eq!(receiver.recv().await.unwrap(), None);
}

/// Bodies both ways under the window: a 30 MiB upload (a server whose body limit allows it) echoed back whole.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_large_upload_and_answer() {
    let s = server_with(GuardConfig::default(), |o| o.max_request_body = 64 * 1024 * 1024).await;
    let (c, _srv, _ep) = dial(&s, "good-up").await.unwrap();
    let big: Vec<u8> = (0..30 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
    let started = std::time::Instant::now();
    let mut r = c.request(&RpcRequest::new("POST", "/echo"), &big).await.unwrap();
    assert_eq!(r.status, 200);
    assert!(r.body.read_all(64 * 1024 * 1024).await.unwrap() == big, "the same 30 MiB back");
    eprintln!("30 MiB up and back in {} ms", started.elapsed().as_millis());
}

/// An answer nobody reads waits in the server, not in the client: the server gets the client's window ahead, no
/// more; as the client reads, the rest comes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_unread_answer() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-down").await.unwrap();
    let n = 16 * 1024 * 1024;
    let mut r = c.request(&RpcRequest::new("GET", format!("/bytes?n={n}&track")), b"").await.unwrap();
    assert_eq!(r.status, 200);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let ahead = BYTES_WRITTEN.load(std::sync::atomic::Ordering::SeqCst);
    assert!(ahead <= uu_link::RTC_CREDIT_WINDOW + 128 * 1024, "the server is held back: {ahead} written, none read");
    let body = r.body.read_all(n).await.unwrap();
    assert_eq!(body.len(), n);
    assert_eq!(BYTES_WRITTEN.load(std::sync::atomic::Ordering::SeqCst), n);
}

/// Windows past the initial one come out of the session's pool: streams that read a little and then stop can't each
/// keep a whole window (12 x 1 MiB); the pool's 8 MiB, and each stream's own initial window, is what they get together.
/// The session and new streams go on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_pool() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-pool").await.unwrap();
    let msg = 64 * 1024;
    let streams = 12;
    let mut total = 0usize;
    let mut held = Vec::new();
    for _ in 0..streams {
        let r = c.request_duplex(&RpcRequest::new("GET", "/ws-sip")).await.unwrap();
        let uu_link::Duplex { mut sender, receiver } = r.duplex.unwrap();
        loop {
            match tokio::time::timeout(
                Duration::from_millis(300),
                sender.send(&DuplexMessage::Binary(vec![1u8; msg].into())),
            )
            .await
            {
                Ok(Ok(())) => total += msg,
                Ok(Err(e)) => panic!("a reset under the window: {e:?}"),
                Err(_) => break, // held back
            }
        }
        held.push((sender, receiver));
    }
    // (each window is sized by what the others hold unread when it is given: the pool, plus the last one's window)
    let bound =
        uu_link::RTC_SESSION_RECV_MAX + uu_link::RTC_CREDIT_WINDOW + streams * (uu_link::RTC_CREDIT_INITIAL + msg);
    assert!(total <= bound, "{total} out at once over {streams} streams (bound {bound})");
    assert!(total >= uu_link::RTC_SESSION_RECV_MAX / 2, "the pool was used: {total}");
    let mut e = c.request(&RpcRequest::new("POST", "/echo"), b"hi").await.unwrap();
    assert_eq!(&e.body.read_all(1024).await.unwrap()[..], b"hi");
    assert!(c.close_info().is_none());
}

/// Sends `total` bytes on a fresh `/ws-sink` stream and waits for the count; the time it took.
async fn sink(c: &Session, total: usize) -> Duration {
    let started = std::time::Instant::now();
    let r = c.request_duplex(&RpcRequest::new("GET", "/ws-sink")).await.unwrap();
    let uu_link::Duplex { mut sender, mut receiver } = r.duplex.unwrap();
    let msg = 64 * 1024;
    for _ in 0..total / msg {
        sender.send(&DuplexMessage::Binary(vec![2u8; msg].into())).await.unwrap();
    }
    sender.finish().await.unwrap();
    let n = receiver.recv().await.unwrap().unwrap();
    assert_eq!(n, DuplexMessage::Text(total.to_string()));
    started.elapsed()
}

/// Streams that sent a burst (read at once) and then went quiet keep their windows but hold none of the pool (it
/// counts unread bytes, not credit given): a new stream goes at full speed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_idle_streams_leave_the_pool() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-idle").await.unwrap();
    let mut idle = Vec::new();
    for _ in 0..12 {
        let r = c.request_duplex(&RpcRequest::new("GET", "/ws-sink")).await.unwrap();
        let uu_link::Duplex { mut sender, receiver } = r.duplex.unwrap();
        for _ in 0..12 {
            sender.send(&DuplexMessage::Binary(vec![1u8; 64 * 1024].into())).await.unwrap();
        }
        idle.push((sender, receiver)); // quiet from here on, its window granted
    }
    let took =
        tokio::time::timeout(Duration::from_secs(20), sink(&c, 8 * 1024 * 1024)).await.expect("the new stream moved");
    eprintln!("8 MiB beside 12 idle streams in {} ms", took.as_millis());
}

/// The pool full of bytes nobody reads (streams that stopped reading): a new stream still moves, on the initial window
/// every stream keeps (a grant whenever its sender has less left than a message costs).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_full_pool_still_moves() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-full").await.unwrap();
    let mut held = Vec::new();
    let mut total = 0usize;
    for _ in 0..12 {
        let r = c.request_duplex(&RpcRequest::new("GET", "/ws-sip")).await.unwrap();
        let uu_link::Duplex { mut sender, receiver } = r.duplex.unwrap();
        while let Ok(Ok(())) = tokio::time::timeout(
            Duration::from_millis(300),
            sender.send(&DuplexMessage::Binary(vec![1u8; 64 * 1024].into())),
        )
        .await
        {
            total += 64 * 1024;
        }
        held.push((sender, receiver));
    }
    assert!(total >= uu_link::RTC_SESSION_RECV_MAX - uu_link::RTC_CREDIT_WINDOW, "the pool is full: {total}");
    let took =
        tokio::time::timeout(Duration::from_secs(30), sink(&c, 2 * 1024 * 1024)).await.expect("the new stream moved");
    eprintln!("2 MiB beside a full pool in {} ms", took.as_millis());
}

/// A grant the connection refuses to take (str0m's buffer full: `Ok(false)`) is not counted as given: it goes again
/// after the next input, and the transfer finishes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn credit_refused_grant_goes_again() {
    let s = server(GuardConfig::default()).await;
    let (c, _srv, _ep) = dial(&s, "good-refuse").await.unwrap();
    c.test_refuse_grant_writes(30);
    let n = 8 * 1024 * 1024;
    let mut r = c.request(&RpcRequest::new("GET", format!("/bytes?n={n}")), b"").await.unwrap();
    let body = tokio::time::timeout(Duration::from_secs(20), r.body.read_all(n)).await.expect("not stuck").unwrap();
    assert_eq!(body.len(), n);
    assert_eq!(c.test_grant_writes_to_refuse(), 0, "grants were refused on the way");
}

/// A client whose offer names many host candidates, most of them unreachable, as Chrome's does once a page has the
/// microphone (every interface: VM bridges, Tailscale, ULAs), with server and client on every interface of this
/// machine. Checks from the client's interface addresses also reach the answer's loopback candidates (the OS delivers
/// them), but nothing can be sent back from there: those pairs must never carry the session (the hub drops such
/// packets, `answerable`). The session works, RPCs answer, nothing is lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_many_host_candidates() {
    let s = server_on(GuardConfig::default(), vec![], |_| {}).await;
    let ep = client_on(vec![]).await;
    // unreachable ones in the client's offer (as host candidates: what the endpoint announces as its own)
    for addr in [
        "192.0.2.10:40001",
        "192.0.2.11:40002",
        "198.51.100.12:40003",
        "203.0.113.13:40004",
        "100.64.0.250:40005",
        "192.168.64.250:40006",
        "10.255.1.2:40007",
        "172.31.9.9:40008",
        "[fd00:db8:1::99]:40009",
        "[fd00:db8:2::99]:40010",
        "[fd7a:115c:a1e0::99]:40011",
        "[2001:db8::99]:40012",
    ] {
        assert!(ep.add_rtc_external_addr(addr.parse().unwrap()));
    }
    let (c, _srv) = dial_from(&ep, &s, "good-many").await.unwrap();
    // long enough for every pair to be checked and nominations to settle
    let body = vec![5u8; 64 * 1024];
    for i in 0..30 {
        let mut r = tokio::time::timeout(Duration::from_secs(5), c.request(&RpcRequest::new("POST", "/echo"), &body))
            .await
            .unwrap_or_else(|_| panic!("round {i}: no answer ({:?}, {:?})", c.path(), c.close_info()))
            .unwrap();
        assert!(r.body.read_all(1 << 20).await.unwrap() == body, "round {i}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(c.close_info().is_none());
}

/// The packet that broke it, sent on purpose: a check with USE-CANDIDATE (as Chrome sends once a page has the
/// microphone and checks from all its interface addresses) from this machine's interface address to the answer's
/// loopback candidate. The OS delivers it, but nothing can go back from 127.0.0.1 to there; a server that took it as
/// its nominated pair went mute (every send failed: EADDRNOTAVAIL / EINVAL). It must not touch the session.
/// (Skipped on a host without a non-loopback address.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_loopback_candidate_from_elsewhere() {
    // this machine's address on its default route (no packet is sent)
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
    let lan = match probe.connect("192.0.2.1:9").and_then(|_| probe.local_addr()) {
        Ok(a) if !a.ip().is_loopback() && !a.ip().is_unspecified() => a.ip(),
        _ => {
            eprintln!("no non-loopback address: skipped");
            return;
        }
    };
    let s = server(GuardConfig::default()).await;
    let ep = client().await;
    let l = s.listener.clone();
    let seen: Arc<std::sync::Mutex<(String, String)>> = Default::default();
    let keep = seen.clone();
    let c = ep
        .dial_rtc(
            move |offer: String| async move {
                let answer = l.accept_rtc_offer(&offer, Some("127.0.0.1".parse().unwrap())).await?;
                *keep.lock().unwrap() = (offer, answer.clone());
                Ok(answer)
            },
            &s.fp,
            &hello("good-loop", "web-1"),
            &DialOptions::default(),
        )
        .await
        .unwrap();
    let _srv = tokio::time::timeout(Duration::from_secs(5), s.listener.accept()).await.unwrap().unwrap();
    let (offer, answer) = seen.lock().unwrap().clone();
    let sdp_of = |json: &str, key: &str| {
        serde_json::from_str::<serde_json::Value>(json).unwrap()[key].as_str().unwrap().to_string()
    };
    let (offer, answer) = (sdp_of(&offer, "offer"), sdp_of(&answer, "answer"));
    let attr = |sdp: &str, name: &str| {
        sdp.lines().find_map(|l| l.strip_prefix(&format!("a={name}:"))).unwrap().trim().to_string()
    };
    let (server_ufrag, server_pwd, client_ufrag) =
        (attr(&answer, "ice-ufrag"), attr(&answer, "ice-pwd"), attr(&offer, "ice-ufrag"));
    let port: u16 = answer
        .lines()
        .filter_map(|l| l.strip_prefix("a=candidate:"))
        .map(|l| l.split_whitespace().collect::<Vec<_>>())
        .find(|f| f.get(4) == Some(&"127.0.0.1"))
        .and_then(|f| f[5].parse().ok())
        .expect("a loopback candidate in the answer");
    let request = stun_use_candidate(format!("{server_ufrag}:{client_ufrag}"), server_pwd);
    let from = std::net::UdpSocket::bind((lan, 0)).unwrap();
    for _ in 0..5 {
        from.send_to(&request(), ("127.0.0.1", port)).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    for i in 0..10 {
        let mut r =
            tokio::time::timeout(Duration::from_secs(3), c.request(&RpcRequest::new("POST", "/echo"), b"still here"))
                .await
                .unwrap_or_else(|_| panic!("round {i}: the server went mute ({:?})", c.path()))
                .unwrap();
        assert_eq!(&r.body.read_all(1024).await.unwrap()[..], b"still here");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A STUN binding request as a controlling ICE agent nominates with (RFC 8445): USERNAME, PRIORITY,
/// ICE-CONTROLLING, USE-CANDIDATE, MESSAGE-INTEGRITY, FINGERPRINT; a fresh transaction id each call.
fn stun_use_candidate(username: String, pwd: String) -> impl Fn() -> Vec<u8> {
    move || {
        let mut attrs = Vec::new();
        let put = |attrs: &mut Vec<u8>, t: u16, v: &[u8]| {
            attrs.extend_from_slice(&t.to_be_bytes());
            attrs.extend_from_slice(&(v.len() as u16).to_be_bytes());
            attrs.extend_from_slice(v);
            while !attrs.len().is_multiple_of(4) {
                attrs.push(0);
            }
        };
        put(&mut attrs, 0x0006, username.as_bytes());
        put(&mut attrs, 0x0024, &0x7eff_ffffu32.to_be_bytes());
        put(&mut attrs, 0x802a, &u64::MAX.to_be_bytes());
        put(&mut attrs, 0x0025, &[]);
        let mut tid = [0u8; 12];
        for b in &mut tid {
            *b = rand::random();
        }
        let msg = |attrs: &[u8], extra: usize| {
            let mut m = Vec::new();
            m.extend_from_slice(&0x0001u16.to_be_bytes());
            m.extend_from_slice(&((attrs.len() + extra) as u16).to_be_bytes());
            m.extend_from_slice(&0x2112_a442u32.to_be_bytes());
            m.extend_from_slice(&tid);
            m.extend_from_slice(attrs);
            m
        };
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, pwd.as_bytes());
        let mi = ring::hmac::sign(&key, &msg(&attrs, 24));
        put(&mut attrs, 0x0008, mi.as_ref());
        let crc = crc32(&msg(&attrs, 8)) ^ 0x5354_554e;
        put(&mut attrs, 0x8028, &crc.to_be_bytes());
        msg(&attrs, 0)
    }
}

fn crc32(data: &[u8]) -> u32 {
    let mut c = 0xffff_ffffu32;
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xedb8_8320 } else { c >> 1 };
        }
    }
    !c
}

/// The answer offers this computer's loopback candidates only to a client that offers its own (one on this machine
/// that gathers them, as the core does); a browser doesn't gather loopback, and a client elsewhere can't reach it.
/// (The interface-only half is skipped on a host without a non-loopback address.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rtc_loopback_candidates_only_for_loopback_offers() {
    let s = server_on(GuardConfig::default(), vec![], |_| {}).await;
    let answer_ips = |answer: &str| -> Vec<std::net::IpAddr> {
        let sdp = serde_json::from_str::<serde_json::Value>(answer).unwrap()["answer"].as_str().unwrap().to_string();
        sdp.lines()
            .filter_map(|l| l.strip_prefix("a=candidate:"))
            .filter_map(|l| l.split_whitespace().nth(4)?.parse().ok())
            .collect()
    };
    let dial_on = |bind: std::net::IpAddr| {
        let l = s.listener.clone();
        let fp = s.fp.clone();
        async move {
            let ep = client_on(vec![bind]).await;
            let seen: Arc<std::sync::Mutex<String>> = Default::default();
            let keep = seen.clone();
            let c = ep
                .dial_rtc(
                    move |offer: String| async move {
                        let answer = l.accept_rtc_offer(&offer, Some("127.0.0.1".parse().unwrap())).await?;
                        *keep.lock().unwrap() = answer.clone();
                        Ok(answer)
                    },
                    &fp,
                    &hello("good-lo", "web-1"),
                    &DialOptions::default(),
                )
                .await
                .unwrap();
            let answer = seen.lock().unwrap().clone();
            (c, ep, answer)
        }
    };
    // a client on loopback: it gets them (and connects over them)
    let (c, _ep, answer) = dial_on("127.0.0.1".parse().unwrap()).await;
    assert!(answer_ips(&answer).iter().any(|ip| ip.is_loopback()), "{:?}", answer_ips(&answer));
    let mut r = c.request(&RpcRequest::new("POST", "/echo"), b"lo").await.unwrap();
    assert_eq!(&r.body.read_all(64).await.unwrap()[..], b"lo");
    // a client on this machine's interface address only: none
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
    let Some(lan) = probe
        .connect("192.0.2.1:9")
        .and_then(|_| probe.local_addr())
        .ok()
        .map(|a| a.ip())
        .filter(|ip| !ip.is_loopback() && !ip.is_unspecified())
    else {
        eprintln!("no non-loopback address: the interface half skipped");
        return;
    };
    let (c, _ep2, answer) = dial_on(lan).await;
    let ips = answer_ips(&answer);
    assert!(!ips.is_empty() && ips.iter().all(|ip| !ip.is_loopback()), "{ips:?}");
    let mut r = c.request(&RpcRequest::new("POST", "/echo"), b"lan").await.unwrap();
    assert_eq!(&r.body.read_all(64).await.unwrap()[..], b"lan");
}
