import type { ControlDevice, Controller, ControlRole } from "@yoyocontrol/screen-web";
import type { Words } from "./strings.js";
/**
 * Several devices watching the same computer's screen (docs/REMOTE.md「控制权」): one controls, the others watch. The
 * status / `screen.control` say who holds it (`controllerDevice`); a device that isn't the holder is a viewer: its
 * touches send nothing, and a pill says who controls with a one-tap Take Over (iOS `ScreenControlModel`). Pure.
 */
export type { ControlRole };
export declare class ControlModel {
    role: ControlRole;
    /** `controllerSince` of this device's last take (a status from before it saying another holds is stale). */
    private tookSince;
    get isViewer(): boolean;
    static roleOf(controller: Controller, device: ControlDevice | null | undefined, me: string | null): ControlRole;
    /** A status or a `screen.control`: who holds it now. Returns the holder's name when another device took over from this one. */
    status(controller: Controller, device: ControlDevice | null | undefined, since: number | null | undefined, me: string | null): {
        tookOver: string | null;
    } | null;
    /** This device took control (the control request's answer). */
    took(controller: Controller, device: ControlDevice | null | undefined, since: number | null | undefined, me: string | null): {
        tookOver: string | null;
    } | null;
    /** An input was refused: another device holds control. */
    refused(device: ControlDevice): {
        tookOver: string | null;
    } | null;
    private move;
    /** The holder's name to show: its own, else "Another iPhone" / "Another iPad" for the generic names, else "Another device". */
    static displayName(name: string | null | undefined, words: Words): string;
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
export declare function controlAnswer(controlling: boolean, viewer: boolean, canTake: boolean): "go" | "take" | "nudge" | "ignore";
/**
 * What the pill at the top says (with its button) while the page doesn't control (iOS `ScreenControlPolicy.pill`):
 * `free` "View only · Take Control", `agent` "Agent is using the screen · Take Over", `other` "<name> is controlling ·
 * Take Over". null in control (the badge says "You have control") or when input isn't possible here (`canControl`:
 * the picture shows, Accessibility is granted, not a phone turned to landscape). Full screen counts as not in control.
 */
export declare function controlPill(controlling: boolean, canControl: boolean, role: ControlRole): {
    t: "free";
} | {
    t: "agent";
} | {
    t: "other";
    name: string | null;
} | null;
/** A refusal because another device holds control (409 `code: "controlled-elsewhere"` with `controllerDevice`). */
export declare function controlledElsewhere(error: unknown): ControlDevice | null;
