/**
 * How hard the decoder works here, from each picture's decode time (queued → out of `VideoDecoder`, ms), and what the
 * page does about it (pure; `VideoStream` feeds it, the page's session acts):
 *
 * - `DecodeWatch` (one stream): the median of the last `DECODE_WINDOW_MS`. Above `DECODE_SLOW_MS` while the A/V sync
 *   holds pictures back (a floor) for `DECODE_FLOOR_HOLD_MS`: "floor" — the decoder has few output buffers and the
 *   pictures held for the sound use them up (seen on Android: decode 9 ms without the floor, 250 ms with a 300 ms one);
 *   above it without a floor for `DECODE_SLOW_HOLD_MS`: "slow" — it can't keep up with the stream's size and rate;
 *   under `DECODE_EASY_MS` for `DECODE_EASY_HOLD_MS`: "easy". Each verdict once per stream.
 * - `StreamLevels` (the page): the stream's size and rate, `STREAM_LEVELS[index]` (the stream request's `maxWidth` /
 *   `fps`). "slow" steps down; "easy" steps up again after `LEVEL_UP_AFTER_MS` at a level, unless the last step up
 *   turned slow within `LEVEL_UP_FAILED_MS` (then it stays for the visit).
 */

export const DECODE_WINDOW_MS = 1500;
export const DECODE_MIN_SAMPLES = 15;
export const DECODE_SLOW_MS = 80;
export const DECODE_SLOW_HOLD_MS = 3000;
export const DECODE_FLOOR_HOLD_MS = 1000;
export const DECODE_EASY_MS = 30;
export const DECODE_EASY_HOLD_MS = 60_000;

export type DecodeVerdict = "slow" | "floor" | "easy";

export class DecodeWatch {
  private samples: { at: number; ms: number }[] = [];
  private slowSince: number | null = null;
  private floorSince: number | null = null;
  private easySince: number | null = null;
  private said = new Set<DecodeVerdict>();

  /** One picture's decode time `ms`, out at `at`; `floorMs` the A/V sync's hold now. A verdict the first time one holds. */
  add(ms: number, at: number, floorMs: number): DecodeVerdict | null {
    if (!Number.isFinite(ms) || ms < 0) return null;
    this.samples.push({ at, ms });
    while (this.samples.length && at - this.samples[0]!.at > DECODE_WINDOW_MS) this.samples.shift();
    const m = this.median();
    if (m === null) return null;
    const slow = m > DECODE_SLOW_MS;
    const held = slow && floorMs > 0;
    this.floorSince = held ? (this.floorSince ?? at) : null;
    this.slowSince = slow && !held ? (this.slowSince ?? at) : null;
    this.easySince = m < DECODE_EASY_MS ? (this.easySince ?? at) : null;
    if (this.floorSince !== null && at - this.floorSince >= DECODE_FLOOR_HOLD_MS) return this.say("floor");
    if (this.slowSince !== null && at - this.slowSince >= DECODE_SLOW_HOLD_MS) return this.say("slow");
    if (this.easySince !== null && at - this.easySince >= DECODE_EASY_HOLD_MS) return this.say("easy");
    return null;
  }

  /** The window's median decode time (null: fewer than `DECODE_MIN_SAMPLES`). */
  median(): number | null {
    if (this.samples.length < DECODE_MIN_SAMPLES) return null;
    const s = this.samples.map((x) => x.ms).sort((a, b) => a - b);
    return s[Math.floor(s.length / 2)]!;
  }

  private say(v: DecodeVerdict): DecodeVerdict | null {
    if (this.said.has(v)) return null;
    this.said.add(v);
    return v;
  }
}

/** The stream's size and rate, best first. */
export const STREAM_LEVELS: readonly { maxWidth: number; fps: number }[] = [
  { maxWidth: 3840, fps: 60 },
  { maxWidth: 1920, fps: 60 },
  { maxWidth: 1600, fps: 30 },
  { maxWidth: 1280, fps: 30 },
];
export const LEVEL_UP_AFTER_MS = 180_000;
export const LEVEL_UP_FAILED_MS = 60_000;

export class StreamLevels {
  index = 0;
  private changedAt = -Infinity;
  private wentUpAt: number | null = null;
  private upFailed = false;

  get level(): { maxWidth: number; fps: number } {
    return STREAM_LEVELS[this.index]!;
  }

  /** The decoder can't keep up: one level down (false: already the lowest). */
  slow(now: number): boolean {
    if (this.wentUpAt !== null && now - this.wentUpAt < LEVEL_UP_FAILED_MS) this.upFailed = true;
    this.wentUpAt = null;
    if (this.index >= STREAM_LEVELS.length - 1) return false;
    this.index++;
    this.changedAt = now;
    return true;
  }

  /** The decoder has room: one level up when it has been long enough (false: stays). */
  easy(now: number): boolean {
    if (this.index === 0 || this.upFailed || now - this.changedAt < LEVEL_UP_AFTER_MS) return false;
    this.index--;
    this.changedAt = now;
    this.wentUpAt = now;
    return true;
  }
}
