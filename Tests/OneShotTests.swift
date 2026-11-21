import AppKit

func oneShotTests() {
    do { try checkOneShot() }
    catch { check(false, "one-shot setup failed: \(error)") }
}

private func checkOneShot() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let keys = ["hideBubble", "polishCard", "copyScreenshots", "screenshotFolder", "polish.folder",
                "polish.last", "polish.export1x", "save.images", "save.screenshots"]
    let old = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, old) { defaults.set(value, forKey: key) } }
    defaults.set(true, forKey: "hideBubble")
    defaults.set(true, forKey: "polishCard")
    defaults.set(false, forKey: "copyScreenshots")
    Prefs.set("images", true)
    Prefs.set("screenshots", true)

    let folder = Paths.dir.appendingPathComponent("one-shot-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defaults.set(folder.path, forKey: "screenshotFolder")
    defaults.set(folder.path, forKey: "polish.folder")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("original.png")
    let context = CGContext(data: nil, width: 2481, height: 901, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.23, blue: 0.38, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2481, height: 901))
    context.setFillColor(CGColor(red: 0.28, green: 0.91, blue: 0.62, alpha: 1))
    context.fill(CGRect(x: 31, y: 83, width: 457, height: 37))
    try PolishRenderer.png(context.makeImage()!)!.write(to: source)
    let clipHash = "f:" + sha(source.path)

    let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    let app = AppDelegate()
    let x = (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 4000
    let area = NSRect(x: x, y: 0, width: 1400, height: 900)
    app.displays = { [Display(id: 1001, frame: area, visible: area)] }
    app.pointer = { CGPoint(x: area.midX, y: area.midY) }
    app.model.db.insertIfMissing(kind: "file", text: source.path, source: "Screenshot", hash: clipHash, created: Date())
    app.setUpWindows(keyable: false)
    let windows = NSApp.windows.filter { !priorWindows.contains(ObjectIdentifier($0)) }
    let board = NSPasteboard(name: .init("polish-one-shot-" + UUID().uuidString))
    let editorBoard = NSPasteboard(name: .init("polish-one-shot-editor-" + UUID().uuidString))
    defer {
        app.shotCard.hide(animated: false)
        windows.forEach { $0.orderOut(nil) }
        board.releaseGlobally()
        editorBoard.releaseGlobally()
    }
    guard let clip = app.model.db.clip(hash: clipHash), let image = PolishRenderer.load(source),
          let panel = windows.first(where: { $0.frame.width == 420 }) else {
        check(false, "one-shot source and panel are ready")
        return
    }
    let editor = PolishModel(url: source, image: image)
    editor.pasteboard = editorBoard
    func editorPNG(style: PolishStyle) -> Data? {
        editor.doc.style = style
        editor.copy()
        return editorBoard.data(forType: .png)
    }

    var writes = 0
    app.putPolishedOnClipboard = { data in
        writes += 1
        return Board.writePNG(data, to: board, polished: true)
    }
    app.putOnClipboard = { _ in check(false, "one-shot must not copy the original file"); return nil }
    var captures = 0
    let capture = Capture(board: board) { [weak app] copied in
        DispatchQueue.main.async {
            if copied { captures += 1 }
            app?.clipboardChanged(copied: copied)
        }
    }
    defer { withExtendedLifetime(capture) {} }

    let startingStyle = PolishStyle(background: .solid(RGBA(hex: 0xFBAA6E)), padding: 0.19, radius: 0.05, frame: .dark)
    defaults.set(true, forKey: "polish.export1x")
    let expected = editorPNG(style: startingStyle)
    check(expected != nil, "editor can export the reference PNG")
    app.toggle()
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
    app.model.polish(clip)
    app.model.polish(clip)
    check(app.model.polishStatus(for: clip) == .rendering && writes == 0, "one-shot reports rendering before writing")
    check(waitForOneShot { app.model.polishStatus(for: clip) == .copied }, "one-shot reports success")
    check(writes == 1, "double click makes a single clipboard write")
    check(board.data(forType: .png) == expected, "one-shot PNG matches the editor's full-resolution source, starting style and export scale")
    check(app.model.polishToast?.source == source && app.model.polishToast?.thumbnail != nil,
          "the toast keeps the original URL and a preview")
    check(panel.isVisible && Set(NSApp.windows.map(ObjectIdentifier.init)) == before, "one-shot leaves the panel open and opens no window")
    app.toggle()
    if let expected {
        let hash = "i:" + sha(expected)
        check(waitForOneShot { captures == 1 && app.model.db.clip(hash: hash)?.source == "Polished" },
              "clipboard capture records the PNG once and labels it Polished")
        check(app.model.db.clips(kind: "image").filter { $0.hash == hash }.count == 1 && !app.shotCard.isVisible,
              "the captured PNG has one history entry and doesn't trigger a screenshot card")
    }

    let missing = Clip(id: -1, kind: "file", text: folder.appendingPathComponent("missing.png").path,
                       file: nil, source: "Screenshot", created: Date())
    let count = board.changeCount
    app.model.polish(missing)
    check(waitForOneShot { app.model.polishStatus(for: missing) == .failed }, "a missing source reports failure")
    check(writes == 1 && board.changeCount == count && app.model.polishToast?.thumbnail == nil,
          "a failed one-shot leaves the clipboard alone")
    check(!app.shotCard.isVisible, "a failed one-shot doesn't show the card")

    defaults.set(false, forKey: "polish.export1x")
    let gradient = editorPNG(style: PolishPreset.gradient.style)
    PolishPreset.last = PolishPreset.builtIn[0].style
    check(PolishPreset.last.isPlain, "the starting style can be set to None")
    app.screenshotAdded(source, at: Date())
    check(app.shotCard.isVisible, "a new screenshot still shows its card")
    app.shotCard.state.polish()
    app.shotCard.state.polish()
    check(app.shotCard.state.polishStatus == .rendering, "the card shows its render state")
    check(waitForOneShot { app.shotCard.state.polishStatus == .copied }, "the card confirms the copy")
    check(writes == 2, "the card ignores repeat clicks")
    check(matchesGradient(board.data(forType: .png), gradient), "the card uses Gradient for a plain style")
    check(app.shotCard.isVisible && app.shotCard.state.url == source && app.shotCard.state.polishedThumbnail != nil,
          "the card keeps the original URL and displays the polished thumbnail")
    check(Set(NSApp.windows.map(ObjectIdentifier.init)) == before, "the card's Polish action opens no window")
    app.shotCard.hide(animated: false)

    defaults.removeObject(forKey: "polish.last")
    app.model.polish(clip)
    check(waitForOneShot { writes == 3 }, "a missing starting preference still copies")
    check(matchesGradient(board.data(forType: .png), gradient), "a missing starting preference uses the built-in Gradient")
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    check(files == [source.lastPathComponent],
          "one-shot leaves the screenshot and editor output folders untouched")
}

private func matchesGradient(_ actual: Data?, _ expected: Data?) -> Bool {
    guard let actual, let expected, let result = NSBitmapImageRep(data: actual),
          let reference = NSBitmapImageRep(data: expected) else { return false }
    let width = reference.pixelsWide, height = reference.pixelsHigh
    guard result.pixelsWide == width, result.pixelsHigh == height else { return false }
    // Core Graphics can vary the shadow between exports. Sample the gradient and original away from it.
    return [(0, 0), (width - 1, height - 1), (width / 2, height / 2)].allSatisfy { x, y in
        result.colorAt(x: x, y: y) == reference.colorAt(x: x, y: y)
    }
}

private func waitForOneShot(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}
