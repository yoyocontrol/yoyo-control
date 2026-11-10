/**
 * A/V sync on the screen page, as the iOS kit's `ScreenAVSync` (pure; the page runs it a few times a second, or lets an
 * `AVSyncDriver` do it). Every delay is this side's clock − the computer's (ms), for the same instant on the computer:
 * the sound's `X-Audio-Time` + `X-Audio-Video-Offset` is the `X-Frame-Time` a real display's picture of that instant
 * carries.
 *
 * - Sound: what plays now + the output latency − the offset; its own delay leaves the sync depth out.
 * - Picture: base + smooth depth + two refreshes (`videoDelay`, what the video would do by itself); `shownDelay` the one
 *   in use (touch, sync floor).
 * - Skew = sound − picture (+ = the sound comes later; the report's `skewMs`).
 *
 * The video waits for the sound while watching: not interactive, sound in the last 5 s and the sound more than
 * `VIDEO_ENTER_MS` later than the picture: the playout's `syncFloor` = that − `SOUND_LATER_MS`, at most
 * `MAX_VIDEO_FLOOR_MS` (the playout ramps to it). It stays engaged (following the skew) until the skew is under
 * `SOUND_LATER_MS`, the sound has been silent, or it is turned off; interactive pictures get no floor. The sound never
 * chases the video's touch drops: only when the smooth video delay is above the sound's own does the sound's delay goal
 * become video + `SOUND_LATER_MS` (the buffer moves its depth there by at most 20 ms a second).
 */
export class AVSync {
    static VIDEO_ENTER_MS = 45;
    static SOUND_LATER_MS = 15;
    static MAX_VIDEO_FLOOR_MS = 300;
    /** Sound is "playing" when a packet with sound came this recently (ms). */
    static SILENT_AFTER_MS = 5000;
    /** The video floor is engaged. */
    engaged = false;
    update(i) {
        const a = i.audioDelay, v = i.videoDelay;
        if (i.enabled === false || a === null || v === null) {
            this.engaged = false;
            return { videoFloor: 0, audioDelayGoal: null, skew: null };
        }
        const out = { videoFloor: 0, audioDelayGoal: null, skew: i.shownDelay !== null ? a - i.shownDelay : a - v };
        const skew = a - v;
        if (i.videoFloorEnabled === false || !i.soundRecent || skew <= AVSync.SOUND_LATER_MS)
            this.engaged = false;
        else if (!i.interactive && skew > AVSync.VIDEO_ENTER_MS)
            this.engaged = true;
        if (this.engaged && !i.interactive)
            out.videoFloor = Math.min(Math.max(skew - AVSync.SOUND_LATER_MS, 0), AVSync.MAX_VIDEO_FLOOR_MS);
        if (i.audioOwnDelay !== null && v > i.audioOwnDelay)
            out.audioDelayGoal = v + AVSync.SOUND_LATER_MS;
        return out;
    }
}
/**
 * Runs `AVSync` every `everyMs` between the page's sound and its current video stream (the video changes with each
 * reopen: `video()` returns the one open now). Only a real display's video should be synced (the page knows: a virtual
 * display's pictures don't carry the same-instant times); return null from `video()` otherwise.
 */
export class AVSyncDriver {
    audio;
    video;
    everyMs;
    sync = new AVSync();
    timer = null;
    /** The last output (for a stats line or a test). */
    last = { videoFloor: 0, audioDelayGoal: null, skew: null };
    constructor(audio, video, everyMs = 250) {
        this.audio = audio;
        this.video = video;
        this.everyMs = everyMs;
    }
    start() {
        if (this.timer === null)
            this.timer = setInterval(() => this.tick(), this.everyMs);
    }
    /** Stops, and takes the floor and the goal away. */
    stop() {
        if (this.timer !== null)
            clearInterval(this.timer);
        this.timer = null;
        const v = this.video();
        if (v)
            v.syncFloor = 0;
        this.audio.setSyncDelayGoal(null);
        this.audio.setSyncReport(null, null);
        this.sync.engaged = false;
    }
    /** One round (the timer calls it). */
    tick() {
        const a = this.audio.syncDelays();
        const v = this.video();
        const d = v?.syncDelays() ?? null;
        const out = this.sync.update({
            audioDelay: a?.delay ?? null,
            audioOwnDelay: a?.ownDelay ?? null,
            videoDelay: d?.smooth ?? null,
            shownDelay: d?.shown ?? null,
            interactive: v?.interactive ?? false,
            soundRecent: a?.soundRecent ?? false,
        });
        if (v)
            v.syncFloor = out.videoFloor;
        this.audio.setSyncDelayGoal(out.audioDelayGoal);
        this.audio.setSyncReport(out.skew, out.videoFloor > 0 ? out.videoFloor : null);
        this.last = out;
        return out;
    }
}
