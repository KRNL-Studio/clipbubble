import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Polish editor window: a toolbar of tools across the top, the canvas, an inspector on the right,
// and presets plus the ways out (drag, share, save, copy) along the bottom.

/// The settings new marks start with, remembered between screenshots.
struct Ink: Codable, Equatable {
    var color = RGBA.palette[0]
    /// Stroke width in steps of the image's unit (so it looks the same on a small crop and a 5K screen).
    var width: CGFloat = 4
    /// Text and step size, as a multiple of the default.
    var size: CGFloat = 1
    var fill: Mark.Fill = .stroke
    var pill = false
    var doubleHead = false
    var redaction: Mark.Redaction = .pixelate

    private static let key = "polish.ink"
    static var saved: Ink {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Ink.self, from: $0) } ?? Ink() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

final class PolishModel: ObservableObject {
    let source: CGImage
    /// A smaller copy for crop mode and quick thumbnails.
    let preview: CGImage
    let name: String

    @Published var doc: PolishDoc
    @Published var tool: PolishTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop { applyCrop() }
            if tool == .crop { cropDraft = doc.crop; selection = nil }
            if tool.kind != nil { pane = .markup }
        }
    }
    @Published var selection: UUID? { didSet { if selection != nil { pane = .markup } } }
    @Published var cropDraft: CGRect
    @Published var zoom: CGFloat = 1
    @Published var pan: CGPoint = .zero
    @Published var ink = Ink.saved { didSet { Ink.saved = ink } }
    @Published var pane: Pane = .style
    @Published var toast: Toast?
    @Published var busy: String?
    @Published var thumbs: [String: NSImage] = [:]
    @Published var presets = PolishPreset.all
    @Published var copied = false
    @Published var redactKinds: Set<Redactor.Kind> = Set(Redactor.Kind.allCases)
    @Published var redactFaces = false

    var history = DocHistory()
    var onClose: () -> Void = {}
    var onSaved: (URL) -> Void = { _ in }
    var focusInspector: () -> Void = {}

    enum Pane: String, CaseIterable { case style = "Style", markup = "Markup" }

    struct Toast: Equatable {
        var text: String
        var symbol: String
        var id = UUID()
    }

    init(url: URL, image: CGImage) {
        source = image
        name = url.deletingPathExtension().lastPathComponent
        let k = min(1, 2400 / CGFloat(max(image.width, image.height)))
        preview = k < 1 ? PolishModel.scaled(image, k) ?? image : image
        let d = PolishDoc(source: url, size: CGSize(width: image.width, height: image.height))
        doc = d
        cropDraft = d.crop
        makeThumbs()
    }

    static func scaled(_ img: CGImage, _ k: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Marks

    /// One unit of stroke width, in source pixels.
    var unit: CGFloat { max(1, CGFloat(max(source.width, source.height)) / 900) }

    func newMark(_ kind: Mark.Kind, at p: CGPoint) -> Mark {
        var m = Mark(kind, kind == .pen ? [p] : [p, p])
        m.color = ink.color
        m.width = ink.width * unit
        m.fill = ink.fill
        m.pill = ink.pill
        m.doubleHead = ink.doubleHead
        m.redaction = ink.redaction
        switch kind {
        case .text: m.size = (22 * unit * ink.size).rounded()
        case .step: m.size = (30 * unit * ink.size).rounded(); m.number = doc.nextStep
        case .measure: m.size = 22 * unit; m.width = max(unit * 2, 2)
        case .redact: m.color = RGBA(hex: 0x1C1C1E)
        default: break
        }
        return m
    }

    func mark(_ id: UUID) -> Mark? { doc.marks.first { $0.id == id } }

    func update(_ id: UUID, _ f: (inout Mark) -> Void) {
        guard let i = doc.marks.firstIndex(where: { $0.id == id }) else { return }
        f(&doc.marks[i])
    }

    var selected: Mark? { selection.flatMap(mark) }

    private var lastCoalesce: (key: String, at: Date)?

    /// A change from the inspector. Changes to the same control in quick succession (a slider drag) undo as one.
    func edit(_ key: String, _ f: (inout PolishDoc) -> Void) {
        let now = Date()
        if lastCoalesce?.key != key || now.timeIntervalSince(lastCoalesce!.at) > 0.8 { history.record(doc) }
        lastCoalesce = (key, now)
        f(&doc)
    }

    /// Change the selected mark (if any) and the ink for the next one.
    func style(_ key: String, ink change: (inout Ink) -> Void, mark apply: (inout Mark) -> Void) {
        change(&ink)
        if let id = selection { edit(key + id.uuidString) { _ in }; update(id, apply) }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        history.record(doc)
        doc.marks.removeAll { $0.id == id }
        selection = nil
        // Steps renumber, so removing step 2 of 3 leaves 1 and 2.
        var n = 0
        for i in doc.marks.indices where doc.marks[i].kind == .step { n += 1; doc.marks[i].number = n }
    }

    func undo() {
        guard let d = history.undo(doc) else { NSSound.beep(); return }
        doc = d
        dropStaleSelection()
    }

    func redo() {
        guard let d = history.redo(doc) else { NSSound.beep(); return }
        doc = d
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        if let id = selection, mark(id) == nil { selection = nil }
        lastCoalesce = nil
    }

    // MARK: Style

    func apply(_ p: PolishPreset) {
        edit("preset") { $0.style = p.style }
        lastCoalesce = nil
        PolishPreset.last = p.style
    }

    func saveAsPreset(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var saved = PolishPreset.saved.filter { $0.name != n }
        saved.append(PolishPreset(name: n, style: doc.style))
        PolishPreset.saved = saved
        presets = PolishPreset.all
        makeThumbs()
        say("Saved “\(n)”", "star")
    }

    func removePreset(_ p: PolishPreset) {
        PolishPreset.saved = PolishPreset.saved.filter { $0.name != p.name }
        presets = PolishPreset.all
    }

    func applyCrop() {
        let r = cropDraft.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard r.width >= 4, r.height >= 4, r != doc.crop else { return }
        edit("crop") { $0.crop = r }
        lastCoalesce = nil
        makeThumbs()
    }

    func cancelCrop() {
        cropDraft = doc.crop
        tool = .select
    }

    func resetCrop() {
        cropDraft = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        if tool != .crop { applyCrop() }
    }

    /// Small renders of each preset with this screenshot, for the preset strip.
    func makeThumbs() {
        let doc = self.doc, src = preview, k = CGFloat(preview.width) / CGFloat(source.width), list = presets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var d = doc
            d.marks = []
            d.source = doc.source
            d.crop = CGRect(x: doc.crop.minX * k, y: doc.crop.minY * k, width: doc.crop.width * k, height: doc.crop.height * k).integral
            var out: [String: NSImage] = [:]
            for p in list {
                d.style = p.style
                // About 130 px across: sharp at 2× in a 66-point chip.
                let one = PolishLayout(doc: d, scale: 1).canvas
                if let img = PolishRenderer.render(d, source: src, scale: 130 / max(one.width, one.height), marks: false) {
                    out[p.name] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                }
            }
            DispatchQueue.main.async { self?.thumbs = out }
        }
    }

    // MARK: Out

    private var retina: Bool { !UserDefaults.standard.bool(forKey: "polish.export1x") }

    func png() -> Data? {
        PolishPreset.last = doc.style
        return PolishRenderer.png(doc, retina: retina)
    }

    func copy() {
        guard let d = png() else { say("Couldn't make the image", "exclamationmark.triangle"); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(d, forType: .png)
        copied = true
        say("Copied", "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copied = false }
    }

    func copyAndClose() {
        copy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.close() }
    }

    func save() {
        guard let d = png() else { say("Couldn't make the image", "exclamationmark.triangle"); return }
        let url = PolishRenderer.saveURL(for: doc.source)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url)
            onSaved(url)
            say("Saved as “\(url.lastPathComponent)”", "square.and.arrow.down")
        } catch {
            say("Couldn't save: \(error.localizedDescription)", "exclamationmark.triangle")
        }
    }

    /// A finished copy in a temporary folder, for dragging out and sharing.
    func exportFile() -> URL? {
        guard let d = png() else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipBubble Polish", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name) polished.png")
        return (try? d.write(to: url)) != nil ? url : nil
    }

    func close() { onClose() }

    func say(_ text: String, _ symbol: String) {
        let t = Toast(text: text, symbol: symbol)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self?.toast?.id == t.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    // MARK: Vision

    /// Covers emails, numbers, keys and (if asked) faces. Replaces the last auto-redact, keeps hand-drawn ones.
    func autoRedact() {
        guard busy == nil else { return }
        busy = "Looking for things to hide…"
        let src = source, kinds = redactKinds, faces = redactFaces, crop = doc.crop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Redactor.find(in: src, kinds: kinds, faces: faces).filter { crop.intersects($0.1) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                self.history.record(self.doc)
                let before = self.doc.marks.filter(\.auto).count
                self.doc.marks.removeAll(where: \.auto)
                for (_, r) in found {
                    var m = Mark(.redact, [r.origin, CGPoint(x: r.maxX, y: r.maxY)])
                    m.redaction = self.ink.redaction
                    m.color = RGBA(hex: 0x1C1C1E)
                    m.auto = true
                    self.doc.marks.insert(m, at: 0)
                }
                if found.isEmpty && before == 0 { self.history.cancel() }
                self.selection = nil
                let n = found.count
                self.say(n == 0 ? "Nothing sensitive found" : "Hid \(n) \(n == 1 ? "thing" : "things") · select one to remove it",
                         n == 0 ? "checkmark.shield" : "eye.slash")
            }
        }
    }

    func removeAutoRedactions() {
        guard doc.marks.contains(where: \.auto) else { return }
        history.record(doc)
        doc.marks.removeAll(where: \.auto)
    }

    func copyText() {
        guard busy == nil else { return }
        busy = "Reading text…"
        let src = source, crop = doc.crop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = src.cropping(to: crop) ?? src
            let text = Redactor.text(in: img)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                guard !text.isEmpty else { self.say("No text found", "text.viewfinder"); return }
                Board.writeText(text)
                let lines = text.split(separator: "\n").count
                self.say("Copied \(lines) \(lines == 1 ? "line" : "lines") of text", "text.viewfinder")
            }
        }
    }
}

extension Clip {
    /// The image Polish can open: a copied image or an image file, here on this Mac.
    var polishPath: String? {
        guard !remote, let p = imagePath, FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
}

// MARK: - Window

final class PolishWindow: NSObject, NSWindowDelegate {
    private static var open: [PolishWindow] = []
    /// Called with each saved copy, so it can join history.
    static var onSaved: (URL) -> Void = { _ in }

    let window: EditorWindow
    let model: PolishModel
    let canvas = PolishCanvas()

    /// Opens a screenshot in the editor, or brings forward the window it's already open in.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        if let w = open.first(where: { $0.model.doc.source == url }) {
            NSApp.activate(ignoringOtherApps: true)
            w.window.makeKeyAndOrderFront(nil)
            return true
        }
        guard let img = PolishRenderer.load(url) else { return false }
        let w = PolishWindow(url: url, image: img)
        open.append(w)
        w.show()
        return true
    }

    private init(url: URL, image: CGImage) {
        model = PolishModel(url: url, image: image)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        canvas.model = model
        window.canvas = canvas
        window.title = "Polish — \(model.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PolishView(model: model, canvas: canvas))
        window.setContentSize(idealSize(for: image))
        model.onClose = { [weak self] in self?.window.performClose(nil) }
        model.onSaved = { PolishWindow.onSaved($0) }
    }

    /// Big enough to see the screenshot well, never bigger than the screen.
    private func idealSize(for img: CGImage) -> NSSize {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let chrome = NSSize(width: 290, height: 140)
        let one = PolishLayout(doc: model.doc, scale: 1).canvas
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let maxW = screen.width * 0.86 - chrome.width, maxH = screen.height * 0.86 - chrome.height
        let k = min(maxW / one.width, maxH / one.height, 1 / backing * 1.4)
        return NSSize(width: max(860, one.width * k + chrome.width + 72), height: max(560, one.height * k + chrome.height + 60))
    }

    private func show() {
        Presence.opened(window)
        window.center()
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ n: Notification) {
        canvas.endTextEdit(commit: true)
        ColorPanelLink.shared.detach()
        PolishPreset.last = model.doc.style
        Presence.closed(window)
        PolishWindow.open.removeAll { $0 === self }
    }
}

/// Sends tool keys to the canvas wherever focus is (except while typing), and handles the editor's shortcuts.
final class EditorWindow: NSWindow {
    weak var canvas: PolishCanvas?

    private var typing: Bool { firstResponder is NSTextView }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, !typing, let c = canvas, c.handleKey(e) { return }
        super.sendEvent(e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, let m = canvas?.model else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if typing && mods == .command && ["c", "v", "x", "a", "z"].contains(key) { return super.performKeyEquivalent(with: e) }
        switch (mods, key) {
        case (.command, "s"): m.save(); return true
        case (.command, "c"): m.copy(); return true
        case ([.command, .shift], "c"): m.copyText(); return true
        case (.command, "z"): m.undo(); return true
        case ([.command, .shift], "z"): m.redo(); return true
        case (.command, "0"): m.zoom = 1; m.pan = .zero; return true
        case (.command, "="), (.command, "+"): m.zoom = min(8, m.zoom * 1.25); return true
        case (.command, "-"): m.zoom = max(0.25, m.zoom / 1.25); if m.zoom <= 1 { m.pan = .zero }; return true
        case ([.command, .shift], "r"): m.autoRedact(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }
}

// MARK: - Views

private struct CanvasHost: NSViewRepresentable {
    @ObservedObject var model: PolishModel
    let canvas: PolishCanvas

    func makeNSView(context: Context) -> PolishCanvas { canvas }
    func updateNSView(_ v: PolishCanvas, context: Context) { v.sync() }
}

/// Empty toolbar space that drags the window, like a real title bar.
private struct WindowDragArea: NSViewRepresentable {
    final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

struct PolishView: View {
    @ObservedObject var model: PolishModel
    let canvas: PolishCanvas
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            PolishToolbar(model: model)
            Divider()
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    CanvasHost(model: model, canvas: canvas)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    ToastView(model: model)
                        .padding(.bottom, 16)
                }
                Divider()
                PolishInspector(model: model)
                    .frame(width: 272)
            }
            Divider()
            PolishBottomBar(model: model)
        }
        .ignoresSafeArea(.container, edges: .top)
        .scaleEffect(appeared ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { appeared = true } }
    }
}

// MARK: Toolbar

private struct PolishToolbar: View {
    @ObservedObject var model: PolishModel

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 72)  // the traffic lights
            ForEach(Array(PolishTool.groups.enumerated()), id: \.offset) { i, group in
                if i > 0 { Divider().frame(height: 18) }
                HStack(spacing: 2) {
                    ForEach(group) { t in ToolButton(tool: t, on: model.tool == t) { model.tool = model.tool == t && t == .crop ? .select : t } }
                }
            }
            WindowDragArea().frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.tool == .crop {
                Button("Reset") { model.resetCrop() }.controlSize(.small)
                Button("Cancel") { model.cancelCrop() }.controlSize(.small)
                Button("Done") { model.tool = .select }.controlSize(.small).buttonStyle(.borderedProminent)
                Divider().frame(height: 18)
            }
            IconButton(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z", disabled: !model.history.canUndo) { model.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z", disabled: !model.history.canRedo) { model.redo() }
            Menu {
                Button("Zoom to Fit  ⌘0") { model.zoom = 1; model.pan = .zero }
                Button("Zoom In  ⌘+") { model.zoom = min(8, model.zoom * 1.25) }
                Button("Zoom Out  ⌘−") { model.zoom = max(0.25, model.zoom / 1.25); if model.zoom <= 1 { model.pan = .zero } }
            } label: {
                Text(model.zoom == 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 40)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }
}

private struct ToolButton: View {
    let tool: PolishTool
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                .frame(width: 30, height: 28)
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.82))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? Color.accentColor : Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("\(tool.title)  \(tool.key.uppercased())")
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover && !disabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: Toast

private struct ToastView: View {
    @ObservedObject var model: PolishModel

    var body: some View {
        Group {
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                }
                .pill()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let t = model.toast {
                HStack(spacing: 7) {
                    Image(systemName: t.symbol).foregroundStyle(.secondary)
                    Text(t.text)
                }
                .pill()
                .id(t.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.busy)
        .allowsHitTesting(false)
    }
}

private extension View {
    func pill() -> some View {
        font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

// MARK: Inspector

private struct PolishInspector: View {
    @ObservedObject var model: PolishModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.pane) {
                ForEach(PolishModel.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.pane == .style { StylePane(model: model) } else { MarkupPane(model: model) }
                }
                .frame(width: 244, alignment: .leading)
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var format: (CGFloat) -> String = { "\(Int(($0 * 100).rounded()))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

private struct StylePane: View {
    @ObservedObject var model: PolishModel
    @State private var naming = false
    @State private var presetName = ""

    private func bind<T>(_ key: WritableKeyPath<PolishStyle, T>, _ id: String) -> Binding<T> {
        Binding(get: { model.doc.style[keyPath: key] }, set: { v in model.edit(id) { $0.style[keyPath: key] = v } })
    }

    private var isBackground: (PolishStyle.Background) -> Bool { { model.doc.style.background == $0 } }

    var body: some View {
        Section(title: "Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                Swatch(on: isBackground(.none), help: "None") { Checker() }
                    .onTapGesture { model.edit("bg") { $0.style.background = .none } }
                Swatch(on: isBackground(.blurred), help: "Blurred screenshot") {
                    Image(decorative: model.preview, scale: 1).resizable().scaledToFill().blur(radius: 3).overlay(Color.black.opacity(0.12))
                }
                .onTapGesture { model.edit("bg") { $0.style.background = .blurred } }
                ForEach(Gradients.all.indices, id: \.self) { i in
                    Swatch(on: isBackground(.gradient(i)), help: Gradients.all[i].name) {
                        LinearGradient(colors: Gradients.all[i].colors.map { Color(nsColor: $0.ns) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .onTapGesture { model.edit("bg") { $0.style.background = .gradient(i) } }
                }
                ForEach([RGBA.white, RGBA(hex: 0xF2F2F7), RGBA(hex: 0x1C1C1E), RGBA.black], id: \.self) { c in
                    Swatch(on: isBackground(.solid(c)), help: "Solid") { Color(nsColor: c.ns) }
                        .onTapGesture { model.edit("bg") { $0.style.background = .solid(c) } }
                }
                ColorWell(color: { if case .solid(let c) = model.doc.style.background { return c }; return .white }(),
                          alpha: false) { c in model.edit("bgcolor") { $0.style.background = .solid(c) } }
                    .frame(width: 30, height: 30)
                    .frame(width: 34, height: 34)
                    .help("Any color")
            }
        }
        Section(title: "Shape") {
            SliderRow(title: "Padding", value: bind(\.padding, "padding"), range: 0...0.25)
            SliderRow(title: "Corners", value: bind(\.radius, "radius"), range: 0...0.08, format: { "\(Int(($0 / 0.08 * 100).rounded()))" })
            SliderRow(title: "Shadow", value: bind(\.shadow, "shadow"), range: 0...1)
        }
        Section(title: "Window") {
            Picker("", selection: bind(\.frame, "frame")) {
                Text("None").tag(PolishStyle.Frame.none)
                Text("Light").tag(PolishStyle.Frame.light)
                Text("Dark").tag(PolishStyle.Frame.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Section(title: "Size") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(PolishStyle.Size.allCases, id: \.self) { s in
                    Chip(title: s.title, on: model.doc.style.size == s) { model.edit("size") { $0.style.size = s } }
                }
            }
            Text(sizeLine).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
        Section(title: "Crop") {
            HStack {
                Button(model.tool == .crop ? "Done Cropping" : "Crop…") { model.tool = model.tool == .crop ? .select : .crop }
                if model.doc.crop.size != CGSize(width: model.source.width, height: model.source.height) {
                    Button("Reset") { model.resetCrop() }
                }
            }
            .controlSize(.small)
        }
        Divider()
        Button { presetName = ""; naming = true } label: { Label("Save Style as Preset…", systemImage: "star") }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .popover(isPresented: $naming, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Name this style").font(.headline)
                    TextField("My style", text: $presetName).frame(width: 200).onSubmit(save)
                    HStack {
                        Spacer()
                        Button("Cancel") { naming = false }
                        Button("Save", action: save).buttonStyle(.borderedProminent).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(16)
            }
    }

    private func save() {
        model.saveAsPreset(presetName)
        naming = false
    }

    private var sizeLine: String {
        let c = PolishLayout(doc: model.doc, scale: model.doc.style.size.pixels == nil && UserDefaults.standard.bool(forKey: "polish.export1x") ? 0.5 : 1).canvas
        return "Exports at \(Int(c.width)) × \(Int(c.height)) px"
    }
}

private struct Swatch<Content: View>: View {
    let on: Bool
    let help: String
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(2.5)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: on ? 2 : 0))
            .scaleEffect(hover ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
            .onHover { hover = $0 }
            .contentShape(Rectangle())
            .help(help)
            .frame(width: 34, height: 34)
    }
}

private struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where Int(x / s + y / s) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct MarkupPane: View {
    @ObservedObject var model: PolishModel

    /// What the controls apply to: the selected mark, or the tool's next one.
    private var kind: Mark.Kind? { model.selected?.kind ?? model.tool.kind }

    var body: some View {
        if let kind {
            Section(title: model.selected != nil ? "Selected \(title(kind))" : "New \(title(kind))") { EmptyView() }
            if kind != .redact && kind != .highlight { colors }
            if [.arrow, .line, .rect, .ellipse, .pen].contains(kind) {
                SliderRow(title: "Width", value: Binding(
                    get: { model.selected.map { $0.width / model.unit } ?? model.ink.width },
                    set: { v in model.style("width", ink: { $0.width = v }, mark: { $0.width = v * model.unit }) }),
                          range: 1...14, format: { "\(Int($0.rounded()))" })
            }
            if kind == .rect || kind == .ellipse {
                Picker("", selection: Binding(
                    get: { model.selected?.fill ?? model.ink.fill },
                    set: { v in model.style("fill", ink: { $0.fill = v }, mark: { $0.fill = v }) })) {
                    Text("Outline").tag(Mark.Fill.stroke)
                    Text("Tinted").tag(Mark.Fill.both)
                    Text("Filled").tag(Mark.Fill.fill)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if kind == .arrow {
                Toggle("Arrow at both ends", isOn: Binding(
                    get: { model.selected?.doubleHead ?? model.ink.doubleHead },
                    set: { v in model.style("double", ink: { $0.doubleHead = v }, mark: { $0.doubleHead = v }) }))
                    .font(.system(size: 12))
                Text("Drag the middle handle to curve it.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if kind == .text || kind == .step {
                SliderRow(title: "Size", value: Binding(
                    get: { model.selected.map { $0.size / ((kind == .text ? 22 : 30) * model.unit) } ?? model.ink.size },
                    set: { v in model.style("size", ink: { $0.size = v }, mark: { $0.size = ((kind == .text ? 22 : 30) * model.unit * v).rounded() }) }),
                          range: 0.5...3, format: { String(format: "%.1f×", $0) })
            }
            if kind == .text {
                Toggle("Background pill", isOn: Binding(
                    get: { model.selected?.pill ?? model.ink.pill },
                    set: { v in model.style("pill", ink: { $0.pill = v }, mark: { $0.pill = v }) }))
                    .font(.system(size: 12))
                Text("Double-click text to edit it. Return finishes, ⌥Return adds a line.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if kind == .step, let m = model.selected {
                Stepper("Number \(m.number)", value: Binding(
                    get: { m.number },
                    set: { v in model.edit("number" + m.id.uuidString) { _ in }; model.update(m.id) { $0.number = max(1, v) } }), in: 1...99)
                    .font(.system(size: 12))
            }
            if kind == .redact {
                Picker("", selection: Binding(
                    get: { model.selected?.redaction ?? model.ink.redaction },
                    set: { v in model.style("redaction", ink: { $0.redaction = v }, mark: { $0.redaction = v }) })) {
                    ForEach(Mark.Redaction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("Covered pixels are replaced in the exported image, not just hidden.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if kind == .highlight {
                Text("Everything outside the box is dimmed. Draw several to spotlight more than one thing.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if kind == .measure {
                Text("Shows the distance in the screenshot's own pixels. Hold Shift for straight lines.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if model.selected != nil {
                Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .controlSize(.small)
            }
            Divider()
        } else {
            Text("Pick a tool above, or press its key: A for an arrow, R for a box, T for text, B to redact.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
        Section(title: "Hide sensitive info") {
            ForEach(Redactor.Kind.allCases, id: \.self) { k in
                Toggle(k.title, isOn: Binding(get: { model.redactKinds.contains(k) },
                                              set: { if $0 { model.redactKinds.insert(k) } else { model.redactKinds.remove(k) } }))
                    .font(.system(size: 12))
            }
            Toggle("Faces", isOn: $model.redactFaces).font(.system(size: 12))
            HStack {
                Button { model.autoRedact() } label: { Label("Find and Hide", systemImage: "eye.slash") }
                    .disabled(model.busy != nil || (model.redactKinds.isEmpty && !model.redactFaces))
                if model.doc.marks.contains(where: \.auto) {
                    Button("Undo All") { model.removeAutoRedactions() }
                }
            }
            .controlSize(.small)
            Text("Text is read on this Mac. Check the result: anything missed can be covered with the Redact tool.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ k: Mark.Kind) -> String {
        switch k {
        case .rect: return "box"
        case .highlight: return "spotlight"
        default: return k.rawValue
        }
    }

    private var colors: some View {
        let current = model.selected?.color ?? model.ink.color
        return HStack(spacing: 4) {
            ForEach(RGBA.palette, id: \.self) { c in
                Circle()
                    .fill(Color(nsColor: c.ns))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .padding(2)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: current == c ? 2 : 0))
                    .contentShape(Circle())
                    .onTapGesture { model.style("color", ink: { $0.color = c }, mark: { $0.color = c }) }
            }
            ColorWell(color: current, alpha: true) { c in model.style("color", ink: { $0.color = c }, mark: { $0.color = c }) }
                .frame(width: 22, height: 22)
                .help("Any color")
        }
    }
}

/// A rainbow swatch that opens the system color panel, for any color beyond the presets.
private struct ColorWell: View {
    let color: RGBA
    let alpha: Bool
    let changed: (RGBA) -> Void
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                Circle().fill(Color(nsColor: color.ns)).padding(d * 0.22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).padding(d * 0.22))
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .scaleEffect(hover ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture { ColorPanelLink.shared.open(color, alpha: alpha, changed) }
    }
}

/// Points the shared color panel at whichever swatch opened it last.
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    private var changed: ((RGBA) -> Void)?

    fileprivate func open(_ c: RGBA, alpha: Bool, _ f: @escaping (RGBA) -> Void) {
        let p = NSColorPanel.shared
        changed = nil
        p.showsAlpha = alpha
        p.color = c.ns
        p.isContinuous = true
        p.setTarget(self)
        p.setAction(#selector(picked))
        changed = f
        p.orderFront(nil)
    }

    @objc private func picked(_ p: NSColorPanel) { changed?(RGBA(p.color)) }

    /// When the editor that owns it closes.
    func detach() {
        changed = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.close()
    }
}

// MARK: Bottom bar

private struct PolishBottomBar: View {
    @ObservedObject var model: PolishModel

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.presets) { p in
                        PresetChip(preset: p, image: model.thumbs[p.name], on: model.doc.style == p.style,
                                   removable: !PolishPreset.builtIn.contains { $0.name == p.name },
                                   apply: { model.apply(p) }, remove: { model.removePreset(p) })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider().frame(height: 36)
            HStack(spacing: 4) {
                IconButton(symbol: "eye.slash", help: "Hide sensitive info  ⇧⌘R", disabled: model.busy != nil) { model.autoRedact() }
                IconButton(symbol: "text.viewfinder", help: "Copy text in the image  ⇧⌘C", disabled: model.busy != nil) { model.copyText() }
                DragOut(model: model)
                ShareButton(model: model).frame(width: 28, height: 28).help("Share")
            }
            Button { model.save() } label: { Text("Save") }
                .help("Save a copy  ⌘S")
                .controlSize(.large)
            Button { model.copy() } label: {
                Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 74)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Copy the image  ⌘C · Return copies and closes")
            .padding(.trailing, 14)
        }
        .frame(height: 74)
        .background(.bar)
    }
}

private struct PresetChip: View {
    let preset: PolishPreset
    let image: NSImage?
    let on: Bool
    let removable: Bool
    let apply: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05))
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(3) }
            }
            .frame(width: 66, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: on ? 2 : 1))
            Text(preset.name).font(.system(size: 10, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
        }
        .frame(width: 70)
        .scaleEffect(hover ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: apply)
        .contextMenu { if removable { Button("Remove Preset", role: .destructive, action: remove) } }
    }
}

/// A handle that drags the finished image out, into Slack, a browser or Finder.
private struct DragOut: View {
    @ObservedObject var model: PolishModel
    @State private var hover = false

    var body: some View {
        Image(systemName: "hand.draw")
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .onHover { hover = $0 }
            .help("Drag the finished image anywhere")
            .onDrag {
                guard let url = model.exportFile() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
    }
}

private struct ShareButton: NSViewRepresentable {
    @ObservedObject var model: PolishModel

    final class Coordinator: NSObject {
        var model: PolishModel
        init(_ m: PolishModel) { model = m }
        @objc func share(_ b: NSButton) {
            guard let url = model.exportFile() else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                         target: context.coordinator, action: #selector(Coordinator.share))
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.model = model }
}
