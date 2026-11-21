import AppKit
import Carbon.HIToolbox
import SwiftUI

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

    @Published var doc: PolishDoc {
        didSet {
            let redactions = doc.marks.lazy.filter { $0.kind == .redact }
            let previous = oldValue.marks.lazy.filter { $0.kind == .redact }
            let changed = !redactions.elementsEqual(previous)
            if changed { thumbs.removeAll() }
            if changed || doc.crop != oldValue.crop { makeThumbs(delay: 0.15) }
        }
    }
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
    @Published var zoom: CGFloat = 1 {
        didSet {
            if !zoom.isFinite { zoom = 1 }
            else if zoom < 0.25 || zoom > 8 { zoom = min(8, max(0.25, zoom)) }
        }
    }
    @Published var pan: CGPoint = .zero
    @Published var ink = Ink.saved { didSet { Ink.saved = ink } }
    @Published var pane: Pane = .style
    @Published var toast: Toast?
    @Published private var activity: Activity?
    var busy: String? { activity?.rawValue }
    var findingRedactions: Bool { activity == .finding }
    private var queuedExports: [(PolishModel) -> Void] = []

    private enum Activity: String {
        case finding = "Looking for things to hide…"
        case reading = "Reading text…"
    }
    @Published var thumbs: [String: NSImage] = [:]
    @Published var presets = PolishPreset.all
    @Published var copied = false
    @Published var redactKinds: Set<Redactor.Kind> = Set(Redactor.Kind.allCases)
    @Published var redactFaces = false

    var history = DocHistory()
    var onClose: () -> Void = {}
    var onSaved: (URL) -> Void = { _ in }
    var pasteboard = NSPasteboard.general
    var detectRedactions: (CGImage, Set<Redactor.Kind>, Bool) throws -> [(Redactor.Kind?, CGRect)] = Redactor.find

    private static let thumbnailQueue = DispatchQueue(label: "polish.thumbnails", qos: .userInitiated)
    private var thumbnailWork: DispatchWorkItem?
    private var thumbnailRequest = UUID()

    enum Pane: String, CaseIterable { case style = "Style", markup = "Markup" }

    struct Toast: Equatable {
        var text: String
        var symbol: String
        var id = UUID()
    }

    init(url: URL, image: CGImage) {
        source = image
        name = url.deletingPathExtension().lastPathComponent
        preview = PolishRenderer.thumbnail(image, maxSide: 2400)
        let d = PolishDoc(source: url, size: CGSize(width: image.width, height: image.height))
        doc = d
        cropDraft = d.crop
        makeThumbs()
    }

    deinit { thumbnailWork?.cancel() }

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
        guard let id = selection, let index = doc.marks.firstIndex(where: { $0.id == id }) else { return }
        history.record(doc)
        let deleted = doc.marks.remove(at: index)
        selection = nil
        if deleted.kind == .step {
            for i in index..<doc.marks.endIndex where doc.marks[i].kind == .step {
                doc.marks[i].number = max(1, doc.marks[i].number - 1)
            }
        }
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

    private var validCropDraft: CGRect? {
        guard cropDraft.hasFiniteBounds else { return nil }
        let r = cropDraft.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        // Validate before snapping so a subpixel drag can't become an applied crop.
        return r.width >= 1 && r.height >= 1 ? r.integral : nil
    }

    var cropBadgeText: String {
        guard let crop = validCropDraft else { return "Crop too small" }
        var draft = doc
        draft.crop = crop
        let size = PolishLayout(doc: draft, scale: exportScale).canvas
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    func applyCrop() {
        guard let r = validCropDraft, r != doc.crop else { return }
        edit("crop") { $0.crop = r }
        lastCoalesce = nil
    }

    private func canUseCropDraft() -> Bool {
        guard tool != .crop || validCropDraft != nil else {
            say("Crop too small — adjust or reset it", "exclamationmark.triangle")
            return false
        }
        return true
    }

    func finishCrop() {
        guard canUseCropDraft() else { return }
        tool = .select
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
    private func makeThumbs(delay: TimeInterval = 0) {
        thumbnailWork?.cancel()
        let request = UUID()
        thumbnailRequest = request
        let doc = self.doc, src = preview, list = presets
        let kx = CGFloat(src.width) / CGFloat(source.width), ky = CGFloat(src.height) / CGFloat(source.height)
        let work = DispatchWorkItem { [weak self] in
            var d = doc
            let transform = CGAffineTransform(scaleX: kx, y: ky)
            d.crop = doc.crop.applying(transform).integral
            d.marks = doc.marks.compactMap { mark in
                guard mark.kind == .redact, !mark.rect.isEmpty else { return nil }
                var scaled = mark
                let rect = mark.rect.integral.applying(transform)
                scaled.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
                return scaled
            }
            var out: [String: NSImage] = [:]
            for p in list {
                d.style = p.style
                // About 130 px across: sharp at 2× in a 66-point chip.
                let one = PolishLayout(doc: d, scale: 1).canvas
                if let img = PolishRenderer.render(d, source: src, scale: 130 / max(one.width, one.height)) {
                    out[p.name] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.thumbnailRequest == request else { return }
                self.thumbnailWork = nil
                self.thumbs = out
            }
        }
        thumbnailWork = work
        Self.thumbnailQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Out

    var exportScale: CGFloat { PolishRenderer.exportScale(for: doc.style) }

    private func png() -> Data? {
        guard !findingRedactions else { return nil }
        if tool == .crop { tool = .select }
        PolishPreset.last = doc.style
        return PolishRenderer.render(doc, source: source, scale: exportScale).flatMap(PolishRenderer.png)
    }

    private func exportWhenReady(_ action: @escaping (PolishModel, Data) -> Void) {
        let run: (PolishModel) -> Void = { model in
            // Find and Hide can finish after the draft has changed.
            guard model.canUseCropDraft() else { return }
            guard let data = model.png() else {
                model.say("Couldn't make the image", "exclamationmark.triangle")
                return
            }
            action(model, data)
        }
        if findingRedactions {
            if canUseCropDraft() { queuedExports.append(run) }
        } else { run(self) }
    }

    private func copy(closeAfter: Bool) {
        exportWhenReady { model, data in
            let pb = model.pasteboard
            pb.clearContents()
            guard pb.setData(data, forType: .png) else {
                model.say("Couldn't copy the image", "exclamationmark.triangle")
                return
            }
            model.copied = true
            model.say("Copied", "checkmark")
            if closeAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak model] in model?.close() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak model] in model?.copied = false }
        }
    }

    func copy() { copy(closeAfter: false) }
    func copyAndClose() { copy(closeAfter: true) }

    func save() {
        exportWhenReady { model, data in
            guard let url = PolishRenderer.saveURL(for: model.doc.source) else {
                model.say("Couldn't find a folder for the saved copy", "exclamationmark.triangle")
                return
            }
            do {
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                guard let path = realpath(parent.path, nil) else {
                    model.say("Couldn't find a folder for the saved copy", "exclamationmark.triangle")
                    return
                }
                defer { free(path) }
                let resolvedParent = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                guard !PolishHandoffs.contains(resolvedParent) else {
                    model.say("Couldn't find a folder for the saved copy", "exclamationmark.triangle")
                    return
                }
                try data.write(to: resolvedParent.appendingPathComponent(url.lastPathComponent), options: .withoutOverwriting)
                model.onSaved(url)
                model.say("Saved as “\(url.lastPathComponent)”", "square.and.arrow.down")
            } catch {
                model.say("Couldn't save: \(error.localizedDescription)", "exclamationmark.triangle")
            }
        }
    }

    /// Drag must produce its item immediately. The drag control is disabled during detection.
    func exportFile() -> URL? {
        guard canUseCropDraft(), !findingRedactions else { return nil }
        guard let data = png() else {
            say("Couldn't make the image", "exclamationmark.triangle")
            return nil
        }
        return handoff(data)
    }

    func share(_ show: @escaping (URL) -> Void) {
        exportWhenReady { model, data in
            if let url = model.handoff(data) { show(url) }
        }
    }

    private func handoff(_ data: Data) -> URL? {
        do {
            return try PolishHandoffs.write(data, name: PolishRenderer.polishedFilename(base: name))
        } catch {
            say("Couldn't prepare the image", "exclamationmark.triangle")
            return nil
        }
    }

    func cancelExports() { queuedExports.removeAll() }

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
        activity = .finding
        let src = source, kinds = redactKinds, faces = redactFaces, detect = detectRedactions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detected = try? detect(src, kinds, faces)
            DispatchQueue.main.async {
                guard let self else { return }
                // A failed scan must leave the existing coverage and clipboard alone.
                guard let detected else {
                    self.cancelExports()
                    self.activity = nil
                    self.say("Couldn't check the image; nothing was copied", "exclamationmark.triangle")
                    return
                }
                let crop = (self.tool == .crop ? self.validCropDraft : nil) ?? self.doc.crop
                let found = detected.filter { crop.intersects($0.1) }
                if !found.isEmpty || self.doc.marks.contains(where: \.auto) {
                    self.history.record(self.doc)
                    self.doc.marks.removeAll(where: \.auto)
                }
                for (_, r) in found {
                    var m = Mark(.redact, [r.origin, CGPoint(x: r.maxX, y: r.maxY)])
                    m.redaction = self.ink.redaction
                    m.color = RGBA(hex: 0x1C1C1E)
                    m.auto = true
                    self.doc.marks.insert(m, at: 0)
                }
                self.selection = nil
                let n = found.count
                self.say(n == 0 ? "Nothing sensitive found" : "Hid \(n) \(n == 1 ? "thing" : "things") · select one to remove it",
                         n == 0 ? "checkmark.shield" : "eye.slash")
                self.activity = nil
                let exports = self.queuedExports
                self.queuedExports.removeAll()
                for export in exports { export(self) }
            }
        }
    }

    func removeAutoRedactions() {
        guard doc.marks.contains(where: \.auto) else { return }
        history.record(doc)
        doc.marks.removeAll(where: \.auto)
    }

    func copyText() {
        guard canUseCropDraft(), busy == nil else { return }
        if tool == .crop { tool = .select }
        activity = .reading
        let src = source, doc = self.doc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PolishRenderer.render(doc, source: src)
            let text = image.map { Redactor.text(in: $0) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.activity = nil
                guard !text.isEmpty else { self.say("No text found", "text.viewfinder"); return }
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                let lines = text.split(separator: "\n").count
                self.say("Copied \(lines) \(lines == 1 ? "line" : "lines") of text", "text.viewfinder")
            }
        }
    }
}

enum PolishHandoffs {
    private static let lifetime: TimeInterval = 3600
    private static let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    private static let lock = NSLock()
    private static var closed = false
    private static let temp = FileManager.default.temporaryDirectory
    private static let rootPrefix = "ClipBubble Polish"
    static let root: URL = {
        // A second instance with its own data folder also has its own handoffs.
        let suffix = ProcessInfo.processInfo.environment["CLIPBUBBLE_HOME"].map { "-" + sha($0) } ?? ""
        return temp.appendingPathComponent(rootPrefix + suffix, isDirectory: true)
    }()
    private static let launch = root.appendingPathComponent("\(getpid())-\(UUID())", isDirectory: true)
    private static let startup: Void? = try? sweep(root, matching: canRemoveLaunch)

    static func prepare() { _ = startup }

    static func clear() {
        lock.withLock {
            closed = true
            remove(launch)
        }
    }

    static func contains(_ child: URL) -> Bool {
        func isHandoffPath(_ url: URL, under parent: URL) -> Bool {
            relativePath(of: url, in: parent)?.first?.range(of: rootPrefix, options: [.anchored, .caseInsensitive]) != nil
        }
        let resolvedTemp = temp.resolvingSymlinksInPath()
        return isHandoffPath(child, under: temp) || isHandoffPath(child, under: resolvedTemp)
            || isHandoffPath(resolvingSymlinks(child), under: resolvedTemp)
    }

    private static func relativePath(of child: URL, in parent: URL) -> ArraySlice<String>? {
        let path = child.standardizedFileURL.pathComponents
        let prefix = parent.standardizedFileURL.pathComponents
        guard path.starts(with: prefix, by: { $0.caseInsensitiveCompare($1) == .orderedSame }) else { return nil }
        return path.dropFirst(prefix.count)
    }

    // A save can create a directory below a symlink, so resolve the existing ancestor.
    private static func resolvingSymlinks(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return url }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    private static func remove(_ folder: URL) {
        // Never follow a redirect out of the handoff root or launch folder.
        guard ![root, folder.deletingLastPathComponent(), folder].contains(where: {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }) else { return }
        if let destination = PolishRenderer.saveFolder,
           relativePath(of: destination, in: folder) != nil ||
           relativePath(of: resolvingSymlinks(destination), in: folder.resolvingSymlinksInPath()) != nil { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func canRemoveLaunch(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true } // Older versions used only a UUID.
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0, String(pid) == parts[0],
              UUID(uuidString: String(parts[1])) != nil else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func sweep(_ folder: URL, matching: (String) -> Bool) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        let stale = Date().addingTimeInterval(-lifetime)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink == false, let date = values.contentModificationDate, date < stale,
                  matching(entry.lastPathComponent) else { continue }
            remove(entry)
        }
    }

    static func write(_ data: Data, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw POSIXError(.EINVAL)
        }
        return try lock.withLock {
            guard !closed else { throw POSIXError(.ECANCELED) }
            prepare()
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: permissions)
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
                throw POSIXError(.ENOTDIR)
            }
            try fm.createDirectory(at: launch, withIntermediateDirectories: true, attributes: permissions)
            try sweep(launch) { UUID(uuidString: $0) != nil }

            let folder = launch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: permissions)
            let url = folder.appendingPathComponent(name)
            do {
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try file.write(contentsOf: data)
                try file.close()
            } catch {
                remove(folder)
                throw error
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) {
                lock.withLock { remove(folder) }
            }
            return url
        }
    }
}

extension Clip {
    /// The image Polish can open: a copied image or an image file, here on this Mac.
    var polishPath: String? {
        remote ? nil : imagePath
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
        PolishHandoffs.prepare()
        let w = PolishWindow(url: url, image: img)
        open.append(w)
        w.show()
        return true
    }

    init(url: URL, image: CGImage) {
        model = PolishModel(url: url, image: image)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        canvas.model = model
        window.canvas = canvas
        window.title = "Polish — \(model.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: Optional(PolishView(model: model, canvas: canvas)))
        model.onClose = { [weak self] in self?.window.performClose(nil) }
        model.onSaved = { PolishWindow.onSaved($0) }
    }

    private func show() {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            window.minSize = NSSize(width: min(900, area.width), height: min(600, area.height))
            let width = min(area.width, 1280, max(900, (area.width * 0.7).rounded()))
            let height = min(area.height, 820, max(600, (area.height * 0.7).rounded()))
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                                   width: width, height: height), display: false)
        }
        Presence.opened(window)
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
        model.cancelExports()
        canvas.detach()
        window.makeFirstResponder(nil)
        window.canvas = nil
        // SwiftUI can keep the detached hosting view around until the next update.
        (window.contentView as? NSHostingView<PolishView?>)?.rootView = nil
        window.contentView = nil
        ColorPanelLink.shared.detach()
        PolishPreset.last = model.doc.style
        if PolishWindow.open.contains(where: { $0 === self }) {
            Presence.closed(window)
            PolishWindow.open.removeAll { $0 === self }
        }
    }
}

/// Sends tool keys to the canvas wherever focus is (except while typing), and handles the editor's shortcuts.
final class EditorWindow: NSWindow {
    weak var canvas: PolishCanvas?

    private var typing: Bool { firstResponder is NSTextView }

    override func sendEvent(_ e: NSEvent) {
        if zoomIn(with: e) { return }
        if e.type == .keyDown, !typing, let c = canvas, c.handleKey(e) { return }
        super.sendEvent(e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, let m = canvas?.model else { return super.performKeyEquivalent(with: e) }
        if zoomIn(with: e) { return true }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let text = firstResponder as? NSTextView {
            switch (mods, key) {
            case (.command, "z"): text.undoManager?.undo(); return true
            case ([.command, .shift], "z"): text.undoManager?.redo(); return true
            case (.command, "c"): text.copy(nil); return true
            case (.command, "v"): text.paste(nil); return true
            case (.command, "x"): text.cut(nil); return true
            case (.command, "a"): text.selectAll(nil); return true
            default: break
            }
        }
        switch (mods, key) {
        case (.command, "s"): m.save(); return true
        case (.command, "c"): m.copy(); return true
        case ([.command, .shift], "c"): m.copyText(); return true
        case (.command, "z"): m.undo(); return true
        case ([.command, .shift], "z"): m.redo(); return true
        case (.command, "0"): m.zoom = 1; m.pan = .zero; return true
        case (.command, "-"): m.zoom = max(0.25, m.zoom / 1.25); if m.zoom <= 1 { m.pan = .zero }; return true
        case ([.command, .shift], "r"): m.autoRedact(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    private func zoomIn(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, let model = canvas?.model else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift] else { return false }
        let key = e.charactersIgnoringModifiers
        guard e.keyCode == kVK_ANSI_Equal || e.keyCode == kVK_ANSI_KeypadPlus || key == "=" || key == "+" else { return false }
        model.zoom = min(8, model.zoom * 1.25)
        return true
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
                    ForEach(group) { t in
                        ToolButton(tool: t, on: model.tool == t) {
                            if t == .crop && model.tool == .crop { model.finishCrop() } else { model.tool = t }
                        }
                    }
                }
            }
            WindowDragArea().frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.tool == .crop {
                Button("Reset") { model.resetCrop() }.controlSize(.small)
                Button("Cancel") { model.cancelCrop() }.controlSize(.small)
                Button("Done") { model.finishCrop() }.controlSize(.small).buttonStyle(.borderedProminent)
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
            InspectorHintLabel(text: Text(sizeLine).font(.system(size: 11).monospacedDigit()))
        }
        Section(title: "Crop") {
            HStack {
                Button(model.tool == .crop ? "Done Cropping" : "Crop…") {
                    if model.tool == .crop { model.finishCrop() } else { model.tool = .crop }
                }
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
        let c = PolishLayout(doc: model.doc, scale: model.exportScale).canvas
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

enum InspectorHint: CaseIterable, View {
    case arrow, text, redact, spotlight, measure, tools, privacy

    private var message: String {
        switch self {
        case .arrow: return "Drag the middle handle to curve it."
        case .text: return "Double-click text to edit it. Return finishes, ⌥Return adds a line."
        case .redact: return "Covered pixels are replaced in the exported image, not just hidden."
        case .spotlight: return "Everything outside the box is dimmed. Draw several to spotlight more than one thing."
        case .measure: return "Shows the distance in the screenshot's own pixels. Hold Shift for straight lines."
        case .tools: return "Pick a tool above, or press its key: A for an arrow, R for a box, T for text, B to redact."
        case .privacy: return "Text is read on this Mac. Check the result: anything missed can be covered with the Redact tool."
        }
    }

    var body: some View { InspectorHintLabel(text: Text(message).font(.system(size: self == .tools ? 12 : 11))) }
}

private struct InspectorHintLabel: View {
    let text: Text
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        text.foregroundStyle(Color(white: colorScheme == .dark ? 0.78 : 0.33))
            .fixedSize(horizontal: false, vertical: true)
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
                InspectorHint.arrow
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
                InspectorHint.text
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
                InspectorHint.redact
            }
            if kind == .highlight {
                InspectorHint.spotlight
            }
            if kind == .measure {
                InspectorHint.measure
            }
            if model.selected != nil {
                Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .controlSize(.small)
            }
            Divider()
        } else {
            InspectorHint.tools
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
            InspectorHint.privacy
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
            .onDrag {
                guard let url = model.exportFile() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            .disabled(model.findingRedactions)
            .opacity(model.findingRedactions ? 0.45 : 1)
            .help(model.findingRedactions ? "Drag available after Find and Hide finishes" : "Drag the finished image anywhere")
    }
}

private struct ShareButton: NSViewRepresentable {
    @ObservedObject var model: PolishModel

    final class Coordinator: NSObject {
        weak var model: PolishModel?
        init(_ m: PolishModel) { model = m }
        @objc func share(_ b: NSButton) {
            model?.share { [weak b] url in
                guard let b, b.window?.isVisible == true else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            }
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
