//! Frame → blocks → shards, the parity policy (LINK.md §5.3) and Reed-Solomon over a block's data shards.

use crate::wire::{MAX_DATA_SHARDS, MAX_PARITY_SHARDS, VideoHeader};

/// One block of a frame: `len` bytes from `offset`, cut into `k` shards of `shard_size` (the last zero-padded).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockPlan {
    pub offset: usize,
    pub len: usize,
    pub k: usize,
    pub shard_size: usize,
}

/// Largest even shard payload that fits a datagram of `max_datagram` bytes.
pub fn max_shard_size(max_datagram: usize) -> usize {
    max_datagram.saturating_sub(VideoHeader::LEN) & !1
}

/// Most frame bytes one frame can carry with this shard size (256 blocks of 32 shards).
pub fn max_frame_bytes(max_shard: usize) -> usize {
    256 * MAX_DATA_SHARDS * max_shard
}

/// Split `total` frame bytes into blocks of ≤ 32 data shards of at most `max_shard` bytes.
///
/// A one-block frame (the common case) gets even shards: `shard_size = ceil(total / k)` rounded up to even, the
/// last shard zero-padded. With several blocks, every block but the last is exactly full (`k × max_shard` bytes, no
/// padding — so the receiver just concatenates blocks) and the shards are spread evenly over the blocks; the last
/// block gets the rest with even shards. None when `total` is 0, `max_shard < 2`, or the frame is too large.
pub fn plan_blocks(total: usize, max_shard: usize) -> Option<Vec<BlockPlan>> {
    let max_shard = max_shard & !1;
    if total == 0 || max_shard < 2 || total > max_frame_bytes(max_shard) {
        return None;
    }
    let shards = total.div_ceil(max_shard);
    let nblocks = shards.div_ceil(MAX_DATA_SHARDS);
    let mut out = Vec::with_capacity(nblocks);
    let (mut shards_left, mut offset) = (shards, 0usize);
    for i in 0..nblocks {
        if i + 1 == nblocks {
            let len = total - offset;
            let k = len.div_ceil(max_shard);
            let shard_size = (len.div_ceil(k) + 1) & !1;
            out.push(BlockPlan { offset, len, k, shard_size: shard_size.min(max_shard) });
        } else {
            let k = shards_left.div_ceil(nblocks - i);
            let len = k * max_shard;
            out.push(BlockPlan { offset, len, k, shard_size: max_shard });
            shards_left -= k;
            offset += len;
        }
    }
    Some(out)
}

/// The parity policy (LINK.md §5.3).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FecPolicy {
    /// Base parity ratio.
    pub base: f64,
    /// Ratio per unit of pre-FEC loss.
    pub loss_gain: f64,
    pub min_ratio: f64,
    pub max_ratio: f64,
    /// Extra ratio for key frames.
    pub key_extra: f64,
    /// Loss above which every block gets at least one parity shard.
    pub loss_floor: f64,
    /// Above `loss_floor`, at least the parity that keeps a block's chance of failing (more of its `k + m`
    /// shards lost than `m`, losses independent at the measured rate) at or below this. The ratio alone leaves
    /// small blocks short at heavy loss: at 15 % a 5-shard block with 3 parity fails 2 % of the time, a frame
    /// every half second at 60 fps, each one a recovery (where recovery means a key frame, a blurry one at a low
    /// rate). NACKs can't step in where the round trip is longer than the frame's deadline.
    pub residual: f64,
}

impl Default for FecPolicy {
    fn default() -> FecPolicy {
        FecPolicy {
            base: 0.05,
            loss_gain: 2.5,
            min_ratio: 0.05,
            max_ratio: 0.5,
            key_extra: 0.10,
            loss_floor: 0.005,
            residual: 0.01,
        }
    }
}

impl FecPolicy {
    /// `r = clamp(5 % + 2.5 × loss, 5 %, 50 %)`.
    pub fn ratio(&self, loss: f64) -> f64 {
        (self.base + self.loss_gain * loss.max(0.0)).clamp(self.min_ratio, self.max_ratio)
    }

    /// Parity shards for a block of `k` data shards: `ceil(k × r)` (+10 % for key frames), at least one when loss is
    /// above 0.5 % or the frame is a key / recovery frame; none for a single-shard delta frame when there is no loss.
    pub fn parity(&self, k: usize, loss: f64, key: bool, recovery: bool, single_shard_frame: bool) -> usize {
        if single_shard_frame && !key && !recovery && loss <= 0.0 {
            return 0;
        }
        let r = self.ratio(loss) + if key { self.key_extra } else { 0.0 };
        let mut m = (k as f64 * r - 1e-9).ceil().max(0.0) as usize;
        if (loss > self.loss_floor || key || recovery) && m == 0 {
            m = 1;
        }
        // (beyond 30 % no parity carries it: the rate controller calls that congestion)
        if loss > self.loss_floor && loss <= 0.3 {
            while m < MAX_PARITY_SHARDS && m < 2 * k && block_failure(k, m, loss) > self.residual {
                m += 1;
            }
        }
        m.min(MAX_PARITY_SHARDS)
    }
}

/// The chance a block of `k` data and `m` parity shards can't be decoded: more than `m` of its `k + m` shards
/// lost, each independently with probability `p`.
pub fn block_failure(k: usize, m: usize, p: f64) -> f64 {
    let n = k + m;
    let p = p.clamp(0.0, 1.0);
    // P(X ≤ m) for X ~ Binomial(n, p), term by term
    let mut term = (1.0 - p).powi(n as i32); // P(X = 0)
    let mut ok = term;
    for i in 1..=m.min(n) {
        term *= (n - i + 1) as f64 / i as f64 * p / (1.0 - p).max(1e-12);
        ok += term;
    }
    (1.0 - ok).max(0.0)
}

/// Parity shards for `data` (all the same even length). Empty when `m` is 0.
pub fn encode_parity(data: &[Vec<u8>], m: usize) -> Vec<Vec<u8>> {
    if m == 0 || data.is_empty() {
        return Vec::new();
    }
    // Shard counts and sizes are checked by the caller (k ≤ 32, m ≤ 32, even non-zero size), all supported.
    reed_solomon_simd::encode(data.len(), m, data).unwrap_or_default()
}

/// Recover the `k` data shards from any `k` of `k + m` (`shards[i]` = shard `i`, data first). None if not enough
/// shards or the decoder refused them.
pub fn recover(k: usize, m: usize, shards: &[Option<Vec<u8>>]) -> Option<Vec<Vec<u8>>> {
    if shards.len() != k + m {
        return None;
    }
    if shards[..k].iter().all(|s| s.is_some()) {
        return Some(shards[..k].iter().map(|s| s.clone().unwrap_or_default()).collect());
    }
    if m == 0 {
        return None;
    }
    let original = shards[..k].iter().enumerate().filter_map(|(i, s)| s.as_ref().map(|s| (i, s)));
    let parity = shards[k..].iter().enumerate().filter_map(|(i, s)| s.as_ref().map(|s| (i, s)));
    let restored = reed_solomon_simd::decode(k, m, original, parity).ok()?;
    let mut out = Vec::with_capacity(k);
    for (i, s) in shards[..k].iter().enumerate() {
        match s {
            Some(s) => out.push(s.clone()),
            None => out.push(restored.get(&i)?.clone()),
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_cover_the_frame() {
        for max_shard in [2usize, 100, 1180] {
            for total in
                [1usize, 2, 3, 99, 100, 101, 1180, 1181, 31 * 1180 + 5, 32 * 1180, 32 * 1180 + 1, 100_000, 400_000]
            {
                let Some(plan) = plan_blocks(total, max_shard) else {
                    assert!(total > max_frame_bytes(max_shard));
                    continue;
                };
                let mut off = 0;
                for (i, b) in plan.iter().enumerate() {
                    assert_eq!(b.offset, off);
                    assert!(b.k >= 1 && b.k <= MAX_DATA_SHARDS, "{total} {max_shard} {b:?}");
                    assert!(b.shard_size % 2 == 0 && b.shard_size <= max_shard && b.shard_size > 0);
                    assert!(b.k * b.shard_size >= b.len);
                    assert!((b.k - 1) * b.shard_size < b.len);
                    if i + 1 < plan.len() {
                        assert_eq!(b.k * b.shard_size, b.len, "non-last blocks are full");
                    }
                    off += b.len;
                }
                assert_eq!(off, total);
                assert!(plan.len() <= 256);
            }
        }
        assert!(plan_blocks(0, 100).is_none());
        assert!(plan_blocks(10, 1).is_none());
        // one shard of 1001 bytes is padded to 1002
        assert_eq!(plan_blocks(1001, 1180).unwrap()[0].shard_size, 1002);
        // 3 shards spread evenly
        assert_eq!(plan_blocks(2400, 1180).unwrap()[0], BlockPlan { offset: 0, len: 2400, k: 3, shard_size: 800 });
    }

    #[test]
    fn policy() {
        let p = FecPolicy::default();
        assert_eq!(p.ratio(0.0), 0.05);
        assert!((p.ratio(0.04) - 0.15).abs() < 1e-12);
        assert_eq!(p.ratio(0.5), 0.5);
        assert_eq!(p.parity(1, 0.0, false, false, true), 0);
        assert_eq!(p.parity(1, 0.0, true, false, true), 1);
        assert_eq!(p.parity(1, 0.001, false, false, true), 1);
        assert_eq!(p.parity(20, 0.0, false, false, false), 1);
        // the ratio's 3 would fail 1.4 % of the time
        assert_eq!(p.parity(20, 0.04, false, false, false), 4);
        // heavy random loss: small blocks get what keeps their failure ≤ 1 % (the ratio's 1 and 3: 2.3 %, 2.1 %)
        assert_eq!(p.parity(1, 0.15, false, false, true), 2);
        assert_eq!(p.parity(5, 0.15, false, false, false), 4);
        assert!(block_failure(5, 4, 0.15) <= 0.01 && block_failure(5, 3, 0.15) > 0.02);
        assert_eq!(p.parity(20, 0.0, true, false, false), 3);
        assert_eq!(p.parity(32, 1.0, true, false, false), 20);
    }

    #[test]
    fn recovers_any_k() {
        let k = 5;
        let m = 3;
        let data: Vec<Vec<u8>> = (0..k).map(|i| (0..64).map(|j| (i * 31 + j) as u8).collect()).collect();
        let parity = encode_parity(&data, m);
        assert_eq!(parity.len(), m);
        let all: Vec<Vec<u8>> = data.iter().chain(parity.iter()).cloned().collect();
        // drop every combination of m shards
        for a in 0..k + m {
            for b in a + 1..k + m {
                for c in b + 1..k + m {
                    let shards: Vec<Option<Vec<u8>>> =
                        all.iter().enumerate().map(|(i, s)| (i != a && i != b && i != c).then(|| s.clone())).collect();
                    assert_eq!(recover(k, m, &shards).unwrap(), data);
                }
            }
        }
        let mut too_few: Vec<Option<Vec<u8>>> = all.iter().cloned().map(Some).collect();
        for s in too_few.iter_mut().take(4) {
            *s = None;
        }
        assert!(recover(k, m, &too_few).is_none());
    }
}
