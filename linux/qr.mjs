// A QR code (Model 2, byte mode, error correction M) for the pairing link: the `pair` command prints it in the
// terminal (half blocks) where no qrencode is installed — always on Windows — and writes it as an SVG page there. The
// algorithm after Project Nayuki's QR Code generator (MIT): data codewords, Reed–Solomon blocks interleaved, function
// patterns, the zigzag placement, the mask with the lowest penalty.

// error correction M: EC codewords per block and blocks, by version (index 0 unused)
const ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
const BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
const FORMAT_M = 0;

function rawModules(ver) {
  let r = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const n = Math.floor(ver / 7) + 2;
    r -= (25 * n - 10) * n - 55;
    if (ver >= 7) r -= 36;
  }
  return r;
}

const dataCodewords = (ver) => Math.floor(rawModules(ver) / 8) - ECC_PER_BLOCK[ver] * BLOCKS[ver];

function gfMul(x, y) {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsDivisor(degree) {
  const r = new Array(degree).fill(0);
  r[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < r.length; j++) {
      r[j] = gfMul(r[j], root);
      if (j + 1 < r.length) r[j] ^= r[j + 1];
    }
    root = gfMul(root, 0x02);
  }
  return r;
}

function rsRemainder(data, div) {
  const r = div.map(() => 0);
  for (const b of data) {
    const f = b ^ r.shift();
    r.push(0);
    div.forEach((c, i) => (r[i] ^= gfMul(c, f)));
  }
  return r;
}

function alignmentPositions(ver) {
  if (ver === 1) return [];
  const n = Math.floor(ver / 7) + 2;
  const size = ver * 4 + 17;
  const step = ver === 32 ? 26 : Math.ceil((ver * 4 + 4) / (n * 2 - 2)) * 2;
  const r = [6];
  for (let pos = size - 7; r.length < n; pos -= step) r.splice(1, 0, pos);
  return r;
}

/** The modules of `text`'s QR code (UTF-8, byte mode, level M): rows of booleans (true = dark). */
export function qrMatrix(text) {
  const bytes = [...Buffer.from(text, "utf8")];
  let ver = 1;
  for (; ver <= 40; ver++) {
    const bits = 4 + (ver <= 9 ? 8 : 16) + bytes.length * 8;
    if (bits <= dataCodewords(ver) * 8) break;
  }
  if (ver > 40) throw new Error("too long for a QR code");
  const cap = dataCodewords(ver) * 8;
  const bits = [];
  const put = (v, n) => {
    for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1);
  };
  put(4, 4);
  put(bytes.length, ver <= 9 ? 8 : 16);
  for (const b of bytes) put(b, 8);
  put(0, Math.min(4, cap - bits.length));
  put(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < cap; pad ^= 0xec ^ 0x11) put(pad, 8);
  const data = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));

  // the blocks, each with its EC, interleaved
  const nb = BLOCKS[ver], ecLen = ECC_PER_BLOCK[ver], raw = Math.floor(rawModules(ver) / 8);
  const shortBlocks = nb - (raw % nb), shortLen = Math.floor(raw / nb);
  const div = rsDivisor(ecLen);
  const blocks = [];
  for (let i = 0, k = 0; i < nb; i++) {
    const dat = data.slice(k, k + shortLen - ecLen + (i < shortBlocks ? 0 : 1));
    k += dat.length;
    const ecc = rsRemainder(dat, div);
    if (i < shortBlocks) dat.push(0);
    blocks.push(dat.concat(ecc));
  }
  const words = [];
  for (let i = 0; i < blocks[0].length; i++)
    for (let j = 0; j < blocks.length; j++) if (i !== shortLen - ecLen || j >= shortBlocks) words.push(blocks[j][i]);

  const size = ver * 4 + 17;
  const mod = Array.from({ length: size }, () => new Array(size).fill(false));
  const fn = Array.from({ length: size }, () => new Array(size).fill(false));
  const setF = (x, y, dark) => {
    mod[y][x] = dark;
    fn[y][x] = true;
  };
  for (let i = 0; i < size; i++) {
    setF(6, i, i % 2 === 0);
    setF(i, 6, i % 2 === 0);
  }
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
    for (let dy = -4; dy <= 4; dy++)
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        setF(x, y, d !== 2 && d !== 4);
      }
  }
  const al = alignmentPositions(ver);
  for (let i = 0; i < al.length; i++)
    for (let j = 0; j < al.length; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) setF(al[i] + dx, al[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  const drawFormat = (mask) => {
    const d = (FORMAT_M << 3) | mask;
    let rem = d;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const b = ((d << 10) | rem) ^ 0x5412;
    const bit = (i) => ((b >>> i) & 1) !== 0;
    for (let i = 0; i <= 5; i++) setF(8, i, bit(i));
    setF(8, 7, bit(6));
    setF(8, 8, bit(7));
    setF(7, 8, bit(8));
    for (let i = 9; i < 15; i++) setF(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) setF(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) setF(8, size - 15 + i, bit(i));
    setF(8, size - 8, true);
  };
  drawFormat(0); // reserves the format areas
  if (ver >= 7) {
    let rem = ver;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const b = (ver << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const dark = ((b >>> i) & 1) !== 0;
      const a = size - 11 + (i % 3), c = Math.floor(i / 3);
      setF(a, c, dark);
      setF(c, a, dark);
    }
  }
  // the codewords, zigzag from the bottom right
  let i = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let v = 0; v < size; v++)
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const y = ((right + 1) & 2) === 0 ? size - 1 - v : v;
        if (!fn[y][x] && i < words.length * 8) {
          mod[y][x] = ((words[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0;
          i++;
        }
      }
  }
  const MASKS = [
    (x, y) => (x + y) % 2 === 0,
    (x, y) => y % 2 === 0,
    (x) => x % 3 === 0,
    (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
    (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
    (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
  ];
  const apply = (m) => {
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y][x] && MASKS[m](x, y)) mod[y][x] = !mod[y][x];
  };
  // the penalty's runs (rule 1), 2×2 blocks (rule 2) and balance (rule 4): enough to stay clear of the worst masks
  const penalty = () => {
    let p = 0, dark = 0;
    for (let a = 0; a < size; a++)
      for (const row of [true, false]) {
        let run = 1;
        for (let b = 1; b <= size; b++) {
          const same = b < size && (row ? mod[a][b] === mod[a][b - 1] : mod[b][a] === mod[b - 1][a]);
          if (same) run++;
          else {
            if (run >= 5) p += run - 2;
            run = 1;
          }
        }
      }
    for (let y = 0; y < size; y++)
      for (let x = 0; x < size; x++) {
        if (mod[y][x]) dark++;
        if (x < size - 1 && y < size - 1 && mod[y][x] === mod[y][x + 1] && mod[y][x] === mod[y + 1][x] && mod[y][x] === mod[y + 1][x + 1]) p += 3;
      }
    const total = size * size;
    return p + (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
  };
  let best = 0, bestP = Infinity;
  for (let m = 0; m < 8; m++) {
    apply(m);
    drawFormat(m);
    const p = penalty();
    if (p < bestP) (best = m), (bestP = p);
    apply(m);
  }
  apply(best);
  drawFormat(best);
  return mod;
}

/** The code for a terminal: two rows per line in half blocks, dark on light, a quiet zone of 2. */
export function qrTerminal(text) {
  const m = qrMatrix(text);
  const q = 2, n = m.length;
  const dark = (x, y) => x >= 0 && y >= 0 && x < n && y < n && m[y][x];
  const lines = [];
  for (let y = -q; y < n + q; y += 2) {
    let s = "";
    for (let x = -q; x < n + q; x++) {
      const top = dark(x, y), bottom = dark(x, y + 1);
      // light is the block (white on a dark terminal is the paper)
      s += top && bottom ? " " : top ? "▄" : bottom ? "▀" : "█";
    }
    lines.push(s);
  }
  return lines.join("\n");
}

/** The code as an SVG (a module per unit, a quiet zone of 4). */
export function qrSvg(text, px = 8) {
  const m = qrMatrix(text);
  const n = m.length + 8;
  let path = "";
  for (let y = 0; y < m.length; y++) for (let x = 0; x < m.length; x++) if (m[y][x]) path += `M${x + 4} ${y + 4}h1v1h-1z`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" width="${n * px}" height="${n * px}" shape-rendering="crispEdges"><rect width="${n}" height="${n}" fill="#fff"/><path d="${path}" fill="#000"/></svg>`;
}
