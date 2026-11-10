#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Client-drawn pointer for `cursor=client` streams (round 3 wire spec): instead of compositing the pointer
// into every picture, the stream sends small cursor JSON parts (`StreamWire.cursor`) with its position,
// visibility and (when it changed) its shape as a PNG. Every coordinate is in the space of `POST /input`
// x/y for that display: normalized 0…1 of the display (x = 0 left edge, 1 right edge), so a client
// overlays the pointer exactly where its touches land.
//
// The shape is the system's current cursor (DisplayPointer.swift), else the built-in arrow (shapeId 0), 26 px tall
// per 1600 px of picture width and rendered at 2x that for a crisp PNG.

/// What a cursor part says, minus the shape payload.
struct ClientCursor: Equatable, Sendable {
    var x: Double
    var y: Double
    var visible: Bool
    var shapeId: Int
}

/// A cursor shape in `/input` coordinates (normalized to the display), with its PNG.
struct ClientCursorShape: Sendable {
    let id: Int
    let png: Data
    let hotX: Double
    let hotY: Double
    let width: Double
    let height: Double

    var json: [String: Any] {
        ["id": id, "png": png.base64EncodedString(), "hotX": hotX, "hotY": hotY, "width": width, "height": height]
    }

    /// Height of the built-in arrow's visible rows as a fraction of the picture WIDTH (the composite's 26 px per 1600).
    static let arrowWidthFraction = 26.0 / 1600
    /// The built-in arrow is rendered this many times its nominal 26 px for the PNG.
    static let arrowRenderScale = 2.0

    private static let arrowLock = NSLock()
    nonisolated(unsafe) private static var arrowCache: (cursor: CursorImage, png: Data)?  // guarded by `arrowLock`

    /// The built-in arrow (shapeId 0) for a `width` × `height` display.
    static func builtinArrow(width: Int, height: Int) -> ClientCursorShape? {
        arrowLock.lock()
        if arrowCache == nil {
            let cursor = CursorImage.arrow(visibleHeight: Int((26 * arrowRenderScale).rounded()))
            if let png = pngData(cursor) { arrowCache = (cursor, png) }
        }
        let cached = arrowCache
        arrowLock.unlock()
        guard let (cursor, png) = cached, width > 0, height > 0, cursor.visibleHeight > 0 else { return nil }
        // Normalized units per PNG pixel: horizontally k, vertically k × (display width / height).
        let k = arrowWidthFraction / Double(cursor.visibleHeight)
        let aspect = Double(width) / Double(height)
        return ClientCursorShape(id: 0, png: png, hotX: Double(cursor.hotspotX) * k, hotY: Double(cursor.hotspotY) * k * aspect,
                                 width: Double(cursor.width) * k, height: Double(cursor.height) * k * aspect)
    }

    /// PNG of a premultiplied-RGBA cursor.
    static func pngData(_ c: CursorImage) -> Data? {
        guard !c.isEmpty, let provider = CGDataProvider(data: Data(c.rgba) as CFData),
              let image = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

enum StreamCursorPart {
    /// The JSON body of a cursor part; `shape` only when it changed since the last part (and in the first).
    static func body(_ c: ClientCursor, shape: ClientCursorShape?) -> Data {
        var obj: [String: Any] = ["x": c.x, "y": c.y, "visible": c.visible, "shapeId": c.shapeId]
        if let shape { obj["shape"] = shape.json }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// A cursor image: premultiplied RGBA8, row-major, tightly packed (`width * 4` bytes per row), with the hotspot (the
/// pixel under the pointer position) in image coordinates.
struct CursorImage: Sendable, Equatable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    /// Premultiplied RGBA8, `width * height * 4` bytes.
    let rgba: [UInt8]
    /// Height of the rows that hold any visible pixel (the image is padded with transparent rows).
    let visibleHeight: Int

    var isEmpty: Bool { width == 0 || height == 0 || visibleHeight == 0 }

    init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, premultipliedRGBA rgba: [UInt8]) {
        precondition(width >= 0 && height >= 0 && rgba.count == width * height * 4, "cursor size mismatch")
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgba = rgba
        var top = -1, bottom = -1
        for y in 0..<height {
            var any = false
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] != 0 { any = true; break }
            if any { if top < 0 { top = y }; bottom = y }
        }
        self.visibleHeight = top < 0 ? 0 : bottom - top + 1
    }

    // MARK: built-in arrow

    /// The arrow rasterised so its visible rows are as close to `visibleHeight` px as the unit
    /// allows (the outline polygon plus its border is ~20.4 units tall). Crisp at any size: drawn
    /// natively, never resampled.
    static func arrow(visibleHeight target: Int) -> CursorImage {
        let t = max(8, target)
        var unit = Double(t) / 20.4
        var best = makeArrow(unit: unit)
        // Nudge the unit until the anti-aliased height lands on the target (a couple of tries).
        for _ in 0..<3 where best.visibleHeight != t {
            unit *= Double(t) / Double(max(best.visibleHeight, 1))
            let next = makeArrow(unit: unit)
            if abs(next.visibleHeight - t) < abs(best.visibleHeight - t) { best = next }
        }
        return best
    }

    /// Rasterise the arrow at `unit` pixels per arrow unit (the outline polygon is ~11 × 18 units),
    /// 4×4 supersampled for anti-aliased edges. The tip sits at pixel (pad, pad) = the hotspot (3,3 at the default unit).
    static func makeArrow(unit: Double) -> CursorImage {
        // Black body, tip at the origin, clockwise: left edge down, notch, tail, right wing.
        let body: [(Double, Double)] = [
            (0, 0), (0, 15.5), (3.7, 12.0), (6.3, 17.8), (8.6, 16.8), (6.0, 11.2), (11.0, 11.0),
        ]
        let outline = 1.3 * unit      // white border width, in pixels
        let pad = Int(outline.rounded(.up)) + 1   // transparent margin so the round border isn't clipped
        let pts = body.map { (Double(pad) + $0.0 * unit, Double(pad) + $0.1 * unit) }
        let w = Int((11.0 * unit + 2 * Double(pad)).rounded(.up))
        let h = Int((17.8 * unit + 2 * Double(pad)).rounded(.up))

        func inside(_ px: Double, _ py: Double) -> Bool {
            var c = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let (xi, yi) = pts[i], (xj, yj) = pts[j]
                if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi { c.toggle() }
                j = i
            }
            return c
        }
        func edgeDistance(_ px: Double, _ py: Double) -> Double {
            var best = Double.infinity
            var j = pts.count - 1
            for i in 0..<pts.count {
                let (ax, ay) = pts[j], (bx, by) = pts[i]
                let dx = bx - ax, dy = by - ay
                let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
                let ex = ax + t * dx - px, ey = ay + t * dy - py
                best = min(best, (ex * ex + ey * ey).squareRoot())
                j = i
            }
            return best
        }

        let ss = 4
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var alpha = 0.0, white = 0.0   // coverage of any paint / of white paint
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let px = Double(x) + (Double(sx) + 0.5) / Double(ss)
                        let py = Double(y) + (Double(sy) + 0.5) / Double(ss)
                        if inside(px, py) {
                            alpha += 1
                        } else if edgeDistance(px, py) <= outline {
                            alpha += 1; white += 1
                        }
                    }
                }
                let n = Double(ss * ss)
                let a = UInt8((alpha / n * 255).rounded())
                let v = UInt8((white / n * 255).rounded())   // premultiplied white contribution
                let d = (y * w + x) * 4
                out[d] = v; out[d + 1] = v; out[d + 2] = v; out[d + 3] = a
            }
        }
        return CursorImage(width: w, height: h, hotspotX: pad, hotspotY: pad, premultipliedRGBA: out)
    }
}
#endif
