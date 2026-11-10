// Who controls the screen (docs/REMOTE.md「控制权」, the Mac's RemoteControl.swift): nobody, or one paired phone
// (`POST /control`). Only with `--remote`: without it there is no controller and no 409 ever.
//
// - A phone always gets control when it asks (the latest taker holds it); its `/input` goes through only while it holds
//   it: none → 409 "take control of the screen first", another phone → 409 `controlled-elsewhere`.
// - The token listener's clients (whatever they relay: their own users, automation) carry no identity here, so they are
//   not a controller: their `/input` goes through while no phone holds control, and is a 409 `controlled-elsewhere`
//   while one does.
// - Released after `idleMs` (10 min) without input, when the holder lets go, is removed, or `releaseAny` (the admin's
//   `disconnect`). Every change is an `/events` line `{"type":"control","control":{…}}`; a held button is lifted.
import { InputError } from "./input.mjs";

export const CONTROL_IDLE_MS = 10 * 60_000;
export const CONTROLLED_ELSEWHERE = "controlled-elsewhere";

export class RemoteControl {
  constructor({ idleMs = CONTROL_IDLE_MS, now = Date.now, onChange = () => {}, log = () => {} } = {}) {
    this.idleMs = idleMs;
    this.now = now;
    this.onChange = onChange;
    this.log = log;
    /** `{ id, name, since }` or null */
    this.holder = null;
    this.lastActivity = 0;
    this.timer = null;
  }

  /** `/status`'s and the `/events` line's `control`. */
  get json() {
    const h = this.holder;
    return h ? { controller: "remote", since: h.since, device: { id: h.id, name: h.name } } : { controller: "none" };
  }

  /** The phone takes control (from nobody or from another phone). Counts as activity. */
  take(device) {
    this.lastActivity = this.now();
    const h = this.holder;
    if (h && h.id === device.id) {
      if (h.name !== device.name) this.holder = { ...h, name: device.name };
      this.arm();
      return;
    }
    this.holder = { id: device.id, name: device.name, since: this.now() };
    this.arm();
    this.changed(h, `control taken by ${device.name}`);
  }

  /** The phone lets go (only its own control). */
  release(device) {
    return this.releaseWhere((h) => h.id === device.id, `control released by ${device.name}`);
  }

  /** Whoever holds it lets go. false when nobody did. */
  releaseAny(why) {
    return this.releaseWhere(() => true, why);
  }

  /** That device was removed: it loses control if it held it. */
  deviceRemoved(id) {
    return this.releaseWhere((h) => h.id === id, "the controlling device was removed");
  }

  releaseWhere(match, why) {
    const h = this.holder;
    if (!h || !match(h)) return false;
    this.holder = null;
    clearTimeout(this.timer);
    this.timer = null;
    this.changed(h, why);
    return true;
  }

  /**
   * `/input` from `device` (null: the token listener) may go through; throws the 409 otherwise. A phone's accepted
   * input counts as activity.
   */
  admitInput(device) {
    const h = this.holder;
    if (!device) {
      if (h) throw elsewhere(h);
      return;
    }
    if (!h) throw new InputError("take control of the screen first (POST /control)", 409);
    if (h.id !== device.id) throw elsewhere(h);
    this.lastActivity = this.now();
  }

  /** Releases control idle for too long (the timer calls it; tests too). */
  checkIdle() {
    if (!this.holder) return;
    if (this.now() - this.lastActivity >= this.idleMs) this.releaseAny(`control idle for ${Math.round(this.idleMs / 60_000)} min`);
    else this.arm();
  }

  arm() {
    clearTimeout(this.timer);
    const wait = Math.max(0, this.lastActivity + this.idleMs - this.now()) + 50;
    this.timer = setTimeout(() => this.checkIdle(), wait);
    this.timer.unref?.();
  }

  stop() {
    clearTimeout(this.timer);
    this.timer = null;
  }

  changed(previous, why) {
    this.log(`remote: ${why}`);
    this.onChange(this.json, previous);
  }
}

function elsewhere(h) {
  const err = new InputError(`${h.name} controls the screen`, 409);
  err.extra = { code: CONTROLLED_ELSEWHERE, controllerDevice: { id: h.id, name: h.name } };
  return err;
}
