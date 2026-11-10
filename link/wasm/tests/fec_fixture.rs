//! The FEC cross-check between the native media layer and its wasm build: a key frame as the native `ServerMedia`
//! sends it (data and Reed-Solomon parity shards), with some data shards to drop, written to
//! `tests/fixtures/fec-frame.bin`. This test proves the native `ClientMedia` restores the frame from it; the
//! link-web test (`packages/link-web/test/wasm.test.ts`) feeds the same bytes to the wasm build and must get the same
//! access unit and the same number of FEC-restored shards. The committed file also pins the native sender's bytes:
//! when they change on purpose, regenerate it with `UU_LINK_UPDATE_FIXTURES=1 cargo test -p uu-link-wasm`.
//!
//! Format: `"UUFX1"`, `u32 n`, n × (`u16 len`, datagram), `u16 d`, d × `u16` index of a datagram to drop, `u32 len`,
//! the access unit (all big-endian).

use std::path::PathBuf;

use uu_link_media::{
    ClientConfig, ClientEvent, ClientMedia, Codec, FrameKind, FrameMeta, Micros, ServerConfig, ServerMedia,
    wire::VideoHeader,
};

const FLAG_PARITY: u8 = 0x01;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fec-frame.bin")
}

/// A deterministic access unit: an IDR slice NAL with patterned bytes.
fn access_unit() -> Vec<u8> {
    let mut au = vec![0, 0, 0, 1, 0x65];
    au.extend((0..30_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8 | 1));
    au
}

/// Every datagram the server sends for one key frame, and the indices of the data shards to drop (two of the first
/// block: within what its parity can restore).
fn generate() -> (Vec<Vec<u8>>, Vec<u16>, Vec<u8>) {
    let mut server = ServerMedia::new(ServerConfig::default());
    server.open_video(1);
    let mut now = Micros::from_secs(1);
    server.set_rtt(now, Micros::from_millis(20));
    server.handle_timeout(now);
    let au = access_unit();
    let meta = FrameMeta {
        codec: Codec::H264,
        kind: FrameKind::Key,
        width: 640,
        height: 360,
        capture_us: 1_700_000_000_000_000,
        recovery_base: 0,
        au_len: 0,
    };
    server.send_frame(now, 1, meta, &au).expect("send_frame");
    let mut out = Vec::new();
    while now < Micros::from_secs(3) {
        while let Some(d) = server.poll_transmit(now) {
            out.push(d);
        }
        server.handle_timeout(now);
        now += Micros::from_millis(1);
    }
    let mut drops = Vec::new();
    let mut parity_in_block0 = 0;
    for d in &out {
        if let Ok((h, _)) = VideoHeader::parse(d)
            && h.block == 0
            && h.flags & FLAG_PARITY != 0
        {
            parity_in_block0 += 1;
        }
    }
    for (i, d) in out.iter().enumerate() {
        if let Ok((h, _)) = VideoHeader::parse(d)
            && h.block == 0
            && h.flags & FLAG_PARITY == 0
            && (h.shard == 1 || h.shard == 3)
            && drops.len() < parity_in_block0.min(2)
        {
            drops.push(i as u16);
        }
    }
    (out, drops, au)
}

fn encode(datagrams: &[Vec<u8>], drops: &[u16], au: &[u8]) -> Vec<u8> {
    let mut f = b"UUFX1".to_vec();
    f.extend((datagrams.len() as u32).to_be_bytes());
    for d in datagrams {
        f.extend((d.len() as u16).to_be_bytes());
        f.extend(d);
    }
    f.extend((drops.len() as u16).to_be_bytes());
    for i in drops {
        f.extend(i.to_be_bytes());
    }
    f.extend((au.len() as u32).to_be_bytes());
    f.extend(au);
    f
}

#[test]
fn native_client_restores_the_fixture_frame() {
    let (datagrams, drops, au) = generate();
    assert!(drops.len() == 2, "the first block has room for two lost data shards: {drops:?}");
    let bytes = encode(&datagrams, &drops, &au);
    let path = fixture_path();
    if std::env::var_os("UU_LINK_UPDATE_FIXTURES").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();
    }
    let committed = std::fs::read(&path).expect("fixture (UU_LINK_UPDATE_FIXTURES=1 writes it)");
    assert!(
        committed == bytes,
        "the native sender's datagrams changed: regenerate the fixture with UU_LINK_UPDATE_FIXTURES=1"
    );

    let mut client = ClientMedia::new(ClientConfig::default());
    client.open_video(1);
    let now = Micros::from_secs(1);
    for (i, d) in datagrams.iter().enumerate() {
        if !drops.contains(&(i as u16)) {
            client.handle_datagram(now, d).unwrap();
        }
    }
    let frame = std::iter::from_fn(|| client.poll_event())
        .find_map(|e| match e {
            ClientEvent::Frame(f) => Some(f),
            _ => None,
        })
        .expect("the frame, restored by FEC");
    assert_eq!(frame.au, au);
    assert_eq!(client.stats(now).fec_recovered, drops.len() as u64);
}
