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
    private var storedRotation: CGFloat?

    private enum CodingKeys: String, CodingKey {
        case id, kind, points, color, width, fill, text, size, number, pill, doubleHead, redaction, auto
        case storedRotation = "rotation"
    }

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

    var canRotate: Bool { kind == .rect || kind == .ellipse || kind == .text }

    /// Clockwise radians in source coordinates. Older marks without an angle are upright.
    var rotation: CGFloat {
        get { canRotate ? storedRotation ?? 0 : 0 }
        set { storedRotation = newValue == 0 ? nil : newValue }
    }

    var rotationCenter: CGPoint {
        let r = unrotatedBounds
        return CGPoint(x: r.midX, y: r.midY)
    }

    var rotationTransform: CGAffineTransform {
        rotation == 0 ? .identity : rotationTransform(around: rotationCenter)
    }

    /// Preserve the source rotation when the canvas snaps each axis to whole pixels.
    func rotationTransform(around center: CGPoint, aspect: CGFloat = 1) -> CGAffineTransform {
        let angle = rotation
        guard angle.isFinite, angle != 0, center.hasFiniteCoordinates,
              aspect.isFinite, aspect >= CGFloat.ulpOfOne else { return .identity }
        let c = cos(angle), sx = -sin(angle) * aspect, sy = sin(angle) / aspect
        let tx = center.x - c * center.x - sx * center.y, ty = center.y - sy * center.x - c * center.y
        guard tx.isFinite, ty.isFinite else { return .identity }
        return CGAffineTransform(a: c, b: sy, c: sx, d: c, tx: tx, ty: ty)
    }

    /// Everything the mark covers before applying its rotation.
    var unrotatedBounds: CGRect {
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

    var bounds: CGRect { unrotatedBounds.applying(rotationTransform) }

    /// Whether a click at `p` lands on this mark. `slop` is how far off it can be, in source pixels.
    func hit(_ point: CGPoint, slop: CGFloat, in canvas: (layout: PolishLayout, crop: CGRect)? = nil) -> Bool {
        let p = rotation == 0 ? point : point.applying(rotationTransform.inverted())
        let near = slop == 0 ? width / 2 : max(slop, width)
        switch kind {
        case .redact: return !rect.isEmpty && rect.integral.insetBy(dx: -slop, dy: -slop).contains(p)
        case .line, .measure: return Mark.distance(p, a, b) <= near
        case .arrow:
            let map: (CGPoint) -> CGPoint = { point in
                guard let canvas else { return point }
                return canvas.layout.toCanvas(point, crop: canvas.crop)
            }
            let headPoint = map(p)
            if let arrow = ArrowGeometry(self, map: map, width: width * (canvas?.layout.scale ?? 1)),
               arrow.endHead.contains(headPoint) || arrow.startHead?.contains(headPoint) == true { return true }
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
        case .ellipse:
            let r = rect, rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let d = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            let distance = (d - 1) * min(rx, ry)
            return fill == .stroke ? abs(distance) <= near : distance <= slop
        default: return unrotatedBounds.insetBy(dx: -slop, dy: -slop).contains(p)
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

/// Shared by the painter and hit-testing so the arrowheads match at any zoom.
private struct ArrowGeometry {
    let control: CGPoint?
    let shaftStart: CGPoint
    let shaftEnd: CGPoint
    let startHead: CGPath?
    let endHead: CGPath

    init?(_ mark: Mark, map: (CGPoint) -> CGPoint, width: CGFloat) {
        let a = map(mark.a), b = map(mark.b)
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0.5 else { return nil }
        let head = min(max(width * 3.6, 10), len * 0.6)
        let k = mark.bend.map { Mark.control(a, map($0), b) }
        control = k
        // The head points along the curve's direction at each end.
        let inEnd = k ?? a, inStart = k ?? b
        let endAngle = atan2(b.y - inEnd.y, b.x - inEnd.x), startAngle = atan2(a.y - inStart.y, a.x - inStart.x)
        // Stop the shaft inside the head, so its round cap doesn't poke out of the tip.
        let back = head * 0.6
        shaftEnd = CGPoint(x: b.x - cos(endAngle) * back, y: b.y - sin(endAngle) * back)
        shaftStart = mark.doubleHead ? CGPoint(x: a.x - cos(startAngle) * back, y: a.y - sin(startAngle) * back) : a
        endHead = Self.head(at: b, angle: endAngle, size: head)
        startHead = mark.doubleHead ? Self.head(at: a, angle: startAngle, size: head) : nil
    }

    private static func head(at tip: CGPoint, angle: CGFloat, size: CGFloat) -> CGPath {
        let spread: CGFloat = 0.45
        let p1 = CGPoint(x: tip.x - cos(angle - spread) * size, y: tip.y - sin(angle - spread) * size)
        let p2 = CGPoint(x: tip.x - cos(angle + spread) * size, y: tip.y - sin(angle + spread) * size)
        let notch = CGPoint(x: tip.x - cos(angle) * size * 0.78, y: tip.y - sin(angle) * size * 0.78)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: p1)
        path.addLine(to: notch)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }
}

// MARK: - Painting

enum MarkPainter {
    /// Draws live marks into a top-down context, with redactions above all the other marks.
    static func draw(_ marks: [Mark], doc: PolishDoc, source: CGImage, layout L: PolishLayout, in ctx: CGContext) {
        drawAnnotations(marks, crop: doc.crop, layout: L, excluding: [], in: ctx)
        let masks = redactions(marks, in: doc.crop, source: source)
        guard !masks.isEmpty else { return }
        let map = { (p: CGPoint) in L.toCanvas(p, crop: doc.crop) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: L.image)
        paintRedactions(masks, source: source, in: ctx) { rectOnCanvas($0, map) }
    }

    /// On export the masks are baked into the source. Leave those pixels untouched by annotations.
    static func drawAnnotations(_ marks: [Mark], crop: CGRect, layout L: PolishLayout, excluding masks: [Redaction], in ctx: CGContext) {
        guard marks.contains(where: { $0.kind != .redact }) else { return }
        let map = { (p: CGPoint) in L.toCanvas(p, crop: crop) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: L.image)
        for mask in masks {
            let path = CGPath(rect: rectOnCanvas(mask.rect, map), transform: nil)
            clipOutside(path, image: L.image, in: ctx)
        }
        let lights = marks.filter { $0.kind == .highlight && $0.rect.width > 0 && $0.rect.height > 0 }
        if !lights.isEmpty {
            ctx.saveGState()
            // Intersect the areas outside each spotlight so overlapping lights stay bright.
            for m in lights {
                let r = rectOnCanvas(m.rect, map)
                let corner = min(r.width, r.height, 12 * L.scale) / 2
                let path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
                clipOutside(path, image: L.image, in: ctx)
            }
            ctx.setFillColor(gray: 0, alpha: 0.5)
            ctx.fill(L.image)
            ctx.restoreGState()
        }
        let aspect = L.pixelAspect(crop: crop)
        for m in marks where m.kind != .redact && m.kind != .highlight {
            draw(m, map: map, scale: L.scale, aspect: aspect, in: ctx)
        }
    }

    private static func clipOutside(_ path: CGPath, image: CGRect, in ctx: CGContext) {
        ctx.beginPath()
        ctx.addRect(image)
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
    }

    static func rectOnCanvas(_ r: CGRect, _ map: (CGPoint) -> CGPoint) -> CGRect {
        let p = map(r.origin), q = map(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y)
    }

    private static func draw(_ m: Mark, map: (CGPoint) -> CGPoint, scale s: CGFloat, aspect: CGFloat, in ctx: CGContext) {
        let w = m.width * s
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if m.rotation != 0 {
            ctx.concatenate(m.rotationTransform(around: map(m.rotationCenter), aspect: aspect))
        }
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
        guard let arrow = ArrowGeometry(m, map: map, width: w) else { return }
        ctx.move(to: arrow.shaftStart)
        if let k = arrow.control { ctx.addQuadCurve(to: arrow.shaftEnd, control: k) } else { ctx.addLine(to: arrow.shaftEnd) }
        ctx.strokePath()
        ctx.addPath(arrow.endHead)
        ctx.fillPath()
        if let head = arrow.startHead {
            ctx.addPath(head)
            ctx.fillPath()
        }
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

    struct Redaction: Hashable {
        let rect: CGRect
        let mode: Mark.Redaction
        let color: RGBA?
    }

    private enum RedactionWork: Hashable {
        case patch(CGRect, Mark.Redaction, [Redaction])
        case crop(CGRect, [Redaction])
    }

    private final class ImageKey: NSObject {
        // Retain the image while cached so its identity cannot be reused.
        let source: CGImage
        let work: RedactionWork

        init(_ source: CGImage, _ work: RedactionWork) {
            self.source = source
            self.work = work
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(ObjectIdentifier(source))
            hasher.combine(work)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ImageKey else { return false }
            return source === other.source && work == other.work
        }
    }

    private static let cache: NSCache<ImageKey, CGImage> = {
        let cache = NSCache<ImageKey, CGImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private static func cachedImage(_ source: CGImage, _ work: RedactionWork, make: () -> CGImage?) -> CGImage? {
        let key = ImageKey(source, work)
        if let image = cache.object(forKey: key) { return image }
        guard let image = make() else { return nil }
        cache.setObject(image, forKey: key, cost: source.bytesPerRow * source.height + image.bytesPerRow * image.height)
        return image
    }

    static func redactions(_ marks: [Mark], in crop: CGRect, source: CGImage) -> [Redaction] {
        let bounds = crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return marks.compactMap { mark in
            guard mark.kind == .redact, !mark.rect.isEmpty else { return nil }
            let rect = mark.rect.integral.intersection(bounds)
            guard !rect.isEmpty else { return nil }
            return Redaction(rect: rect, mode: mark.redaction, color: mark.redaction == .solid ? mark.color.alpha(1) : nil)
        }
    }

    static func redactedCrop(_ cropped: CGImage, source: CGImage, bounds: CGRect, redactions: [Redaction]) -> CGImage? {
        guard !redactions.isEmpty else { return cropped }
        return cachedImage(source, .crop(bounds, redactions)) {
            guard let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.translateBy(x: -bounds.minX, y: bounds.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            PolishRenderer.drawImage(cropped, in: bounds, ctx: ctx)
            paintRedactions(redactions, source: source, in: ctx) { $0 }
            return ctx.makeImage()
        }
    }

    private static func paintRedactions(_ masks: [Redaction], source: CGImage, in ctx: CGContext, place: (CGRect) -> CGRect) {
        let solids = masks.filter { $0.mode == .solid }
        for mask in masks where mask.mode != .solid {
            paintPatch(mask, sampling: source, solids: solids, in: place(mask.rect), ctx: ctx)
        }
        // Solid coverage still wins in the final image.
        for mask in solids { fillSolid(mask, in: place(mask.rect), ctx: ctx) }
    }

    private static func fillSolid(_ mask: Redaction, in dest: CGRect, ctx: CGContext) {
        guard let color = mask.color else { return }
        ctx.setFillColor(color.cg)
        ctx.fill(dest)
    }

    private static func paintPatch(_ mask: Redaction, sampling source: CGImage, solids: [Redaction], in dest: CGRect, ctx: CGContext) {
        // Sample only whole source pixels inside the crop, even on a fractional edge.
        let x = ceil(mask.rect.minX), y = ceil(mask.rect.minY)
        let r = CGRect(x: x, y: y, width: max(0, floor(mask.rect.maxX) - x), height: max(0, floor(mask.rect.maxY) - y))
        let overlaps = solids.filter { !$0.rect.intersection(r).isEmpty }
        guard !r.isEmpty, let img = cachedImage(source, .patch(r, mask.mode, overlaps), make: {
            guard let crop = patchSource(source, in: r, solids: overlaps) else { return nil }
            return redacted(crop, mask.mode)
        }) else {
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(dest)
            return
        }
        ctx.saveGState()
        ctx.interpolationQuality = mask.mode == .pixelate ? .none : .high
        PolishRenderer.drawImage(img, in: dest, ctx: ctx)
        ctx.restoreGState()
    }

    private static func patchSource(_ source: CGImage, in rect: CGRect, solids: [Redaction]) -> CGImage? {
        guard let crop = source.cropping(to: rect) else { return nil }
        guard !solids.isEmpty else { return crop }
        // The filter only reads its patch. Fill the overlapping solids before it samples any pixels.
        guard let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: -rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        PolishRenderer.drawImage(crop, in: rect, ctx: ctx)
        for mask in solids { fillSolid(mask, in: mask.rect, ctx: ctx) }
        return ctx.makeImage()
    }

    /// The covered pixels. Pixelate keeps a handful of big blocks; blur is heavy enough that text can't be read back.
    private static func redacted(_ crop: CGImage, _ mode: Mark.Redaction) -> CGImage? {
        let width = CGFloat(crop.width), height = CGFloat(crop.height)
        switch mode {
        case .solid: return nil
        case .pixelate:
            // Blocks at least as tall as half the region: one or two rows over a line of text.
            let block = max(10, min(width, height) / 2)
            let w = max(1, Int((width / block).rounded(.up))), h = max(1, Int((height / block).rounded(.up)))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .medium
            let dest = CGRect(x: 0, y: 0, width: w, height: h)
            // An opaque matte stops the original from showing through the patch.
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(dest)
            ctx.draw(crop, in: dest)
            return ctx.makeImage()
        case .blur:
            let img = CIImage(cgImage: crop)
            let sigma = max(8, min(width, height) * 0.45)
            let matte = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            let out = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).composited(over: matte).cropped(to: img.extent)
            return PolishRenderer.ci.createCGImage(out, from: img.extent)
        }
    }
}
