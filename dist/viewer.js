export class ControlModel {
    role = { t: "free" };
    /** `controllerSince` of this device's last take (a status from before it saying another holds is stale). */
    tookSince = null;
    get isViewer() {
        return this.role.t === "other";
    }
    static roleOf(controller, device, me) {
        if (controller === "agent")
            return { t: "agent" };
        if (controller !== "user")
            return { t: "free" };
        if (device && me && device.id !== me)
            return { t: "other", name: device.name ?? null };
        return { t: "me" };
    }
    /** A status or a `screen.control`: who holds it now. Returns the holder's name when another device took over from this one. */
    status(controller, device, since, me) {
        const next = ControlModel.roleOf(controller, device, me);
        if (next.t === "other" && since != null && this.tookSince !== null && since < this.tookSince)
            return null;
        return this.move(next);
    }
    /** This device took control (the control request's answer). */
    took(controller, device, since, me) {
        if (controller === "user")
            this.tookSince = since ?? null;
        return this.status(controller, device, since, me);
    }
    /** An input was refused: another device holds control. */
    refused(device) {
        return this.move({ t: "other", name: device.name ?? null });
    }
    move(next) {
        const was = this.role;
        this.role = next;
        return was.t === "me" && next.t === "other" ? { tookOver: next.name } : null;
    }
    /** The holder's name to show: its own, else "Another iPhone" / "Another iPad" for the generic names, else "Another device". */
    static displayName(name, words) {
        const n = name?.trim();
        if (!n)
            return words.t("anotherDevice");
        if (n === "iPhone")
            return words.t("anotherIPhone");
        if (n === "iPad")
            return words.t("anotherIPad");
        return n;
    }
}
/**
 * When the Screen page takes the screen (iOS `ScreenControlPolicy`): it opens as a viewer and takes control only at a
 * real input — the first touch on the trackpad or the picture, a click, a scroll on the picture, the keyboard button,
 * a key or typed text, a paste into the computer. Opening, coming back, a status or `screen.control`, zooming or panning
 * the picture, full screen and turning the phone are not input and never ask. At an input the user wins over
 * automation (an agent's control is taken); another device's control is only taken with Take Over.
 *
 * `controlling`: input goes now; `viewer`: another device holds control; `canTake`: input is possible here
 * (Accessibility granted, not view only, not a viewer). `"go"`: the input goes; `"take"`: take the screen, then it goes;
 * `"nudge"`: the Take Over pill is nudged, nothing goes; `"ignore"`: nothing can take it. Pure.
 */
export function controlAnswer(controlling, viewer, canTake) {
    if (controlling)
        return "go";
    if (viewer)
        return "nudge";
    return canTake ? "take" : "ignore";
}
/**
 * What the pill at the top says (with its button) while the page doesn't control (iOS `ScreenControlPolicy.pill`):
 * `free` "View only · Take Control", `agent` "Agent is using the screen · Take Over", `other` "<name> is controlling ·
 * Take Over". null in control (the badge says "You have control") or when input isn't possible here (`canControl`:
 * the picture shows, Accessibility is granted, not a phone turned to landscape). Full screen counts as not in control.
 */
export function controlPill(controlling, canControl, role) {
    if (controlling || !canControl)
        return null;
    if (role.t === "other")
        return { t: "other", name: role.name };
    return role.t === "agent" ? { t: "agent" } : { t: "free" };
}
/** A refusal because another device holds control (409 `code: "controlled-elsewhere"` with `controllerDevice`). */
export function controlledElsewhere(error) {
    const body = error?.body;
    if (!body || body.code !== "controlled-elsewhere")
        return null;
    const d = body.controllerDevice;
    if (!d || typeof d.id !== "string" || !d.id.trim())
        return null;
    return typeof d.name === "string" ? { id: d.id, name: d.name } : { id: d.id };
}
