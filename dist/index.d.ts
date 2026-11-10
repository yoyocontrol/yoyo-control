export * from "./contracts.js";
export * from "./strings.js";
export * from "./gestures.js";
export * from "./drop.js";
export { LoupeView, type LoupeSource } from "./loupe.js";
export * from "./trackpad.js";
export * from "./viewer.js";
export * from "./clipboard-model.js";
export * from "./connector.js";
export * from "./session.js";
export * from "./preview.js";
export { YoyoScreenElement, displayTitle, displaySubtitle } from "./screen-element.js";
export { YoyoClipboardElement, tagNames } from "./clipboard-element.js";
/** Registers `<yoyo-screen>` and `<yoyo-clipboard>` (once; another name for either is the host's choice). */
export declare function defineElements(names?: {
    screen?: string;
    clipboard?: string;
}): void;
