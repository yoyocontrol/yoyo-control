// The WebRTC transport on loopback: a server endpoint with an rtc socket, clients dialing it with `dial_rtc` (str0m as
// the offering side, the way a browser does), signaled straight into `Listener::accept_rtc_offer`. The same session
// protocol as on QUIC: handshake, the answer's signature, control messages, RPC, datagrams, media, close codes,
// the guard.

use std::{
    net::IpAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use bytes::Bytes;
use serde_json::json;
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, CloseCode, DenyCode, DialOptions, Endpoint, EndpointConfig, GuardConfig,
    Headers, Hello, IdentityKey, LinkError, Listener, PathKind, RpcHandler, RpcRequest, RpcResponder, RtcConfig,
    ServerInfo, ServerOptions, Session, Transport,
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

#[async_trait]
impl RpcHandler for Routes {
    async fn handle(&self, session: Session, req: RpcRequest, body: Bytes, mut res: RpcResponder) {
        let mut h = Headers::new();
        h.insert("x-principal".into(), session.principal()["device"]["id"].as_str().unwrap_or("").into());
        match req.path.split('?').next().unwrap() {
            "/echo" => res.respond(200, &h, &body).await.unwrap(),
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
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let identity = test_identity();
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    cfg.guard = guard;
    cfg.bind_ips = vec!["127.0.0.1".parse().unwrap()];
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
    let listener = Arc::new(ep.listen(opts).unwrap());
    Server { ep, listener, tokens, fp: identity_fingerprint(&identity).unwrap() }
}

async fn client() -> Endpoint {
    let mut cfg = EndpointConfig::client(generate_link_key());
    cfg.bind_ips = vec!["127.0.0.1".parse().unwrap()];
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
    let l = s.listener.clone();
    let c = ep
        .dial_rtc(
            |offer| async move { l.accept_rtc_offer(&offer, Some("127.0.0.1".parse().unwrap())).await },
            &s.fp,
            &hello(token, "web-1"),
            &DialOptions::default(),
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
        GuardConfig { max_unauthenticated: 2, failure_limit: 2, exempt_loopback: false, ..GuardConfig::default() };
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
    // two pending offers fill the unauthenticated slots
    assert!(matches!(offer(1).await, LinkError::Connect(_)));
    assert!(matches!(offer(1).await, LinkError::Connect(_)));
    assert_eq!(s.ep.guard().counts(), (2, 2));
    match offer(2).await {
        LinkError::Denied { code: DenyCode::Busy, .. } => {}
        other => panic!("{other:?}"),
    }
    // they time out (no ICE within 10 s): two failures for 198.51.100.1, which is now blocked
    tokio::time::sleep(Duration::from_millis(10_800)).await;
    assert_eq!(s.ep.guard().counts(), (0, 0));
    assert!(s.ep.guard().is_blocked("198.51.100.1".parse().unwrap()));
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
