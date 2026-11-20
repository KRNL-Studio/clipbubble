import AppKit
import QuartzCore

// The editor's canvas: shows the polished picture, and draws, selects, moves and resizes marks on it.
// The background, frame and shadow come from the renderer as one image; marks are drawn live on top
// with the same painter the export uses, so nothing shifts between the editor and the copy.

enum PolishTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rect, ellipse, pen, text, step, measure, highlight, redact
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Box"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .text: return "Text"
        case .step: return "Step"
        case .measure: return "Measure"
        case .highlight: return "Spotlight"
        case .redact: return "Redact"
        }
    }

    var key: Character {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .text: return "t"
        case .step: return "n"
        case .measure: return "m"
        case .highlight: return "h"
        case .redact: return "b"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .measure: return "ruler"
        case .highlight: return "light.max"
        case .redact: return "eye.slash"
        }
    }

    var kind: Mark.Kind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .text: return .text
        case .step: return .step
        case .measure: return .measure
        case .highlight: return .highlight
        case .redact: return .redact
        }
    }

    /// The toolbar's groups.
    static let groups: [[PolishTool]] = [[.select, .crop], [.arrow, .line, .rect, .ellipse, .pen], [.text, .step, .measure], [.highlight, .redact]]
}

/// Where the picture sits in the view, and how big.
struct Geometry: Equatable {
    var origin: CGPoint
    var layout: PolishLayout
    var crop: CGRect

    func view(_ p: CGPoint) -> CGPoint {
        let c = layout.toCanvas(p, crop: crop)
        return CGPoint(x: c.x + origin.x, y: c.y + origin.y)
    }

    func source(_ v: CGPoint) -> CGPoint { layout.toSource(CGPoint(x: v.x - origin.x, y: v.y - origin.y), crop: crop) }

    func view(_ r: CGRect) -> CGRect {
        guard r.hasFiniteBounds else { return .null }
        let a = view(r.origin), b = view(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    func rotationTransform(for mark: Mark) -> CGAffineTransform {
        guard mark.rotation != 0 else { return .identity }
        return mark.rotationTransform(around: view(mark.rotationCenter), aspect: layout.pixelAspect(crop: crop))
    }

    var canvasRect: CGRect { CGRect(origin: origin, size: layout.canvas) }

    static func lerp(_ a: Geometry, _ b: Geometry, _ t: CGFloat) -> Geometry {
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func p(_ x: CGPoint, _ y: CGPoint) -> CGPoint { CGPoint(x: l(x.x, y.x), y: l(x.y, y.y)) }
        func r(_ x: CGRect, _ y: CGRect) -> CGRect { CGRect(x: l(x.minX, y.minX), y: l(x.minY, y.minY), width: l(x.width, y.width), height: l(x.height, y.height)) }
        var g = b
        g.origin = p(a.origin, b.origin)
        g.layout.canvas = CGSize(width: l(a.layout.canvas.width, b.layout.canvas.width), height: l(a.layout.canvas.height, b.layout.canvas.height))
        g.layout.card = r(a.layout.card, b.layout.card)
        g.layout.image = r(a.layout.image, b.layout.image)
        g.layout.titleBar = l(a.layout.titleBar, b.layout.titleBar)
        g.layout.radius = l(a.layout.radius, b.layout.radius)
        // Scale follows the image's width, so marks stay pinned to it while it moves.
        g.layout.scale = g.layout.image.width / max(b.crop.width, 1)
        g.layout.image.size.height = max(1, b.crop.height * g.layout.scale)
        return g
    }
}

final class PolishCanvas: NSView, NSTextViewDelegate {
    weak var model: PolishModel?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // What's on screen. `shown` animates toward the target when the style changes.
    private var shown: Geometry?
    var geometry: Geometry? { shown }
    private var anim: (from: Geometry, to: Geometry, start: CFTimeInterval)?
    private var base: CGImage?, oldBase: CGImage?, fadeStart: CFTimeInterval = 0
    private var baseKey: BaseKey?, wantedKey: BaseKey?
    private var baseWork: DispatchWorkItem?
    private var generation = 0
    private var link: CADisplayLink?
    private var last: (style: PolishStyle, crop: CGRect, tool: PolishTool, zoom: CGFloat, pan: CGPoint)?
    private static let renderQueue = DispatchQueue(label: "polish.render", qos: .userInteractive)

    struct BaseKey: Equatable {
        let style: PolishStyle
        let crop: CGRect
        let scale: CGFloat
        private let redactions: [MarkPainter.Redaction]

        init(doc: PolishDoc, source: CGImage, scale: CGFloat) {
            style = doc.style
            crop = doc.crop
            self.scale = scale
            // Blurred padding reads the same masked pixels as the renderer.
            redactions = style.background == .blurred ? MarkPainter.redactions(doc.marks, in: crop, source: source) : []
        }
    }

    private enum Handle: Equatable { case point(Int), box(Int, Int), rotation }
    private enum Drag {
        case none
        case create(Mark, CGPoint)
        case move(UUID, CGPoint)
        case handle(Mark, Handle, CGPoint)
        case pan(CGPoint)
        case cropNew(CGPoint), cropMove(CGPoint), cropHandle(Int, Int, CGRect)
    }
    private var drag = Drag.none
    private var recorded = false
    private var creationBefore: PolishDoc?

    // In-place text editing.
    private var editor: NSTextView?
    private var editingID: UUID?
    private var editingNew = false
    private var editingBefore = ""

    private let animDuration: CFTimeInterval = 0.24, fadeDuration: CFTimeInterval = 0.16

    // MARK: Sync

    /// Called whenever the model changes.
    func sync() {
        guard let m = model else { return }
        let now = (m.doc.style, m.doc.crop, m.tool, m.zoom, m.pan)
        let changed = last.map { $0.style != now.0 || $0.crop != now.1 || $0.zoom != now.3 } ?? false
        let toolSwitch = last.map { ($0.tool == .crop) != (now.2 == .crop) } ?? false
        last = now
        relayout(animated: changed && !toolSwitch)
        requestBase()
        if let id = editingID, m.mark(id) == nil { endTextEdit(commit: false) }
        layoutEditor()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        relayout(animated: false)
        requestBase()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestBase()
    }

    /// The document being shown: in crop mode, the whole screenshot with no style.
    private var shownDoc: PolishDoc? {
        guard let m = model else { return nil }
        guard m.tool == .crop else { return m.doc }
        var d = m.doc
        d.crop = CGRect(x: 0, y: 0, width: m.source.width, height: m.source.height)
        d.style = PolishPreset.builtIn[0].style
        return d
    }

    private func target() -> Geometry? {
        guard let m = model, let d = shownDoc, d.crop.hasFiniteBounds, !d.crop.isEmpty,
              bounds.hasFiniteBounds, bounds.width > 40, bounds.height > 40 else { return nil }
        let one = PolishLayout(doc: d, scale: 1)
        let fit = max(0.01, min((bounds.width - 72) / one.canvas.width, (bounds.height - 60) / one.canvas.height, 1))
        let L = PolishLayout(doc: d, scale: fit * m.zoom)
        let origin = CGPoint(x: ((bounds.width - L.canvas.width) / 2 + m.pan.x).rounded(),
                             y: ((bounds.height - L.canvas.height) / 2 + m.pan.y).rounded())
        guard origin.hasFiniteCoordinates, L.card.hasFiniteBounds, L.image.hasFiniteBounds,
              L.scale.isFinite, L.scale > 0 else { return nil }
        return Geometry(origin: origin, layout: L, crop: d.crop)
    }

    private func relayout(animated: Bool) {
        guard let t = target() else { shown = nil; anim = nil; needsDisplay = true; return }
        if animated, let s = shown, s != t {
            anim = (s, t, CACurrentMediaTime())
            startLink()
        } else {
            anim = nil
            shown = t
        }
        needsDisplay = true
    }

    // MARK: Base image

    private func currentBaseKey() -> BaseKey? {
        guard let m = model, let t = target() else { return nil }
        // Enough pixels for this screen, rounded up so a live resize doesn't re-render every frame.
        let backing = window?.backingScaleFactor ?? 2
        let wanted = t.layout.scale / max(PolishLayout(doc: m.doc, scale: 1).scale, 0.0001) * backing
        let scale = min(1, max(0.1, (wanted * 8).rounded(.up) / 8))
        return BaseKey(doc: m.doc, source: m.source, scale: scale)
    }

    private func cancelBaseRequest() {
        baseWork?.cancel()
        baseWork = nil
        wantedKey = nil
        generation += 1
    }

    private func requestBase() {
        guard let m = model, let key = currentBaseKey(), key != wantedKey else { return }
        // Undo can land on the image we already have while another render is pending.
        if wantedKey != nil { cancelBaseRequest() }
        guard key != baseKey else { return }
        wantedKey = key
        let gen = generation, doc = m.doc, src = m.source
        let work = DispatchWorkItem { [weak self] in
            let img = PolishRenderer.render(doc, source: src, scale: key.scale, marks: false)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.baseWork = nil
                self.wantedKey = nil
                guard self.currentBaseKey() == key else { self.requestBase(); return }
                guard let img else { return }
                // A new style crossfades in; the same style at a new size just swaps.
                let restyled = self.baseKey.map { $0.style != key.style || $0.crop != key.crop } ?? false
                self.oldBase = restyled ? self.base : nil
                self.base = img
                self.baseKey = key
                if restyled { self.fadeStart = CACurrentMediaTime(); self.startLink() }
                self.needsDisplay = true
            }
        }
        baseWork = work
        PolishCanvas.renderQueue.async(execute: work)
    }

    func detach() {
        model = nil
        cancelBaseRequest()
        link?.invalidate()
        link = nil
        anim = nil
        base = nil
        oldBase = nil
        baseKey = nil
        creationBefore = nil
    }

    // MARK: Animation

    private func startLink() {
        guard link == nil else { return }
        link = displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let a = anim {
            let t = min(1, (now - a.start) / animDuration)
            // Ease out: quick to respond, gentle to land.
            let e = 1 - pow(1 - t, 3)
            shown = Geometry.lerp(a.from, a.to, CGFloat(e))
            if t >= 1 { anim = nil; shown = a.to }
            layoutEditor()
        }
        if oldBase != nil, now - fadeStart >= fadeDuration { oldBase = nil }
        needsDisplay = true
        if anim == nil && oldBase == nil { link?.invalidate(); link = nil }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        guard let m = model, let g = shown, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if m.tool == .crop { drawCrop(m, g, ctx); return }
        let canvas = g.canvasRect
        if m.doc.style.background == .none { drawChecker(in: g.view(g.crop).intersection(canvas), ctx) }
        if let b = base {
            if let old = oldBase {
                let t = min(1, (CACurrentMediaTime() - fadeStart) / fadeDuration)
                PolishRenderer.drawImage(old, in: canvas, ctx: ctx)
                ctx.setAlpha(CGFloat(t))
                PolishRenderer.drawImage(b, in: canvas, ctx: ctx)
                ctx.setAlpha(1)
            } else {
                PolishRenderer.drawImage(b, in: canvas, ctx: ctx)
            }
        } else {
            PolishRenderer.drawImage(m.preview.cropping(to: previewRect(m, g.crop)) ?? m.preview, in: g.view(g.crop), ctx: ctx)
        }
        drawMarks(m, g, ctx)
        drawSelection(m, g, ctx)
    }

    private func drawMarks(_ m: PolishModel, _ g: Geometry, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: g.origin.x, y: g.origin.y)
        let L = g.layout
        ctx.addPath(CGPath(roundedRect: L.card, cornerWidth: L.radius, cornerHeight: L.radius, transform: nil))
        ctx.clip()
        var doc = m.doc
        doc.crop = g.crop
        MarkPainter.draw(doc.marks, doc: doc, source: m.source, layout: L, in: ctx)
        ctx.restoreGState()
    }

    /// The part of the downsized preview that matches a crop in source pixels.
    private func previewRect(_ m: PolishModel, _ r: CGRect) -> CGRect {
        let k = CGFloat(m.preview.width) / CGFloat(m.source.width)
        return CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).integral
    }

    private func drawChecker(in r: CGRect, _ ctx: CGContext) {
        guard r.hasFiniteBounds, !r.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(r)
        ctx.setFillColor(gray: 0.86, alpha: 1)
        let s: CGFloat = 8
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : s)
            while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: s, height: s)); x += s * 2 }
            y += s; row += 1
        }
        ctx.restoreGState()
    }

    private var accent: CGColor { NSColor.controlAccentColor.cgColor }

    private func drawSelection(_ m: PolishModel, _ g: Geometry, _ ctx: CGContext) {
        guard let id = m.selection, id != editingID, let mk = m.mark(id) else { return }
        ctx.saveGState()
        var transform = g.rotationTransform(for: mk)
        if !(mk.isBoxy || mk.isLiney) {
            let r = g.view(mk.unrotatedBounds).insetBy(dx: -5, dy: -5)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: &transform))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        } else if mk.isBoxy {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(rect: g.view(mk.rect), transform: &transform))
            ctx.strokePath()
        }
        if let arm = rotationArm(mk, g) {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            ctx.move(to: g.view(arm.start))
            ctx.addLine(to: g.view(arm.end))
            ctx.strokePath()
        }
        for (h, p) in handles(mk, g) { drawHandle(g.view(p), bend: h == .point(2), ctx) }
        ctx.restoreGState()
    }

    private func drawHandle(_ p: CGPoint, bend: Bool, _ ctx: CGContext) {
        let r: CGFloat = bend ? 4 : 4.5
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(bend ? accent : CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(bend ? CGColor(gray: 1, alpha: 1) : accent)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)
    }

    private func drawCrop(_ m: PolishModel, _ g: Geometry, _ ctx: CGContext) {
        let img = g.view(g.crop)
        PolishRenderer.drawImage(m.preview, in: img, ctx: ctx)
        drawMarks(m, g, ctx)
        let r = g.view(m.cropDraft)
        guard r.hasFiniteBounds else { return }
        // Dim what's cut away.
        let dim = CGMutablePath()
        dim.addRect(img); dim.addRect(r)
        ctx.addPath(dim)
        ctx.setFillColor(gray: 0, alpha: 0.55)
        ctx.fillPath(using: .evenOdd)
        // Thirds, faint, to help line things up.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        ctx.setLineWidth(1)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        if r.isEmpty {
            ctx.move(to: r.origin)
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx.strokePath()
        } else { ctx.stroke(r) }
        // Corner brackets, thicker, so the grab points are obvious.
        ctx.setLineWidth(4)
        let k = min(18, r.width / 3, r.height / 3)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: x, y: y + k * dy)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + k * dx, y: y))
        }
        ctx.strokePath()
        let label = m.cropBadgeText as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        var pill = CGRect(x: r.midX - sz.width / 2 - 8, y: r.minY - sz.height - 14, width: sz.width + 16, height: sz.height + 6)
        if pill.minY < 4 { pill.origin.y = r.minY + 8 }
        ctx.setFillColor(gray: 0, alpha: 0.7)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        MarkPainter.text(label as String, at: CGPoint(x: pill.minX + 8, y: pill.minY + 3), attrs: attrs, in: ctx)
    }

    // MARK: Handles

    private func rotationArm(_ mk: Mark, _ g: Geometry) -> (start: CGPoint, end: CGPoint)? {
        guard mk.canRotate, mk.unrotatedBounds.hasFiniteBounds, g.layout.scale.isFinite, g.layout.scale > 0 else { return nil }
        let r = mk.unrotatedBounds, transform = mk.rotationTransform
        let top = CGPoint(x: r.midX, y: r.minY)
        let knob = CGPoint(x: top.x, y: top.y - 18 / g.layout.scale)
        let start = top.applying(transform), end = knob.applying(transform)
        guard start.hasFiniteCoordinates, end.hasFiniteCoordinates else { return nil }
        return (start, end)
    }

    private func handles(_ mk: Mark, _ g: Geometry) -> [(Handle, CGPoint)] {
        var out: [(Handle, CGPoint)] = []
        if let arm = rotationArm(mk, g) { out.append((.rotation, arm.end)) }
        if mk.isBoxy {
            let r = mk.rect, transform = mk.rotationTransform
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let p = CGPoint(x: r.midX + CGFloat(dx) * r.width / 2, y: r.midY + CGFloat(dy) * r.height / 2)
                out.append((.box(dx, dy), p.applying(transform)))
            } }
        }
        if mk.isLiney {
            out += [(.point(0), mk.a), (.point(1), mk.b)]
            if mk.kind == .arrow { out.append((.point(2), mk.bendHandle)) }
        }
        return out.filter { $0.1.hasFiniteCoordinates }
    }

    private func handle(at v: CGPoint, for mk: Mark, _ g: Geometry) -> Handle? {
        // Endpoints win over the bend handle when they're close together.
        handles(mk, g).min { hypot(g.view($0.1).x - v.x, g.view($0.1).y - v.y) < hypot(g.view($1.1).x - v.x, g.view($1.1).y - v.y) }
            .flatMap { hypot(g.view($0.1).x - v.x, g.view($0.1).y - v.y) <= 8 ? $0.0 : nil }
    }

    private static func resize(_ r: CGRect, _ dx: Int, _ dy: Int, to p: CGPoint, square: Bool) -> CGRect {
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if dx == -1 { x0 = p.x } else if dx == 1 { x1 = p.x }
        if dy == -1 { y0 = p.y } else if dy == 1 { y1 = p.y }
        if square, dx != 0, dy != 0 {
            let fixed = CGPoint(x: dx == -1 ? x1 : x0, y: dy == -1 ? y1 : y0)
            let q = Mark.square(fixed, CGPoint(x: dx == -1 ? x0 : x1, y: dy == -1 ? y0 : y1))
            return CGRect(x: min(fixed.x, q.x), y: min(fixed.y, q.y), width: abs(q.x - fixed.x), height: abs(q.y - fixed.y))
        }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func record() {
        guard !recorded, let m = model else { return }
        m.history.record(m.doc)
        recorded = true
    }

    override func mouseDown(with e: NSEvent) {
        if editor != nil { endTextEdit(commit: true) }
        window?.makeFirstResponder(self)
        guard let m = model, let g = shown else { return }
        let v = point(e), p = g.source(v)
        recorded = false
        creationBefore = nil
        drag = .none
        guard v.hasFiniteCoordinates, p.hasFiniteCoordinates else { return }

        if m.tool == .crop { cropDown(m, g, v, p); return }

        // The selected mark's handles come first, whatever the tool.
        if let id = m.selection, let mk = m.mark(id), let h = handle(at: v, for: mk, g) {
            drag = .handle(mk, h, p)
            return
        }
        let slop = 6 / g.layout.scale
        // Reverse the paint order so a covering redaction gets the click.
        let marks = m.doc.marks
        let hit = marks.last { $0.kind == .redact && $0.redaction == .solid && $0.hit(p, slop: slop) }
            ?? marks.last { $0.kind == .redact && $0.redaction != .solid && $0.hit(p, slop: slop) }
            ?? marks.last { $0.kind != .redact && $0.kind != .highlight && $0.hit(p, slop: slop) }
            ?? marks.last { $0.kind == .highlight && $0.hit(p, slop: slop) }

        switch m.tool {
        case .select:
            if let hit {
                m.selection = hit.id
                if e.clickCount == 2, hit.kind == .text { beginTextEdit(hit.id, new: false); return }
                if e.clickCount == 2, hit.kind == .step { m.focusInspector(); return }
                drag = .move(hit.id, p)
            } else {
                m.selection = nil
                if m.zoom > 1 { drag = .pan(v); NSCursor.closedHand.set() }
            }

        case .text:
            if let hit, hit.kind == .text {
                m.selection = hit.id
                beginTextEdit(hit.id, new: false)
                return
            }
            var mk = m.newMark(.text, at: p)
            mk.points = [CGPoint(x: p.x, y: p.y - mk.size * 0.6)]
            m.doc.marks.append(mk)
            m.selection = mk.id
            beginTextEdit(mk.id, new: true)

        case .step:
            if let hit, hit.kind == .step { m.selection = hit.id; drag = .move(hit.id, p); return }
            record()
            let mk = m.newMark(.step, at: p)
            m.doc.marks.append(mk)
            m.selection = mk.id
            drag = .move(mk.id, p)

        default:
            guard let kind = m.tool.kind else { return }
            drag = .create(m.newMark(kind, at: p), p)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let m = model, let g = shown else { return }
        let v = point(e), p = g.source(v), shift = e.modifierFlags.contains(.shift)
        guard v.hasFiniteCoordinates, p.hasFiniteCoordinates else { return }
        autoscroll(with: e)
        switch drag {
        case .none: return
        case .create(let draft, let start):
            if creationBefore == nil {
                guard p != start else { return }
                creationBefore = m.doc
                m.doc.marks.append(draft)
                m.selection = draft.id
            }
            m.update(draft.id) { mk in
                switch mk.kind {
                case .pen: mk.points.append(p)
                case .rect, .ellipse, .highlight, .redact: mk.points = [start, shift ? Mark.square(start, p) : p]
                default: mk.points = [start, shift ? Mark.snap45(start, p) : p]
                }
            }
        case .move(let id, let from):
            record()
            m.update(id) { $0 = $0.moved(by: CGSize(width: p.x - from.x, height: p.y - from.y)) }
            drag = .move(id, p)
            NSCursor.closedHand.set()
        case .handle(let original, let h, let start):
            guard let current = m.mark(original.id) else { return }
            var mk = current
            switch h {
            case .box(let dx, let dy):
                let transform = original.rotationTransform
                let local = p.applying(transform.inverted())
                let r = PolishCanvas.resize(original.rect, dx, dy, to: local, square: shift)
                // Rotate around the resized centre while keeping the opposite edge in place.
                let center = CGPoint(x: r.midX, y: r.midY)
                let moved = center.applying(transform)
                let result = r.offsetBy(dx: moved.x - center.x, dy: moved.y - center.y)
                mk.points = [result.origin, CGPoint(x: result.maxX, y: result.maxY)]
            case .rotation:
                let center = original.rotationCenter
                guard p != center else { return }
                let delta = atan2(p.y - center.y, p.x - center.x) - atan2(start.y - center.y, start.x - center.x)
                var angle = original.rotation + delta
                let step = CGFloat.pi / 12
                if shift { angle = (angle / step).rounded() * step }
                mk.rotation = atan2(sin(angle), cos(angle))
            case .point(2):
                // Dragged back onto the straight line, the bend goes away.
                let straight = Mark.distance(p, mk.a, mk.b) < 4 / g.layout.scale
                if straight { mk.points = Array(mk.points.prefix(2)) }
                else if mk.points.count > 2 { mk.points[2] = p } else { mk.points.append(p) }
            case .point(let i):
                let other = mk.points[1 - i]
                mk.points[i] = shift ? Mark.snap45(other, p) : p
            }
            guard mk != current else { return }
            record()
            m.update(original.id) { $0 = mk }
        case .pan(let from):
            m.pan = CGPoint(x: m.pan.x + v.x - from.x, y: m.pan.y + v.y - from.y)
            drag = .pan(v)
        case .cropNew(let start):
            m.cropDraft = clampCrop(m, CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)))
        case .cropMove(let from):
            var r = m.cropDraft
            r.origin.x = min(max(0, r.minX + p.x - from.x), CGFloat(m.source.width) - r.width)
            r.origin.y = min(max(0, r.minY + p.y - from.y), CGFloat(m.source.height) - r.height)
            m.cropDraft = r
            drag = .cropMove(p)
        case .cropHandle(let dx, let dy, let rect):
            m.cropDraft = clampCrop(m, PolishCanvas.resize(rect, dx, dy, to: p, square: shift))
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; recorded = false; creationBefore = nil; window?.invalidateCursorRects(for: self) }
        guard let m = model, let g = shown else { return }
        switch drag {
        case .create(let draft, _):
            let id = draft.id
            guard let before = creationBefore else { m.selection = nil; return }
            guard var mk = m.mark(id) else { return }
            let size = mk.kind == .pen ? max(mk.bounds.width, mk.bounds.height) : (mk.isBoxy ? min(mk.rect.width, mk.rect.height) : hypot(mk.b.x - mk.a.x, mk.b.y - mk.a.y))
            if size * g.layout.scale < 4 && !(mk.kind == .pen && mk.points.count > 1) {
                m.doc.marks.removeAll { $0.id == id }
                m.selection = nil
            } else {
                // Keep redo until the drag has made a mark worth keeping.
                m.history.record(before)
                if mk.kind == .pen { mk.points = Mark.smooth(mk.points, minGap: 1.5 / g.layout.scale) }
                m.update(id) { $0 = mk }
            }
        default: break
        }
    }

    private func cropDown(_ m: PolishModel, _ g: Geometry, _ v: CGPoint, _ p: CGPoint) {
        let r = m.cropDraft.hasFiniteBounds ? m.cropDraft : m.doc.crop
        var nearest: (dx: Int, dy: Int, distance: CGFloat)?
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
            let h = g.view(CGPoint(x: r.midX + CGFloat(dx) * r.width / 2, y: r.midY + CGFloat(dy) * r.height / 2))
            let distance = hypot(h.x - v.x, h.y - v.y)
            if distance <= 12, distance < (nearest?.distance ?? .infinity) { nearest = (dx, dy, distance) }
        } }
        if let nearest { drag = .cropHandle(nearest.dx, nearest.dy, r); return }
        // Inside a crop that's already been drawn, a drag moves it. Over the whole image, it draws a new one.
        let whole = r.size == CGSize(width: m.source.width, height: m.source.height)
        if r.contains(p) && !whole { drag = .cropMove(p); return }
        let start = CGPoint(x: min(max(0, p.x), CGFloat(m.source.width)), y: min(max(0, p.y), CGFloat(m.source.height)))
        drag = .cropNew(start)
    }

    private func clampCrop(_ m: PolishModel, _ r: CGRect) -> CGRect {
        // Clamp both edges to the image so a drag past it can still leave a finite line.
        let w = CGFloat(m.source.width), h = CGFloat(m.source.height)
        let x0 = min(w, max(0, r.minX)), x1 = min(w, max(0, r.maxX))
        let y0 = min(h, max(0, r.minY)), y1 = min(h, max(0, r.maxY))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    override func magnify(with e: NSEvent) {
        guard let m = model else { return }
        m.zoom = min(8, max(0.25, m.zoom * (1 + e.magnification)))
        if m.zoom <= 1 { m.pan = .zero }
    }

    override func scrollWheel(with e: NSEvent) {
        guard let m = model else { return }
        if e.modifierFlags.contains(.command) {
            m.zoom = min(8, max(0.25, m.zoom * (1 + e.scrollingDeltaY * 0.01)))
            if m.zoom <= 1 { m.pan = .zero }
        } else if m.zoom > 1 {
            m.pan = CGPoint(x: m.pan.x + e.scrollingDeltaX, y: m.pan.y + e.scrollingDeltaY)
        } else {
            super.scrollWheel(with: e)
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        registerCursorRects(addCursorRect(_:cursor:))
    }

    func registerCursorRects(_ register: (CGRect, NSCursor) -> Void) {
        guard let m = model else { return }
        func add(_ rect: CGRect, _ cursor: NSCursor) {
            guard rect.hasFiniteBounds, !rect.isEmpty else { return }
            register(rect, cursor)
        }
        let cursor: NSCursor
        switch m.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        add(bounds, cursor)
        guard let g = shown else { return }
        if m.tool == .crop {
            let rect = g.view(m.cropDraft)
            // Insetting past the centre gives CGRect.null, which AppKit can't register.
            if rect.width > 20, rect.height > 20 { add(rect.insetBy(dx: 10, dy: 10), .openHand) }
            return
        }
        if m.tool == .select {
            for mk in m.doc.marks { add(g.view(mk.bounds).insetBy(dx: -4, dy: -4), .openHand) }
        }
        if let id = m.selection, let mk = m.mark(id) {
            for (_, p) in handles(mk, g) {
                let v = g.view(p)
                add(CGRect(x: v.x - 7, y: v.y - 7, width: 14, height: 14), .crosshair)
            }
        }
    }

    // MARK: Keys

    /// Single-key tools and editing keys. Returns whether the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        guard let m = model, editor == nil else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        switch Int(e.keyCode) {
        case 53: // Esc
            if m.tool == .crop { m.cancelCrop() }
            else if m.selection != nil { m.selection = nil }
            else if m.tool != .select { m.tool = .select }
            else { m.close() }
            return true
        case 36, 76: // Return, Enter
            if m.tool == .crop { m.finishCrop() } else { m.copyAndClose() }
            return true
        case 51, 117: // Delete
            guard m.selection != nil else { return false }
            m.deleteSelection()
            return true
        case 123, 124, 125, 126: // Arrows nudge by a screen point, Shift by ten.
            guard let id = m.selection, let g = shown else { return false }
            let step = (e.modifierFlags.contains(.shift) ? 10 : 1) / g.layout.scale
            let d: CGSize = [123: CGSize(width: -step, height: 0), 124: CGSize(width: step, height: 0),
                             125: CGSize(width: 0, height: step), 126: CGSize(width: 0, height: -step)][Int(e.keyCode)]!
            m.history.record(m.doc)
            m.update(id) { $0 = $0.moved(by: d) }
            return true
        default: break
        }
        guard mods.isEmpty, let c = e.charactersIgnoringModifiers?.lowercased().first,
              let tool = PolishTool.allCases.first(where: { $0.key == c }) else { return false }
        if tool == .crop && m.tool == .crop { m.finishCrop() } else { m.tool = tool }
        return true
    }

    @objc func undo(_ sender: Any?) { model?.undo() }
    @objc func redo(_ sender: Any?) { model?.redo() }
    @objc func copy(_ sender: Any?) { model?.copy() }
    @objc func delete(_ sender: Any?) { model?.deleteSelection() }

    // MARK: Text editing

    var isEditingText: Bool { editor != nil }

    private func beginTextEdit(_ id: UUID, new: Bool) {
        guard let m = model, let mk = m.mark(id) else { return }
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.allowsUndo = true
        tv.delegate = self
        // The canvas draws the text itself, exactly as it will export; the editor only shows the caret and selection.
        tv.textColor = .clear
        tv.insertionPointColor = (mk.pill ? mk.color.contrast : mk.color).ns
        tv.string = mk.text
        editor = tv
        editingID = id
        editingNew = new
        editingBefore = mk.text
        addSubview(tv)
        layoutEditor()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func layoutEditor() {
        guard let tv = editor, let id = editingID, let m = model, let mk = m.mark(id), let g = shown else { return }
        let s = g.layout.scale
        let pad = mk.pill ? CGSize(width: mk.size * 0.4 * s, height: mk.size * 0.18 * s) : .zero
        let r = g.view(mk.textRect)
        tv.font = Mark.font(mk.size * s)
        let transform = g.rotationTransform(for: mk)
        let origin = CGPoint(x: r.minX + pad.width, y: r.minY + pad.height).applying(transform)
        tv.frameRotation = 0
        tv.frame = CGRect(origin: origin, size: CGSize(width: max(r.width - pad.width * 2, 4) + mk.size * s, height: r.height - pad.height * 2))
        tv.frameRotation = atan2(transform.b, transform.a) * 180 / .pi
    }

    func textDidChange(_ n: Notification) {
        guard let tv = editor, let id = editingID else { return }
        model?.update(id) { $0.text = tv.string }
        layoutEditor()
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            endTextEdit(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endTextEdit(commit: false)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            tv.insertText("\n", replacementRange: tv.selectedRange())
            return true
        default: return false
        }
    }

    func endTextEdit(commit: Bool) {
        guard let tv = editor, let id = editingID, let m = model else { return }
        editor = nil
        editingID = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard let index = m.doc.marks.firstIndex(where: { $0.id == id }) else { return }

        let text = commit ? tv.string : editingBefore
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if commit && (editingNew ? !empty : text != editingBefore) {
            var before = m.doc
            if editingNew { before.marks.remove(at: index) }
            else { before.marks[index].text = editingBefore }
            m.history.record(before)
        }
        if empty && (commit || editingNew) {
            m.doc.marks.remove(at: index)
            m.selection = nil
        } else {
            m.doc.marks[index].text = text
        }
    }
}

extension PolishCanvas {
    /// Where a source pixel is in this view, for tests driving the canvas with events.
    func viewPoint(_ p: CGPoint) -> CGPoint { geometry?.view(p) ?? p }
}
