import AppKit
import CoreImage

// Marks: the arrows, boxes, text and redactions drawn on a screenshot.
// Every point is in source pixels (origin top left), so a mark stays put when the style or zoom changes.

struct Mark: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case arrow, line, rect, ellipse, text, pen, highlight, step, redact, measure
    }
    enum Fill: String, Codable, CaseIterable { case stroke, fill, both }
    enum Redaction: String, Codable, CaseIterable {
        case pixelate, blur, solid
        var title: String { rawValue.capitalized }
    }

    var id = UUID()
    var kind: Kind
    /// Two corners for boxes, start and end for lines (plus an optional bend point for arrows),
    /// the anchor for text and steps, every sample for a pen stroke.
    var points: [CGPoint]
    var color: RGBA = RGBA.palette[0]
    var width: CGFloat = 6
    var fill: Fill = .stroke
    var text = ""
    /// Font size for text, diameter for a step.
    var size: CGFloat = 32
    var number = 0
    /// Text sits on a rounded pill of its color.
    var pill = false
    var doubleHead = false
    var redaction: Redaction = .pixelate
    /// Added by auto-redact, so a second run can replace its own marks and keep yours.
    var auto = false

    init(_ kind: Kind, _ points: [CGPoint]) {
        self.kind = kind
        self.points = points
    }

    var a: CGPoint { points.first ?? .zero }
    var b: CGPoint { points.count > 1 ? points[1] : a }
    /// An arrow's bend point, if it's been bent.
    var bend: CGPoint? { kind == .arrow && points.count > 2 ? points[2] : nil }

    /// The box between the first two points.
    var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }

    var isBoxy: Bool { [.rect, .ellipse, .highlight, .redact].contains(kind) }
    var isLiney: Bool { [.arrow, .line, .measure].contains(kind) }

    // MARK: Geometry

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: Mark.font(size), .foregroundColor: (pill ? color.contrast : color).ns]
    }

    /// The text's box, pill included.
    var textRect: CGRect {
        let s = (text.isEmpty ? " " : text as NSString).size(withAttributes: textAttributes)
        let pad = pill ? CGSize(width: size * 0.4, height: size * 0.18) : .zero
        return CGRect(x: a.x, y: a.y, width: ceil(s.width) + pad.width * 2, height: ceil(s.height) + pad.height * 2)
    }

    /// Everything the mark covers, for selection and hit testing.
    var bounds: CGRect {
        switch kind {
        case .text: return textRect
        case .step: return CGRect(x: a.x - size / 2, y: a.y - size / 2, width: size, height: size)
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -width / 2, dy: -width / 2)
        case .arrow, .line, .measure:
            var r = rect
            if let c = bend { r = r.union(CGRect(origin: c, size: .zero)) }
            return r.insetBy(dx: -width * 2, dy: -width * 2)
        default: return rect
        }
    }

    /// Whether a click at `p` lands on this mark. `slop` is how far off it can be, in source pixels.
    func hit(_ p: CGPoint, slop: CGFloat) -> Bool {
        let near = max(slop, width)
        switch kind {
        case .line, .measure: return Mark.distance(p, a, b) <= near
        case .arrow:
            guard let c = bend else { return Mark.distance(p, a, b) <= near }
            let pts = Mark.curve(a, c, b)
            return pts.indices.dropLast().contains { Mark.distance(p, pts[$0], pts[$0 + 1]) <= near }
        case .pen:
            if points.count == 1 { return hypot(p.x - a.x, p.y - a.y) <= near }
            return points.indices.dropLast().contains { Mark.distance(p, points[$0], points[$0 + 1]) <= near }
        case .rect where fill == .stroke:
            // An empty box is only grabbed by its edge, so you can still click what's inside it.
            let r = rect
            return r.insetBy(dx: -near, dy: -near).contains(p) && !r.insetBy(dx: near, dy: near).contains(p)
        case .ellipse where fill == .stroke:
            let r = rect, rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let d = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(d - 1) * min(rx, ry) <= near
        default: return bounds.insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    func moved(by d: CGSize) -> Mark {
        var m = self
        m.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return m
    }

    /// The bend point to draw a handle at: the real one, or the middle of a straight arrow.
    var bendHandle: CGPoint { bend ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    // MARK: Maths

    /// Distance from `p` to the segment `a`–`b`.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// A curve through `c` (not just pulled toward it), sampled for hit testing.
    static func curve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, steps: Int = 24) -> [CGPoint] {
        let k = control(a, c, b)
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * k.x + t * t * b.x, y: u * u * a.y + 2 * u * t * k.y + t * t * b.y)
        }
    }

    /// The quadratic control point that makes the curve pass through `c` at its middle.
    static func control(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: 2 * c.x - (a.x + b.x) / 2, y: 2 * c.y - (a.y + b.y) / 2)
    }

    /// Snap the end of a line to 45° steps, for Shift.
    static func snap45(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
    }

    /// Make a box square, for Shift.
    static func square(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let s = max(abs(to.x - from.x), abs(to.y - from.y))
        return CGPoint(x: from.x + (to.x >= from.x ? s : -s), y: from.y + (to.y >= from.y ? s : -s))
    }

    /// Thin out and smooth a freehand stroke, dropping samples closer together than `minGap`.
    static func smooth(_ pts: [CGPoint], minGap: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst() where hypot(p.x - out.last!.x, p.y - out.last!.y) >= minGap { out.append(p) }
        if out.last != pts.last { out.append(pts.last!) }
        // One pass of neighbour averaging takes the jitter out of a trackpad stroke.
        guard out.count > 2 else { return out }
        return [out[0]] + (1..<(out.count - 1)).map { i in
            CGPoint(x: (out[i - 1].x + out[i].x * 2 + out[i + 1].x) / 4, y: (out[i - 1].y + out[i].y * 2 + out[i + 1].y) / 4)
        } + [out.last!]
    }
}

// MARK: - Painting

enum MarkPainter {
    /// Draws marks into a top-down context laid out by `L`. Redactions go first, from the source pixels,
    /// then the highlight dimming, then everything else in the order it was drawn.
    static func draw(_ marks: [Mark], doc: PolishDoc, source: CGImage, layout L: PolishLayout, in ctx: CGContext) {
        let map = { (p: CGPoint) in L.toCanvas(p, crop: doc.crop) }
        ctx.saveGState()
        ctx.clip(to: L.image)
        for m in marks where m.kind == .redact { redact(m, source: source, map: map, scale: L.scale, in: ctx) }
        let lights = marks.filter { $0.kind == .highlight && $0.rect.width > 0 && $0.rect.height > 0 }
        if !lights.isEmpty {
            let path = CGMutablePath()
            path.addRect(L.image)
            for m in lights {
                let r = rectOnCanvas(m.rect, map)
                path.addRoundedRect(in: r, cornerWidth: min(r.width, r.height, 12 * L.scale) / 2, cornerHeight: min(r.width, r.height, 12 * L.scale) / 2)
            }
            ctx.addPath(path)
            ctx.setFillColor(gray: 0, alpha: 0.5)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
        for m in marks where m.kind != .redact && m.kind != .highlight { draw(m, map: map, scale: L.scale, in: ctx) }
    }

    static func rectOnCanvas(_ r: CGRect, _ map: (CGPoint) -> CGPoint) -> CGRect {
        let p = map(r.origin), q = map(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y)
    }

    static func draw(_ m: Mark, map: (CGPoint) -> CGPoint, scale s: CGFloat, in ctx: CGContext) {
        let w = m.width * s
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(m.color.cg)
        ctx.setFillColor(m.color.cg)
        ctx.setLineWidth(w)
        // A soft shadow lifts marks off busy screenshots.
        let lift = { ctx.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 3 * s, color: CGColor(gray: 0, alpha: 0.3)) }

        switch m.kind {
        case .line:
            lift()
            ctx.move(to: map(m.a)); ctx.addLine(to: map(m.b)); ctx.strokePath()

        case .arrow:
            lift()
            arrow(m, map: map, w: w, in: ctx)

        case .rect, .ellipse:
            let r = rectOnCanvas(m.rect, map)
            let path = m.kind == .rect
                ? CGPath(roundedRect: r, cornerWidth: min(w * 1.5, r.width / 2, r.height / 2), cornerHeight: min(w * 1.5, r.width / 2, r.height / 2), transform: nil)
                : CGPath(ellipseIn: r, transform: nil)
            if m.fill != .stroke {
                ctx.setFillColor(m.color.alpha(m.fill == .both ? m.color.a * 0.25 : m.color.a).cg)
                ctx.addPath(path); ctx.fillPath()
            }
            if m.fill != .fill { lift(); ctx.addPath(path); ctx.strokePath() }

        case .pen:
            lift()
            let pts = m.points.map(map)
            guard let first = pts.first else { return }
            if pts.count == 1 { ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w)); return }
            ctx.move(to: first)
            // Through the midpoints, with each sample as a control point: smooth without overshoot.
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                ctx.addQuadCurve(to: mid, control: pts[i - 1])
            }
            ctx.addLine(to: pts.last!)
            ctx.strokePath()

        case .text:
            let r = rectOnCanvas(m.textRect, map)
            if m.pill {
                lift()
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2.6, cornerHeight: r.height / 2.6, transform: nil))
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 4 * s, color: CGColor(gray: 0, alpha: m.color.contrast == .black ? 0.55 : 0.25))
            }
            var attrs = m.textAttributes
            attrs[.font] = Mark.font(m.size * s)
            let pad = m.pill ? CGSize(width: m.size * 0.4 * s, height: m.size * 0.18 * s) : .zero
            text(m.text, at: CGPoint(x: r.minX + pad.width, y: r.minY + pad.height), attrs: attrs, in: ctx)

        case .step:
            let c = map(m.a), d = m.size * s
            let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            lift()
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(1, d * 0.07))
            ctx.strokeEllipse(in: r.insetBy(dx: d * 0.035, dy: d * 0.035))
            let font = NSFont.systemFont(ofSize: d * (m.number > 9 ? 0.46 : 0.56), weight: .bold)
            let label = "\(m.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.color.contrast.ns]
            let sz = label.size(withAttributes: attrs)
            text("\(m.number)", at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), attrs: attrs, in: ctx)

        case .measure:
            measure(m, map: map, s: s, in: ctx)

        case .redact, .highlight: break
        }
    }

    private static func arrow(_ m: Mark, map: (CGPoint) -> CGPoint, w: CGFloat, in ctx: CGContext) {
        let a = map(m.a), b = map(m.b)
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0.5 else { return }
        let head = min(max(w * 3.6, 10), len * 0.6)
        let k = m.bend.map { Mark.control(a, map($0), b) }
        // The head points along the curve's direction at each end.
        let inEnd = k ?? a, inStart = k ?? b
        let endAngle = atan2(b.y - inEnd.y, b.x - inEnd.x), startAngle = atan2(a.y - inStart.y, a.x - inStart.x)
        // Stop the shaft inside the head, so its round cap doesn't poke out of the tip.
        let back = head * 0.6
        let shaftEnd = CGPoint(x: b.x - cos(endAngle) * back, y: b.y - sin(endAngle) * back)
        let shaftStart = m.doubleHead ? CGPoint(x: a.x - cos(startAngle) * back, y: a.y - sin(startAngle) * back) : a
        ctx.move(to: shaftStart)
        if let k { ctx.addQuadCurve(to: shaftEnd, control: k) } else { ctx.addLine(to: shaftEnd) }
        ctx.strokePath()
        arrowHead(at: b, angle: endAngle, size: head, in: ctx)
        if m.doubleHead { arrowHead(at: a, angle: startAngle, size: head, in: ctx) }
    }

    private static func arrowHead(at tip: CGPoint, angle: CGFloat, size: CGFloat, in ctx: CGContext) {
        let spread: CGFloat = 0.45
        let p1 = CGPoint(x: tip.x - cos(angle - spread) * size, y: tip.y - sin(angle - spread) * size)
        let p2 = CGPoint(x: tip.x - cos(angle + spread) * size, y: tip.y - sin(angle + spread) * size)
        // A slight notch in the back of the head reads as an arrow, not a triangle.
        let notch = CGPoint(x: tip.x - cos(angle) * size * 0.78, y: tip.y - sin(angle) * size * 0.78)
        ctx.move(to: tip); ctx.addLine(to: p1); ctx.addLine(to: notch); ctx.addLine(to: p2); ctx.closePath()
        ctx.fillPath()
    }

    private static func measure(_ m: Mark, map: (CGPoint) -> CGPoint, s: CGFloat, in ctx: CGContext) {
        let a = map(m.a), b = map(m.b)
        let angle = atan2(b.y - a.y, b.x - a.x), tick = max(m.width * s * 2.2, 6)
        let nx = -sin(angle) * tick, ny = cos(angle) * tick
        ctx.setLineWidth(max(1, m.width * s * 0.5))
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 3 * s, color: CGColor(gray: 0, alpha: 0.35))
        ctx.move(to: a); ctx.addLine(to: b)
        for p in [a, b] { ctx.move(to: CGPoint(x: p.x - nx, y: p.y - ny)); ctx.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny)) }
        ctx.strokePath()
        let px = hypot(m.b.x - m.a.x, m.b.y - m.a.y)
        let dx = Int(abs(m.b.x - m.a.x).rounded()), dy = Int(abs(m.b.y - m.a.y).rounded())
        let label = dx == 0 || dy == 0 ? "\(Int(px.rounded())) px" : "\(Int(px.rounded())) px  (\(dx)×\(dy))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(m.size * 0.5, 11) * s, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.color.contrast.ns]
        let sz = (label as NSString).size(withAttributes: attrs)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let pill = CGRect(x: mid.x - sz.width / 2 - sz.height * 0.45, y: mid.y - sz.height * 0.6 - sz.height * 0.9,
                          width: sz.width + sz.height * 0.9, height: sz.height * 1.2)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        text(label, at: CGPoint(x: pill.minX + sz.height * 0.45, y: pill.minY + sz.height * 0.1), attrs: attrs, in: ctx)
    }

    /// Draws text the right way up in a top-down context.
    static func text(_ s: String, at p: CGPoint, attrs: [NSAttributedString.Key: Any], in ctx: CGContext) {
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (s as NSString).draw(at: p, withAttributes: attrs)
        NSGraphicsContext.current = saved
    }

    // MARK: Redaction

    private static let cache = NSCache<NSString, CGImage>()

    /// Covers a region with pixels made from the source, so nothing of what was under it survives the export.
    private static func redact(_ m: Mark, source: CGImage, map: (CGPoint) -> CGPoint, scale: CGFloat, in ctx: CGContext) {
        let r = m.rect.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard r.width >= 1, r.height >= 1 else { return }
        let dest = rectOnCanvas(r, map)
        if m.redaction == .solid {
            ctx.setFillColor(m.color.cg)
            ctx.fill(dest)
            return
        }
        let key = "\(m.redaction.rawValue) \(r) \(ObjectIdentifier(source))" as NSString
        let img = cache.object(forKey: key) ?? {
            let made = redacted(source, r, m.redaction)
            if let made { cache.setObject(made, forKey: key) }
            return made
        }()
        guard let img else { ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(dest); return }
        ctx.saveGState()
        ctx.interpolationQuality = m.redaction == .pixelate ? .none : .high
        PolishRenderer.drawImage(img, in: dest, ctx: ctx)
        ctx.restoreGState()
    }

    /// The covered pixels. Pixelate keeps a handful of big blocks; blur is heavy enough that text can't be read back.
    static func redacted(_ source: CGImage, _ r: CGRect, _ mode: Mark.Redaction) -> CGImage? {
        guard let crop = source.cropping(to: r) else { return nil }
        switch mode {
        case .solid: return nil
        case .pixelate:
            // Blocks at least as tall as half the region: one or two rows over a line of text.
            let block = max(10, min(r.width, r.height) / 2)
            let w = max(1, Int((r.width / block).rounded(.up))), h = max(1, Int((r.height / block).rounded(.up)))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        case .blur:
            let img = CIImage(cgImage: crop)
            let sigma = max(8, min(r.width, r.height) * 0.45)
            let out = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: img.extent)
            return PolishRenderer.ci.createCGImage(out, from: img.extent)
        }
    }
}
