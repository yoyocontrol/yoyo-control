//! A STUN binding request (RFC 8489) from the rtc socket, for the server's own public address: the answer's
//! server-reflexive candidate. Only what that needs: the request, and XOR-MAPPED-ADDRESS (or MAPPED-ADDRESS) out of
//! a success response.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

const MAGIC: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const MAPPED_ADDRESS: u16 = 0x0001;
const XOR_MAPPED_ADDRESS: u16 = 0x0020;

/// A binding request with transaction id `tid`.
pub(crate) fn request(tid: [u8; 12]) -> Vec<u8> {
    let mut m = Vec::with_capacity(20);
    m.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    m.extend_from_slice(&0u16.to_be_bytes());
    m.extend_from_slice(&MAGIC.to_be_bytes());
    m.extend_from_slice(&tid);
    m
}

/// The transaction id of a binding success response.
pub(crate) fn success_tid(packet: &[u8]) -> Option<[u8; 12]> {
    if packet.len() < 20
        || u16::from_be_bytes([packet[0], packet[1]]) != BINDING_SUCCESS
        || u32::from_be_bytes(packet[4..8].try_into().ok()?) != MAGIC
    {
        return None;
    }
    packet[8..20].try_into().ok()
}

/// The mapped address in a binding success response.
pub(crate) fn mapped_address(packet: &[u8]) -> Option<SocketAddr> {
    let tid = success_tid(packet)?;
    let len = u16::from_be_bytes([packet[2], packet[3]]) as usize;
    let body = packet.get(20..20 + len)?;
    let mut plain = None;
    let mut at = 0;
    while at + 4 <= body.len() {
        let t = u16::from_be_bytes([body[at], body[at + 1]]);
        let l = u16::from_be_bytes([body[at + 2], body[at + 3]]) as usize;
        let v = body.get(at + 4..at + 4 + l)?;
        match t {
            XOR_MAPPED_ADDRESS => return address(v, Some(&tid)),
            MAPPED_ADDRESS => plain = address(v, None),
            _ => {}
        }
        at += 4 + l.div_ceil(4) * 4;
    }
    plain
}

fn address(v: &[u8], xor: Option<&[u8; 12]>) -> Option<SocketAddr> {
    if v.len() < 8 {
        return None;
    }
    let magic = MAGIC.to_be_bytes();
    let mut port = u16::from_be_bytes([v[2], v[3]]);
    if xor.is_some() {
        port ^= (MAGIC >> 16) as u16;
    }
    let ip = match v[1] {
        1 => {
            let mut o: [u8; 4] = v[4..8].try_into().ok()?;
            if xor.is_some() {
                for (b, m) in o.iter_mut().zip(magic) {
                    *b ^= m;
                }
            }
            IpAddr::V4(Ipv4Addr::from(o))
        }
        2 if v.len() >= 20 => {
            let mut o: [u8; 16] = v[4..20].try_into().ok()?;
            if let Some(tid) = xor {
                let key: Vec<u8> = magic.iter().chain(tid.iter()).copied().collect();
                for (b, m) in o.iter_mut().zip(key) {
                    *b ^= m;
                }
            }
            IpAddr::V6(Ipv6Addr::from(o))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

#[cfg(test)]
pub(crate) fn success(tid: [u8; 12], mapped: SocketAddr) -> Vec<u8> {
    let magic = MAGIC.to_be_bytes();
    let mut v = vec![0u8, if mapped.is_ipv4() { 1 } else { 2 }];
    v.extend_from_slice(&(mapped.port() ^ (MAGIC >> 16) as u16).to_be_bytes());
    match mapped.ip() {
        IpAddr::V4(ip) => v.extend(ip.octets().iter().zip(magic).map(|(b, m)| b ^ m)),
        IpAddr::V6(ip) => v.extend(ip.octets().iter().zip(magic.iter().chain(tid.iter())).map(|(b, m)| b ^ m)),
    }
    let mut m = Vec::new();
    m.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
    m.extend_from_slice(&((4 + v.len()) as u16).to_be_bytes());
    m.extend_from_slice(&magic);
    m.extend_from_slice(&tid);
    m.extend_from_slice(&XOR_MAPPED_ADDRESS.to_be_bytes());
    m.extend_from_slice(&(v.len() as u16).to_be_bytes());
    m.extend_from_slice(&v);
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let tid = [9u8; 12];
        assert_eq!(request(tid).len(), 20);
        for a in ["203.0.113.7:47821", "[2001:db8::7]:5000"] {
            let a: SocketAddr = a.parse().unwrap();
            let r = success(tid, a);
            assert_eq!(success_tid(&r), Some(tid));
            assert_eq!(mapped_address(&r), Some(a));
        }
        assert!(mapped_address(&request(tid)).is_none());
        assert!(mapped_address(&[0u8; 10]).is_none());
    }
}
