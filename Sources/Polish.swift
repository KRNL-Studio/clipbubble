import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Polish: make a screenshot presentable. A document is the source image, a crop, a style and the marks drawn on it.
// One renderer draws it for the live preview and for export, so what you see is what you copy.

// MARK: - Color

/// A color that survives JSON.
struct RGBA: Codable, Equatable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha)
    }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? .black
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func alpha(_ x: CGFloat) -> RGBA { RGBA(r, g, b, x) }
    /// Black or white, whichever reads better on this color.
    var contrast: RGBA { (0.299 * r + 0.587 * g + 0.114 * b) > 0.62 ? RGBA(0, 0, 0) : RGBA(1, 1, 1) }

    static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0)
    /// The markup palette: red first, since that's what most arrows want.
    static let palette: [RGBA] = [RGBA(hex: 0xFF3B30), RGBA(hex: 0xFF9500), RGBA(hex: 0xFFCC00), RGBA(hex: 0x34C759),
                                  RGBA(hex: 0x0A84FF), RGBA(hex: 0xBF5AF2), .white, .black]
}

// MARK: - Style

struct PolishStyle: Codable, Equatable {
    enum Background: Codable, Equatable {
        case none
        case solid(RGBA)
        case gradient(Int)        // index into Gradients.all
        case blurred              // the screenshot itself, blurred and dimmed
    }

    enum Frame: String, Codable, CaseIterable { case none, light, dark }

    enum Size: String, Codable, CaseIterable {
        case auto, wide, classic, square, tall, x, linkedin

        var title: String {
            switch self {
            case .auto: return "Auto"
            case .wide: return "16:9"
            case .classic: return "4:3"
            case .square: return "1:1"
            case .tall: return "9:16"
            case .x: return "X post"
            case .linkedin: return "LinkedIn"
            }
        }

        /// Width over height, or nil to wrap the image.
        var aspect: CGFloat? {
            switch self {
            case .auto: return nil
            case .wide, .x: return 16.0 / 9
            case .classic: return 4.0 / 3
            case .square: return 1
            case .tall: return 9.0 / 16
            case .linkedin: return 1200.0 / 627
            }
        }

        /// An exact size in pixels, for the presets made for one site.
        var pixels: CGSize? {
            switch self {
            case .x: return CGSize(width: 1600, height: 900)
            case .linkedin: return CGSize(width: 1200, height: 627)
            default: return nil
            }
        }
    }

    var background: Background = .gradient(0)
    /// Space around the image, as a share of its longer side.
    var padding: CGFloat = 0.08
    /// Corner radius, as a share of the image's shorter side.
    var radius: CGFloat = 0.02
    /// 0 is no shadow, 1 is a deep one.
    var shadow: CGFloat = 0.5
    var frame: Frame = .none
    var size: Size = .auto

    /// Nothing around the image at all: export is the cropped, marked-up image.
    var isPlain: Bool { background == .none && padding == 0 && frame == .none && size == .auto }
}

enum Gradients {
    static let all: [(name: String, colors: [RGBA])] = [
        ("Dusk", [RGBA(hex: 0x6A5AF9), RGBA(hex: 0xD66EFD)]),
        ("Sunset", [RGBA(hex: 0xFF7E5F), RGBA(hex: 0xFEB47B)]),
        ("Ocean", [RGBA(hex: 0x2193B0), RGBA(hex: 0x6DD5ED)]),
        ("Mint", [RGBA(hex: 0x11998E), RGBA(hex: 0x38EF7D)]),
        ("Candy", [RGBA(hex: 0xF953C6), RGBA(hex: 0xB91D73)]),
        ("Peach", [RGBA(hex: 0xFFDDE1), RGBA(hex: 0xEE9CA7)]),
        ("Night", [RGBA(hex: 0x232526), RGBA(hex: 0x414345)]),
        ("Sky", [RGBA(hex: 0xE0EAFC), RGBA(hex: 0xCFDEF3)]),
    ]
}

struct PolishPreset: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var style: PolishStyle

    static let gradient = PolishPreset(name: "Gradient", style: PolishStyle(background: .gradient(0), padding: 0.09, radius: 0.022, shadow: 0.55))

    static let builtIn: [PolishPreset] = [
        PolishPreset(name: "None", style: PolishStyle(background: .none, padding: 0, radius: 0, shadow: 0, frame: .none, size: .auto)),
        PolishPreset(name: "Clean", style: PolishStyle(background: .solid(RGBA(hex: 0xF2F2F7)), padding: 0.07, radius: 0.018, shadow: 0.35)),
        gradient,
        PolishPreset(name: "Window", style: PolishStyle(background: .gradient(2), padding: 0.08, radius: 0.02, shadow: 0.6, frame: .light)),
        PolishPreset(name: "Dark", style: PolishStyle(background: .gradient(6), padding: 0.08, radius: 0.02, shadow: 0.7, frame: .dark)),
        PolishPreset(name: "Social", style: PolishStyle(background: .gradient(1), padding: 0.07, radius: 0.022, shadow: 0.55, size: .x)),
    ]

    private static let savedKey = "polish.presets", lastKey = "polish.last"

    /// Presets you saved yourself.
    static var saved: [PolishPreset] {
        get { (UserDefaults.standard.data(forKey: savedKey)).flatMap { try? JSONDecoder().decode([PolishPreset].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: savedKey) }
    }

    static var all: [PolishPreset] { builtIn + saved }

    /// The style the editor opens with: the last one used, else the default from Settings.
    static var last: PolishStyle {
        get { UserDefaults.standard.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(PolishStyle.self, from: $0) } ?? gradient.style }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastKey) }
    }
}

// MARK: - Document

struct PolishDoc: Codable, Equatable {
    var source: URL
    /// The part of the source that's kept, in source pixels, origin top left.
    var crop: CGRect
    var style: PolishStyle
    var marks: [Mark] = []

    init(source: URL, size: CGSize, style: PolishStyle = PolishPreset.last) {
        self.source = source
        crop = CGRect(origin: .zero, size: size)
        self.style = style
    }

    /// The next number for a step marker.
    var nextStep: Int { (marks.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }
}

// MARK: - Layout

extension CGPoint {
    var hasFiniteCoordinates: Bool { x.isFinite && y.isFinite }
}

extension CGRect {
    var hasFiniteBounds: Bool {
        !isNull && !isInfinite && origin.hasFiniteCoordinates && size.width.isFinite && size.height.isFinite
            && minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
    }
}

/// Where everything goes for a document at a given scale (1 = the source's own pixels).
struct PolishLayout: Equatable {
    /// The whole picture.
    var canvas: CGSize
    /// The window (title bar and image) inside it.
    var card: CGRect
    /// Just the image inside the card.
    var image: CGRect
    var titleBar: CGFloat
    var radius: CGFloat
    /// Image pixels per source pixel.
    var scale: CGFloat

    init(doc: PolishDoc, scale requested: CGFloat = 1) {
        let style = doc.style
        let crop = doc.crop.hasFiniteBounds ? doc.crop.size : .zero
        let content = CGSize(width: max(1, crop.width), height: max(1, crop.height))
        let bar = style.frame == .none ? 0 : min(max(content.width / 36, 22), 60)
        let cardSize = CGSize(width: content.width, height: content.height + bar)
        let padding = max(0, style.padding) * max(content.width, content.height) * 2
        let pad = padding.isFinite ? padding : 0
        var size = CGSize(width: cardSize.width + pad, height: cardSize.height + pad)
        if let aspect = style.size.aspect {
            // Grow the short side so the card still fits with its padding.
            if size.width / size.height < aspect { size.width = size.height * aspect } else { size.height = size.width / aspect }
        }
        var s = requested.isFinite && requested > 0 ? requested : 1
        if let px = style.size.pixels { s *= px.width / size.width }
        canvas = CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
        // Snap the clip and image together so odd sizes keep their opaque edges at 1×.
        let cw = max(1, (cardSize.width * s).rounded()), ih = max(1, (content.height * s).rounded())
        let ch = max(ih, (cardSize.height * s).rounded())
        card = CGRect(x: ((canvas.width - cw) / 2).rounded(), y: ((canvas.height - ch) / 2).rounded(), width: cw, height: ch)
        titleBar = ch - ih
        image = CGRect(x: card.minX, y: card.minY + titleBar, width: cw, height: ih)
        let corner = style.radius * min(content.width, content.height) * s
        radius = corner.isFinite ? max(0, corner) : 0
        scale = s
    }

    /// A point in source pixels to a point on the canvas (origin top left).
    func toCanvas(_ p: CGPoint, crop: CGRect) -> CGPoint {
        guard crop.hasFiniteBounds else { return image.origin }
        return CGPoint(x: image.minX + (p.x - crop.minX) * (image.width / max(1, crop.width)),
                       y: image.minY + (p.y - crop.minY) * (image.height / max(1, crop.height)))
    }

    /// A point on the canvas back to source pixels.
    func toSource(_ p: CGPoint, crop: CGRect) -> CGPoint {
        guard crop.hasFiniteBounds else { return .zero }
        return CGPoint(x: (p.x - image.minX) * (max(1, crop.width) / max(1, image.width)) + crop.minX,
                       y: (p.y - image.minY) * (max(1, crop.height) / max(1, image.height)) + crop.minY)
    }

    func pixelAspect(crop: CGRect) -> CGFloat {
        guard crop.hasFiniteBounds else { return 1 }
        return (max(1, image.width) / max(1, crop.width)) / (max(1, image.height) / max(1, crop.height))
    }
}

// MARK: - Rendering

enum PolishRenderer {
    static let ci = CIContext(options: [.cacheIntermediates: false])

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        guard let value = properties?[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: value), orientation != .up else { return image }
        return orient(image, as: orientation)
    }

    private static func orient(_ image: CGImage, as orientation: CGImagePropertyOrientation) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case .up: return image
        case .upMirrored: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return image
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let size = rect.applying(transform).size
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.concatenate(transform)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// The whole picture. `marks: false` leaves them out, for the editor, which draws them live on top.
    static func render(_ doc: PolishDoc, source: CGImage, scale: CGFloat = 1, marks drawMarks: Bool = true) -> CGImage? {
        guard doc.crop.hasFiniteBounds, scale.isFinite, scale > 0 else { return nil }
        let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let bounds = doc.crop.integral.intersection(sourceBounds)
        guard !bounds.isEmpty, let cropped = bounds == sourceBounds ? source : source.cropping(to: bounds) else { return nil }
        let L = PolishLayout(doc: doc, scale: scale)
        guard let width = Int(exactly: L.canvas.width), let height = Int(exactly: L.canvas.height),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Draw top-down, like the layout.
        ctx.translateBy(x: 0, y: L.canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        // The editor draws the masks live over the foreground, but padding also reads source pixels.
        let masks = drawMarks || doc.style.background == .blurred ? MarkPainter.redactions(doc.marks, in: doc.crop, source: source) : []
        guard let redacted = MarkPainter.redactedCrop(cropped, source: source, bounds: bounds, redactions: masks) else { return nil }
        drawBackground(doc.style, cropped: redacted, in: ctx, L: L)

        let cardPath = CGPath(roundedRect: L.card, cornerWidth: L.radius, cornerHeight: L.radius, transform: nil)
        if doc.style.shadow > 0 && !doc.style.isPlain && doc.style.background != .none {
            let s = doc.style.shadow, d = max(L.card.width, L.card.height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.012 * s), blur: d * 0.05 * s,
                          color: CGColor(gray: 0, alpha: 0.25 + 0.3 * s))
            ctx.addPath(cardPath)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        if L.titleBar > 0 { drawTitleBar(doc.style.frame, in: ctx, L: L) }
        drawImage(drawMarks ? redacted : cropped, in: L.image, ctx: ctx)
        if drawMarks { MarkPainter.drawAnnotations(doc.marks, crop: doc.crop, layout: L, excluding: masks, in: ctx) }
        ctx.restoreGState()
        if L.titleBar > 0 || L.radius > 0, !doc.style.isPlain {
            // A hairline, so a white screenshot doesn't melt into a white background.
            ctx.addPath(CGPath(roundedRect: L.card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: L.radius, cornerHeight: L.radius, transform: nil))
            ctx.setStrokeColor(gray: 0, alpha: doc.style.frame == .dark ? 0.5 : 0.12)
            ctx.setLineWidth(max(1, L.scale))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    /// Draws an image the right way up in a top-down context.
    static func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private static func drawBackground(_ style: PolishStyle, cropped: CGImage, in ctx: CGContext, L: PolishLayout) {
        let all = CGRect(origin: .zero, size: L.canvas)
        switch style.background {
        case .none: break
        case .solid(let c):
            ctx.setFillColor(c.cg)
            ctx.fill(all)
        case .gradient(let i):
            let colors = Gradients.all[min(max(i, 0), Gradients.all.count - 1)].colors.map(\.cg) as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: all.maxX, y: all.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .blurred:
            let blur = max(L.canvas.width, L.canvas.height) * 0.04
            let img = CIImage(cgImage: cropped)
            // Fill the canvas, then blur: clamped first so the edges don't fade to clear.
            let k = max(L.canvas.width / img.extent.width, L.canvas.height / img.extent.height)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let out = scaled.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: scaled.extent)
            if let cg = ci.createCGImage(out, from: out.extent) {
                let r = CGRect(x: (L.canvas.width - out.extent.width) / 2, y: (L.canvas.height - out.extent.height) / 2,
                               width: out.extent.width, height: out.extent.height)
                drawImage(cg, in: r, ctx: ctx)
            }
            ctx.setFillColor(gray: 0, alpha: 0.18)
            ctx.fill(all)
        }
    }

    private static func drawTitleBar(_ frame: PolishStyle.Frame, in ctx: CGContext, L: PolishLayout) {
        let bar = CGRect(x: L.card.minX, y: L.card.minY, width: L.card.width, height: L.titleBar)
        ctx.setFillColor(frame == .dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.fill(bar)
        let d = L.titleBar * 0.42, gap = d * 0.55
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            let x = bar.minX + L.titleBar * 0.55 + CGFloat(i) * (d + gap)
            ctx.setFillColor(RGBA(hex: UInt32(hex)).cg)
            ctx.fillEllipse(in: CGRect(x: x, y: bar.midY - d / 2, width: d, height: d))
        }
        ctx.setFillColor(gray: 0, alpha: frame == .dark ? 0.6 : 0.08)
        ctx.fill(CGRect(x: bar.minX, y: bar.maxY - max(1, L.scale), width: bar.width, height: max(1, L.scale)))
    }

    // MARK: Export

    static func exportScale(for style: PolishStyle, retina: Bool) -> CGFloat {
        retina || style.size.pixels != nil ? 1 : 0.5
    }

    /// A finished PNG. `retina: false` halves a 2× screenshot for a smaller file.
    static func png(_ doc: PolishDoc, retina: Bool = true) -> Data? {
        guard let src = load(doc.source) else { return nil }
        guard let img = render(doc, source: src, scale: exportScale(for: doc.style, retina: retina)) else { return nil }
        return png(img)
    }

    static func png(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Where a saved copy goes: next to the original unless Settings picked a folder, never over another file.
    /// A copied image lives in ClipBubble's own data, so its copy goes to the screenshot folder instead.
    static func saveURL(for source: URL) -> URL {
        let custom = UserDefaults.standard.string(forKey: "polish.folder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let inApp = source.deletingLastPathComponent().resolvingSymlinksInPath().path == Paths.images.resolvingSymlinksInPath().path
        let dir = custom ?? (inApp ? FolderWatcher.screenshotFolder : source.deletingLastPathComponent())
        let base = (inApp ? "Image" : source.deletingPathExtension().lastPathComponent) + " polished"
        var url = dir.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        return url
    }
}

extension PolishRenderer {
    /// A copy this editor saved, so the screenshot watcher doesn't treat it as a new screenshot.
    static func isPolished(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.range(of: #" polished( \d+)?$"#, options: .regularExpression) != nil
    }
}

// MARK: - Undo

/// Undo and redo as whole-document snapshots: documents are small, and it can't get out of step.
struct DocHistory {
    private(set) var undos: [PolishDoc] = [], redos: [PolishDoc] = []
    var limit = 200

    /// Call with the document as it was, before a change.
    mutating func record(_ before: PolishDoc) {
        if undos.last == before { return }
        undos.append(before)
        if undos.count > limit { undos.removeFirst() }
        redos.removeAll()
    }

    mutating func undo(_ now: PolishDoc) -> PolishDoc? {
        guard let prev = undos.popLast() else { return nil }
        redos.append(now)
        return prev
    }

    mutating func redo(_ now: PolishDoc) -> PolishDoc? {
        guard let next = redos.popLast() else { return nil }
        undos.append(now)
        return next
    }

    /// Forget the last record, for a change that was started and then abandoned (a click that drew nothing).
    mutating func cancel() { _ = undos.popLast() }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }
}
