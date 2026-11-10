import type { ScreenBackend, ScreenHost } from "./contracts.js";
/** The tag names the elements are registered under (`defineElements`). */
export declare const tagNames: {
    screen: string;
    clipboard: string;
};
export declare class YoyoClipboardElement extends HTMLElement {
    private _backend;
    private _host;
    private _computer;
    private words;
    private root;
    private wrap;
    private toastEl;
    private picker;
    private state;
    private unobserve;
    private expanded;
    private thumbnail;
    private thumbLoading;
    private textAsked;
    private busy;
    private toastTimer;
    private lastChange;
    constructor();
    get backend(): ScreenBackend | null;
    set backend(b: ScreenBackend | null);
    get host(): ScreenHost;
    set host(h: ScreenHost);
    /** Whose clipboard: "mac", or another platform ("linux"…: the words say "computer"). */
    get computer(): string;
    set computer(c: string);
    connectedCallback(): void;
    disconnectedCallback(): void;
    private observe;
    private get status();
    private get canSend();
    private changed;
    private loadThumbnail;
    private render;
    private card;
    private actions;
    private copy;
    /** The item as files (an image, or a files item's regular files, downloaded one by one). */
    private asFiles;
    private share;
    private save;
    private pasteFromBrowser;
    private get limit();
    private pick;
    private sendFiles;
    private send;
    private setBusy;
    private toast;
}
