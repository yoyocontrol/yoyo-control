import CoreGraphics
import Foundation
import YoyoClipboard
import YoyoCore
import simd

/// The liquid-glass lens over the pointer (`ScreenDropView`, drawn in Metal), after iOS 26's text loupe: a clear
/// glass disc whose middle magnifies the picture evenly (`ScreenLoupe.magnification`) out to `flatRadius`, then a
/// rounded bevel (`bevel`) that refracts like a glass edge: it pulls in the picture from around the drop and squeezes
/// it towards the rim (`profile`), splitting its colours into a thin rainbow (`dispersion`). A slight milky lift, a thin
/// light line round the rim (brightest top left and bottom right) and a faint shadow make the glass read as a thing
/// lying on the screen. It moves on springs (`ScreenDropMotion`): it swells from a point on a touch, fading in, drawn
/// up tall, then bouncing through a squash into round (`pop`), follows the pointer with a little give, stretches along
/// a fast move with a tail behind it, wobbles and sloshes forward when it stops, and squashes flat as it shrinks and
/// fades away when the fingers lift. Its middle is always the pointer, which it magnifies around. At the picture's
/// edge it doesn't move aside: it runs into the edge like a drop of water touching the side of a glass (`merge`):
/// the part past the edge is cut off, its rim curves out to meet the edge in a smooth fillet instead of crossing it,
/// and as it comes close it reaches out and joins the edge before it touches.
enum ScreenDrop {
    /// Its radius is this much of the loupe's diameter.
    static let sizeScale: CGFloat = 1
    /// The rounded glass edge: this much of the radius, outside `flatRadius`.
    static let bevel = 0.16
    /// Within this fraction of the radius the picture is magnified evenly (no warping around the pointer); the bevel
    /// refracts the rest.
    static var flatRadius: Double { 1 - bevel }
    /// What shows on the very rim is the picture this far (in radii) beyond the drop's edge: the bevel squeezes the
    /// picture round the drop into itself, whatever the magnification (`refraction(magnification:)`).
    static let rimReach = 0.2
    /// How much further violet bends than red in the bevel (relative to the refraction): the rainbow along the rim.
    static let dispersion = 0.2
    /// The bevel's profile: a quarter circle cut just short of vertical (so the squeeze at the rim stays finite).
    private static let bevelCut = 0.97
    /// How wide (in radii) the fillet is where the drop meets the picture's edge (a smooth minimum of the two outlines):
    /// it joins the edge once it is within about half this of it.
    static let merge = 0.4
    /// The edge it merges with is this far (in radii) past the picture's edge, so the edge alone is no glass: only
    /// where the drop comes near does the outline reach the picture.
    static let mergeOffset = 0.06
    /// The most it stretches along a fast move (log: e^0.25 ≈ 1.28× longer, 0.78× narrower; the area stays).
    static let maxStretch = 0.25
    /// The longest its tail gets behind a fast move (the trailing side is this much longer than the leading one).
    static let maxTail = 0.28
    /// The speed (points per second) at which it is stretched the most.
    static let stretchSpeed = 2400.0
    /// How far it may deform at all (overshoots included): the drawing's box has room for this much.
    static let maxDeformation = 0.4
    /// It may swell this much past its size when it pops in.
    static let maxPresence = 1.2
    /// The stretch follows the speed on a bouncy spring: a sudden stop overshoots into a squash, then wobbles out.
    static let deform = ScreenSpring.Parameters(response: 0.30, dampingRatio: 0.38)
    /// The jelly wobble of popping in and out: a vertical log-stretch (negative: tall) on a bouncy spring, kicked tall
    /// as it appears (`popIn`, its speed) and flat as it goes (`popOut`).
    static let pop = ScreenSpring.Parameters(response: 0.6, dampingRatio: 0.32)
    static let popIn = -2.2
    static let popOut = 2.2
    /// Its opacity follows how far it has swelled, full from this much on (it fades in and out with the pop).
    static let opaquePresence = 0.55
    /// The tail sloshes forward on a stop and settles.
    static let tail = ScreenSpring.Parameters(response: 0.34, dampingRatio: 0.48)
    /// Reduce Motion: appearing and going are a short scale without bounce.
    static let reducedPresence = ScreenSpring.Parameters(response: 0.16, dampingRatio: 1)
    /// The drawing's box is this many radii across, around the drop's center (room for the stretch, the tail, the
    /// pop's overshoot and the shadow: `maxPresence · e^maxDeformation · (1 + maxDeformation) · 1.2` < 3).
    static let box: CGFloat = 6

    /// The smooth union of the drop's outline `a` and the edge's `b` (signed distances, in radii: negative inside):
    /// the merged distance, and how much of its slope is the drop's (1: all the drop's, 0: all the edge's).
    static func merged(_ a: Double, _ b: Double) -> (distance: Double, drop: Double) {
        let k = merge
        let h = min(max(0.5 + 0.5 * (b - a) / k, 0), 1)
        return (b + (a - b) * h - k * h * (1 - h), h)
    }

    /// Its radius over a picture of `picture` points.
    static func radius(picture: CGSize) -> CGFloat {
        ScreenLoupe.diameter(picture: picture) * sizeScale / 2
    }

    /// How far the bevel at `x` (0 = where it starts, at `flatRadius`; 1 = the rim) has pulled the picture outwards,
    /// as a fraction of `refraction`: 0 → 1, level where it starts (no crease against the flat middle), steepest at
    /// the rim (the glass's edge turns down there).
    static func profile(_ x: Double) -> Double {
        let x = min(max(x, 0), 1), k = bevelCut
        return (1 - (1 - k * k * x * x).squareRoot()) / (1 - (1 - k * k).squareRoot())
    }

    /// How far (in radii) the bevel pushes the picture out at the rim, past the evenly magnified picture, for a middle
    /// magnified `m` times: from `1/m` (where the flat middle would put it) out to `1 + rimReach`.
    static func refraction(magnification m: Double) -> Double {
        1 + rimReach - 1 / max(m, 1)
    }

    /// Where `rho` (0 = the middle, 1 = the edge) lies in the bevel: 0 up to `flatRadius`, 1 at the edge.
    static func bevelPosition(_ rho: Double) -> Double {
        min(max((rho - flatRadius) / bevel, 0), 1)
    }

    /// The deformation it heads for while moving at `velocity` (points per second): a stretch along the move (the
    /// traceless log-stretch tensor's two components) and a tail pointing back (its amount along the unit direction).
    static func deformation(velocity v: CGVector) -> (xx: Double, xy: Double, tail: CGVector) {
        let speed = hypot(Double(v.dx), Double(v.dy))
        guard speed.isFinite, speed > 1 else { return (0, 0, .zero) }
        // quick to show a little on a slow move, full at `stretchSpeed`
        let u = pow(min(speed / stretchSpeed, 1), 0.75)
        let (cx, cy) = (Double(v.dx) / speed, Double(v.dy) / speed)
        let s = maxStretch * u
        // cos 2θ = cx² − cy², sin 2θ = 2 cx cy
        return (s * (cx * cx - cy * cy), s * 2 * cx * cy, CGVector(dx: -cx * maxTail * u, dy: -cy * maxTail * u))
    }

    /// The stretch (area-preserving) of the log-stretch tensor [[xx, xy], [xy, −xx]]: exp of it.
    static func stretch(xx: Double, xy: Double) -> simd_double2x2 {
        let s = hypot(xx, xy)
        guard s > 1e-9, s.isFinite else { return matrix_identity_double2x2 }
        let (c, k) = (cosh(s), sinh(s) / s)
        return simd_double2x2(rows: [SIMD2(c + k * xx, k * xy), SIMD2(k * xy, c - k * xx)])
    }

    /// Y′CbCr (as sampled, 0…1) → R′G′B′: `rgb = rows · (yuv − offset)`, the range expansion folded in. `matrix`:
    /// the luma weights (Kr, Kb) of BT.709 (the default), BT.601 or BT.2020.
    static func yuvToRGB(kr: Double, kb: Double, fullRange: Bool) -> (rows: [SIMD3<Float>], offset: SIMD3<Float>) {
        let kg = 1 - kr - kb
        let ys = fullRange ? 1.0 : 255.0 / 219
        let cs = fullRange ? 1.0 : 255.0 / 224
        let rows = [SIMD3(ys, 0, cs * 2 * (1 - kr)),
                    SIMD3(ys, -cs * 2 * kb * (1 - kb) / kg, -cs * 2 * kr * (1 - kr) / kg),
                    SIMD3(ys, cs * 2 * (1 - kb), 0)].map { SIMD3<Float>($0) }
        return (rows, SIMD3<Float>(Float(fullRange ? 0 : 16.0 / 255), 128 / 255, 128 / 255))
    }

    /// The luma weights for a buffer's `kCVImageBufferYCbCrMatrixKey` value (BT.709 when unknown).
    static func lumaWeights(matrix: String?) -> (kr: Double, kb: Double) {
        switch matrix {
        case "ITU_R_601_4", "SMPTE_240M_1995": (0.299, 0.114)
        case "ITU_R_2020": (0.2627, 0.0593)
        default: (0.2126, 0.0722)
        }
    }
}

/// The drop's shape and place right now (canvas points), as the shader draws it.
struct ScreenDropShape: Equatable, Sendable {
    /// Its middle: the pointer, what it magnifies around.
    var center: CGPoint
    /// Its radius at rest, times how far it has swelled.
    var radius: CGFloat
    /// How much its middle magnifies now.
    var magnification: CGFloat
    /// How far the rim refracts now (`ScreenDrop.refraction(magnification:)`, grown in with the drop).
    var refraction: Double
    /// How far it has swelled (0…1): its light and shadow come in with it.
    var presence: Double
    /// How opaque it is (it fades in and out as it pops: `ScreenDrop.opaquePresence`).
    var opacity: Double
    /// Points → its unit space before the tail: the stretch's inverse over the radius (|e| = 1 on the edge).
    var inverse: simd_double2x2
    /// The tail's direction in the unit space (unit, or zero) and how much longer the trailing side is.
    var tailDirection: SIMD2<Double>
    var tail: Double
    /// The picture as it shows, whose edge it merges with (`ScreenDrop.merge`); nil: no edge.
    var area: CGRect?

    /// The drop's own outline: 0 in the middle, 1 on the edge.
    func dropRho(at p: CGPoint) -> Double {
        guard radius > 0 else { return .infinity }
        var e = inverse * SIMD2(Double(p.x - center.x), Double(p.y - center.y))
        let along = simd_dot(e, tailDirection)
        if along > 0 { e -= tailDirection * along * (tail / (1 + tail)) }
        return simd_length(e)
    }

    /// How far `p` is into the area (points; negative outside it).
    func edgeDistance(at p: CGPoint) -> CGFloat {
        guard let area, !area.isNull else { return .infinity }
        return min(p.x - area.minX, area.maxX - p.x, p.y - area.minY, area.maxY - p.y)
    }

    /// 0 in the middle, 1 on the edge, the drop merged with the area's edge (same as the shader).
    func rho(at p: CGPoint) -> Double {
        let a = dropRho(at: p)
        let d = edgeDistance(at: p)
        guard d.isFinite, a.isFinite, radius > 0 else { return a }
        return 1 + ScreenDrop.merged(a - 1, Double(d / radius) + ScreenDrop.mergeOffset).distance
    }

    /// The picture's point that shows at `p`: inside the flat middle, pulled towards the middle by the magnification;
    /// in the bevel, pushed out along the ray from the middle as well (same as the shader, before dispersion).
    func source(at p: CGPoint) -> CGPoint {
        let rho = rho(at: p)
        guard rho < 1 else { return p }
        let m = Double(magnification)
        let d = SIMD2(Double(p.x - center.x), Double(p.y - center.y))
        var s = SIMD2(Double(center.x), Double(center.y)) + d / m
        let x = ScreenDrop.bevelPosition(rho)
        let r = dropRho(at: p)
        if x > 0, r > 1e-9 { s += d * (refraction * ScreenDrop.profile(x) / r) }
        return CGPoint(x: s.x, y: s.y)
    }
}

/// The springs behind the drop: its place (`ScreenLoupe.follow`), how far it has swelled (`appear` / `disappear`),
/// its stretch (`ScreenDrop.deform`, from the place's velocity) and its tail (`ScreenDrop.tail`).
struct ScreenDropMotion: Equatable, Sendable {
    var x = ScreenSpring(0)
    var y = ScreenSpring(0)
    /// 0 = gone, 1 = full size.
    var presence = ScreenSpring(0)
    var xx = ScreenSpring(0)
    var xy = ScreenSpring(0)
    var tailX = ScreenSpring(0)
    var tailY = ScreenSpring(0)
    /// The pop's wobble (`ScreenDrop.pop`): added to `xx`.
    var pop = ScreenSpring(0)
    /// Shown, or on its way in (false: shrinking away or gone).
    private(set) var visible = false

    /// Head for `point`; appearing from nothing (or `jump`): start there.
    mutating func aim(at point: CGPoint, jump: Bool = false) {
        if jump || (!visible && presence.value < 0.05) {
            x = ScreenSpring(Double(point.x))
            y = ScreenSpring(Double(point.y))
        } else {
            x.target = Double(point.x)
            y.target = Double(point.y)
        }
    }

    mutating func setVisible(_ on: Bool, animated: Bool = true, reduceMotion: Bool = false) {
        visible = on
        presence.target = on ? 1 : 0
        if !animated { presence = ScreenSpring(on ? 1 : 0) }
        if !on, !animated {
            xx = ScreenSpring(0); xy = ScreenSpring(0); tailX = ScreenSpring(0); tailY = ScreenSpring(0); pop = ScreenSpring(0)
        }
        // the jelly kick: tall when it pops up from nothing, flat as it goes
        guard animated, !reduceMotion else { return }
        if on, presence.value < 0.3 { pop.velocity = ScreenDrop.popIn } else if !on { pop.velocity += ScreenDrop.popOut }
    }

    mutating func step(_ dt: Double, reduceMotion: Bool) {
        x.step(dt, ScreenLoupe.follow)
        y.step(dt, ScreenLoupe.follow)
        presence.step(dt, reduceMotion ? ScreenDrop.reducedPresence : visible ? ScreenLoupe.appear : ScreenLoupe.disappear)
        let d = reduceMotion ? (xx: 0.0, xy: 0.0, tail: CGVector.zero)
            : ScreenDrop.deformation(velocity: CGVector(dx: x.velocity, dy: y.velocity))
        xx.target = d.xx
        xy.target = d.xy
        tailX.target = Double(d.tail.dx)
        tailY.target = Double(d.tail.dy)
        for i in [\ScreenDropMotion.xx, \.xy] { self[keyPath: i].step(dt, ScreenDrop.deform) }
        for i in [\ScreenDropMotion.tailX, \.tailY] { self[keyPath: i].step(dt, ScreenDrop.tail) }
        pop.step(dt, ScreenDrop.pop)
        if reduceMotion {
            xx = ScreenSpring(0); xy = ScreenSpring(0); tailX = ScreenSpring(0); tailY = ScreenSpring(0); pop = ScreenSpring(0)
        }
    }

    /// Nothing moves any more.
    var settled: Bool {
        x.settled(epsilon: 0.05) && y.settled(epsilon: 0.05) && presence.settled()
            && xx.settled(epsilon: 0.0005) && xy.settled(epsilon: 0.0005)
            && tailX.settled(epsilon: 0.0005) && tailY.settled(epsilon: 0.0005) && pop.settled(epsilon: 0.0005)
    }

    /// The shape for a drop of `radius` whose middle magnifies `magnification` once full, merging with the edge of
    /// `area` (the picture as it shows; nil: none).
    func shape(radius: CGFloat, magnification m: CGFloat, inside area: CGRect? = nil) -> ScreenDropShape {
        let p = min(max(presence.value, 0), ScreenDrop.maxPresence)
        let r = radius * CGFloat(p)
        let mag = 1 + (m - 1) * CGFloat(min(p, 1))
        // the deformation is kept within what the drawing's box has room for
        func clamped(_ a: Double, _ b: Double) -> (Double, Double) {
            let n = hypot(a, b), limit = ScreenDrop.maxDeformation
            return n > limit && n.isFinite ? (a * limit / n, b * limit / n) : (n.isFinite ? (a, b) : (0, 0))
        }
        let (sxx, sxy) = clamped(xx.value + pop.value, xy.value)
        let (tx, ty) = clamped(tailX.value, tailY.value)
        let inverse = r > 0 ? ScreenDrop.stretch(xx: -sxx, xy: -sxy) * (1 / Double(r)) : matrix_identity_double2x2
        let tail = hypot(tx, ty)
        var direction = SIMD2<Double>.zero
        if tail > 1e-6 {
            let t = inverse * SIMD2(tx / tail, ty / tail)
            direction = simd_length(t) > 0 ? simd_normalize(t) : .zero
        }
        return ScreenDropShape(center: CGPoint(x: x.value, y: y.value), radius: r, magnification: mag,
                               refraction: ScreenDrop.refraction(magnification: Double(mag)) * min(p, 1),
                               presence: min(p, 1), opacity: min(p / ScreenDrop.opaquePresence, 1), inverse: inverse,
                               tailDirection: direction, tail: tail, area: area.flatMap { $0.isNull ? nil : $0 })
    }
}

#if DEBUG
/// `-YoyoLoupePath YES`: a fixed course for the pointer (normalized) so the drop's motion can be filmed in the
/// simulator without touches: a slow drift, flings that stop dead, a circle, a lift and a new touch, a small jerk.
enum ScreenDropCourse {
    static let duration = 10.0

    /// Where the pointer is `t` seconds into the course, and whether a finger is down.
    static func at(_ t: Double) -> (point: CGPoint, down: Bool) {
        func ease(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
            let u = min(max(u, 0), 1), s = u * u * (3 - 2 * u)
            return CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
        }
        let a = CGPoint(x: 0.2, y: 0.3), b = CGPoint(x: 0.5, y: 0.35), c = CGPoint(x: 0.82, y: 0.62)
        let d = CGPoint(x: 0.2, y: 0.6), o = CGPoint(x: 0.5, y: 0.5), e = CGPoint(x: 0.3, y: 0.3)
        let ring = CGPoint(x: o.x + 0.18, y: o.y)
        switch t {
        case ..<2: return (ease(a, b, t / 2), true)
        case ..<2.2: return (ease(b, c, (t - 2) / 0.2), true)
        case ..<3.2: return (c, true)
        case ..<3.45: return (ease(c, d, (t - 3.2) / 0.25), true)
        case ..<4.3: return (d, true)
        case ..<4.6: return (ease(d, ring, (t - 4.3) / 0.3), true)
        case ..<6.6:
            let angle = (t - 4.6) * .pi
            return (CGPoint(x: o.x + 0.18 * cos(angle), y: o.y + 0.25 * sin(angle)), true)
        case ..<7.3: return (ring, true)
        case ..<7.9: return (e, false)
        case ..<8.6: return (e, true)
        case ..<8.7: return (ease(e, CGPoint(x: 0.38, y: 0.3), (t - 8.6) / 0.1), true)
        default: return (CGPoint(x: 0.38, y: 0.3), true)
        }
    }
}
#endif
