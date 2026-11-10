// The media layer through a real session on loopback: video frames (big ones, several blocks) delivered in order
// and acknowledged, target bitrate events, audio, cursor, exactly-once input, media fields in the stats line.

use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use serde_json::json;
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, DialOptions, DialTarget, Endpoint, EndpointConfig, Hello, ServerInfo,
    ServerOptions, Session,
    binding::generate_link_key,
    media::{ClientEvent, Codec, FrameKind, FrameMeta, InputKind, ServerEvent},
};

struct Anyone;

#[async_trait]
impl Authenticator for Anyone {
    async fn authenticate(&self, _r: AuthRequest) -> AuthDecision {
        AuthDecision::Accept { principal: json!({}), features: None }
    }
}

async fn pair() -> (Session, Session, Endpoint, Endpoint) {
    let mut cfg = EndpointConfig::server(generate_link_key(), 0);
    cfg.portmapper = Some(false);
    let server = Endpoint::bind(cfg).await.unwrap();
    let listener = server.listen(ServerOptions::new(ServerInfo::default(), Arc::new(Anyone))).unwrap();
    let client = Endpoint::bind(EndpointConfig::client(generate_link_key())).await.unwrap();
    let target = DialTarget { id: server.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", server.port())] };
    let c = client.dial(&target, &Hello::default(), &DialOptions::default()).await.unwrap();
    let s = listener.accept().await.unwrap();
    (s, c, server, client)
}

fn meta(kind: FrameKind) -> FrameMeta {
    FrameMeta { codec: Codec::Hevc, kind, width: 1920, height: 1080, capture_us: 0, recovery_base: 0, au_len: 0 }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn video_audio_cursor_input() {
    let (s, c, _se, _ce) = pair().await;
    tokio::time::sleep(Duration::from_millis(150)).await; // a first RTT / max datagram for the media layer
    s.open_video(1);
    c.open_video(1);
    s.open_audio(2);
    c.open_audio(2);

    // 30 frames, the first a 200 kB key frame (several FEC blocks), then 8 kB deltas
    let mut sent = Vec::new();
    for i in 0..30u32 {
        let (kind, size) = if i == 0 { (FrameKind::Key, 200_000) } else { (FrameKind::Delta, 8_000) };
        let au: Vec<u8> = (0..size).map(|b| (b as u32 ^ i) as u8).collect();
        let n = s.send_frame(1, meta(kind), &au).unwrap();
        sent.push((n, au));
        s.send_audio(2, i as u64 * 20_000, &[i as u8; 120]).unwrap();
        s.send_cursor(1, format!(r#"{{"x":{i},"y":2,"visible":true,"shapeId":"a"}}"#).as_bytes()).unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }

    let mut frames = Vec::new();
    let mut audio = 0;
    let mut cursor_x = None;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while frames.len() < 30 {
        let ev = tokio::time::timeout_at(deadline, c.recv_client_event()).await.expect("client events").unwrap();
        match ev {
            ClientEvent::Frame(f) => {
                c.frame_decoded(f.stream, f.frame, true).unwrap();
                frames.push(f);
            }
            ClientEvent::Audio(_) => audio += 1,
            ClientEvent::Cursor { json, .. } => {
                let v: serde_json::Value = serde_json::from_slice(&json).unwrap();
                cursor_x = v["x"].as_u64();
            }
            _ => {}
        }
    }
    for (f, (n, au)) in frames.iter().zip(&sent) {
        assert_eq!(f.frame, *n, "in order");
        assert_eq!(&f.au, au, "frame {n} intact");
    }
    assert_eq!(frames[0].meta.kind, FrameKind::Key);
    assert!(audio > 0);
    assert!(cursor_x.is_some());

    // the server hears about deliveries and its target bitrate
    let mut delivered = 0;
    let mut target = None;
    while let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(500), s.recv_server_event()).await {
        match ev {
            ServerEvent::FrameDelivered { frame, .. } => delivered = delivered.max(frame),
            ServerEvent::TargetBitrate { target_bps, .. } => target = Some(target_bps),
            _ => {}
        }
    }
    assert!(delivered >= 25, "delivered {delivered}");
    assert!(target.is_some());
    // MediaCc follows the rate controller
    assert!(s.target_bitrate().follows_media());
    assert_eq!(Some(s.target_bitrate().get()), target.map(|t| t.max(1)));

    // input: discrete events exactly once, in order; acked back to the client
    for i in 0..20 {
        let body = format!(r#"{{"type":"key","n":{i}}}"#);
        c.send_input(InputKind::Discrete, body.as_bytes()).unwrap();
    }
    c.send_input(InputKind::Move, br#"{"type":"move","x":1}"#).unwrap();
    let mut got = Vec::new();
    while got.len() < 20 {
        match tokio::time::timeout(Duration::from_secs(2), s.recv_server_event()).await.unwrap().unwrap() {
            ServerEvent::Input(e) if e.kind == InputKind::Discrete => got.push(e.seq),
            _ => {}
        }
    }
    let mut sorted = got.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(got, sorted, "in order, once each");
    let mut acked = 0;
    while acked < *got.last().unwrap() {
        if let ClientEvent::InputAcked { through } =
            tokio::time::timeout(Duration::from_secs(2), c.recv_client_event()).await.unwrap().unwrap()
        {
            acked = through
        }
    }

    // the media fields reach the stats line
    let line = c.stats().line();
    assert!(line.contains(" fec ") && line.contains(" fps "), "{line}");
    let line = s.stats().line();
    assert!(line.contains(" rate "), "{line}");

    // a server call on a client session is refused
    assert!(c.send_frame(1, meta(FrameKind::Key), b"x").is_err());
    assert!(s.send_input(InputKind::Discrete, b"{}").is_err());
}
