import CoreVideo
import Metal
import QuartzCore
import UIKit
import VideoToolbox
import YoyoClipboard
import YoyoCore
import os
import simd

/// The video's pictures for the drop, from the decoders' queues (`ScreenVideoOutput`'s mirror): keeps the newest and
/// wakes the drop on main to draw it.
final class ScreenDropFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: CVPixelBuffer?
    private var waking = false
    /// Set once on main, before any picture comes; called on main.
    nonisolated(unsafe) fileprivate var onFrame: (@MainActor () -> Void)?

    func receive(_ image: CVPixelBuffer) {
        let wake = lock.withLock { () -> Bool in
            newest = image
            defer { waking = true }
            return !waking
        }
        guard wake else { return }
        Task { @MainActor in
            self.lock.withLock { self.waking = false }
            self.onFrame?()
        }
    }

    var latest: CVPixelBuffer? { lock.withLock { newest } }

    func clear() { lock.withLock { newest = nil } }
}

/// The liquid-glass lens over the pointer (`ScreenDrop`), drawn with Metal into a layer around it (above the picture,
/// under the pointer): the picture under it is sampled from the same source the page shows (the still image, or the
/// video's decoded pictures), magnified in the middle and refracted with a rainbow at the bevel, with light on its rim
/// and a faint shadow around it. Outside that the layer is transparent, so the page's own picture shows. Driven by springs every frame while it
/// moves (`ScreenDropMotion`); a new video picture redraws it at rest. Never takes touches.
final class ScreenDropView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    let frames = ScreenDropFrames()
    private var motion = ScreenDropMotion()
    private var picture: CGRect = .zero
    private var magnification: CGFloat = 1
    private var radius: CGFloat = 76
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    /// Shown, or on its way in (false: shrinking away or gone).
    var visible: Bool { motion.visible }
    /// How much it magnifies at the pointer right now (1 when gone), every frame it draws: the pointer over it grows
    /// as much, as if seen through it.
    var onMagnification: ((CGFloat) -> Void)?
    private var reportedMagnification: CGFloat = 1

    /// Over a still picture: dimmed like it (`YoyoScreenPictureView.dimAlpha`).
    var dim: CGFloat = 0 { didSet { if dim != oldValue { draw() } } }
    /// A held touch armed a drag: the bevel turns clay.
    var tinted = false { didSet { if tinted != oldValue { draw() } } }

    /// The still picture (used while `showsVideo` is false).
    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            // the previous picture's texture stays until this one's is ready (no blank frame in between)
            imageGeneration += 1
            if visible { loadImage() }
        }
    }
    /// The video's pictures are what shows (`frames`).
    var showsVideo = false { didSet { if !showsVideo { frames.clear() } } }

    private var imageTexture: MTLTexture?
    private var imageGeneration = 0
    private var loadingGeneration: Int?
    /// The `image` generation `imageTexture` was made from.
    private var loadedGeneration: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        isOpaque = false
        backgroundColor = .clear
        accessibilityIdentifier = "screen.loupe"
        metalLayer.device = ScreenDropRenderer.shared?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        // the drawing and the layer's move land in the same frame (else its 1× edge would slide against the page)
        metalLayer.presentsWithTransaction = true
        metalLayer.colorspace = ScreenDropRenderer.sRGB
        frames.onFrame = { [weak self] in
            guard let self, self.showsVideo, !self.isHidden else { return }
            self.draw()
        }
        ScreenDropRenderer.shared?.prepare()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Look at `point` (the superview's coordinates) of `picture` (its frame there), its middle `magnification` times
    /// bigger, `radius` points at rest. Showing: it springs there; appearing: it starts there.
    func aim(at point: CGPoint, picture: CGRect, magnification m: CGFloat, radius r: CGFloat) {
        self.picture = picture
        magnification = m
        radius = r
        motion.aim(at: point, jump: UIAccessibility.isReduceMotionEnabled)
        run()
    }

    func setVisible(_ on: Bool, animated: Bool) {
        guard on != visible else { return }
        motion.setVisible(on, animated: animated, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        if on {
            isHidden = false
            if !showsVideo, imageTexture == nil || loadedGeneration != imageGeneration { loadImage() }
        }
        run()
    }

    private func run() {
        if link == nil, window != nil {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
            lastTick = nil
        }
        draw()
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let dt = min(lastTick.map { now - $0 } ?? (1.0 / 120), 1.0 / 30)
        lastTick = now
        motion.step(dt, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        draw()
        if motion.settled {
            l.invalidate()
            link = nil
            if !visible { hide() }
        }
    }

    // the display link holds this view: off screen, it stops
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { if !motion.settled { run() }; return }
        link?.invalidate()
        link = nil
    }

    // the still picture's texture stays for the next touch (made again, it would miss the pop: it takes a moment)
    private func hide() {
        isHidden = true
        report(1)
        ScreenDropRenderer.shared?.flush()
    }

    private func report(_ m: CGFloat) {
        guard abs(m - reportedMagnification) > 0.001 else { return }
        reportedMagnification = m
        onMagnification?(m)
    }

    /// The still picture as a texture, off the main thread (drawn into sRGB, like the layer).
    private func loadImage() {
        guard let renderer = ScreenDropRenderer.shared, let cg = image?.cgImage, loadingGeneration != imageGeneration else { return }
        let generation = imageGeneration
        loadingGeneration = generation
        let source = UncheckedSendable(cg)
        let device = UncheckedSendable(renderer.device)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let texture = ScreenDropRenderer.texture(from: source.value, device: device.value).map(UncheckedSendable.init)
            Task { @MainActor [weak self] in
                guard let self, self.imageGeneration == generation else { return }
                self.loadingGeneration = nil
                self.loadedGeneration = generation
                self.imageTexture = texture?.value
                self.draw()
            }
        }
    }

    /// Place the layer around the drop and draw it as the springs have it now.
    private func draw() {
        guard !isHidden, let renderer = ScreenDropRenderer.shared, superview != nil, picture.width > 0, picture.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        // it merges with the edge of the picture as it shows (and is cut off past it)
        let shape = motion.shape(radius: radius, magnification: magnification, inside: picture.intersection(superview?.bounds ?? picture))
        report(shape.radius > 0.5 ? shape.magnification : 1)
        // a square around the drop's middle, on the pixel grid (the picture under it lines up pixel for pixel)
        let side = ceil(radius * ScreenDrop.box * scale) / scale
        let origin = CGPoint(x: (round((shape.center.x - side / 2) * scale)) / scale,
                             y: (round((shape.center.y - side / 2) * scale)) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if bounds.size != CGSize(width: side, height: side) || center != CGPoint(x: origin.x + side / 2, y: origin.y + side / 2) {
            bounds = CGRect(x: 0, y: 0, width: side, height: side)
            center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        }
        let pixels = CGSize(width: side * scale, height: side * scale)
        if metalLayer.drawableSize != pixels { metalLayer.drawableSize = pixels }
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }

        let source: ScreenDropRenderer.Source?
        if showsVideo, let buffer = frames.latest {
            source = renderer.source(buffer)
            if let space = source?.colorSpace, metalLayer.colorspace.map({ !CFEqual($0, space) }) ?? true { metalLayer.colorspace = space }
        } else if !showsVideo, let imageTexture {
            source = .init(planes: [imageTexture], yuv: nil, uv: SIMD4(0, 0, 1, 1), keep: [], colorSpace: nil)
            if metalLayer.colorspace.map({ !CFEqual($0, ScreenDropRenderer.sRGB) }) ?? true { metalLayer.colorspace = ScreenDropRenderer.sRGB }
        } else {
            source = nil
        }
        let plain = UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled
        let outline = (tinted ? Theme.coral : UIColor.label).resolvedColor(with: traitCollection)
        renderer.draw(into: metalLayer, shape: shape, origin: origin, pointsPerPixel: 1 / scale, picture: picture,
                      source: source, dim: dim, plain: plain, outline: outline, tint: tinted ? 1 : 0)
    }
}

/// A value carried across threads where it is only handed over, never shared (a texture made on a background queue,
/// an image read there).
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The Metal side of the drop: one device, queue and pipeline for the app (the shader is compiled from source once,
/// off the main thread, the first time a screen page opens), the video pictures' texture cache.
@MainActor
final class ScreenDropRenderer {
    static let shared = ScreenDropRenderer()
    nonisolated static let log = Logger(subsystem: "ca.sarria.yoyocontrol", category: "screen-drop")

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var compiling = false
    private var cache: CVMetalTextureCache?
    /// Pixel formats already logged as not drawn.
    private var unsupported = Set<OSType>()
    /// Bound where a picture has no second plane.
    private let blank: MTLTexture?

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.cache = cache
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: d)
    }

    /// Compile the shader (once, in the background).
    func prepare() {
        guard pipeline == nil, !compiling else { return }
        compiling = true
        let device = UncheckedSendable(device)
        DispatchQueue.global(qos: .userInitiated).async {
            let state: MTLRenderPipelineState?
            do {
                let library = try device.value.makeLibrary(source: ScreenDropShader.source, options: nil)
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "dropVertex")
                d.fragmentFunction = library.makeFunction(name: "dropFragment")
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                state = try device.value.makeRenderPipelineState(descriptor: d)
            } catch {
                ScreenDropRenderer.log.error("drop shader: \(error.localizedDescription, privacy: .public)")
                state = nil
            }
            let result = UncheckedSendable(state)
            Task { @MainActor in
                ScreenDropRenderer.shared?.pipeline = result.value
                ScreenDropRenderer.shared?.compiling = false
            }
        }
    }

    func flush() {
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    /// What the shader samples: one plane (BGRA) or two (Y′, CbCr: `yuv` set), the part of them that is the picture
    /// (`uv`: origin, size), and what must live until the GPU is done.
    struct Source {
        var planes: [MTLTexture]
        var yuv: (rows: [SIMD3<Float>], offset: SIMD3<Float>)?
        var uv: SIMD4<Float>
        var keep: [CVMetalTexture]
        var colorSpace: CGColorSpace?
    }

    /// A decoded video picture as textures (no copy). Nil for a format it can't sample.
    func source(_ buffer: CVPixelBuffer) -> Source? {
        guard let cache else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planes: [MTLPixelFormat]
        var fullRange = false
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_Lossless_32BGRA: planes = [.bgra8Unorm]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange:
            planes = [.r8Unorm, .rg8Unorm]
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
            planes = [.r8Unorm, .rg8Unorm]
            fullRange = true
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            planes = [.r16Unorm, .rg16Unorm]
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            planes = [.r16Unorm, .rg16Unorm]
            fullRange = true
        default:
            // anything else: converted to BGRA first (in hardware), so the drop always has a picture
            if unsupported.insert(format).inserted {
                Self.log.error("drop: video pixel format \(format, privacy: .public) is converted")
            }
            guard format != kCVPixelFormatType_32BGRA, let bgra = converted(buffer) else { return nil }
            return source(bgra)
        }
        var textures: [MTLTexture] = []
        var keep: [CVMetalTexture] = []
        for (i, pixelFormat) in planes.enumerated() {
            let planar = CVPixelBufferIsPlanar(buffer)
            let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, i) : CVPixelBufferGetWidth(buffer)
            let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, i) : CVPixelBufferGetHeight(buffer)
            var t: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, pixelFormat, w, h, i, &t) == kCVReturnSuccess,
                  let t, let texture = CVMetalTextureGetTexture(t) else { return nil }
            textures.append(texture)
            keep.append(t)
        }
        var yuv: (rows: [SIMD3<Float>], offset: SIMD3<Float>)?
        if planes.count == 2 {
            let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            let k = ScreenDrop.lumaWeights(matrix: matrix)
            yuv = ScreenDrop.yuvToRGB(kr: k.kr, kb: k.kb, fullRange: fullRange)
        }
        // the clean aperture: the part the display layer shows (the decoder may pad the frame)
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let clean = CVImageBufferGetCleanRect(buffer)
        let uv = size.width > 0 && size.height > 0 && clean.width > 0 && clean.height > 0
            ? SIMD4(Float(clean.minX / size.width), Float(clean.minY / size.height),
                    Float(clean.width / size.width), Float(clean.height / size.height))
            : SIMD4<Float>(0, 0, 1, 1)
        return Source(planes: textures, yuv: yuv, uv: uv, keep: keep, colorSpace: colorSpace(of: buffer))
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Color spaces made from the pictures' tags, by their tags (made once, not per picture).
    private var spaces: [String: CGColorSpace] = [:]

    /// The color space the video's pictures are tagged with (BT.709 when untagged), so the drop matches the display
    /// layer's own color matching.
    private func colorSpace(of buffer: CVPixelBuffer) -> CGColorSpace? {
        let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        let tag = keys.map { (CVBufferCopyAttachment(buffer, $0, nil) as? String) ?? "" }.joined(separator: "|")
        if let space = spaces[tag] { return space }
        var space: CGColorSpace?
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) {
            space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
        }
        let result = space ?? CGColorSpace(name: CGColorSpace.itur_709)
        spaces[tag] = result
        return result
    }

    private var transfer: VTPixelTransferSession?

    /// `buffer` as a BGRA picture (for a pixel format the shader doesn't read).
    private func converted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil { VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) }
        guard let transfer else { return nil }
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out) == kCVReturnSuccess,
              let out, VTPixelTransferSessionTransferImage(transfer, from: buffer, to: out) == noErr else { return nil }
        return out
    }

    /// `image` drawn into an sRGB BGRA texture (any thread).
    nonisolated static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let (w, h) = (image.width, image.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return texture
    }

    /// The uniforms, in the shader's layout (float4s only, so both sides agree).
    struct Uniforms {
        var box: SIMD4<Float>        // origin (pt), points per pixel
        var center: SIMD4<Float>     // center (pt), flat radius (unit space), magnification
        var shape: SIMD4<Float>      // points → unit space, row major
        var tail: SIMD4<Float>       // direction (unit space), amount, radius (pt)
        var picture: SIMD4<Float>    // origin, size (pt)
        var uv: SIMD4<Float>         // the picture's part of the texture: origin, size
        var yuv0: SIMD4<Float>
        var yuv1: SIMD4<Float>
        var yuv2: SIMD4<Float>
        var yuvOffset: SIMD4<Float>  // w: 1 = two planes
        var light: SIMD4<Float>      // refraction (radii), dispersion, presence (light and shadow), dim
        var style: SIMD4<Float>      // plain, opacity, outline width (unit space), tint (the bevel in the outline's colour)
        var outline: SIMD4<Float>
        var area: SIMD4<Float>       // the picture as it shows, whose edge it merges with: origin, size (pt)
    }

    /// Draws the drop into `layer` (whose box starts at `origin`, canvas points); no source: a clear layer.
    func draw(into layer: CAMetalLayer, shape: ScreenDropShape, origin: CGPoint, pointsPerPixel: CGFloat, picture: CGRect,
              source: Source?, dim: CGFloat, plain: Bool, outline: UIColor, tint: Float = 0) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pipeline, let source, shape.radius > 0.5 {
            let inv = shape.inverse
            let area = shape.area ?? picture
            let yuv = source.yuv
            var o: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 1)
            outline.getRed(&o.0, green: &o.1, blue: &o.2, alpha: &o.3)
            var u = Uniforms(
                box: SIMD4(Float(origin.x), Float(origin.y), Float(pointsPerPixel), 0),
                center: SIMD4(Float(shape.center.x), Float(shape.center.y), Float(ScreenDrop.flatRadius), Float(shape.magnification)),
                shape: SIMD4(Float(inv[0][0]), Float(inv[1][0]), Float(inv[0][1]), Float(inv[1][1])),
                tail: SIMD4(Float(shape.tailDirection.x), Float(shape.tailDirection.y), Float(shape.tail), Float(shape.radius)),
                picture: SIMD4(Float(picture.minX), Float(picture.minY), Float(picture.width), Float(picture.height)),
                uv: source.uv,
                yuv0: SIMD4(yuv?.rows[0] ?? .zero, 0), yuv1: SIMD4(yuv?.rows[1] ?? .zero, 0), yuv2: SIMD4(yuv?.rows[2] ?? .zero, 0),
                yuvOffset: SIMD4(yuv?.offset ?? .zero, yuv == nil ? 0 : 1),
                light: SIMD4(Float(shape.refraction), Float(ScreenDrop.dispersion), Float(shape.presence), Float(dim)),
                style: SIMD4(plain ? 1 : 0, Float(shape.opacity), Float(2 / max(shape.radius, 1)), tint),
                outline: SIMD4(Float(o.0), Float(o.1), Float(o.2), 1),
                area: SIMD4(Float(area.minX), Float(area.minY), Float(area.width), Float(area.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(source.planes[0], index: 0)
            encoder.setFragmentTexture(source.planes.count > 1 ? source.planes[1] : blank, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        let keep = UncheckedSendable(source?.keep ?? [])
        buffer.addCompletedHandler { _ in withExtendedLifetime(keep) {} }
        buffer.commit()
        // presentsWithTransaction: present inside the transaction that moves the layer
        buffer.waitUntilScheduled()
        drawable.present()
    }
}

/// The drop's shader (compiled at run time: no Metal toolchain needed to build the app). Mirrors `ScreenDropShape`.
enum ScreenDropShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U { float4 box, center, shape, tail, picture, uv, yuv0, yuv1, yuv2, yuvOffset, light, style, outline, area; };
    struct V { float4 position [[position]]; };

    vertex V dropVertex(uint id [[vertex_id]]) {
        float2 p = float2(float((id << 1) & 2), float(id & 2));
        V v;
        v.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return v;
    }

    // The picture at `pt` (canvas points); `a`: 1 inside the picture, 0 outside (soft over a pixel).
    static float3 pictureAt(float2 pt, constant U &u, texture2d<float> t0, texture2d<float> t1, sampler s, thread float &a) {
        float2 q = (pt - u.picture.xy) / u.picture.zw;
        float2 inside = min(q, 1.0 - q) * u.picture.zw / u.box.z;
        a = saturate(min(inside.x, inside.y) + 0.5);
        float2 uv = u.uv.xy + saturate(q) * u.uv.zw;
        if (u.yuvOffset.w < 0.5) return t0.sample(s, uv).rgb;
        float3 yuv = float3(t0.sample(s, uv).r, t1.sample(s, uv).rg) - u.yuvOffset.xyz;
        return saturate(float3(dot(u.yuv0.xyz, yuv), dot(u.yuv1.xyz, yuv), dot(u.yuv2.xyz, yuv)));
    }

    // How far `p` is into `area` (points; negative outside it), and the way in from its nearest edge.
    static float edgeDistance(float2 p, float4 area, thread float2 &inward) {
        float l = p.x - area.x, r = area.x + area.z - p.x, t = p.y - area.y, b = area.y + area.w - p.y;
        float dx = min(l, r), dy = min(t, b);
        if (dx < dy) { inward = float2(l < r ? 1.0 : -1.0, 0.0); return dx; }
        inward = float2(0.0, t < b ? 1.0 : -1.0);
        return dy;
    }

    // The weight of a wavelength in each channel, `w` from -1 (red: bent the least) to 1 (violet: the most).
    static float3 spectrum(float w) {
        float3 d = (w - float3(-0.7, 0.0, 0.7)) / 0.55;
        return exp(-d * d);
    }

    fragment float4 dropFragment(V in [[stage_in]], constant U &u [[buffer(0)]],
                                 texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 p = u.box.xy + in.position.xy * u.box.z;
        float2 d = p - u.center.xy;
        float2 e = float2(dot(u.shape.xy, d), dot(u.shape.zw, d));
        // the trailing side is longer: its coordinate is shortened
        float along = dot(e, u.tail.xy);
        if (along > 0.0) e -= u.tail.xy * along * (u.tail.z / (1.0 + u.tail.z));
        float drop = length(e);
        // merged with the edge of the picture as it shows (`ScreenDrop.merged`): a smooth minimum of the drop's outline
        // and the edge's (moved out a little, so the edge alone is no glass), in radii; `h`: how much is the drop's
        float2 inward;
        float edge = edgeDistance(p, u.area, inward);
        float a0 = drop - 1.0, b0 = edge / max(u.tail.w, 1.0) + \(ScreenDrop.mergeOffset);
        const float k = \(ScreenDrop.merge);
        float h = saturate(0.5 + 0.5 * (b0 - a0) / k);
        float rho = 1.0 + mix(b0, a0, h) - k * h * (1.0 - h);
        float w = max(fwidth(rho), 1e-4);
        // only what is on the picture as it shows (soft over a pixel)
        float on = saturate(edge / u.box.z + 0.5);
        float presence = u.light.z;
        // a faint shadow round it (the glass lifts off the picture)
        float shadow = presence * 0.16 * pow(saturate(1.0 - (drop - 1.0) / 0.2), 2.0);
        // it fades in and out as it pops
        on *= u.style.y;
        if (rho >= 1.0 + w) return float4(0.0, 0.0, 0.0, shadow * on);
        float cover = 1.0 - smoothstep(1.0 - w, 1.0 + w, rho);
        float m = u.center.w;
        float a;
        float2 da = p - u.center.xy;

        if (u.style.x > 0.5) {
            // Reduce Transparency / Increase Contrast: a sharp disc magnified evenly, a solid rim
            float3 c = pictureAt(u.center.xy + da / m, u, t0, t1, s, a) * (1.0 - u.light.w);
            float rim = smoothstep(1.0 - u.style.z - w, 1.0 - u.style.z, rho);
            float4 col = mix(float4(c, 1.0), float4(u.outline.rgb, 1.0), rim);
            return col * cover * on;
        }

        // magnified evenly around the middle (the pointer); in the bevel (`ScreenDrop.profile`) also pushed out along the ray from
        // the middle, steeper and steeper towards the rim, so the picture round the drop squeezes into it
        float flat = u.center.z;
        float x = saturate((rho - flat) / (1.0 - flat));
        float3 c;
        if (x > 0.0) {
            const float k = 0.97;
            float n0 = 1.0 - sqrt(1.0 - k * k);
            float root = sqrt(1.0 - k * k * x * x);
            float profile = (1.0 - root) / n0;
            float slope = k * k * x / (root * n0);
            float depth = u.light.x;
            // `ray`: the way out from the middle in points, one radius long (here)
            float2 ray = d / max(drop, 1e-4);
            float2 dir = normalize(ray);
            // how many of the picture's pixels one pixel spans across the bevel: the taps spread over that (no
            // sparkle on thin text where it squeezes hardest)
            float squeeze = 1.0 / m + depth * slope / (1.0 - flat);
            float spread = 0.5 * squeeze * u.box.z;
            // eight wavelengths, each bent a little differently (red least, violet most): the rainbow at the rim
            float3 sum = float3(0.0), weight = float3(0.0);
            for (int i = 0; i < 8; i++) {
                float wl = (float(i) + 0.5) / 4.0 - 1.0;
                float2 q = u.center.xy + da / m + ray * depth * profile * (1.0 + u.light.y * wl) + dir * spread * wl;
                float3 wt = spectrum(wl);
                sum += pictureAt(q, u, t0, t1, s, a) * wt;
                weight += wt;
            }
            c = sum / weight;
        } else {
            c = pictureAt(u.center.xy + da / m, u, t0, t1, s, a);
        }

        // a held touch armed a drag: the bevel takes the outline's colour (clay)
        c = mix(c, u.outline.rgb, u.style.w * 0.6 * smoothstep(0.0, 0.6, x));
        c *= 1.0 - u.light.w;
        // the glass: a slight milky lift (blacks lift a little, whites stay), more in the bevel
        c = mix(c, float3(1.0), presence * (0.045 + 0.05 * x * x));
        // light from the upper left: a thin line round the rim, brightest facing it and on the far side (where it
        // comes out again), and a soft sheen over the lit side of the bevel
        // (the outline's normal: the drop's, turning into the edge's along the fillet)
        float2 n = mix(inward, drop > 1e-4 ? e / drop : float2(0.0), h);
        n = length(n) > 1e-4 ? normalize(n) : float2(0.0);
        float facing = dot(n, normalize(float2(-0.55, -0.85)));
        float rim = (1.0 - rho) / u.style.z;
        float line = exp(-rim * rim * 1.2);
        float hl = presence * (line * (0.22 + 0.7 * pow(abs(facing), 3.0)) + 0.12 * x * x * x * saturate(facing));
        c = c + (1.0 - c) * saturate(hl);
        return (float4(c, 1.0) * cover + float4(0.0, 0.0, 0.0, shadow) * (1.0 - cover)) * on;
    }
    """
}
