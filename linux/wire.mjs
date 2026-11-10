// The bytes on the wire (README.md「流的格式」): the media type names (the reference server's StreamWire.swift), one
// multipart part, and the records of yoyo-x11video's stdout.

export const WIRE = Object.freeze({
  current: Object.freeze({
    boundary: "frame",
    stream: "application/vnd.yoyo-control.stream; boundary=frame",
    audio: "application/vnd.yoyo-control.audio; boundary=frame",
    cursor: "application/vnd.yoyo-control.cursor+json",
    status: "application/vnd.yoyo-control.status+json",
  }),
});

/**
 * The names a stream or the sound goes out with: always `current` (the pre-release names of before Yoyo Control are
 * gone since 0.2.0; `Accept` is no longer looked at).
 */
export function negotiate() {
  return WIRE.current;
}

/**
 * One part: `--<boundary>`, its headers, the body, CRLF. A picture has `size`, `codec`; a cursor or status part
 * neither.
 */
export function streamPart({ boundary, contentType, body, size, seq, time, kind, codec }) {
  let head = `--${boundary}\r\nContent-Type: ${contentType}\r\nContent-Length: ${body.length}\r\n`;
  if (size) head += `X-Frame-Width: ${size[0]}\r\nX-Frame-Height: ${size[1]}\r\n`;
  head += `X-Frame-Seq: ${seq}\r\n`;
  if (time != null) head += `X-Frame-Time: ${Math.round(time)}\r\n`;
  head += `X-Frame-Kind: ${kind}\r\n`;
  if (codec) head += `X-Stream-Codec: ${codec}\r\n`;
  head += "\r\n";
  return Buffer.concat([Buffer.from(head, "latin1"), body, Buffer.from("\r\n")]);
}

/**
 * yoyo-x11video's records, from its stdout in chunks split anywhere: `{ type: "H", width, height }`, `{ type: "C" }`,
 * `{ type: "F", key, changed, time, au }`, `{ type: "S" }`, `{ type: "P", x, y, serial, xhot, yhot, w, h, visible,
 * none, pixels? }` (the pointer, `--cursor client`; `pixels`: premultiplied RGBA). A record larger than `max` is a
 * broken helper: throws.
 */
export class RecordReader {
  constructor(max = 32 * 1024 * 1024) {
    this.max = max;
    this.buf = Buffer.alloc(0);
  }

  feed(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    const out = [];
    while (this.buf.length >= 5) {
      const len = this.buf.readUInt32BE(1);
      if (len > this.max) throw new Error(`video helper: a record of ${len} bytes`);
      if (this.buf.length < 5 + len) break;
      const type = String.fromCharCode(this.buf[0]);
      const body = this.buf.subarray(5, 5 + len);
      this.buf = this.buf.subarray(5 + len);
      if (type === "H" && len >= 4) out.push({ type, width: body.readUInt16BE(0), height: body.readUInt16BE(2) });
      else if (type === "C" || type === "S") out.push({ type });
      else if (type === "F" && len > 9) {
        out.push({ type, key: (body[0] & 1) !== 0, changed: (body[0] & 2) !== 0, time: body.readDoubleLE(1), au: Buffer.from(body.subarray(9)) });
      } else if (type === "P" && len >= 17) {
        const flags = body[16];
        const p = {
          type,
          x: body.readInt16BE(0),
          y: body.readInt16BE(2),
          serial: body.readUInt32BE(4),
          xhot: body.readUInt16BE(8),
          yhot: body.readUInt16BE(10),
          w: body.readUInt16BE(12),
          h: body.readUInt16BE(14),
          visible: (flags & 1) !== 0,
          none: (flags & 4) !== 0,
        };
        if (flags & 2 && len === 17 + p.w * p.h * 4) p.pixels = Buffer.from(body.subarray(17));
        out.push(p);
      }
    }
    return out;
  }
}

/** The NAL unit types of an Annex-B access unit, in order (H.264: the low 5 bits of each unit's first byte). */
export function nalTypes(au) {
  const types = [];
  for (let i = 0; i + 3 < au.length; i++) {
    if (au[i] === 0 && au[i + 1] === 0 && (au[i + 2] === 1 || (au[i + 2] === 0 && au[i + 3] === 1))) {
      const start = au[i + 2] === 1 ? i + 3 : i + 4;
      if (start < au.length) types.push(au[start] & 0x1f);
      i = start;
    }
  }
  return types;
}
