import type { Point, Rect } from "./gestures.js";
/** What the loupe samples: a canvas the page draws its pictures into, or an image. */
export type LoupeSource = HTMLCanvasElement | HTMLImageElement | ImageBitmap;
/** The loupe: a canvas the page puts in the picture's clip (positioned by the loupe itself). */
export declare class LoupeView {
    readonly canvas: HTMLCanvasElement;
    private readonly g;
    /** The 2D fallback (no WebGL2). */
    private readonly ctx2d;
    private readonly motion;
    private picture;
    private clip;
    private magnification;
    private radius;
    private raf;
    private last;
    private source;
    private uploaded;
    /** Over a still picture: dimmed like it. */
    dim: number;
    /** A held touch armed a drag: the bevel turns the accent colour. */
    tinted: boolean;
    /** Reduce Motion; Reduce Transparency / more contrast (the plain magnifier). */
    reduceMotion: boolean;
    plain: boolean;
    /** The accent (tint) and the text colour (the plain rim), as 0…1 RGB. */
    accent: [number, number, number];
    ink: [number, number, number];
    /** How much it magnifies at the pointer right now (1 when gone), every frame: the pointer over it grows as much. */
    onMagnification: ((m: number) => void) | null;
    private reported;
    constructor(doc?: Document);
    /** WebGL2 draws the drop (false: the plain 2D magnifier). */
    get liquid(): boolean;
    get visible(): boolean;
    /** The picture to sample changed (a new video picture, a still): re-uploaded at the next draw. */
    setSource(source: LoupeSource | null): void;
    /** Look at `point` (clip px) of `picture` (its frame in the clip; zoomed: bigger than `clip`). */
    aim(point: Point, picture: Rect, clip: Rect, magnification: number, radius: number): void;
    setVisible(on: boolean, animated?: boolean): void;
    /** The page went away. */
    stop(): void;
    private run;
    private tick;
    private hide;
    private report;
    private draw;
    private drawGl;
    /** Without WebGL2: a round magnifier with a rim (no refraction). */
    private draw2d;
}
