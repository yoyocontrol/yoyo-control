//! The link key and its binding to the server's identity (docs/LINK.md「Identity」).
//!
//! A server's identity is its P-256 key (`fp = "sha256:" + hex(SHA-256(04‖X‖Y))`, the key phones pin). The link key
//! is an Ed25519 key (its public key is the endpoint id). The binding is the identity's signature over the link key:
//! a client that knows `fp` checks `SHA-256(key) == fp` and the signature, then trusts `id`.

use std::{fs, io::Write, path::Path};

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use data_encoding::HEXLOWER;
use ring::{
    rand::SystemRandom,
    signature::{self, EcdsaKeyPair, KeyPair, UnparsedPublicKey},
};
use serde::{Deserialize, Serialize};

use crate::error::{LinkError, Result};

/// What the identity signs: this, then the 32 raw bytes of the link public key.
pub const BINDING_CONTEXT: &[u8] = b"yoyocontrol-link-v1:";
/// The identity key file's format: X9.63 private key, 04 ‖ X ‖ Y ‖ D.
pub const IDENTITY_KEY_LEN: usize = 97;

/// `{"id": hex(ed25519 pub), "key": b64(P-256 pub, 65 bytes), "sig": b64(r‖s)}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Binding {
    pub id: String,
    pub key: String,
    pub sig: String,
}

/// `"sha256:" + hex(SHA-256(public key X9.63))`.
pub fn fingerprint(public_key_x963: &[u8]) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, public_key_x963);
    format!("sha256:{}", HEXLOWER.encode(digest.as_ref()))
}

/// The fingerprint of the identity in a 97-byte X9.63 private key.
pub fn identity_fingerprint(identity_key: &[u8]) -> Result<String> {
    let (public, _) = split_identity(identity_key)?;
    Ok(fingerprint(public))
}

fn split_identity(identity_key: &[u8]) -> Result<(&[u8], &[u8])> {
    if identity_key.len() != IDENTITY_KEY_LEN || identity_key[0] != 0x04 {
        return Err(LinkError::Binding(format!(
            "identity key: want {IDENTITY_KEY_LEN} bytes of X9.63 (04 ‖ X ‖ Y ‖ D), got {}",
            identity_key.len()
        )));
    }
    Ok((&identity_key[..65], &identity_key[65..]))
}

fn message(link_public: &[u8; 32]) -> Vec<u8> {
    let mut m = Vec::with_capacity(BINDING_CONTEXT.len() + 32);
    m.extend_from_slice(BINDING_CONTEXT);
    m.extend_from_slice(link_public);
    m
}

/// Signs `link_public` with the identity (the 97-byte X9.63 private key of the identity files).
pub fn sign_binding(identity_key: &[u8], link_public: &[u8; 32]) -> Result<Binding> {
    let (public, private) = split_identity(identity_key)?;
    let rng = SystemRandom::new();
    let pair = EcdsaKeyPair::from_private_key_and_public_key(
        &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        private,
        public,
        &rng,
    )
    .map_err(|e| LinkError::Binding(format!("identity key rejected: {e}")))?;
    debug_assert_eq!(pair.public_key().as_ref(), public);
    let sig = pair.sign(&rng, &message(link_public)).map_err(|e| LinkError::Binding(format!("sign: {e}")))?;
    Ok(Binding { id: HEXLOWER.encode(link_public), key: B64.encode(public), sig: B64.encode(sig.as_ref()) })
}

/// `sign_binding` with any identity signer (`rtc::IdentitySigner`: the key file, or a key held elsewhere).
pub fn sign_binding_with(identity: &dyn crate::rtc::IdentitySigner, link_public: &[u8; 32]) -> Result<Binding> {
    let public = identity.public_key();
    let sig = identity.sign(&message(link_public))?;
    Ok(Binding { id: HEXLOWER.encode(link_public), key: B64.encode(public), sig: B64.encode(sig) })
}

/// Checks a binding against the fingerprint the client pinned; returns the link public key it vouches for.
pub fn verify_binding(binding: &Binding, fingerprint_pin: &str) -> Result<[u8; 32]> {
    let key = B64.decode(binding.key.as_bytes()).map_err(|_| LinkError::Binding("key is not base64".into()))?;
    if key.len() != 65 || key[0] != 0x04 {
        return Err(LinkError::Binding("key is not a 65-byte X9.63 P-256 key".into()));
    }
    if fingerprint(&key) != fingerprint_pin.trim().to_ascii_lowercase() {
        return Err(LinkError::Binding("key does not match the pinned fingerprint".into()));
    }
    let id = parse_endpoint_id(&binding.id)?;
    let sig = B64.decode(binding.sig.as_bytes()).map_err(|_| LinkError::Binding("sig is not base64".into()))?;
    UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, &key)
        .verify(&message(&id), &sig)
        .map_err(|_| LinkError::Binding("signature does not verify".into()))?;
    Ok(id)
}

/// 64 lowercase hex digits → 32 bytes.
pub fn parse_endpoint_id(id: &str) -> Result<[u8; 32]> {
    let bytes = HEXLOWER
        .decode(id.trim().to_ascii_lowercase().as_bytes())
        .map_err(|_| LinkError::InvalidArgument(format!("endpoint id is not hex: {id}")))?;
    bytes.try_into().map_err(|_| LinkError::InvalidArgument(format!("endpoint id is not 32 bytes: {id}")))
}

/// A new random link secret key (Ed25519, 32 bytes).
pub fn generate_link_key() -> [u8; 32] {
    iroh::SecretKey::generate().to_bytes()
}

/// The public key (endpoint id bytes) of a link secret key.
pub fn link_public_key(secret: &[u8; 32]) -> [u8; 32] {
    *iroh::SecretKey::from_bytes(secret).public().as_bytes()
}

/// The link secret key in `path` (32 raw bytes, 0600), made on first use. A file of the wrong size is an error, not
/// replaced: the key is never rotated except together with the identity.
pub fn load_or_create_link_key(path: &Path) -> Result<[u8; 32]> {
    match fs::read(path) {
        Ok(bytes) => {
            return bytes.try_into().map_err(|_| LinkError::Io(format!("{}: not a 32-byte link key", path.display())));
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(LinkError::Io(format!("{}: {e}", path.display()))),
    }
    let key = generate_link_key();
    let tmp = path.with_extension("tmp");
    let write = || -> std::io::Result<()> {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(&key)?;
        f.sync_all()?;
        fs::rename(&tmp, path)
    };
    write().map_err(|e| LinkError::Io(format!("{}: {e}", path.display())))?;
    Ok(key)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A P-256 identity key (X9.63, 97 bytes) made with Node's crypto the way the identity files are, and a binding
    /// Node signed with it over 32 × 0x07 (cross-checks the format with another implementation).
    const NODE_KEY_HEX: &str = "046bc5766fbfe96fc522ac07c730f0376a1140560d35e9c3ba3fc81e62613dc3992e6e15eabdacb3b33ef7a7b5c1b581e2015d66775c209b8c76276e4a7957abde90971831715dcc0fd2868a93503a71e68128b546aa4689d2a9d66bde72306cbb";
    const NODE_FP: &str = "sha256:6f84c42a48cbf5dddf36d44e235ea38dff8045ac86ef98a4de76b77c71c6042f";
    const NODE_KEY_B64: &str =
        "BGvFdm+/6W/FIqwHxzDwN2oRQFYNNenDuj/IHmJhPcOZLm4V6r2ss7M+96e1wbWB4gFdZndcIJuMdiduSnlXq94=";
    const NODE_SIG_B64: &str =
        "gubw92P81iSIw2CwzpDvIoEWVY+qGSg5OshCE9CF06iUr85gS1idO+BkiTL2WE6/HD69szGKnkunNelH1mD8Ow==";

    #[test]
    fn interop_with_node() {
        let key = HEXLOWER.decode(NODE_KEY_HEX.as_bytes()).unwrap();
        assert_eq!(identity_fingerprint(&key).unwrap(), NODE_FP);
        let node = Binding { id: HEXLOWER.encode(&[7u8; 32]), key: NODE_KEY_B64.into(), sig: NODE_SIG_B64.into() };
        assert_eq!(verify_binding(&node, NODE_FP).unwrap(), [7u8; 32]);
        let ours = sign_binding(&key, &[7u8; 32]).unwrap();
        assert_eq!(ours.key, NODE_KEY_B64);
        assert_eq!(verify_binding(&ours, NODE_FP).unwrap(), [7u8; 32]);
    }

    #[test]
    fn sign_then_verify() {
        let id = test_identity();
        let fp = identity_fingerprint(&id).unwrap();
        let link = link_public_key(&generate_link_key());
        let b = sign_binding(&id, &link).unwrap();
        assert_eq!(verify_binding(&b, &fp).unwrap(), link);
        // the pin is compared case-insensitively, trimmed
        assert!(verify_binding(&b, &format!(" {} ", fp.to_uppercase().replace("SHA256", "sha256"))).is_ok());
    }

    #[test]
    fn verify_rejects() {
        let id = test_identity();
        let fp = identity_fingerprint(&id).unwrap();
        let link = link_public_key(&generate_link_key());
        let b = sign_binding(&id, &link).unwrap();
        // another key's pin
        let other_fp = identity_fingerprint(&test_identity()).unwrap();
        assert!(verify_binding(&b, &other_fp).is_err());
        // a swapped id
        let mut swapped = b.clone();
        swapped.id = HEXLOWER.encode(&link_public_key(&generate_link_key()));
        assert!(verify_binding(&swapped, &fp).is_err());
        // a broken signature
        let mut broken = b.clone();
        let mut sig = B64.decode(&broken.sig).unwrap();
        sig[10] ^= 1;
        broken.sig = B64.encode(sig);
        assert!(verify_binding(&broken, &fp).is_err());
        // garbage
        assert!(sign_binding(&[4u8; 10], &link).is_err());
    }

    #[test]
    fn link_key_file() {
        let dir = std::env::temp_dir().join(format!("uu-link-key-{}", rand::random::<u64>()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("link-key");
        let a = load_or_create_link_key(&path).unwrap();
        let b = load_or_create_link_key(&path).unwrap();
        assert_eq!(a, b);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        fs::write(&path, b"short").unwrap();
        assert!(load_or_create_link_key(&path).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }

    /// A fresh identity key in the identity files' format (X9.63 04 ‖ X ‖ Y ‖ D), built from a PKCS#8 document.
    pub fn test_identity() -> Vec<u8> {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        let public = pair.public_key().as_ref().to_vec();
        // ring's PKCS#8 v1 document for P-256: the private scalar follows `04 20` inside the ECPrivateKey
        let doc = pkcs8.as_ref();
        let at = doc.windows(2).position(|w| w == [0x04, 0x20]).unwrap() + 2;
        let mut key = public;
        key.extend_from_slice(&doc[at..at + 32]);
        key
    }
}
