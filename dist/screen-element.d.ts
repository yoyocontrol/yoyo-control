import { type Display } from "@yoyocontrol/screen-web";
import type { ScreenBackend, ScreenHost } from "./contracts.js";
import { Words } from "./strings.js";
export declare class YoyoScreenElement extends HTMLElement {
    private _backend;
    private _host;
    private words;
    private built;
    private root;
    private stage;
    private probe;
    private pad;
    private padHint;
    private clip;
    private zoomLayer;
    private canvas;
    private dim;
    private overlay;
    private cursorImg;
    private pbadge;
    private loupe;
    private fsButton;
    private badges;
    private badge;
    private vpill;
    private hintPill;
    private zoomHint;
    private stats;
    private conn;
    private spinner;
    private note;
    private empty;
    private bar;
    private lead;
    private trail;
    private buttons;
    private toastEl;
    private keys;
    private keybar;
    private keybarButtons;
    private clipKeys;
    private filePicker;
    private scrim;
    private sheet;
    private menu;
    private session;
    private status;
    private statusError;
    private displayId;
    private heldByMe;
    /** A take of control on its way. */
    private taking;
    /** What the real inputs that asked for control wait to do once the take is through (in order; dropped if it fails). */
    private afterTake;
    private fullScreen;
    private desktopFull;
    private mode;
    private modifiers;
    private readonly viewers;
    private readonly cursor;
    private cursorPart;
    private localCursor;
    private lensScale;
    private zoom;
    private pinch;
    private followed;
    private imageSize;
    private layoutBox;
    private hostRect;
    private trackpad;
    private input;
    private clicks;
    private clickTimer;
    private touch;
    private touchTimer;
    private pictureTouches;
    private pictureTapAt;
    private padPointers;
    private mouse;
    private suppressClick;
    private dragHeld;
    private composing;
    private focusLook;
    private focusUnsupported;
    private statusTimer;
    private statsTimer;
    private events;
    private chromeFade;
    private toastTimer;
    private hintTimer;
    private zoomHintTimer;
    private hint;
    private clipboard;
    private clipboardOn;
    private unobserveClipboard;
    private macCountKnown;
    private readonly marks;
    private clipboardBusy;
    private phoneHintAsked;
    private activeFlag;
    private resize;
    private layoutQueued;
    private readonly off;
    /** The computer this page shows. Setting it (re)starts the page. */
    get backend(): ScreenBackend | null;
    set backend(b: ScreenBackend | null);
    /** The app around the page: theme, words, errors, preferences. */
    get host(): ScreenHost;
    set host(h: ScreenHost);
    connectedCallback(): void;
    disconnectedCallback(): void;
    /** Shows / hides the stats line (a three-finger tap does it on touch devices). */
    toggleStats(): void;
    /** The gesture card for the current mode. */
    showGestures(): void;
    private get ns();
    private pref;
    private setPref;
    private get deviceId();
    private get device();
    private get isMac();
    private applyTheme;
    private build;
    private roundButton;
    private setIcon;
    /** Words that follow the language and whose computer it is. */
    private relabel;
    private start;
    /** The page stops for good (`release`: control goes back). */
    private stop;
    private activate;
    private deactivate;
    /** The element's own listeners (once, as it is built). */
    private wireEvents;
    /** The page's listeners on the document and the window (while it runs). */
    private listen;
    private close;
    private refreshStatus;
    private apply;
    private get currentDisplay();
    private get canShow();
    private get canControl();
    private get viewOnly();
    /** Taps and keys go to the computer. */
    private get controlling();
    /** A real input would take the screen now (not view only, not watching another device's control). */
    private get canTake();
    /** A real input (the first touch on the trackpad or the picture, a click, a scroll, the keyboard button, a key, typed
     *  text, a paste into the computer): in control, `then` runs now; else the page takes the screen if it can (over the
     *  agent too: the user wins) and `then` runs once it controls. Watching another device's control, the Take Over pill
     *  is nudged (only it takes the screen then). Nothing else takes the screen. */
    private userInput;
    private followEvents;
    private stopEvents;
    private event;
    /** The pill's button (Take Control / Take Over: explicit, so another device's control too). In full screen: back to
     *  the page first, then the take. */
    private takeControlTapped;
    /** Takes the screen (at a real input, or the pill's button), then runs `then` if it controls. Given back with `releaseControl`. */
    private setControl;
    /** Gives the screen back if this page took it (`leaving`: the page may be going away — keepalive). */
    private releaseControl;
    private tookOver;
    private render;
    /** What shows instead of the picture: loading, unreachable, unavailable, the Screen Recording permission. */
    private renderEmpty;
    private requestPermissions;
    private renderConnection;
    private updateChrome;
    private updateDisplayButton;
    private queueLayout;
    /** Portrait: the picture at the top, the trackpad surface under it (the badges at its top), the buttons in a row at
     *  the bottom. Wide: the buttons in a column on each side. Full screen: the picture alone. */
    private layout;
    private displayAspect;
    /** The picture at the zoom, in its clip. */
    private layoutZoom;
    /** The picture as it shows now (zoomed: bigger than its frame), in its clip's coordinates. */
    private get shown();
    private setZoom;
    private followPointer;
    private pictureArrived;
    private cursorArrived;
    /** Where the pointer is drawn now (0…1), null when none is (the pictures carry the computer's own). */
    private drawnPointer;
    /** The pointer goes to `p` at once: this page sent it there. */
    private moveCursor;
    private layoutCursor;
    private displaySize;
    /** A click shows at once where it lands: a ring spreads (Reduce Motion: it only fades). */
    private showClick;
    private updateLoupe;
    private colorCache;
    private loupeColors;
    private badgeKind;
    private updatePointerBadge;
    private leanTimer;
    private scrollAxis;
    private trackpadHost;
    /** The first finger came down on the trackpad / picture, or the last one lifted. Not in control (the page opened
     *  watching, the agent drives): the touch takes the screen (watching another device's control: only Take Over
     *  does). The keyboard goes at a touch. `deferTake`: a touch on the picture in touch mode, which may be a pinch
     *  (zooming isn't input): it takes the screen once it is a tap or a drag (`pictureTouchUp` / `pictureTouchMove`). */
    private touches;
    private nudgePill;
    private local;
    private onPicture;
    /** A page point as the display's 0…1, through the zoom. */
    private pictureNormalized;
    private displayPointsPerPx;
    private pointerDown;
    private pointerMove;
    private pointerUp;
    private mouseClick;
    private mouseClickAt;
    private lastWasTouch;
    private contextMenu;
    private wheel;
    private pictureTouchDown;
    private pictureTouchMove;
    private pictureTouchUp;
    private runTouch;
    private pictureDoubleTapped;
    private pictureTapped;
    private showZoomHint;
    private zoomHintHide;
    private hideZoomHint;
    private send;
    private modifierField;
    /** The armed (sticky) modifiers, disarmed, merged with `with`. */
    private takeModifiers;
    private withSticky;
    private clickAt;
    private queueScroll;
    /** A live drag's step: `down` / `up` in order with everything else, the held moves merged. */
    private dragStep;
    /** The page stops mid-drag: `up` goes now, past the queue (best effort). */
    private liftDrag;
    private inputFailed;
    private handleError;
    private get isKeyboardUp();
    private refocusKeys;
    private keyDown;
    private sendShortcut;
    private typedInput;
    private compositionEnd;
    /** The keyboard button: up (taking the screen when watching: typing is input; the keyboard comes up at once, as the
     *  tap allows, and what is typed meanwhile waits for the take) or away. */
    private toggleKeyboard;
    private showKeyboard;
    private keyboardShown;
    /** The key bar sits on top of the soft keyboard (the visual viewport's bottom). */
    private placeKeyBar;
    /** After a click: whether the focused element takes typing (then the keyboard comes up), looked at a few times. */
    private lookAtFocus;
    private dropFocusLook;
    private buildKeyBar;
    private relabelKeyBar;
    private toggleModifier;
    private updateModifierKeys;
    private sendKey;
    private switchMode;
    private updateModeButton;
    private showCardOnce;
    private openCard;
    private toggleFullScreen;
    /** Full screen on a touch device: the picture alone, view only (control given back), landscape where it can lock. */
    private setFullScreen;
    private fullscreenChanged;
    /** Into view only: the keyboard and any drag go, control goes back. Out: watching (the next real input takes the
     *  screen again). */
    private viewOnlyChanged;
    private updateFsButton;
    /** The full-screen button and the badges show; in view-only full screen they fade after a moment. */
    private showChrome;
    private toggleSound;
    private updateSoundButton;
    private openMenu;
    private openSheet;
    private closeOverlays;
    private openDisplayMenu;
    private selectDisplay;
    /** The computer has a clipboard (`features.clipboard`, else the Mac only), and the backend can reach it. */
    private updateClipboardCapability;
    private setClipboardOn;
    private clipboardChanged;
    /** What this browser's clipboard holds, when it lets the page look without asking (Chrome with the permission granted). */
    private phoneClipboard;
    private showPhoneHintIfNew;
    private phoneCount;
    private phoneKind;
    private updateClipboardDot;
    private showHint;
    private hintAction;
    private showHintText;
    private hideHint;
    private hintTapped;
    private openClipboardMenu;
    private openPickMenu;
    private openClipboardSheet;
    /** Paste on Mac: this browser's clipboard onto the computer's, then ⌘V (Shift+Insert on Linux) while in control. */
    private pasteOnMac;
    private sendToComputer;
    /** Copy from Mac: the computer's text / image onto this browser's clipboard; files open the Clipboard sheet. */
    private copyFromMac;
    private pick;
    private picked;
    private updateStatsTimer;
    private toast;
    private vibrate;
}
/** A display's name: what the computer calls it, else its kind; else the main display or a number. */
export declare function displayTitle(d: Display, index: number, w: Words): string;
/** Its size in pixels, the scale when whole, and whether it is the main one: `3456 × 2234 @2x · Main`. */
export declare function displaySubtitle(d: Display, w: Words): string;
