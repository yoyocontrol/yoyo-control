import { Spring, type Point, type Rect, type Size, type SpringParameters } from "./gestures.js";
/**
 * The liquid-glass lens over the pointer (iOS ScreenDrop.swift): a clear disc whose middle magnifies the picture evenly
 * out to `flatRadius`, then a rounded bevel that refracts like a glass edge — it pulls in the picture from around the
 * drop and squeezes it towards the rim, splitting its colours into a thin rainbow. It moves on springs (`DropMotion`):
 * it swells from a point on a touch, follows the pointer with a little give, stretches along a fast move with a tail,
 * wobbles when it stops and squashes flat as it goes. At the picture's edge it merges with the edge like a drop of
 * water touching a glass's side. Pure numbers: `DropRenderer` (WebGL2) draws it.
 */
export declare const Drop: {
    SIZE_SCALE: number;
    BEVEL: number;
    readonly FLAT_RADIUS: number;
    RIM_REACH: number;
    DISPERSION: number;
    BEVEL_CUT: number;
    MERGE: number;
    MERGE_OFFSET: number;
    MAX_STRETCH: number;
    MAX_TAIL: number;
    STRETCH_SPEED: number;
    MAX_DEFORMATION: number;
    MAX_PRESENCE: number;
    deform: SpringParameters;
    pop: SpringParameters;
    POP_IN: number;
    POP_OUT: number;
    OPAQUE_PRESENCE: number;
    tail: SpringParameters;
    reducedPresence: SpringParameters;
    /** The drawing's box is this many radii across. */
    BOX: number;
    /** The smooth union of the drop's outline `a` and the edge's `b` (signed distances in radii). */
    merged(a: number, b: number): {
        distance: number;
        drop: number;
    };
    radius(picture: Size): number;
    /** How far the bevel at `x` (0 = its start, 1 = the rim) has pulled the picture outwards, as a fraction. */
    profile(x: number): number;
    /** How far (radii) the bevel pushes the picture out at the rim for a middle magnified `m` times. */
    refraction(m: number): number;
    bevelPosition(rho: number): number;
    /** The deformation it heads for at `v` (points per second): a log-stretch along the move and a tail pointing back. */
    deformation(v: Point): {
        xx: number;
        xy: number;
        tail: Point;
    };
    /** exp of the log-stretch tensor [[xx, xy], [xy, −xx]] (row major: a, b, c, d). */
    stretch(xx: number, xy: number): [number, number, number, number];
};
/** The drop's shape and place right now (CSS pixels of the picture's clip), as the shader draws it. */
export interface DropShape {
    center: Point;
    radius: number;
    magnification: number;
    refraction: number;
    presence: number;
    opacity: number;
    /** Points → unit space before the tail (row major). */
    inverse: [number, number, number, number];
    tailDirection: Point;
    tail: number;
    area: Rect | null;
}
/** The drop's own outline: 0 in the middle, 1 on the edge. */
export declare function dropRho(s: DropShape, p: Point): number;
/** 0 in the middle, 1 on the edge, merged with the area's edge (as the shader). */
export declare function shapeRho(s: DropShape, p: Point): number;
/** The picture's point that shows at `p` (as the shader, before dispersion). */
export declare function shapeSource(s: DropShape, p: Point): Point;
/** The springs behind the drop: its place, how far it has swelled, its stretch and its tail. */
export declare class DropMotion {
    x: Spring;
    y: Spring;
    presence: Spring;
    xx: Spring;
    xy: Spring;
    tailX: Spring;
    tailY: Spring;
    pop: Spring;
    visible: boolean;
    aim(point: Point, jump?: boolean): void;
    setVisible(on: boolean, animated?: boolean, reduceMotion?: boolean): void;
    private resetDeformation;
    step(dt: number, reduceMotion: boolean): void;
    get settled(): boolean;
    /** The shape for a drop of `radius` whose middle magnifies `m` once full, merging with `area`'s edge. */
    shape(radius: number, m: number, area?: Rect | null): DropShape;
}
