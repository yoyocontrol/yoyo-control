//! uu-link-probe: runs a uu Link session end to end and measures it.
//!
//!     uu-link-probe serve [--port 47820] [--key <file>] [--token <t>] [--relay <url>] [--portmap] [--bind <ip>]
//!             [--rtc [--rtc-port <p>] [--signal <port>] [--identity <file>] [--advertise <ip:port> [--advertise-only]] [--stun <host:port>]]
//!             [--screen-clip <file>]
//!     uu-link-probe serve-rtc …            (= serve --rtc --signal 47830)
//!     uu-link-probe dial <id> <ip:port>[,<ip:port>…] [--token <t>] [--seconds 10] [--load-mbps 8] [--video]
//!             [--speed-test [ms]] [--relay <url>] [--bind <ip>]
//!     uu-link-probe dial-rtc <http://127.0.0.1:47830/rtc> <fingerprint> [same options as dial]
//!
//! `serve` prints its id and addresses and answers: RPC `/echo` (the body back) and `/bytes?n=` (n bytes streamed),
//! control `ping` → `pong`, datagram channel 14 echoed, channel 15 counted (the load), `video.open` → synthetic
//! 60 fps video; `welcome.principal` is `{device, client}` (`client` = the client key it saw). With `--rtc` it also takes WebRTC sessions: `--signal <port>` serves the signaling on
//! `127.0.0.1:<port>` (`POST /rtc` with the offer JSON → the answer JSON, `GET /info`; CORS open, for a browser on
//! this machine); `--advertise` adds an address to the answer's candidates (e.g. an impairment proxy's), `--advertise-only` leaves the
//! interface addresses out (then a client can only come through the advertised one). `--screen-clip` makes it a
//! minimal screen for a real client page: `video.open` (with its `id`) answers `video.opened` and loops the clip's
//! H.264 access units at 30 fps (from its key frame again when the client asks for one), `video.close` stops it,
//! `control.take` / `control.release` are granted. The clip file: `UUCLIP01`, width and height (u16 BE), then per
//! access unit a kind byte (1 key, 0 delta), its length (u32 BE) and its Annex-B bytes. `dial`
//! measures the handshake, RPC and control round trips, then for `--seconds`: a 50 Hz datagram ping (channel 14) and
//! a synthetic `--load-mbps` stream of 1150-byte datagrams (channel 15) at once; it prints the session's `link:` lines
//! and a summary. `--speed-test [ms]` runs only the speed test (the
//! server's session sends the filler; docs/LINK.md「测速」) and prints its report. `dial-rtc` does the same over WebRTC, signaled through `serve --signal`. Both ends print their logs
//! to stderr.

use std::{
    net::{IpAddr, SocketAddr},
    process::exit,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use bytes::Bytes;
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use uu_link::{
    AuthDecision, AuthRequest, Authenticator, DenyCode, DialOptions, DialTarget, Endpoint, EndpointConfig, Headers,
    Hello, IdentityKey, LinkError, Listener, RpcHandler, RpcRequest, RpcResponder, RtcConfig, ServerInfo,
    ServerOptions, Session,
    binding::{generate_link_key, identity_fingerprint, load_or_create_link_key},
    log::{LogLevel, set_log_sink},
};

const PING: u8 = 14;
const LOAD: u8 = 15;
const LOAD_SIZE: usize = 1150;

fn usage() -> ! {
    eprintln!(
        "usage: uu-link-probe serve [--port 47820] [--key <file>] [--token <t>] [--relay <url>] [--portmap] [--bind <ip>]\n\
         \x20             [--rtc [--rtc-port <p>] [--signal <port>] [--identity <file>] [--advertise <ip:port> [--advertise-only]] [--stun <host:port>]]\n\
         \x20             [--screen-clip <file>]\n\
         \x20      uu-link-probe serve-rtc [serve options]\n\
         \x20      uu-link-probe dial <id> <ip:port>[,…] [--token <t>] [--seconds 10] [--load-mbps 8] [--video] [--speed-test [ms]] [--relay <url>] [--bind <ip>]\n\
         \x20      uu-link-probe dial-rtc <signal url> <fingerprint> [--token <t>] [--seconds 10] [--load-mbps 8] [--video] [--bind <ip>]"
    );
    exit(2)
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

/// `--bind <ip>[,<ip>…]`: only these local addresses (e.g. to force the path through uu-link-netem).
fn bind_ips(args: &[String]) -> Vec<IpAddr> {
    flag(args, "--bind")
        .map(|v| v.split(',').map(|ip| ip.parse().unwrap_or_else(|_| usage())).collect())
        .unwrap_or_default()
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let verbose = args.iter().any(|a| a == "-v");
    // the libraries' own logs (str0m, iroh) with RUST_LOG, e.g. RUST_LOG=str0m=debug
    if std::env::var_os("RUST_LOG").is_some() {
        tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .with_writer(std::io::stderr)
            .init();
    }
    set_log_sink(Some(Arc::new(move |level, line: &str| {
        if verbose || level >= LogLevel::Info {
            eprintln!("{line}");
        }
    })));
    match args.first().map(String::as_str) {
        Some("serve") => serve(&args[1..]).await,
        Some("serve-rtc") => {
            let mut a = args[1..].to_vec();
            a.push("--rtc".into());
            if flag(&a, "--signal").is_none() {
                a.extend(["--signal".into(), "47830".into()]);
            }
            serve(&a).await
        }
        Some("dial") => dial(&args[1..]).await,
        Some("dial-rtc") => dial_rtc(&args[1..]).await,
        _ => usage(),
    }
}

// MARK: serve

struct Token(String);

#[async_trait::async_trait]
impl Authenticator for Token {
    async fn authenticate(&self, r: AuthRequest) -> AuthDecision {
        if r.hello.credential == format!("Bearer {}", self.0) {
            // the client key too: a test can check it stays the same between dials (a browser's DTLS certificate)
            AuthDecision::Accept {
                principal: json!({"device": r.hello.device.id, "client": r.client_key}),
                features: None,
            }
        } else {
            AuthDecision::Deny { code: DenyCode::Unauthorized, message: "wrong token".into() }
        }
    }
}

struct Routes;

#[async_trait::async_trait]
impl RpcHandler for Routes {
    async fn handle(&self, _s: Session, req: RpcRequest, body: Bytes, mut res: RpcResponder) {
        {
            let route = req.path.split('?').next().unwrap_or("");
            match route {
                "/echo" => {
                    let _ = res.respond(200, &Headers::new(), &body).await;
                }
                "/bytes" => {
                    let n: usize = req.path.split("n=").nth(1).and_then(|v| v.parse().ok()).unwrap_or(1 << 20);
                    let _ = res.head(200, &Headers::new()).await;
                    let chunk = vec![7u8; 64 * 1024];
                    let mut left = n;
                    while left > 0 {
                        let k = left.min(chunk.len());
                        if res.write(&chunk[..k]).await.is_err() {
                            return;
                        }
                        left -= k;
                    }
                    let _ = res.finish().await;
                }
                _ => {
                    let _ = res.respond(404, &Headers::new(), b"{}").await;
                }
            }
        }
    }
}

async fn serve(args: &[String]) {
    let port: u16 = flag(args, "--port").map(|p| p.parse().unwrap_or_else(|_| usage())).unwrap_or(47820);
    let token = flag(args, "--token").unwrap_or_else(|| "probe".into());
    let key = match flag(args, "--key") {
        Some(path) => load_or_create_link_key(std::path::Path::new(&path)).unwrap_or_else(|e| {
            eprintln!("probe: {e}");
            exit(1)
        }),
        None => generate_link_key(),
    };
    let mut cfg = EndpointConfig::server(key, port);
    cfg.relays = flag(args, "--relay").into_iter().collect();
    // the router's port mapping only when asked: a probe should not leave mappings behind
    cfg.portmapper = Some(args.iter().any(|a| a == "--portmap"));
    cfg.bind_ips = bind_ips(args);
    let rtc = args.iter().any(|a| a == "--rtc");
    if rtc {
        let rtc_port = flag(args, "--rtc-port").map(|p| p.parse().unwrap_or_else(|_| usage()));
        cfg.rtc = Some(RtcConfig {
            port: rtc_port.unwrap_or(RtcConfig::default_port(port)),
            stun_servers: flag(args, "--stun").into_iter().collect(),
            external_only: args.iter().any(|a| a == "--advertise-only"),
        });
    }
    let ep = Endpoint::bind(cfg).await.unwrap_or_else(|e| {
        eprintln!("probe: {e}");
        exit(1)
    });
    let identity = match flag(args, "--identity") {
        Some(path) => std::fs::read(&path).unwrap_or_else(|e| {
            eprintln!("probe: {path}: {e}");
            exit(1)
        }),
        None => new_identity(),
    };
    let mut opts = ServerOptions::new(
        ServerInfo { id: "probe".into(), name: "uu-link-probe".into(), platform: std::env::consts::OS.into() },
        Arc::new(Token(token.clone())),
    );
    opts.rpc = Some(Arc::new(Routes));
    opts.rtc_identity = Some(Arc::new(IdentityKey::new(&identity).unwrap_or_else(|e| {
        eprintln!("probe: {e}");
        exit(1)
    })));
    let listener = Arc::new(ep.listen(opts).unwrap());
    tokio::time::sleep(Duration::from_millis(300)).await;
    let info = ep.addr_info();
    println!("id {}", info.id);
    println!("port {}", ep.port());
    println!("direct {}", info.direct.join(","));
    println!("token {token}");
    println!("dial: uu-link-probe dial {} 127.0.0.1:{} --token {token}", info.id, ep.port());
    if rtc {
        let fp = identity_fingerprint(&identity).expect("identity");
        println!("rtc port {}", ep.rtc_port().unwrap_or(0));
        println!("fingerprint {fp}");
        if let Some(a) = flag(args, "--advertise") {
            let a: SocketAddr = a.parse().unwrap_or_else(|_| usage());
            ep.add_rtc_external_addr(a);
            println!("advertise {a}");
        }
        if let Some(p) = flag(args, "--signal") {
            let p: u16 = p.parse().unwrap_or_else(|_| usage());
            let http = TcpListener::bind(("127.0.0.1", p)).await.unwrap_or_else(|e| {
                eprintln!("probe: signaling port {p}: {e}");
                exit(1)
            });
            println!("signal http://127.0.0.1:{p}/rtc");
            println!("dial: uu-link-probe dial-rtc http://127.0.0.1:{p}/rtc {fp} --token {token}");
            let info = json!({"fingerprint": fp, "token": token, "credential": format!("Bearer {token}"),
                "signal": format!("http://127.0.0.1:{p}/rtc")});
            tokio::spawn(signaling(http, listener.clone(), info));
        }
    }
    let clip = flag(args, "--screen-clip").map(|path| {
        Arc::new(Clip::load(&path).unwrap_or_else(|e| {
            eprintln!("probe: {path}: {e}");
            exit(1)
        }))
    });
    while let Some(s) = listener.accept().await {
        tokio::spawn(serve_session(s, clip.clone()));
    }
}

/// `--screen-clip`: H.264 access units to loop as a screen (the format is in the module comment).
struct Clip {
    width: u16,
    height: u16,
    /// (key frame, Annex-B access unit), the first a key frame.
    frames: Vec<(bool, Vec<u8>)>,
}

impl Clip {
    fn load(path: &str) -> Result<Clip, String> {
        let b = std::fs::read(path).map_err(|e| e.to_string())?;
        if b.len() < 12 || &b[..8] != b"UUCLIP01" {
            return Err("not a UUCLIP01 file".into());
        }
        let width = u16::from_be_bytes([b[8], b[9]]);
        let height = u16::from_be_bytes([b[10], b[11]]);
        let mut frames = Vec::new();
        let mut at = 12;
        while at < b.len() {
            if at + 5 > b.len() {
                return Err("truncated record".into());
            }
            let key = b[at] == 1;
            let n = u32::from_be_bytes([b[at + 1], b[at + 2], b[at + 3], b[at + 4]]) as usize;
            at += 5;
            let au = b.get(at..at + n).ok_or("truncated access unit")?.to_vec();
            at += n;
            frames.push((key, au));
        }
        if !frames.first().is_some_and(|f| f.0) {
            return Err("the clip must start with a key frame".into());
        }
        Ok(Clip { width, height, frames })
    }
}

/// A fresh identity key in the identity files' format (X9.63 `04 ‖ X ‖ Y ‖ D`).
fn new_identity() -> Vec<u8> {
    use ring::{
        rand::SystemRandom,
        signature::{self, EcdsaKeyPair, KeyPair},
    };
    let rng = SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).expect("key");
    let pair =
        EcdsaKeyPair::from_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).expect("key");
    let doc = pkcs8.as_ref();
    // ring's PKCS#8 v1 document for P-256: the private scalar follows `04 20` inside the ECPrivateKey
    let at = doc.windows(2).position(|w| w == [0x04, 0x20]).expect("pkcs8") + 2;
    [pair.public_key().as_ref(), &doc[at..at + 32]].concat()
}

// MARK: HTTP signaling (localhost, for browsers and dial-rtc)

/// One HTTP/1.1 request: method, path, body.
async fn read_request(c: &mut TcpStream) -> Option<(String, String, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let head_end = loop {
        let n = c.read(&mut tmp).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 64 * 1024 {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.lines();
    let mut first = lines.next()?.split_whitespace();
    let (method, path) = (first.next()?.to_string(), first.next()?.to_string());
    let len: usize = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse().ok())
        .unwrap_or(0);
    if len > 128 * 1024 {
        return None;
    }
    let mut body = buf[head_end..].to_vec();
    while body.len() < len {
        let n = c.read(&mut tmp).await.ok()?;
        if n == 0 {
            return None;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(len);
    Some((method, path, body))
}

async fn respond(c: &mut TcpStream, status: u16, body: &str) {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        429 => "Too Many Requests",
        _ => "Service Unavailable",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\
         access-control-allow-origin: *\r\naccess-control-allow-methods: GET, POST, OPTIONS\r\n\
         access-control-allow-headers: content-type\r\nconnection: close\r\n\r\n",
        body.len()
    );
    let _ = c.write_all(head.as_bytes()).await;
    let _ = c.write_all(body.as_bytes()).await;
}

async fn signaling(http: TcpListener, listener: Arc<Listener>, info: serde_json::Value) {
    while let Ok((mut c, peer)) = http.accept().await {
        let (listener, info) = (listener.clone(), info.clone());
        tokio::spawn(async move {
            let Some((method, path, body)) = read_request(&mut c).await else { return };
            match (method.as_str(), path.as_str()) {
                ("OPTIONS", _) => respond(&mut c, 204, "").await,
                ("GET", "/info") => respond(&mut c, 200, &info.to_string()).await,
                ("POST", "/rtc") => {
                    let offer = String::from_utf8_lossy(&body).to_string();
                    match listener.accept_rtc_offer(&offer, Some(peer.ip())).await {
                        Ok(answer) => respond(&mut c, 200, &answer).await,
                        Err(e) => {
                            let status = match &e {
                                LinkError::InvalidArgument(_) => 400,
                                LinkError::Denied { code: DenyCode::RateLimited, .. } => 429,
                                _ => 503,
                            };
                            respond(&mut c, status, &json!({"error": e.to_string()}).to_string()).await
                        }
                    }
                }
                _ => respond(&mut c, 404, r#"{"error":"not found"}"#).await,
            }
        });
    }
}

/// `POST url` with `body` (a plain `http://host:port/path`), the response body if 200.
async fn http_post(url: &str, body: String) -> Result<String, LinkError> {
    let rest =
        url.strip_prefix("http://").ok_or_else(|| LinkError::InvalidArgument("signal url: http:// only".into()))?;
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let mut c = TcpStream::connect(host).await.map_err(|e| LinkError::Connect(format!("signal {host}: {e}")))?;
    let req = format!(
        "POST {path} HTTP/1.1\r\nhost: {host}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    c.write_all(req.as_bytes()).await.map_err(|e| LinkError::Connect(e.to_string()))?;
    let mut out = Vec::new();
    c.read_to_end(&mut out).await.map_err(|e| LinkError::Connect(e.to_string()))?;
    let text = String::from_utf8_lossy(&out);
    let (head, body) = text.split_once("\r\n\r\n").ok_or_else(|| LinkError::Connect("signal: bad response".into()))?;
    if !head.starts_with("HTTP/1.1 200") {
        return Err(LinkError::Connect(format!("signal: {} {body}", head.lines().next().unwrap_or(""))));
    }
    Ok(body.to_string())
}

async fn serve_session(s: Session, clip: Option<Arc<Clip>>) {
    s.target_bitrate().set(40_000_000);
    let load = Arc::new(AtomicU64::new(0));
    let load_bytes = Arc::new(AtomicU64::new(0));
    {
        let s = s.clone();
        tokio::spawn(async move {
            while let Ok(Some(d)) = s.recv_datagram(PING).await {
                let _ = s.send_datagram_raw(d);
            }
        });
    }
    {
        let (s, load, load_bytes) = (s.clone(), load.clone(), load_bytes.clone());
        tokio::spawn(async move {
            while let Ok(Some(d)) = s.recv_datagram(LOAD).await {
                load.fetch_add(1, Ordering::Relaxed);
                load_bytes.fetch_add(d.len() as u64, Ordering::Relaxed);
            }
        });
    }
    // `--screen-clip`: the id of the video stream playing (0: none); a newer `video.open` replaces it
    let clip_stream = Arc::new(AtomicU64::new(0));
    let (device_id, device_name) = (s.hello().device.id.clone(), s.hello().device.name.clone());
    while let Some(m) = s.recv_control().await {
        match m["t"].as_str() {
            Some("ping") => {
                let _ = s.send_control(&json!({"t": "pong", "n": m["n"]})).await;
            }
            Some("video.open") => match &clip {
                Some(clip) => {
                    let id = m["id"].as_u64().filter(|&i| (1..=255).contains(&i)).unwrap_or(1) as u8;
                    clip_stream.store(id as u64, Ordering::Relaxed);
                    let opened = json!({"t": "video.opened", "id": id, "codec": "h264", "width": clip.width,
                        "height": clip.height, "headers": {}});
                    let _ = s.send_control(&opened).await;
                    tokio::spawn(clip_video(s.clone(), id, clip.clone(), clip_stream.clone()));
                }
                None => {
                    tokio::spawn(synthetic_video(s.clone()));
                }
            },
            Some("video.close") if clip.is_some() => {
                let id = m["id"].as_u64().unwrap_or(0);
                let _ = clip_stream.compare_exchange(id, 0, Ordering::Relaxed, Ordering::Relaxed);
                s.close_video(id as u8);
            }
            Some(t @ ("control.take" | "control.release")) if clip.is_some() => {
                let take = t == "control.take";
                let holder = if take { json!({"id": device_id, "name": device_name}) } else { serde_json::Value::Null };
                let _ =
                    s.send_control(&json!({"t": "control", "rid": m["rid"], "granted": take, "holder": holder})).await;
            }
            Some("load.report") => {
                let r = json!({
                    "t": "load.report",
                    "datagrams": load.load(Ordering::Relaxed),
                    "bytes": load_bytes.load(Ordering::Relaxed),
                });
                let _ = s.send_control(&r).await;
            }
            _ => {}
        }
    }
}

// MARK: dial

async fn dial(args: &[String]) {
    if args.len() < 2 {
        usage();
    }
    let id = args[0].clone();
    let direct: Vec<String> = args[1].split(',').filter(|a| !a.is_empty()).map(String::from).collect();
    let token = flag(args, "--token").unwrap_or_else(|| "probe".into());
    let seconds: f64 = flag(args, "--seconds").map(|v| v.parse().unwrap_or_else(|_| usage())).unwrap_or(10.0);
    let load_mbps: f64 = flag(args, "--load-mbps").map(|v| v.parse().unwrap_or_else(|_| usage())).unwrap_or(8.0);
    let relays: Vec<String> = flag(args, "--relay").into_iter().collect();

    let mut cfg = EndpointConfig::client(generate_link_key());
    cfg.relays = relays.clone(); // a relay in the target needs the endpoint to use relays at all (RelayMode)
    cfg.bind_ips = bind_ips(args);
    let ep = Endpoint::bind(cfg).await.unwrap();
    let t0 = Instant::now();
    let s = match ep.dial(&DialTarget { id, relays, direct }, &probe_hello(&token), &DialOptions::default()).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("probe: {e}");
            exit(1)
        }
    };
    measure(ep, s, t0, seconds, load_mbps, args).await
}

fn probe_hello(token: &str) -> Hello {
    Hello {
        credential: format!("Bearer {token}"),
        device: uu_link::Device { id: "probe".into(), name: "uu-link-probe".into() },
        app: uu_link::AppInfo { name: "uu-link-probe".into(), version: env!("CARGO_PKG_VERSION").into() },
        features: vec![],
    }
}

async fn dial_rtc(args: &[String]) {
    if args.len() < 2 {
        usage();
    }
    let (url, fp) = (args[0].clone(), args[1].clone());
    let token = flag(args, "--token").unwrap_or_else(|| "probe".into());
    let seconds: f64 = flag(args, "--seconds").map(|v| v.parse().unwrap_or_else(|_| usage())).unwrap_or(10.0);
    let load_mbps: f64 = flag(args, "--load-mbps").map(|v| v.parse().unwrap_or_else(|_| usage())).unwrap_or(8.0);
    let mut cfg = EndpointConfig::client(generate_link_key());
    cfg.bind_ips = bind_ips(args);
    cfg.rtc = Some(RtcConfig::default());
    let ep = Endpoint::bind(cfg).await.unwrap();
    let t0 = Instant::now();
    let signal = |offer: String| async move { http_post(&url, offer).await };
    let s = match ep.dial_rtc(signal, &fp, &probe_hello(&token), &DialOptions::default()).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("probe: {e}");
            exit(1)
        }
    };
    measure(ep, s, t0, seconds, load_mbps, args).await
}

/// The measurements of `dial` / `dial-rtc` on a fresh session.
async fn measure(ep: Endpoint, s: Session, t0: Instant, seconds: f64, load_mbps: f64, args: &[String]) {
    let connect_ms = t0.elapsed().as_secs_f64() * 1e3;
    println!(
        "session ({}): {:.1} ms to welcome, path {:?}, max datagram {}",
        s.transport(),
        connect_ms,
        s.path(),
        s.max_datagram_size()
    );

    // `--speed-test [ms]`: only the speed test (docs/LINK.md「测速」), its report as JSON
    if let Some(i) = args.iter().position(|a| a == "--speed-test") {
        let ms = args.get(i + 1).and_then(|v| v.parse::<u64>().ok()).unwrap_or(8000);
        tokio::time::sleep(Duration::from_millis(500)).await; // RTT samples for the idle RTT
        match s.probe(Duration::from_millis(ms)).await {
            Ok(r) => println!("speed test: {}", serde_json::to_string_pretty(&r).unwrap()),
            Err(e) => {
                eprintln!("speed test: {e}");
                exit(1)
            }
        }
        s.close(uu_link::CloseCode::Normal, "done").await;
        ep.close().await;
        return;
    }

    // RPC round trips
    let mut rpc = Vec::new();
    for _ in 0..50 {
        let t = Instant::now();
        let mut r = s.request(&RpcRequest::new("POST", "/echo"), b"0123456789").await.unwrap();
        r.body.read_all(1024).await.unwrap();
        rpc.push(t.elapsed().as_secs_f64() * 1e3);
    }
    let t = Instant::now();
    let mut r = s.request(&RpcRequest::new("GET", "/bytes?n=8388608"), b"").await.unwrap();
    let got = r.body.read_all(16 << 20).await.unwrap().len();
    let rpc_mbps = got as f64 * 8.0 / t.elapsed().as_secs_f64() / 1e6;
    println!(
        "rpc: echo p50 {:.2} ms p90 {:.2} ms; 8 MiB download {:.0} Mbps",
        pct(&mut rpc, 0.5),
        pct(&mut rpc, 0.9),
        rpc_mbps
    );

    // control round trips
    let mut ctl = Vec::new();
    for n in 0..50 {
        let t = Instant::now();
        s.send_control(&json!({"t": "ping", "n": n})).await.unwrap();
        loop {
            let m = s.recv_control().await.expect("pong");
            if m["t"] == "pong" && m["n"] == n {
                break;
            }
        }
        ctl.push(t.elapsed().as_secs_f64() * 1e3);
    }
    println!("control: ping p50 {:.2} ms p90 {:.2} ms", pct(&mut ctl, 0.5), pct(&mut ctl, 0.9));

    // synthetic 60 fps video from the server through the media layer, and input at 10 Hz
    let video = args.iter().any(|a| a == "--video");
    let video_task = if video {
        s.open_video(1);
        s.send_control(&json!({"t": "video.open", "id": 1})).await.unwrap();
        let s2 = s.clone();
        Some(tokio::spawn(async move {
            let (mut frames, mut bytes, mut acked) = (0u64, 0u64, 0u32);
            let mut input = tokio::time::interval(Duration::from_millis(100));
            let mut sent_inputs = 0u32;
            loop {
                tokio::select! {
                    ev = s2.recv_client_event() => match ev {
                        Some(uu_link::media::ClientEvent::Frame(f)) => {
                            frames += 1;
                            bytes += f.au.len() as u64;
                            let _ = s2.frame_decoded(f.stream, f.frame, true);
                        }
                        Some(uu_link::media::ClientEvent::InputAcked { through }) => acked = through,
                        Some(_) => {}
                        None => break,
                    },
                    _ = input.tick() => {
                        if s2.send_input(uu_link::media::InputKind::Discrete, br#"{"type":"key","key":"a"}"#).is_ok() {
                            sent_inputs += 1;
                        }
                    }
                }
            }
            (frames, bytes, sent_inputs, acked)
        }))
    } else {
        None
    };

    // datagram ping at 50 Hz + the load, for `seconds`
    s.target_bitrate().set(((load_mbps * 1.25).max(1.0) * 1e6) as u64);
    let until = Instant::now() + Duration::from_secs_f64(seconds);
    let pings = (seconds * 50.0) as u64;
    let echo = {
        let s = s.clone();
        tokio::spawn(async move {
            let mut rtts = Vec::new();
            let mut seen = std::collections::HashSet::new();
            let deadline = until + Duration::from_secs(1);
            loop {
                let d = match tokio::time::timeout_at(deadline.into(), s.recv_datagram(PING)).await {
                    Ok(Ok(Some(d))) => d,
                    _ => break,
                };
                if d.len() < 17 {
                    continue;
                }
                let n = u64::from_be_bytes(d[1..9].try_into().unwrap());
                let sent = u64::from_be_bytes(d[9..17].try_into().unwrap());
                if seen.insert(n) {
                    rtts.push((micros_now().saturating_sub(sent)) as f64 / 1e3);
                }
            }
            rtts
        })
    };
    let pinger = {
        let s = s.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            for n in 0..pings {
                tick.tick().await;
                let mut p = Vec::with_capacity(16);
                p.extend_from_slice(&n.to_be_bytes());
                p.extend_from_slice(&micros_now().to_be_bytes());
                let _ = s.send_datagram(PING, &p);
            }
        })
    };
    let sent_load = Arc::new(AtomicU64::new(0));
    let loader = {
        let (s, sent_load) = (s.clone(), sent_load.clone());
        tokio::spawn(async move {
            if load_mbps <= 0.0 {
                return;
            }
            let per_ms = load_mbps * 1e6 / 8.0 / (LOAD_SIZE + 1) as f64 / 1000.0;
            let payload = vec![0u8; LOAD_SIZE];
            let mut tick = tokio::time::interval(Duration::from_millis(1));
            let start = Instant::now();
            let mut sent = 0u64;
            while Instant::now() < until {
                tick.tick().await;
                let due = (start.elapsed().as_secs_f64() * 1000.0 * per_ms) as u64;
                while sent < due {
                    if s.send_datagram(LOAD, &payload).is_ok() {
                        sent_load.fetch_add(1, Ordering::Relaxed);
                    }
                    sent += 1;
                }
            }
        })
    };
    let mut lines = tokio::time::interval(Duration::from_secs(5));
    lines.tick().await;
    while Instant::now() < until {
        tokio::select! {
            _ = lines.tick() => println!("link: {}", s.stats().line()),
            _ = tokio::time::sleep_until(until.into()) => {}
        }
    }
    pinger.await.unwrap();
    loader.await.unwrap();
    let mut rtts = echo.await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    if video {
        println!("link: {}", s.stats().line());
    }
    s.send_control(&json!({"t": "load.report"})).await.unwrap();
    let report = loop {
        let m = s.recv_control().await.expect("load.report");
        if m["t"] == "load.report" {
            break m;
        }
    };
    let received = report["datagrams"].as_u64().unwrap_or(0);
    let sent = sent_load.load(Ordering::Relaxed);
    let st = s.stats();
    println!(
        "datagram ping: {} sent, {} back ({:.1} % lost), rtt p50 {:.2} ms p90 {:.2} ms p99 {:.2} ms",
        pings,
        rtts.len(),
        100.0 * (pings as f64 - rtts.len() as f64) / pings.max(1) as f64,
        pct(&mut rtts, 0.5),
        pct(&mut rtts, 0.9),
        pct(&mut rtts, 0.99)
    );
    println!(
        "load: {:.1} Mbps offered, {} datagrams queued, {} received ({:.1} % lost), {:.1} Mbps delivered; transport lost {} packets",
        load_mbps,
        sent,
        received,
        100.0 * (sent as f64 - received as f64) / sent.max(1) as f64,
        report["bytes"].as_u64().unwrap_or(0) as f64 * 8.0 / seconds / 1e6,
        st.packets_lost,
    );
    println!("link: {}", st.line());
    s.close(uu_link::CloseCode::Normal, "done").await;
    if let Some(t) = video_task {
        let (frames, bytes, inputs, acked) = t.await.unwrap();
        println!(
            "video: {frames} frames delivered ({:.1} fps, {:.1} Mbps of video); input {inputs} sent, {acked} acked",
            frames as f64 / seconds,
            bytes as f64 * 8.0 / seconds / 1e6
        );
    }
    ep.close().await;
}

/// The server's half of `--video`: 60 fps synthetic frames sized to the media layer's encoder target (a key frame
/// first and whenever asked), until the session ends.
async fn synthetic_video(s: Session) {
    use uu_link::media::{Codec, FrameKind, FrameMeta, ServerEvent};
    s.open_video(1);
    let mut encoder_bps = 3_000_000u64;
    let mut key = true;
    let mut tick = tokio::time::interval(Duration::from_micros(16_667));
    loop {
        tokio::select! {
            ev = s.recv_server_event() => match ev {
                Some(ServerEvent::TargetBitrate { encoder_bps: e, .. }) => encoder_bps = e.max(100_000),
                Some(ServerEvent::RecoveryNeeded { .. }) | Some(ServerEvent::KeyframeNeeded { .. }) => key = true,
                Some(_) => {}
                None => return,
            },
            _ = tick.tick() => {
                if s.is_closed() {
                    return;
                }
                if !s.can_send_frame(1).unwrap_or(false) {
                    continue;
                }
                let size = (encoder_bps / 8 / 60) as usize * if key { 4 } else { 1 };
                let meta = FrameMeta {
                    codec: Codec::H264,
                    kind: if key { FrameKind::Key } else { FrameKind::Delta },
                    width: 1920,
                    height: 1080,
                    capture_us: 0,
                    recovery_base: 0,
                    au_len: 0,
                };
                if s.send_frame(1, meta, &vec![0x42u8; size.max(16)]).is_ok() {
                    key = false;
                }
            }
        }
    }
}

/// `--screen-clip`'s video: the clip's access units at 30 fps on stream `id`, looped from its key frame (and from there
/// again whenever the client asks for a key frame), until another stream replaces it, it is closed or the session ends.
async fn clip_video(s: Session, id: u8, clip: Arc<Clip>, playing: Arc<AtomicU64>) {
    use uu_link::media::{Codec, FrameKind, FrameMeta, ServerEvent};
    s.open_video(id);
    let mut at = 0usize;
    let mut tick = tokio::time::interval(Duration::from_micros(33_333));
    loop {
        tokio::select! {
            ev = s.recv_server_event() => match ev {
                Some(ServerEvent::RecoveryNeeded { stream, .. }) | Some(ServerEvent::KeyframeNeeded { stream }) if stream == id => at = 0,
                Some(_) => {}
                None => return,
            },
            _ = tick.tick() => {
                if s.is_closed() || playing.load(Ordering::Relaxed) != id as u64 {
                    return;
                }
                if !s.can_send_frame(id).unwrap_or(false) {
                    continue;
                }
                let (key, au) = &clip.frames[at];
                let meta = FrameMeta {
                    codec: Codec::H264,
                    kind: if *key { FrameKind::Key } else { FrameKind::Delta },
                    width: clip.width,
                    height: clip.height,
                    capture_us: micros_now(),
                    recovery_base: 0,
                    au_len: 0,
                };
                if s.send_frame(id, meta, au).is_ok() {
                    at = (at + 1) % clip.frames.len();
                }
            }
        }
    }
}

fn micros_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_micros() as u64
}
