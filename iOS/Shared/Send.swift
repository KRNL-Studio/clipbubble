import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What this iPhone adds to the history: the clipboard, the share sheet and Shortcuts. Each returns the item's hash.
enum Inbox {
    static func text(_ t: String, source: String) -> String? {
        guard t.utf8.count <= Sync.maxText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hash = "t:" + sha(t)
        DB().upsert(kind: "text", text: t, file: nil, source: source, hash: hash)
        return hash
    }

    /// Stored as PNG, which computers check against the hash and paste as a picture.
    static func image(_ data: Data, source: String) -> String? {
        autoreleasepool {
            guard let image = CGImageSourceCreateWithData(data as CFData, imageSourceOptions),
                  let png = pngData(image, original: { data }) else { return nil }
            return saveImage(png, source: source)
        }
    }

    /// Read directly from the picker's file so large originals stay on disk.
    static func image(_ url: URL, source: String) -> String? {
        autoreleasepool {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
                  let png = pngData(image, original: {
                      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                            size <= Sync.autoFetchLimit else { return nil }
                      return try? Data(contentsOf: url, options: .mappedIfSafe)
                  }) else { return nil }
            return saveImage(png, source: source)
        }
    }

    private static let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    private static func pngData(_ image: CGImageSource, original: () -> Data?) -> Data? {
        if CGImageSourceGetType(image) == UTType.png.identifier as CFString,
           let data = original(), data.count <= Sync.autoFetchLimit {
            return data
        }

        // Decode at thumbnail size and apply EXIF orientation before saving the pixels.
        var pixels = 2560
        while pixels > 0 {
            guard let png = autoreleasepool(invoking: { () -> NSMutableData? in
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ] as CFDictionary) else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, thumbnail, nil)
                return CGImageDestinationFinalize(destination) ? data : nil
            }) else { return nil }
            if png.length <= Sync.autoFetchLimit { return png as Data }
            pixels /= 2
        }
        return nil
    }

    private static func saveImage(_ png: Data, source: String) -> String? {
        let digest = sha(png)
        let url = Paths.images.appendingPathComponent(digest + ".png")
        try? FileManager.default.createDirectory(at: Paths.images, withIntermediateDirectories: true)
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        let hash = "i:" + digest
        DB().upsert(kind: "image", text: "", file: url.path, source: source, hash: hash)
        return hash
    }

    /// A copy in ClipBubble's own folder, since what the share sheet hands over is gone once it closes.
    static func file(_ src: URL, source: String) -> String? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if src.pathExtension.lowercased() == "png",
           let size = try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Sync.autoFetchLimit {
            return image(src, source: source)
        }
        let dir = Paths.dir.appendingPathComponent("sent").appendingPathComponent(UUID().uuidString)
        let dest = dir.appendingPathComponent(safeFileName(src.lastPathComponent))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        let hash = "f:" + sha(dest.path)
        DB().upsert(kind: "file", text: dest.path, file: nil, source: source, hash: hash)
        return hash
    }

    /// `file`, then clears the temporary folder the item was kept in until now.
    static func moved(_ temp: URL, source: String) -> String? {
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        return file(temp, source: source)
    }

    /// Text, a link, a picture or a file from anything that hands over item providers: Paste and the share sheet.
    /// Pasted pictures become images, so they paste as pictures on the computer; shared ones keep their file.
    static func add(_ providers: [NSItemProvider], source: String, picturesAsFiles: Bool = false) async -> [String] {
        var hashes: [String] = []
        for p in providers {
            if let h = await add(p, source: source, picturesAsFiles: picturesAsFiles) { hashes.append(h) }
        }
        return hashes
    }

    private static func add(_ p: NSItemProvider, source: String, picturesAsFiles: Bool) async -> String? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        if p.canLoadObject(ofClass: URL.self), let url = await object(p, URL.self) {
            return url.isFileURL ? file(url, source: source) : text(url.absoluteString, source: source)
        }
        if let t = types.first(where: { $0.conforms(to: .image) }) {
            if picturesAsFiles, let url = await fileCopy(p, t) { return moved(url, source: source) }
            if let d = await data(p, t) { return image(d, source: source) }
        }
        if p.canLoadObject(ofClass: String.self), let s = await object(p, String.self) { return text(s, source: source) }
        if let t = types.first(where: { $0.conforms(to: .data) }), let url = await fileCopy(p, t) { return moved(url, source: source) }
        return nil
    }

    private static func object<T: _ObjectiveCBridgeable>(_ p: NSItemProvider, _: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { c in _ = p.loadObject(ofClass: T.self) { v, _ in c.resume(returning: v) } }
    }

    private static func data(_ p: NSItemProvider, _ t: UTType) async -> Data? {
        await withCheckedContinuation { c in _ = p.loadDataRepresentation(for: t) { d, _ in c.resume(returning: d) } }
    }

    /// The provider's file, moved somewhere that outlives its callback.
    private static func fileCopy(_ p: NSItemProvider, _ t: UTType) async -> URL? {
        let suggested = p.suggestedName
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(for: t, openInPlace: false) { url, _, _ in
                guard let url else { return c.resume(returning: nil) }
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                var name = safeFileName(suggested ?? url.lastPathComponent)
                let ext = url.pathExtension.lowercased()
                let nameExt = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty, nameExt != ext {
                    let existingType = UTType(filenameExtension: nameExt)
                    if existingType == nil || existingType != UTType(filenameExtension: ext) {
                        name = safeFileName(name + "." + url.pathExtension)
                    }
                }
                let dest = keep.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dest)
                    c.resume(returning: dest)
                } catch {
                    try? FileManager.default.removeItem(at: keep)
                    c.resume(returning: nil)
                }
            }
        }
    }
}

/// Links to the computers just long enough to hand something over, for the share sheet and Shortcuts, when
/// ClipBubble itself isn't open. Runs on the main thread.
@MainActor
enum Courier {
    /// Adds the items, waits for a link, and returns once a computer has them on its clipboard or `timeout` passes.
    /// Whatever didn't make it still syncs the next time ClipBubble opens.
    static func deliver(timeout: Double = 25, status: @escaping (String) -> Void = { _ in },
                        add: @escaping () async -> [String]) async -> String {
        let engine = SyncEngine.shared
        guard !SyncEngine.enabledHosts.isEmpty else {
            return await add().isEmpty ? "Couldn't save that." : "Saved. Link a computer in ClipBubble to send it there."
        }
        engine.hold(true)
        defer { engine.hold(false) }
        engine.start()
        status("Connecting…")
        // Saved before the wait, so you can walk away from the share sheet with nothing lost.
        let hashes = await add()
        guard !hashes.isEmpty else { return "Couldn't save that." }
        let wasLinked = engine.statuses.values.contains { $0.ok }
        let linked = await until(seconds: 10) { engine.statuses.values.contains { $0.ok } }
        // A computer only takes what's just been copied onto its clipboard, so the wait mustn't count against it.
        if linked, !wasLinked {
            let now = Date().timeIntervalSince1970
            hashes.forEach { DB().bump(hash: $0, to: now) }
        }
        guard linked else {
            // Connecting or offline needs nothing from you; anything else (an untrusted host, a missing key) does.
            switch engine.statuses.values.first(where: { !$0.ok }) {
            case nil, .connecting?, .offline?: return "Saved. It goes to your computer next time ClipBubble connects."
            case let s?: return "Saved. \(s.phoneText). It goes over once that's fixed."
            }
        }
        let names = Array(Set(engine.statuses.values.compactMap { s -> String? in if case .live(let h) = s { return h.name }; return nil }))
        status("Sending to \(names.joined(separator: ", "))…")
        // Big files wait for Get on the computer; sending them from here means you want them there now.
        for h in hashes where h.hasPrefix("f:") { engine.linked.forEach { engine.send(h, toDevice: $0.device) } }
        // Each item and computer that confirmed it, so two of three photos arriving isn't reported as all of them.
        var got: Set<String> = []
        var progress: [String: Transfer] = [:]
        let (wasApplied, wasTransfers) = (engine.onApplied, engine.onTransfers)
        engine.onApplied = { hash, peer in wasApplied(hash, peer); if hashes.contains(hash) { got.insert(hash + "\n" + peer) } }
        engine.onTransfers = { t in
            wasTransfers(t)
            progress = t
            let sending = t.values.filter(\.sending)
            if !sending.isEmpty {
                let done = sending.map(\.done).reduce(0, +), total = max(1, sending.map(\.total).reduce(0, +))
                status("Sending… \(Int(Double(done) / Double(total) * 100))%")
            }
        }
        // A file still uploading gets up to ten more minutes.
        let deadline = Date().addingTimeInterval(timeout), hardStop = deadline.addingTimeInterval(600)
        while got.count < names.count * hashes.count, Date() < hardStop, Date() < deadline || progress.values.contains(where: \.sending) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        engine.onApplied = wasApplied
        engine.onTransfers = wasTransfers
        // No answer yet doesn't mean it arrived: it's saved here and syncs again next time.
        if got.isEmpty { return "Saved. Still waiting for \(names.joined(separator: ", ")) to confirm." }
        let complete = names.filter { n in hashes.allSatisfy { got.contains($0 + "\n" + n) } }
        if complete.count == names.count { return "On the clipboard of \(complete.sorted().joined(separator: ", "))." }
        return "Saved. Some items are still on their way to \(names.joined(separator: ", "))."
    }

    private static func until(seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }
}
