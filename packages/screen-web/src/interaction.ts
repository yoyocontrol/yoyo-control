import type { SendInput } from "./input.js";

/**
 * Whether the user is interacting with the screen right now (docs/PROTOCOL.md「操作时自动低延迟」): a pointer or finger
 * pressed on the picture (from the first contact, before any gesture is recognized), or an input sent to the computer
 * (a key, text, the wheel, a pointer move), and INTERACTIVE_TAIL_MS after the last contact lifts or the last input.
 * While it is on, the video's playout shows pictures with a depth of about one picture interval (`Playout.interactive`)
 * instead of the smooth buffer's. The page owns one for the screen (it outlives a stream: a stream opened while a
 * finger is down starts interactive) and passes it to each `VideoStream`.
 *
 * The page wires it: `down()` / `up()` on pointerdown / pointerup / pointercancel over the picture (while it holds
 * control), and either `pulse()` on each input, or its sends through `withInteraction(send, interactivity)`.
 */

/** 600 ms covers the computer's answer to the last input (a round trip and an encode, ~250 ms on 5G) with room for a
 *  second tap or key; longer would keep showing a calm screen without its smoothing. */
export const INTERACTIVE_TAIL_MS = 600;

export interface InteractivityClock {
  now: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const browserClock: InteractivityClock = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

export class Interactivity {
  private contacts = 0;
  /** When the tail ends (null: no tail running). */
  private until: number | null = null;
  private timer: unknown = null;
  private readonly listeners = new Set<(on: boolean) => void>();
  private last = false;

  constructor(
    readonly tailMs: number = INTERACTIVE_TAIL_MS,
    private readonly clock: InteractivityClock = browserClock,
  ) {}

  /** A contact is down, or the tail runs. */
  get on(): boolean {
    return this.contacts > 0 || this.until !== null;
  }

  /** Calls `fn` with each change (not with the current state); returns the unsubscribe. */
  subscribe(fn: (on: boolean) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** A pointer / finger went down on the picture. */
  down(): void {
    this.contacts++;
    this.stopTail();
    this.changed();
  }

  /** One went up (or was cancelled); the last one starts the tail. */
  up(): void {
    if (this.contacts === 0) return;
    this.contacts--;
    if (this.contacts === 0) this.startTail();
    this.changed();
  }

  /** An input went to the computer (a key, text, the wheel, a move): on for the tail from now (with a contact down,
   *  until it lifts and the tail runs out). */
  pulse(): void {
    if (this.contacts === 0) this.startTail();
    this.changed();
  }

  /** Off at once (control lost, the page stops). */
  reset(): void {
    this.contacts = 0;
    this.stopTail();
    this.changed();
  }

  private startTail(): void {
    this.stopTail();
    this.until = this.clock.now() + this.tailMs;
    this.timer = this.clock.setTimeout(() => this.expire(), this.tailMs);
  }

  private stopTail(): void {
    if (this.timer !== null) this.clock.clearTimeout(this.timer);
    this.timer = null;
    this.until = null;
  }

  private expire(): void {
    this.timer = null;
    if (this.contacts > 0 || this.until === null) return;
    if (this.clock.now() < this.until) {
      // a late or early timer: wait for the rest
      this.timer = this.clock.setTimeout(() => this.expire(), this.until - this.clock.now());
      return;
    }
    this.until = null;
    this.changed();
  }

  private changed(): void {
    const on = this.on;
    if (on === this.last) return;
    this.last = on;
    for (const fn of [...this.listeners]) fn(on);
  }
}

/** `send` that marks each input as interaction (InputQueue's `SendInput`). */
export function withInteraction(send: SendInput, interactivity: Interactivity): SendInput {
  return (input) => {
    interactivity.pulse();
    return send(input);
  };
}
