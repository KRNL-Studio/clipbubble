import AppKit
import Carbon.HIToolbox

private func editorPump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func editorUntil(_ seconds: TimeInterval = 4, _ test: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !test() && Date() < deadline { editorPump(0.02) }
    return test()
}

private func editorKey(_ key: String, _ code: Int, in window: EditorWindow, mods: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: key,
                                 charactersIgnoringModifiers: key.lowercased(), isARepeat: false, keyCode: UInt16(code))!
    if !mods.contains(.command) || !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
}

private func editorMouse(_ type: NSEvent.EventType, _ p: CGPoint, on canvas: PolishCanvas, clicks: Int = 1) {
    let event = NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.viewPoint(p), to: nil),
                                   modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                                   context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    switch type {
    case .leftMouseDown: canvas.mouseDown(with: event)
    case .leftMouseDragged: canvas.mouseDragged(with: event)
    default: canvas.mouseUp(with: event)
    }
}

private func editorImage(_ color: NSColor = .white, text: Bool = false) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 320, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: 800, height: 320).fill()
    if text {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        ("hidden@example.com" as NSString).draw(at: NSPoint(x: 50, y: 204), withAttributes: attributes)
        ("Visible heading" as NSString).draw(at: NSPoint(x: 50, y: 44), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

private func editorPNG(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

private func editorExports(_ dir: URL) throws {
    let defaults = UserDefaults.standard
    let oneX = defaults.object(forKey: "polish.export1x"), folder = defaults.object(forKey: "polish.folder")
    defaults.set(false, forKey: "polish.export1x")
    defaults.set(dir.path, forKey: "polish.folder")
    defer {
        defaults.set(oneX, forKey: "polish.export1x")
        defaults.set(folder, forKey: "polish.folder")
    }
    let url = dir.appendingPathComponent("editor-\(UUID()).png")
    let src = editorImage(text: true)
    try editorPNG(src).write(to: url)
    let model = PolishModel(url: url, image: src)
    let plain = PolishPreset.builtIn[0].style
    model.doc.style = plain
    var box = Mark(.redact, [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 160)])
    box.redaction = .solid
    box.color = .black
    model.doc.marks = [box]
    model.copyText()
    let ocrFinished = editorUntil { model.busy == nil }
    let copiedText = NSPasteboard.general.string(forType: .string) ?? ""
    check(ocrFinished && copiedText.contains("Visible heading") && !copiedText.contains("hidden@example.com"),
          "Copy Text reads only the visible line")
    model.doc.marks = []

    var saves: [URL] = []
    model.onSaved = { saves.append($0) }
    model.redactKinds = [.email]
    var ink = model.ink
    ink.redaction = .solid
    let oldInk = model.ink
    model.ink = ink
    defer { model.ink = oldInk }
    let pasteboard = NSPasteboard.general
    let beforeCopy = pasteboard.changeCount
    var shared: URL?
    model.autoRedact()
    model.tool = .crop
    model.cropDraft = CGRect(x: 10, y: 10, width: 780, height: 300)
    model.save()
    model.copy()
    model.share { shared = $0 }
    check(saves.isEmpty, "Save waits for Find and Hide")
    check(pasteboard.changeCount == beforeCopy, "Copy waits for Find and Hide")
    check(shared == nil, "Share waits for Find and Hide")
    check(model.exportFile() == nil, "a file handoff waits for Find and Hide")
    check(editorUntil { model.busy == nil && !saves.isEmpty && shared != nil }, "queued Save and Share complete")
    if let saved = saves.last, let image = PolishRenderer.load(saved) {
        check(model.doc.marks.contains(where: \.auto)
              && !Redactor.text(in: image).contains("hidden@example.com"), "queued Save includes the detected redaction")
    } else { check(false, "queued Save includes the detected redaction") }
    let copied = pasteboard.data(forType: .png)
    let shareData = shared.flatMap { try? Data(contentsOf: $0) }
    check(copied != nil && copied == shareData && copied == saves.last.flatMap { try? Data(contentsOf: $0) },
          "queued Copy and Share export the same redacted PNG as Save")
    check(model.tool == .select && model.doc.crop.size == CGSize(width: 780, height: 300)
          && copied.flatMap { NSBitmapImageRep(data: $0)?.pixelsWide } == 780,
          "queued exports apply the draft crop")

    model.tool = .crop
    model.cropDraft = CGRect(x: 40, y: 185, width: 240, height: 90)
    let first = model.exportFile()
    let exported = first.flatMap(PolishRenderer.load)
    check(model.tool == .select && exported?.width == 240 && exported?.height == 90, "a handoff applies the draft crop")
    let second = model.exportFile()
    check(first != nil && second != nil && first != second, "each handoff has a unique URL")
    let modes = [first, second].compactMap { $0 }.compactMap {
        (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.posixPermissions] as? Int
    }
    check(modes == [0o600, 0o600], "handoff files are created with mode 0600")
    if let first, let second {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3601)],
                                              ofItemAtPath: first.deletingLastPathComponent().path)
        check(model.exportFile() != nil && !FileManager.default.fileExists(atPath: first.path)
              && FileManager.default.fileExists(atPath: second.path), "handoffs older than an hour are removed")
        AppDelegate().applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        check(!FileManager.default.fileExists(atPath: second.path), "app quit removes the remaining handoffs")
    }

    model.doc.crop = CGRect(x: 0, y: 0, width: 800, height: 320)
    model.doc.marks = []
    try editorPNG(editorImage(.blue)).write(to: url)
    let png = model.exportFile().flatMap(PolishRenderer.load).map { NSBitmapImageRep(cgImage: $0) }
    check(png?.colorAt(x: 4, y: 4)?.redComponent ?? 0 > 0.9, "export keeps the source shown in the editor after replacement")
    try FileManager.default.removeItem(at: url)
    check(model.exportFile() != nil, "export still works after source deletion")
    var closed = false
    model.onClose = { closed = true }
    let change = pasteboard.changeCount
    model.copyAndClose()
    check(editorUntil { closed } && pasteboard.changeCount != change && pasteboard.data(forType: .png) != nil,
          "Return copies the retained source and closes after success")
    closed = false
    model.doc.crop = .zero
    model.copyAndClose()
    editorPump(0.35)
    check(!closed, "Return keeps the editor open when Copy fails")
}

func polishEditorInteractions(_ model: PolishModel, _ canvas: PolishCanvas, _ window: EditorWindow) {
    func click(_ x: CGFloat, _ y: CGFloat, count: Int = 1) {
        let p = CGPoint(x: x, y: y)
        editorMouse(.leftMouseDown, p, on: canvas, clicks: count)
        editorMouse(.leftMouseUp, p, on: canvas, clicks: count)
    }
    let oldDoc = model.doc, oldHistory = model.history, oldTool = model.tool, oldSelection = model.selection
    defer { model.tool = oldTool; model.doc = oldDoc; model.history = oldHistory; model.selection = oldSelection; canvas.sync() }

    model.doc.marks = []
    model.tool = .rect
    model.history = DocHistory()
    var box = Mark(.rect, [CGPoint(x: 280, y: 60), CGPoint(x: 440, y: 200)])
    model.history.record(model.doc)
    model.doc.marks.append(box)
    model.undo()
    click(120, 150)
    check(model.history.canRedo && model.doc.marks.isEmpty, "an empty drawing click preserves redo")
    model.doc.marks = [box]
    model.selection = box.id
    editorMouse(.leftMouseDown, CGPoint(x: 440, y: 200), on: canvas)
    for x in [380.0, 300, 260, 240, 220, 200] { editorMouse(.leftMouseDragged, CGPoint(x: x, y: 200), on: canvas) }
    editorMouse(.leftMouseUp, CGPoint(x: 200, y: 200), on: canvas)
    let rect = model.mark(box.id)?.rect ?? .zero
    check(abs(rect.maxX - 280) < 1 && abs(rect.width - 80) < 1, "resizing across the opposite edge keeps the anchor")

    box = Mark(.line, [.zero, CGPoint(x: 100, y: 100)])
    let steps = (7...9).map { n -> Mark in var s = Mark(.step, [.zero]); s.number = n; return s }
    model.doc.marks = steps + [box]
    model.selection = box.id
    model.deleteSelection()
    check(model.doc.marks.map(\.number) == [7, 8, 9], "deleting a line preserves custom step numbers")
    model.selection = steps[1].id
    model.deleteSelection()
    check(model.doc.marks.map(\.number) == [7, 8], "deleting a step renumbers only later steps")

    model.doc.marks = []
    model.history = DocHistory()
    model.tool = .text
    click(500, 145)
    let tv = window.firstResponder as? NSTextView
    tv?.insertText("Draft", replacementRange: tv?.selectedRange() ?? NSRange())
    editorKey("\u{1B}", kVK_Escape, in: window)
    check(!canvas.isEditingText && model.doc.marks.isEmpty && !model.history.canUndo, "Escape discards new text and its undo record")

    click(500, 145)
    let existing = window.firstResponder as? NSTextView
    existing?.insertText("Original", replacementRange: existing?.selectedRange() ?? NSRange())
    existing?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let count = model.history.undos.count
    click(505, 145)
    let editing = window.firstResponder as? NSTextView
    editing?.insertText("Replacement", replacementRange: editing?.selectedRange() ?? NSRange())
    editorKey("\u{1B}", kVK_Escape, in: window)
    check(editing != nil && !canvas.isEditingText && model.doc.marks.last?.text == "Original"
          && model.history.undos.count == count, "Escape restores existing text and its history")

    click(530, 250)
    let typing = window.firstResponder as? NSTextView
    typing?.insertText("Retype", replacementRange: typing?.selectedRange() ?? NSRange())
    editorKey("z", kVK_ANSI_Z, in: window, mods: .command)
    let undone = typing?.string == ""
    editorKey("Z", kVK_ANSI_Z, in: window, mods: [.command, .shift])
    check(typing != nil && undone && typing?.string == "Retype" && canvas.isEditingText, "Shift-Command-Z redoes typing in the text view")
    canvas.endTextEdit(commit: false)
}

private func editorPreviewCheck(_ dir: URL) {
    let model = PolishModel(url: dir.appendingPathComponent("preview.png"), image: editorImage())
    // Drive sync ourselves so a SwiftUI update can't hide a stale completion by requesting another render.
    let canvas = PolishCanvas(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
    canvas.model = model
    defer { canvas.detach() }
    model.doc.style = PolishStyle(background: .solid(RGBA(1, 0, 0)), padding: 0.16, radius: 0, shadow: 0)
    canvas.sync()
    func corner() -> NSColor? {
        guard let rect = canvas.geometry?.canvasRect,
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -rect.minX - 4, y: -rect.midY)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        canvas.draw(canvas.bounds)
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: 0, y: 0) }
    }
    check(editorUntil { (corner()?.redComponent ?? 0) > 0.9 && (corner()?.blueComponent ?? 1) < 0.1 }, "the initial red preview is visible")
    model.history.record(model.doc)
    model.doc.style.background = .solid(RGBA(0, 0, 1))
    canvas.sync()
    model.undo()
    canvas.sync()
    editorPump(0.7)
    check((corner()?.redComponent ?? 0) > 0.9 && (corner()?.blueComponent ?? 1) < 0.1, "undo keeps the red preview when a blue render was pending")
}

private func editorBaseKeyChecks(_ dir: URL) {
    let source = editorImage()
    var doc = PolishDoc(source: dir.appendingPathComponent("padding.png"), size: CGSize(width: source.width, height: source.height))
    doc.style.background = .blurred
    func key() -> PolishCanvas.BaseKey { PolishCanvas.BaseKey(doc: doc, source: source, scale: 1) }

    let bare = key()
    doc.marks = [Mark(.redact, [CGPoint(x: 40, y: 40), CGPoint(x: 80, y: 80)])]
    let added = key()
    doc.marks[0] = doc.marks[0].moved(by: CGSize(width: 25, height: 0))
    let moved = key()
    check(moved != added, "moving a redaction changes the blurred preview key")
    doc.marks[0].redaction = .solid
    let solid = key()
    check(solid != moved, "changing the redaction mode changes the blurred preview key")
    doc.marks[0].color = .white
    check(key() != solid, "recoloring a solid redaction changes the blurred preview key")

    let redaction = doc.marks.removeFirst()
    doc.marks.append(Mark(.arrow, [.zero, CGPoint(x: 90, y: 90)]))
    check(added != bare && key() == bare, "adding and deleting a redaction change the blurred preview key")

    doc.style.background = .gradient(0)
    let gradient = key()
    doc.marks.append(redaction)
    doc.marks[1] = redaction.moved(by: CGSize(width: 25, height: 0))
    check(key() == gradient, "redactions do not affect the gradient preview key")
}

private func editorWindowChecks(_ dir: URL) throws {
    let url = dir.appendingPathComponent("window.png")
    try editorPNG(editorImage()).write(to: url)
    var window: EditorWindow?
    weak var model: PolishModel?
    autoreleasepool {
        check(PolishWindow.open(url), "open an editor for interaction tests")
        guard let editor = NSApp.windows.first(where: { $0 is EditorWindow && $0.isVisible }) as? EditorWindow,
              let canvas = editor.canvas, let activeModel = canvas.model else {
            check(false, "find the visible editor canvas and model")
            return
        }
        window = editor
        model = activeModel
        editorPump(0.3)
        polishEditorInteractions(activeModel, canvas, editor)
        activeModel.doc.style.background = .solid(RGBA(0, 1, 0))
        canvas.sync()
        editor.close()
    }
    withExtendedLifetime(window) {
        check(editorUntil { model == nil }, "closing the editor releases its model while AppKit retains the window")
    }
}

private func editorCardChecks(_ dir: URL) throws {
    let defaults = UserDefaults.standard
    let keys = ["hideBubble", "copyScreenshots", "polishCard", "cornerDisplay"]
    let old = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, old) { defaults.set(value, forKey: key) } }
    defaults.set(true, forKey: "hideBubble")
    defaults.set(true, forKey: "polishCard")
    defaults.set(true, forKey: "copyScreenshots")
    defaults.set(801, forKey: "cornerDisplay")
    let x = (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 4000
    let first = NSRect(x: x, y: 0, width: 1300, height: 900)
    let second = first.offsetBy(dx: 1400, dy: 0)
    let app = AppDelegate()
    app.displays = { [Display(id: 801, frame: first, visible: first), Display(id: 802, frame: second, visible: second)] }
    var pointer = CGPoint(x: second.midX, y: second.midY)
    app.pointer = { pointer }
    let prior = Set(NSApp.windows.map(ObjectIdentifier.init))
    app.setUpWindows(keyable: false)
    let windows = NSApp.windows.filter { !prior.contains(ObjectIdentifier($0)) }
    defer { app.shotCard.hide(); windows.forEach { $0.orderOut(nil) }; editorPump(0.3) }
    guard let bubble = windows.first(where: { $0.contentView is BubbleView }) else { check(false, "find the bubble"); return }

    let url = dir.appendingPathComponent("capture.png")
    try editorPNG(editorImage()).write(to: url)
    app.putOnClipboard = { [weak app] _ in
        DispatchQueue.main.async { app?.clipboardChanged(copied: true) }
        return 1
    }
    app.screenshotAdded(url, at: Date())
    editorPump(0.45)
    check(second.contains(bubble.frame) && (second.contains(app.shotCard.frame) || !app.shotCard.isVisible),
          "the screenshot card follows the hidden bubble to the capture display")
    check(app.shotCard.isVisible, "the screenshot card appears on the capture display")
    let other = first.contains(app.shotCard.frame) ? second : first
    pointer = CGPoint(x: other.midX, y: other.midY)
    bubble.orderOut(nil)
    app.reveal()
    editorPump(0.35)
    check(other.contains(bubble.frame) && (!app.shotCard.isVisible || other.contains(app.shotCard.frame)),
          "a visible card follows the bubble when it reappears on another display")

    let named = dir.appendingPathComponent("real screenshot polished.png")
    try editorPNG(editorImage()).write(to: named)
    app.screenshotAdded(named, at: Date())
    editorPump(0.3)
    check(app.model.db.clip(hash: "f:" + sha(named.path))?.source == "Screenshot" && app.shotCard.isVisible,
          "a real screenshot named polished enters history and shows a card")
    let saved = dir.appendingPathComponent("editor output polished.png")
    PolishWindow.onSaved(saved)
    let hops = app.model.pulseTicks
    app.putOnClipboard = { _ in check(false, "watcher never copies an editor-saved file"); return nil }
    app.screenshotAdded(saved, at: Date())
    check(app.model.db.clip(hash: "f:" + sha(saved.path))?.source == "Polished" && app.model.pulseTicks == hops,
          "the screenshot watcher skips an editor-saved path")

    app.toggleBubble()
    check(editorUntil(0.75) { !bubble.isVisible && !app.shotCard.isVisible }, "the hide-bubble shortcut hides the card and bubble together")
}

func polishEditorTests() {
    let dir = testHome.appendingPathComponent("editor")
    let defaults = UserDefaults.standard
    let last = defaults.object(forKey: "polish.last")
    defer { defaults.set(last, forKey: "polish.last"); PolishHandoffs.clear() }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try editorExports(dir)
        editorPreviewCheck(dir)
        editorBaseKeyChecks(dir)
        try editorWindowChecks(dir)
        try editorCardChecks(dir)
    } catch { check(false, "editor fixtures: \(error)") }
}
