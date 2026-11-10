import type { CursorPart } from "./types.js";
/**
 * The pointer the page draws itself (`cursor=client`, docs/PROTOCOL.md「客户端指针」): the server leaves it out of the
 * pictures and sends cursor parts — one before the stream's first picture, then on change. Shapes are cached by
 * `shapeId` (the same id is always the same picture; a `shape` for a known id replaces it). Ids are big numbers
 * (≥ 1e6 on the Mac, a random 2^20 multiple on Linux): never range-checked like coordinates. A stream whose first
 * picture comes without a cursor part before it draws the pointer into its pictures: then nothing is drawn here.
 * Pure: the page renders `view()`.
 */
export interface CursorShape {
    /** A data: URL of the PNG. */
    url: string;
    hotX: number;
    hotY: number;
    width: number;
    height: number;
}
export interface CursorView {
    /** 0…1 of the display: where the shape's top-left goes, and its size. */
    left: number;
    top: number;
    width: number;
    height: number;
    /** null: draw the page's own arrow (shape missing or unknown). */
    url: string | null;
}
/** A cursor part's JSON, leniently: null when it isn't one. */
export declare function parseCursorPart(body: Uint8Array | string): CursorPart | null;
export declare class CursorModel {
    private shapes;
    private part;
    private sawCursor;
    private sawPicture;
    /** The page moved the pointer itself (its own input) since the server's last word. */
    private local;
    /** A new stream: nothing seen yet (cached shapes stay: ids never change meaning). */
    streamOpened(): void;
    /** A cursor part. */
    cursor(p: CursorPart): void;
    /** A picture arrived. true when this stream draws the pointer into its pictures (no cursor part came first). */
    picture(): boolean;
    /** The page's own input moved the pointer (shown at once; the server's echo takes over). */
    moved(x: number, y: number): void;
    /** Whether the page draws a pointer at all (cursor parts are coming). */
    get drawn(): boolean;
    view(): CursorView | null;
}
