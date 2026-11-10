import { Loupe, Spring } from "./gestures.js";
/**
 * The liquid-glass lens over the pointer (iOS ScreenDrop.swift): a clear disc whose middle magnifies the picture evenly
 * out to `flatRadius`, then a rounded bevel that refracts like a glass edge — it pulls in the picture from around the
 * drop and squeezes it towards the rim, splitting its colours into a thin rainbow. It moves on springs (`DropMotion`):
 * it swells from a point on a touch, follows the pointer with a little give, stretches along a fast move with a tail,
 * wobbles when it stops and squashes flat as it goes. At the picture's edge it merges with the edge like a drop of
 * water touching a glass's side. Pure numbers: `DropRenderer` (WebGL2) draws it.
 */
export const Drop = {
    SIZE_SCALE: 1,
    BEVEL: 0.16,
    get FLAT_RADIUS() {
        return 1 - Drop.BEVEL;
    },
    RIM_REACH: 0.2,
    DISPERSION: 0.2,
    BEVEL_CUT: 0.97,
    MERGE: 0.4,
    MERGE_OFFSET: 0.06,
    MAX_STRETCH: 0.25,
    MAX_TAIL: 0.28,
    STRETCH_SPEED: 2400,
    MAX_DEFORMATION: 0.4,
    MAX_PRESENCE: 1.2,
    deform: { response: 0.3, dampingRatio: 0.38 },
    pop: { response: 0.6, dampingRatio: 0.32 },
    POP_IN: -2.2,
    POP_OUT: 2.2,
    OPAQUE_PRESENCE: 0.55,
    tail: { response: 0.34, dampingRatio: 0.48 },
    reducedPresence: { response: 0.16, dampingRatio: 1 },
    /** The drawing's box is this many radii across. */
    BOX: 6,
    /** The smooth union of the drop's outline `a` and the edge's `b` (signed distances in radii). */
    merged(a, b) {
        const k = Drop.MERGE;
        const h = Math.min(Math.max(0.5 + (0.5 * (b - a)) / k, 0), 1);
        return { distance: b + (a - b) * h - k * h * (1 - h), drop: h };
    },
    radius(picture) {
        return (Loupe.diameter(picture) * Drop.SIZE_SCALE) / 2;
    },
    /** How far the bevel at `x` (0 = its start, 1 = the rim) has pulled the picture outwards, as a fraction. */
    profile(x) {
        const t = Math.min(Math.max(x, 0), 1), k = Drop.BEVEL_CUT;
        return (1 - Math.sqrt(1 - k * k * t * t)) / (1 - Math.sqrt(1 - k * k));
    },
    /** How far (radii) the bevel pushes the picture out at the rim for a middle magnified `m` times. */
    refraction(m) {
        return 1 + Drop.RIM_REACH - 1 / Math.max(m, 1);
    },
    bevelPosition(rho) {
        return Math.min(Math.max((rho - Drop.FLAT_RADIUS) / Drop.BEVEL, 0), 1);
    },
    /** The deformation it heads for at `v` (points per second): a log-stretch along the move and a tail pointing back. */
    deformation(v) {
        const speed = Math.hypot(v.x, v.y);
        if (!Number.isFinite(speed) || speed <= 1)
            return { xx: 0, xy: 0, tail: { x: 0, y: 0 } };
        const u = Math.pow(Math.min(speed / Drop.STRETCH_SPEED, 1), 0.75);
        const cx = v.x / speed, cy = v.y / speed;
        const s = Drop.MAX_STRETCH * u;
        return { xx: s * (cx * cx - cy * cy), xy: s * 2 * cx * cy, tail: { x: -cx * Drop.MAX_TAIL * u, y: -cy * Drop.MAX_TAIL * u } };
    },
    /** exp of the log-stretch tensor [[xx, xy], [xy, −xx]] (row major: a, b, c, d). */
    stretch(xx, xy) {
        const s = Math.hypot(xx, xy);
        if (!(s > 1e-9) || !Number.isFinite(s))
            return [1, 0, 0, 1];
        const c = Math.cosh(s), k = Math.sinh(s) / s;
        return [c + k * xx, k * xy, k * xy, c - k * xx];
    },
};
const mul = (m, v) => ({ x: m[0] * v.x + m[1] * v.y, y: m[2] * v.x + m[3] * v.y });
/** The drop's own outline: 0 in the middle, 1 on the edge. */
export function dropRho(s, p) {
    if (!(s.radius > 0))
        return Infinity;
    let e = mul(s.inverse, { x: p.x - s.center.x, y: p.y - s.center.y });
    const along = e.x * s.tailDirection.x + e.y * s.tailDirection.y;
    if (along > 0) {
        const k = along * (s.tail / (1 + s.tail));
        e = { x: e.x - s.tailDirection.x * k, y: e.y - s.tailDirection.y * k };
    }
    return Math.hypot(e.x, e.y);
}
/** 0 in the middle, 1 on the edge, merged with the area's edge (as the shader). */
export function shapeRho(s, p) {
    const a = dropRho(s, p);
    const area = s.area;
    if (!area || !Number.isFinite(a) || !(s.radius > 0))
        return a;
    const d = Math.min(p.x - area.x, area.x + area.width - p.x, p.y - area.y, area.y + area.height - p.y);
    return 1 + Drop.merged(a - 1, d / s.radius + Drop.MERGE_OFFSET).distance;
}
/** The picture's point that shows at `p` (as the shader, before dispersion). */
export function shapeSource(s, p) {
    const rho = shapeRho(s, p);
    if (rho >= 1)
        return p;
    const d = { x: p.x - s.center.x, y: p.y - s.center.y };
    const src = { x: s.center.x + d.x / s.magnification, y: s.center.y + d.y / s.magnification };
    const x = Drop.bevelPosition(rho);
    const r = dropRho(s, p);
    if (x > 0 && r > 1e-9) {
        const k = (s.refraction * Drop.profile(x)) / r;
        src.x += d.x * k;
        src.y += d.y * k;
    }
    return src;
}
/** The springs behind the drop: its place, how far it has swelled, its stretch and its tail. */
export class DropMotion {
    x = new Spring(0);
    y = new Spring(0);
    presence = new Spring(0);
    xx = new Spring(0);
    xy = new Spring(0);
    tailX = new Spring(0);
    tailY = new Spring(0);
    pop = new Spring(0);
    visible = false;
    aim(point, jump = false) {
        if (jump || (!this.visible && this.presence.value < 0.05)) {
            this.x = new Spring(point.x);
            this.y = new Spring(point.y);
        }
        else {
            this.x.target = point.x;
            this.y.target = point.y;
        }
    }
    setVisible(on, animated = true, reduceMotion = false) {
        this.visible = on;
        this.presence.target = on ? 1 : 0;
        if (!animated)
            this.presence = new Spring(on ? 1 : 0);
        if (!on && !animated)
            this.resetDeformation();
        if (!animated || reduceMotion)
            return;
        if (on && this.presence.value < 0.3)
            this.pop.velocity = Drop.POP_IN;
        else if (!on)
            this.pop.velocity += Drop.POP_OUT;
    }
    resetDeformation() {
        this.xx = new Spring(0);
        this.xy = new Spring(0);
        this.tailX = new Spring(0);
        this.tailY = new Spring(0);
        this.pop = new Spring(0);
    }
    step(dt, reduceMotion) {
        this.x.step(dt, Loupe.follow);
        this.y.step(dt, Loupe.follow);
        this.presence.step(dt, reduceMotion ? Drop.reducedPresence : this.visible ? Loupe.appear : Loupe.disappear);
        const d = reduceMotion ? { xx: 0, xy: 0, tail: { x: 0, y: 0 } } : Drop.deformation({ x: this.x.velocity, y: this.y.velocity });
        this.xx.target = d.xx;
        this.xy.target = d.xy;
        this.tailX.target = d.tail.x;
        this.tailY.target = d.tail.y;
        this.xx.step(dt, Drop.deform);
        this.xy.step(dt, Drop.deform);
        this.tailX.step(dt, Drop.tail);
        this.tailY.step(dt, Drop.tail);
        this.pop.step(dt, Drop.pop);
        if (reduceMotion)
            this.resetDeformation();
    }
    get settled() {
        return (this.x.settled(0.05) &&
            this.y.settled(0.05) &&
            this.presence.settled() &&
            this.xx.settled(0.0005) &&
            this.xy.settled(0.0005) &&
            this.tailX.settled(0.0005) &&
            this.tailY.settled(0.0005) &&
            this.pop.settled(0.0005));
    }
    /** The shape for a drop of `radius` whose middle magnifies `m` once full, merging with `area`'s edge. */
    shape(radius, m, area = null) {
        const p = Math.min(Math.max(this.presence.value, 0), Drop.MAX_PRESENCE);
        const r = radius * p;
        const mag = 1 + (m - 1) * Math.min(p, 1);
        const clamped = (a, b) => {
            const n = Math.hypot(a, b), limit = Drop.MAX_DEFORMATION;
            if (!Number.isFinite(n))
                return [0, 0];
            return n > limit ? [(a * limit) / n, (b * limit) / n] : [a, b];
        };
        const [sxx, sxy] = clamped(this.xx.value + this.pop.value, this.xy.value);
        const [tx, ty] = clamped(this.tailX.value, this.tailY.value);
        const st = Drop.stretch(-sxx, -sxy);
        const inverse = r > 0 ? [st[0] / r, st[1] / r, st[2] / r, st[3] / r] : [1, 0, 0, 1];
        const tail = Math.hypot(tx, ty);
        let direction = { x: 0, y: 0 };
        if (tail > 1e-6) {
            const t = mul(inverse, { x: tx / tail, y: ty / tail });
            const l = Math.hypot(t.x, t.y);
            direction = l > 0 ? { x: t.x / l, y: t.y / l } : direction;
        }
        return {
            center: { x: this.x.value, y: this.y.value },
            radius: r,
            magnification: mag,
            refraction: Drop.refraction(mag) * Math.min(p, 1),
            presence: Math.min(p, 1),
            opacity: Math.min(p / Drop.OPAQUE_PRESENCE, 1),
            inverse,
            tailDirection: direction,
            tail,
            area,
        };
    }
}
