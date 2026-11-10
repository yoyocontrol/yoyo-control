// The speed test through a real session on loopback (docs/LINK.md「测速」): the server's session sends filler on its
// own, the client's media layer takes it, the report has both halves; the apps on either side never see the probe's
// control messages or media events; a cancelled test stops on the server and the next one runs.

use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use serde_json::json;
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, DialOptions, DialTarget, Endpoint, EndpointConfig, Hello, PathKind,
    ServerInfo, ServerOptions, Session, Transport,
    binding::generate_link_key,
    media::{ClientEvent, ServerEvent},
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_speed_test_measures_the_video_path() {
    let (s, c, _se, _ce) = pair().await;
    tokio::time::sleep(Duration::from_millis(300)).await; // RTT samples for the idle RTT

    let report = c.probe(Duration::from_millis(2500)).await.unwrap();
    assert_eq!(report.transport, Transport::Quic);
    assert_eq!(report.path, PathKind::Lan);
    assert!(report.frames > 30, "{report:?}");
    assert!(report.received_mbps.unwrap() > 2.0, "{report:?}");
    assert!(report.peak_mbps.unwrap() >= report.received_mbps.unwrap() * 0.9, "{report:?}");
    assert!(report.final_mbps.is_some() && report.final_fps.unwrap() > 20.0, "{report:?}");
    assert!(report.rtt_idle_ms.is_some() && report.rtt_p50_ms.is_some(), "{report:?}");
    assert_eq!(report.lost_frames, 0, "{report:?}");
    let server = report.server.clone().expect("the server's half");
    assert_eq!(server.reason, "done");
    assert!((2400..4000).contains(&report.duration_ms), "{report:?}");
    // on loopback the startup climb runs from 3.5 Mbps
    assert!(server.max_target_mbps > 3.5, "{server:?}");
    assert!(server.frames >= report.frames && server.bytes > 0, "{server:?}");
    assert_eq!(server.fps_cap, 60.0, "{server:?}");

    // the apps heard nothing of it: no control messages, no media events of the probe's stream
    assert!(tokio::time::timeout(Duration::from_millis(100), c.recv_control()).await.is_err());
    assert!(tokio::time::timeout(Duration::from_millis(100), s.recv_control()).await.is_err());
    while let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), s.recv_server_event()).await {
        match ev {
            ServerEvent::FrameDelivered { stream, .. }
            | ServerEvent::RecoveryNeeded { stream, .. }
            | ServerEvent::KeyframeNeeded { stream } => panic!("a media event of stream {stream} reached the app"),
            _ => {}
        }
    }
    while let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), c.recv_client_event()).await {
        if let ClientEvent::Frame(f) = ev {
            panic!("a frame of stream {} reached the app", f.stream);
        }
    }

    // the report is JSON the apps can pass on
    let v = serde_json::to_value(&report).unwrap();
    assert_eq!(v["transport"], "quic");
    assert_eq!(v["path"], "lan");
    assert!(v["server"]["maxTargetMbps"].as_f64().is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cancelled_test_stops_and_the_next_one_runs() {
    let (s, c, _se, _ce) = pair().await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    // dropped after 600 ms of a 10 s test
    assert!(tokio::time::timeout(Duration::from_millis(600), c.probe(Duration::from_secs(10))).await.is_err());
    // the server stops at once (its slot is free again: a second test may start right away)
    tokio::time::sleep(Duration::from_millis(200)).await;
    let report = c.probe(Duration::from_millis(1000)).await.unwrap();
    assert_eq!(report.server.expect("done").reason, "done");
    assert!(report.frames > 10);
    drop(s);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_the_client_runs_it() {
    let (s, _c, _se, _ce) = pair().await;
    assert!(s.probe(Duration::from_secs(1)).await.is_err());
}
