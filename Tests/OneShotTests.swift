import AppKit
import UniformTypeIdentifiers

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
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
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
        PolishHandoffs.clear()
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
    check(draggedFile(app.shotCard.state.dragItem()) == source, "the card drags the original file before polishing")
    check(app.shotCard.state.copyLabel == "Copy", "the card labels its Copy button before polishing")
    app.shotCard.state.polish()
    app.shotCard.state.polish()
    check(app.shotCard.state.polishStatus == .rendering, "the card shows its render state")
    app.shotCard.state.copyFeedback = .copied
    check(waitForOneShot { app.shotCard.state.polishStatus == .copied }, "the card confirms the copy")
    check(writes == 2, "the card ignores repeat clicks")
    check(matchesGradient(board.data(forType: .png), gradient), "the card uses Gradient for a plain style")
    check(app.shotCard.isVisible && app.shotCard.state.url == source && app.shotCard.state.polishedThumbnail != nil,
          "the card keeps the original URL and displays the polished thumbnail")
    check(Set(NSApp.windows.map(ObjectIdentifier.init)) == before, "the card's Polish action opens no window")
    check(app.shotCard.state.copyLabel == "Copy original", "the card distinguishes Copy original after polishing")
    let polishedItem = app.shotCard.state.dragItem()
    let secondItem = app.shotCard.state.dragItem()
    let output = app.shotCard.state.polished
    let polishedPNG = board.data(forType: .png)
    func dragFileCount() -> Int {
        let paths = (try? fm.subpathsOfDirectory(atPath: PolishHandoffs.root.path)) ?? []
        return paths.filter { $0.hasSuffix("/original polished.png") }.count
    }
    check(dragFileCount() == 0, "starting two drags creates no handoffs")
    check(draggedPNG(polishedItem) == polishedPNG && dragFileCount() == 0,
          "the in-memory PNG loads without writing a handoff")

    let copyPolished = app.putPolishedOnClipboard
    app.putPolishedOnClipboard = { _ in false }
    app.shotCard.state.polish()
    check(waitForOneShot { app.shotCard.state.polishStatus == .failed }, "the card reports a failed retry")
    check(draggedFile(app.shotCard.state.dragItem()) == source, "the card drags the original file after polishing fails")
    check(app.shotCard.state.polishedThumbnail == nil && app.shotCard.state.copyLabel == "Copy",
          "a failed retry restores the original thumbnail and Copy label")
    app.shotCard.hide(animated: false)
    app.putPolishedOnClipboard = copyPolished

    check(draggedPNG(polishedItem, asFile: true) == polishedPNG && dragFileCount() == 1,
          "the PNG file representation writes a handoff lazily after the card closes")
    let polishedFile = draggedFile(polishedItem)
    check(polishedFile != source && polishedFile?.pathExtension == "png" &&
          polishedFile.flatMap { try? Data(contentsOf: $0) } == polishedPNG,
          "a URL-only receiver gets the full polished PNG")
    check(polishedFile != nil && draggedFile(secondItem) == polishedFile && dragFileCount() == 1,
          "two drags of one polish result share one handoff file")

    let failedDrag = ShotCardState()
    failedDrag.url = folder.appendingPathComponent(String(repeating: "x", count: 250) + ".png")
    failedDrag.polished = output
    let failedItem = failedDrag.dragItem()
    check(draggedFile(failedItem) == nil && draggedPNG(failedItem) == polishedPNG,
          "the in-memory PNG still loads when the handoff filename is too long to write")

    defaults.removeObject(forKey: "polish.last")
    app.model.polish(clip)
    check(waitForOneShot { writes == 3 }, "a missing starting preference still copies")
    check(matchesGradient(board.data(forType: .png), gradient), "a missing starting preference uses the built-in Gradient")
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    check(files == [source.lastPathComponent],
          "one-shot leaves the screenshot and editor output folders untouched")

    guard let polishedFile, let polishedImage = PolishRenderer.load(polishedFile) else {
        check(false, "the polished drag file is available to edit and save")
        return
    }
    defaults.removeObject(forKey: "polish.folder")
    let handoffEditor = PolishWindow(url: polishedFile, image: polishedImage)
    defer { handoffEditor.window.close() }
    guard let saved = PolishRenderer.saveURL(for: polishedFile) else {
        check(false, "a handoff original has a save location")
        return
    }
    handoffEditor.model.save()
    check(PolishRenderer.load(saved) != nil && app.model.db.clip(hash: "f:" + sha(saved.path))?.source == "Polished",
          "Save writes the handoff original's edited copy and records it in history as Polished")
    check(saved.deletingLastPathComponent().path == FolderWatcher.screenshotFolder.path,
          "Save puts the handoff original's edited copy in the watched screenshot folder")

    let otherRoot = fm.temporaryDirectory.appendingPathComponent("ClipBubble Polish-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: otherRoot, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: otherRoot) }
    let otherOriginal = otherRoot.appendingPathComponent(source.lastPathComponent)
    try fm.copyItem(at: source, to: otherOriginal)
    check(PolishHandoffs.contains(otherRoot) && PolishRenderer.saveURL(for: otherOriginal)?.deletingLastPathComponent().path == folder.path,
          "an original in another instance's handoff root uses the watched screenshot folder")
    defaults.set(otherRoot.appendingPathComponent("exports").path, forKey: "polish.folder")
    check(PolishRenderer.saveURL(for: source)?.deletingLastPathComponent().path == folder.path,
          "a custom destination in another instance's handoff root uses the watched screenshot folder")
    defaults.removeObject(forKey: "polish.folder")

    let alias = folder.appendingPathComponent("drag alias.png")
    try fm.createSymbolicLink(at: alias, withDestinationURL: polishedFile)
    check(PolishRenderer.saveURL(for: alias)?.deletingLastPathComponent().path == folder.path,
          "a symlink to a handoff original uses the watched screenshot folder")
    let handoffAlias = folder.appendingPathComponent("handoff alias", isDirectory: true)
    try fm.createSymbolicLink(at: handoffAlias, withDestinationURL: polishedFile.deletingLastPathComponent())
    let custom = folder.appendingPathComponent("Polish exports", isDirectory: true)
    defaults.set(custom.path, forKey: "polish.folder")
    check(PolishRenderer.saveURL(for: polishedFile)?.deletingLastPathComponent().path == custom.path,
          "a handoff original honors a custom destination outside the handoff root")
    defaults.set(handoffAlias.appendingPathComponent("missing").path, forKey: "polish.folder")
    check(PolishRenderer.saveURL(for: polishedFile)?.deletingLastPathComponent().path == folder.path,
          "a custom destination below a symlink into a handoff uses the watched folder")
    defaults.removeObject(forKey: "polish.folder")
    let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    let readOnly = folder.appendingPathComponent("read-only", isDirectory: true)
    try fm.createDirectory(at: readOnly, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
    let storedImage = Paths.images.appendingPathComponent("clipboard.png")
    for unavailable in [folder.appendingPathComponent("missing"), source, handoffAlias, readOnly] {
        defaults.set(unavailable.path, forKey: "screenshotFolder")
        check(PolishRenderer.saveURL(for: polishedFile)?.deletingLastPathComponent().path == desktop.path,
              "a handoff original falls back to Desktop when the screenshot location is \(unavailable.lastPathComponent)")
        check(PolishRenderer.saveURL(for: storedImage)?.deletingLastPathComponent().path == desktop.path,
              "a stored image falls back to Desktop when the screenshot location is \(unavailable.lastPathComponent)")
    }
    defaults.set(folder.path, forKey: "screenshotFolder")
    check(PolishRenderer.saveURL(for: storedImage)?.deletingLastPathComponent().path == folder.path,
          "a stored image uses a readable, writable screenshot folder")

    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    check(PolishRenderer.load(saved) != nil, "the editor's saved copy of a handoff original survives app quit")
    check(!FileManager.default.fileExists(atPath: polishedFile.path), "app quit removes the polished drag file")
}

private func draggedPNG(_ item: NSItemProvider, asFile: Bool = false) -> Data? {
    var png: Data?
    var finished = false
    let complete: @Sendable (Data?) -> Void = { data in
        DispatchQueue.main.async {
            png = data
            finished = true
        }
    }
    if asFile {
        _ = item.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, _ in
            complete(url.flatMap { try? Data(contentsOf: $0) })
        }
    } else {
        _ = item.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in complete(data) }
    }
    _ = waitForOneShot { finished }
    return png
}

private func draggedFile(_ item: NSItemProvider) -> URL? {
    var url: URL?
    var finished = false
    _ = item.loadObject(ofClass: NSURL.self) { object, _ in
        DispatchQueue.main.async {
            url = object as? URL
            finished = true
        }
    }
    _ = waitForOneShot { finished }
    return url
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
