import AppKit
import Carbon.HIToolbox
import SwiftUI

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

private func editorMouse(_ type: NSEvent.EventType, _ p: CGPoint, on canvas: PolishCanvas, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) {
    let event = NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.viewPoint(p), to: nil),
                                   modifierFlags: mods, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
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
    let pasteboard = NSPasteboard(name: .init("polish-exports-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    model.pasteboard = pasteboard
    let plain = PolishPreset.builtIn[0].style
    model.doc.style = plain
    var box = Mark(.redact, [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 160)])
    box.redaction = .solid
    box.color = .black
    model.doc.marks = [box]
    model.copyText()
    let ocrFinished = editorUntil { model.busy == nil }
    let copiedText = pasteboard.string(forType: .string) ?? ""
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

    let masks = model.doc.marks, undos = model.history.undos.count
    let savedCount = saves.count, clipboardChange = pasteboard.changeCount
    shared = nil
    model.detectRedactions = { _, _, _ in throw CocoaError(.fileReadUnknown) }
    model.autoRedact()
    model.copyAndClose()
    model.save()
    model.share { shared = $0 }
    check(editorUntil { model.busy == nil } && model.doc.marks == masks && model.history.undos.count == undos
          && saves.count == savedCount && pasteboard.changeCount == clipboardChange && shared == nil
          && model.toast?.text == "Couldn't check the image; nothing was copied",
          "failed Find and Hide preserves masks and cancels queued exports")

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

private func editorHandoffIsolation() throws {
    let fm = FileManager.default
    let root = PolishHandoffs.root
    func makeFolder(pid: pid_t, age: TimeInterval) throws -> URL {
        let folder = root.appendingPathComponent("\(pid)-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("handoff.png")
        try Data([1]).write(to: file)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: folder.path)
        return file
    }
    let live = try makeFolder(pid: getpid(), age: 3601)
    let young = try makeFolder(pid: Int32.max, age: 0)
    let stale = try makeFolder(pid: Int32.max, age: 3601)
    defer {
        for file in [live, young, stale] { try? fm.removeItem(at: file.deletingLastPathComponent()) }
    }
    let own = try PolishHandoffs.write(Data([2]), name: "mine.png")
    check(fm.fileExists(atPath: live.path) && fm.fileExists(atPath: young.path) && !fm.fileExists(atPath: stale.path),
          "handoff startup removes only expired files from dead processes")
    PolishHandoffs.clear()
    check(!fm.fileExists(atPath: own.path) && fm.fileExists(atPath: live.path) && fm.fileExists(atPath: young.path),
          "handoff quit clears only this launch's files")
}

private func editorCropBadgeChecks(_ dir: URL) throws {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "polish.export1x")
    defer { defaults.set(previous, forKey: "polish.export1x") }
    let url = dir.appendingPathComponent("badge.png"), source = editorImage()
    try editorPNG(source).write(to: url)
    let model = PolishModel(url: url, image: source)
    model.doc.style = PolishPreset.builtIn[0].style
    let drafts = [CGRect(x: 10.4, y: 11.6, width: 317.2, height: 109.6),
                  CGRect(x: 0.8, y: 52.3, width: 233.6, height: 121.2),
                  CGRect(x: 700.5, y: 250.5, width: 100.8, height: 80.3)]
    for retina in [true, false] {
        defaults.set(!retina, forKey: "polish.export1x")
        for draft in drafts {
            model.tool = .crop
            model.cropDraft = draft
            let badge = model.cropBadgeText
            model.tool = .select
            let png = PolishRenderer.png(model.doc, retina: retina).flatMap { NSBitmapImageRep(data: $0) }
            let expected = png.map { "\($0.pixelsWide) × \($0.pixelsHigh)" }
            check(expected == badge, "fractional crop badge matches PNG size at \(retina ? "2×" : "1×"): \(badge)")
        }
    }
}

private func editorThinCropChecks(_ model: PolishModel, _ canvas: PolishCanvas, _ window: EditorWindow) {
    let doc = model.doc, history = model.history, tool = model.tool
    defer { model.cancelCrop(); model.doc = doc; model.history = history; model.tool = tool; canvas.sync() }
    let start = CGPoint(x: 100.25, y: 100.25)
    for (w, h) in [(180.0, 0.0), (180, 0.5), (180, 6), (0, 100)] {
        if model.tool != .crop { editorKey("c", kVK_ANSI_C, in: window) }
        model.resetCrop()
        canvas.sync()
        guard let g = canvas.geometry else { check(false, "crop has a canvas layout"); return }
        let view = g.view(start)
        let end = g.source(CGPoint(x: view.x + w, y: view.y + h))
        editorMouse(.leftMouseDown, start, on: canvas)
        editorMouse(.leftMouseDragged, end, on: canvas)
        canvas.sync()
        var rects = [CGRect]()
        canvas.registerCursorRects { rect, _ in rects.append(rect) }
        let safe = !rects.isEmpty && rects.allSatisfy { !$0.isNull && !$0.isInfinite
            && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }
        check(safe, "thin crop \(w) × \(h) registers only finite cursor rects")
        if safe { canvas.resetCursorRects() }
        let draft = model.cropDraft
        editorMouse(.leftMouseUp, end, on: canvas)
        check(model.cropDraft == draft && abs(g.view(draft).width - w) < 0.01
              && abs(g.view(draft).height - h) < 0.01, "thin crop \(w) × \(h) remains visible after dragging")
        editorKey("\r", kVK_Return, in: window)
        if draft.width >= 1 && draft.height >= 1 {
            check(model.tool == .select && model.doc.crop == draft.integral, "a six-point crop applies")
            model.doc = doc
        } else {
            check(model.tool == .crop && model.doc.crop == doc.crop && model.cropBadgeText == "Crop too small",
                  "a crop below one source pixel stays a draft")
        }
    }
    let zoom = model.zoom
    model.zoom = .nan
    canvas.sync()
    check(model.zoom == 1 && canvas.geometry?.layout.scale.isFinite == true, "invalid zoom keeps the canvas layout finite")
    model.zoom = zoom
}

@MainActor private func inspectorHintChecks() {
    func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
    for (scheme, name) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
        var backdrop = NSColor.white
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            backdrop = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        let background = luminance(backdrop)
        for hint in InspectorHint.allCases {
            let renderer = ImageRenderer(content: hint.frame(width: 244, alignment: .leading).padding(4)
                .background(Color(nsColor: backdrop)).environment(\.colorScheme, scheme))
            renderer.scale = 3
            guard let image = renderer.cgImage else { check(false, "render inspector \(hint) hint"); continue }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var contrast: CGFloat = 1
            for y in 0..<image.height {
                for x in 0..<image.width {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    let foreground = luminance(color)
                    contrast = max(contrast, (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05))
                }
            }
            check(contrast >= 4.5, "inspector \(hint) hint meets 4.5:1 in \(scheme) (\(contrast))")
        }
    }
}

private func editorThumbnailChecks(_ dir: URL) {
    let model = PolishModel(url: dir.appendingPathComponent("thumbnail.png"), image: editorImage())
    func shade(_ x: Int) -> CGFloat {
        guard let data = model.thumbs["None"]?.tiffRepresentation, let rep = NSBitmapImageRep(data: data) else { return -1 }
        return rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)?.redComponent ?? -1
    }
    check(editorUntil { shade(10) > 0.95 }, "None thumbnail displays the source")
    var box = Mark(.redact, [.zero, CGPoint(x: 300, y: 320)])
    box.redaction = .solid
    box.color = .black
    model.doc.marks = [box]
    check(editorUntil { (0...0.05).contains(shade(10)) }, "adding a redaction refreshes the thumbnail")
    model.history.record(model.doc)
    model.doc.marks[0] = box.moved(by: CGSize(width: 500, height: 0))
    check(editorUntil { shade(10) > 0.95 && (0...0.05).contains(shade(115)) }, "moving the redaction refreshes the thumbnail")
    model.undo()
    check(editorUntil { (0...0.05).contains(shade(10)) }, "undo restores the thumbnail redaction")
    model.doc.marks.removeAll()
    check(editorUntil { shade(10) > 0.95 && shade(115) > 0.95 }, "deleting the redaction refreshes the thumbnail")
}

func editorZoomChecks(_ model: PolishModel, _ window: EditorWindow) {
    let prior = model.zoom
    defer { model.zoom = prior }
    let keys: [(UInt16, String, String, NSEvent.ModifierFlags)] = [
        (24, "=", "=", .command), (24, "+", "+", .command),
        (24, "=", "=", [.command, .shift]), (24, "+", "=", [.command, .shift]),
        (69, "+", "+", [.command, .numericPad])
    ]
    for (code, chars, ignored, mods) in keys {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: ignored, isARepeat: false, keyCode: code)!
        model.zoom = 1
        let handled = window.performKeyEquivalent(with: e) && model.zoom == 1.25
        model.zoom = 1
        window.sendEvent(e)
        check(handled && model.zoom == 1.25, "zoom key \(code) \(chars)\(mods.contains(.shift) ? " with Shift" : "") in both event paths")
    }
}

func editorRotationChecks(_ model: PolishModel, _ canvas: PolishCanvas) {
    let box = Mark(.rect, [CGPoint(x: 250, y: 100), CGPoint(x: 420, y: 190)])
    let r = box.rect
    model.doc.marks = [box]
    model.history = DocHistory()
    model.tool = .select
    model.selection = box.id
    canvas.sync()
    let knob = CGPoint(x: r.midX, y: r.minY - 18 / (canvas.geometry?.layout.scale ?? 1))
    func turned(_ p: CGPoint, by degrees: CGFloat) -> CGPoint {
        var rotated = box
        rotated.rotation = degrees * .pi / 180
        return p.applying(rotated.rotationTransform)
    }
    func drag(_ start: CGPoint, through points: [CGPoint], shift: Bool = false) {
        let mods: NSEvent.ModifierFlags = shift ? .shift : []
        editorMouse(.leftMouseDown, start, on: canvas, mods: mods)
        for p in points { editorMouse(.leftMouseDragged, p, on: canvas, mods: mods) }
        if let last = points.last { editorMouse(.leftMouseUp, last, on: canvas, mods: mods) }
    }
    func atAngle(_ degrees: CGFloat) -> Bool {
        abs((model.mark(box.id)?.rotation ?? -.pi) - degrees * .pi / 180) < 0.001
    }
    drag(knob, through: [10, 20, 30].map { turned(knob, by: $0) })
    check(atAngle(30) && model.history.undos.count == 1, "rotation drag reaches 30° in one undo step")
    drag(turned(knob, by: 30), through: [34, 39, 43].map { turned(knob, by: $0) }, shift: true)
    check(atAngle(45) && model.history.undos.count == 2, "Shift snaps a second rotation drag to 45°")
    let originalCorner = CGPoint(x: r.maxX, y: r.maxY)
    let larger = CGPoint(x: r.maxX + 55, y: r.maxY + 20)
    drag(turned(originalCorner, by: 45), through: [turned(larger, by: 45)])
    let resized = model.mark(box.id)
    let fixed = turned(r.origin, by: 45)
    let resizedAnchor = resized.map { $0.rect.origin.applying($0.rotationTransform) } ?? .zero
    check(atAngle(45) && abs((resized?.rect.width ?? 0) - (r.width + 55)) < 1
          && abs((resized?.rect.height ?? 0) - (r.height + 20)) < 1
          && hypot(fixed.x - resizedAnchor.x, fixed.y - resizedAnchor.y) < 1,
          "resizing a rotated box keeps its opposite corner fixed")
    model.undo()
    check(atAngle(45) && model.mark(box.id)?.rect == r, "one undo restores the rotated box size")
    model.undo()
    check(atAngle(30), "one undo restores the previous rotation")
    model.redo()
    check(atAngle(45), "redo restores the snapped rotation")

    for kind in [Mark.Kind.rect, .ellipse] {
        let center = CGPoint(x: 330, y: 150)
        let point = Mark(kind, [center, center])
        model.doc.marks = [point]
        model.selection = point.id
        canvas.sync()
        let handle = CGPoint(x: center.x, y: center.y - 18 / (canvas.geometry?.layout.scale ?? 1))
        var rotated = point
        rotated.rotation = .pi / 4
        drag(handle, through: [handle.applying(rotated.rotationTransform)])
        var rects = [CGRect]()
        canvas.registerCursorRects { rect, _ in rects.append(rect) }
        let angle = model.mark(point.id)?.rotation ?? 0
        check(abs(angle - .pi / 4) < 0.001 && rects.count > 2 && rects.allSatisfy {
            [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
        }, "a zero-size \(kind) rotates with finite handles")
        let end = CGPoint(x: center.x + 60, y: center.y + 40)
        drag(center, through: [end.applying(rotated.rotationTransform)])
        let size = model.mark(point.id)?.rect.size ?? .zero
        check(abs(size.width - 60) < 0.01 && abs(size.height - 40) < 0.01
              && model.mark(point.id)?.rotation == angle, "a rotated zero-size \(kind) resizes from its point")
    }
}

func polishEditorInteractions(_ model: PolishModel, _ canvas: PolishCanvas, _ window: EditorWindow) {
    func click(_ x: CGFloat, _ y: CGFloat, count: Int = 1) {
        let p = CGPoint(x: x, y: y)
        editorMouse(.leftMouseDown, p, on: canvas, clicks: count)
        editorMouse(.leftMouseUp, p, on: canvas, clicks: count)
    }
    let oldDoc = model.doc, oldHistory = model.history, oldTool = model.tool, oldSelection = model.selection
    defer { model.tool = oldTool; model.doc = oldDoc; model.history = oldHistory; model.selection = oldSelection; canvas.sync() }

    let mask = Mark(.redact, [CGPoint(x: 80, y: 80), CGPoint(x: 180, y: 180)])
    let line = Mark(.line, [CGPoint(x: 90, y: 130), CGPoint(x: 170, y: 130)])
    model.doc.marks = [mask, line]
    model.tool = .select
    model.selection = nil
    click(130, 130)
    check(model.selection == mask.id, "click selects the redaction over a hidden later annotation")

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
    editorRotationChecks(model, canvas)
    editorZoomChecks(model, window)
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
        let controller = PolishWindow(url: url, image: editorImage())
        let editor = controller.window, canvas = controller.canvas, activeModel = controller.model
        let screens = NSScreen.screens.map(\.frame)
        editor.setFrameOrigin(NSPoint(x: (screens.map(\.maxX).max() ?? 0) + 4000, y: 0))
        editor.contentView?.layoutSubtreeIfNeeded()
        editor.makeFirstResponder(canvas)
        check(!editor.isVisible && !editor.isKeyWindow && !NSApp.isActive && !screens.contains { $0.intersects(editor.frame) },
              "interaction tests keep the editor offscreen and unfocused")
        window = editor
        model = activeModel
        editorPump(0.3)
        editorThinCropChecks(activeModel, canvas, editor)
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
    app.putOnClipboard = { _ in nil }
    app.shotCard.state.copy()
    check(app.shotCard.state.copyLabel == "Copy failed", "the screenshot card reports a failed copy")
    app.putOnClipboard = { _ in 1 }
    app.shotCard.state.copy()
    check(app.shotCard.state.copyLabel == "Copied", "the screenshot card confirms a successful retry")

    let saved = dir.appendingPathComponent("editor output polished.png")
    try editorPNG(editorImage()).write(to: saved)
    PolishWindow.onSaved(saved)
    let hops = app.model.pulseTicks
    app.putOnClipboard = { _ in check(false, "watcher never copies an editor-saved file"); return nil }
    app.screenshotAdded(saved, at: Date())
    editorPump(0.15)
    check(app.model.db.clip(hash: "f:" + sha(saved.path))?.source == "Polished" && app.model.pulseTicks == hops,
          "the screenshot watcher skips an unchanged editor-saved file")

    let backlog = dir.appendingPathComponent("backfilled capture.png")
    try editorPNG(editorImage()).write(to: backlog)
    let alias = dir.appendingPathComponent("backfilled editor alias.png")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: saved)
    let lock = NSLock()
    var lookups: [Bool] = []
    let resolve = app.polishedFileAt
    app.polishedFileAt = { url in
        lock.withLock { lookups.append(Thread.isMainThread) }
        return resolve(url)
    }
    app.importFiles([(backlog, Date()), (alias, Date())], source: "Screenshot")
    let backlogHash = "f:" + sha(backlog.path)
    check(editorUntil { app.model.db.clip(hash: backlogHash)?.source == "Screenshot" }
          && app.model.db.clip(hash: "f:" + sha(alias.path)) == nil
          && lock.withLock { lookups == [false, false] },
          "screenshot backfill resolves files off main and skips editor aliases")
    app.polishedFileAt = resolve

    try editorPNG(editorImage(.blue)).write(to: saved, options: .atomic)
    var replacementCopied = false
    app.putOnClipboard = { c in replacementCopied = c.text == saved.path; return 1 }
    app.screenshotAdded(saved, at: Date())
    check(editorUntil { replacementCopied && app.model.db.clip(hash: "f:" + sha(saved.path))?.source == "Screenshot" }
          && app.shotCard.state.url == saved, "a replacement screenshot at an editor-saved path is accepted")

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
        try editorHandoffIsolation()
        try editorExports(dir)
        try editorCropBadgeChecks(dir)
        MainActor.assumeIsolated { inspectorHintChecks() }
        editorThumbnailChecks(dir)
        editorPreviewCheck(dir)
        editorBaseKeyChecks(dir)
        try editorWindowChecks(dir)
        try editorCardChecks(dir)
    } catch { check(false, "editor fixtures: \(error)") }
}
