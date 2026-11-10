// @yoyocontrol/screen-ui: the Screen page and the Clipboard page of a Yoyo Control computer as Web Components
// (<yoyo-screen>, <yoyo-clipboard>), the iOS kit's UX on @yoyocontrol/screen-web. No framework.
import { tagNames, YoyoClipboardElement } from "./clipboard-element.js";
import { YoyoScreenElement } from "./screen-element.js";
export * from "./contracts.js";
export * from "./strings.js";
export * from "./gestures.js";
export * from "./drop.js";
export { LoupeView } from "./loupe.js";
export * from "./trackpad.js";
export * from "./viewer.js";
export * from "./clipboard-model.js";
export * from "./connector.js";
export * from "./session.js";
export * from "./preview.js";
export { YoyoScreenElement, displayTitle, displaySubtitle } from "./screen-element.js";
export { YoyoClipboardElement, tagNames } from "./clipboard-element.js";
/** Registers `<yoyo-screen>` and `<yoyo-clipboard>` (once; another name for either is the host's choice). */
export function defineElements(names = {}) {
    const reg = globalThis.customElements;
    if (!reg)
        return;
    const screen = names.screen ?? tagNames.screen, clipboard = names.clipboard ?? tagNames.clipboard;
    if (!reg.get(screen))
        reg.define(screen, class extends YoyoScreenElement {
        });
    if (!reg.get(clipboard))
        reg.define(clipboard, class extends YoyoClipboardElement {
        });
    tagNames.screen = screen;
    tagNames.clipboard = clipboard;
}
defineElements();
