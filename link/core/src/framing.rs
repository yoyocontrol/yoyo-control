//! `u32 BE length` + UTF-8 JSON object frames (the control stream and the RPC heads).

use serde_json::{Map, Value};

use crate::{
    error::{LinkError, Result},
    transport::{RecvHalf, SendHalf},
};

/// Largest control frame.
pub const MAX_CONTROL_FRAME: usize = 256 * 1024;
/// Largest RPC request / response head.
pub const MAX_RPC_HEAD: usize = 64 * 1024;

pub(crate) fn encode(msg: &Value, max: usize) -> Result<Vec<u8>> {
    if !msg.is_object() {
        return Err(LinkError::InvalidArgument("a frame is a JSON object".into()));
    }
    let body = serde_json::to_vec(msg).map_err(|e| LinkError::InvalidArgument(e.to_string()))?;
    if body.len() > max {
        return Err(LinkError::InvalidArgument(format!("frame of {} bytes is over {max}", body.len())));
    }
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub(crate) async fn write_frame(send: &mut SendHalf, msg: &Value, max: usize) -> Result<()> {
    let bytes = encode(msg, max)?;
    send.write_all(&bytes).await
}

/// The next frame; `None` when the stream ended cleanly between frames.
pub(crate) async fn read_frame(recv: &mut RecvHalf, max: usize) -> Result<Option<Map<String, Value>>> {
    let mut len = [0u8; 4];
    match recv.read(&mut len[..1]).await? {
        None => return Ok(None),
        Some(0) => return Err(LinkError::protocol("empty read")),
        Some(_) => {}
    }
    recv.read_exact(&mut len[1..]).await?;
    let n = u32::from_be_bytes(len) as usize;
    if n > max {
        return Err(LinkError::protocol(format!("frame of {n} bytes is over {max}")));
    }
    let mut body = vec![0u8; n];
    recv.read_exact(&mut body).await?;
    decode(&body).map(Some)
}

pub(crate) fn decode(body: &[u8]) -> Result<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err(LinkError::protocol("frame is not a JSON object")),
        Err(e) => Err(LinkError::protocol(format!("frame is not JSON: {e}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn round_trip_and_limits() {
        let v = json!({"t": "hello", "v": 1});
        let bytes = encode(&v, 1024).unwrap();
        assert_eq!(&bytes[..4], &((bytes.len() - 4) as u32).to_be_bytes());
        assert_eq!(Value::Object(decode(&bytes[4..]).unwrap()), v);
        assert!(encode(&json!([1, 2]), 1024).is_err());
        assert!(encode(&json!({"t": "x".repeat(100)}), 50).is_err());
        assert!(decode(b"[1]").is_err());
        assert!(decode(b"{").is_err());
    }
}
