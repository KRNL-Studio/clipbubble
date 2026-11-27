import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What this iPhone adds to the history: the clipboard, the share sheet and Shortcuts. Each returns the item's hash.
enum Inbox {
    static func text(_ t: String, source: String) -> String? {
        guard t.utf8.count <= Sync.maxText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hash = "t:" + sha(t)
        let db = DB()
        return db.upsert(kind: "text", text: t, file: nil, source: source, hash: hash) ? hash : nil
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
        let hash = "i:" + sha(png)
        let db = DB()
        let fm = FileManager.default
        func hasImage(_ clip: Clip?) -> Bool {
            guard let clip, !clip.remote, let path = clip.file else { return false }
            return fm.fileExists(atPath: path)
        }
        // Each writer owns its staged file, so cleanup can't unlink another process's copy.
        let url = Paths.images.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        var keepFile = false
        defer { if !keepFile { try? fm.removeItem(at: url) } }
        db.upsert(kind: "image", text: "", file: url.path, source: source, hash: hash)
        guard db.exists(hash: hash) else { return nil }
        if !hasImage(db.clip(hash: hash)) {
            // Upserting an existing remote stub only bumps its timestamp.
            db.received(hash: hash, file: url.path, text: nil)
        }
        let saved = db.clip(hash: hash)
        keepFile = saved?.file == url.path
        return hasImage(saved) ? hash : nil
    }

    /// A copy in ClipBubble's own folder, since what the share sheet hands over is gone once it closes.
    static func file(_ src: URL, named name: String? = nil, source: String) -> String? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if ((name ?? src.lastPathComponent) as NSString).pathExtension.lowercased() == "png",
           let size = try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Sync.autoFetchLimit {
            return image(src, source: source)
        }
        let dir = Paths.dir.appendingPathComponent("sent").appendingPathComponent(UUID().uuidString)
        let dest = dir.appendingPathComponent(safeFileName(name ?? src.lastPathComponent))
        let fm = FileManager.default
        var keepFile = false
        defer { if !keepFile { try? fm.removeItem(at: dir) } }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest)
        } catch {
            return nil
        }
        let hash = "f:" + sha(dest.path)
        let db = DB()
        db.upsert(kind: "file", text: dest.path, file: nil, source: source, hash: hash)
        keepFile = db.exists(hash: hash)
        return keepFile ? hash : nil
    }

    /// `file`, then clears the temporary folder the item was kept in until now.
    static func moved(_ temp: URL, source: String) -> String? {
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        return file(temp, source: source)
    }

    /// Pasted pictures become images, so they paste as pictures on the computer.
    static func add(_ providers: [NSItemProvider], source: String) async -> [String] {
        var hashes: [String] = []
        for p in providers {
            guard !Task.isCancelled else { break }
            if let h = await add(p, source: source) { hashes.append(h) }
        }
        return hashes
    }

    /// Share keeps original file bytes and commits each item while its provider's URL is valid.
    static func share(_ providers: [NSItemProvider]) async -> [String] {
        ShareOutbox.recover()
        var hashes: [String] = []
        for p in providers {
            guard !Task.isCancelled else { break }
            if p.canLoadObject(ofClass: URL.self), let url = await object(p, URL.self),
               let hash = url.isFileURL ? ShareOutbox.saveFile(url, name: url.lastPathComponent)
                   : ShareOutbox.saveText(url.absoluteString) {
                hashes.append(hash)
                continue
            }
            let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
            if let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }),
               let hash = await providedFile(p, type, save: ShareOutbox.saveFile) {
                hashes.append(hash)
            } else if p.canLoadObject(ofClass: String.self), let text = await object(p, String.self),
                      let hash = ShareOutbox.saveText(text) {
                hashes.append(hash)
            } else if let type = types.first(where: { $0.conforms(to: .text) }),
                      let hash = await providedFile(p, type, save: ShareOutbox.saveFile) {
                hashes.append(hash)
            }
        }
        return hashes
    }

    private static func add(_ p: NSItemProvider, source: String) async -> String? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        if p.canLoadObject(ofClass: URL.self), let url = await object(p, URL.self) {
            return url.isFileURL ? file(url, source: source) : text(url.absoluteString, source: source)
        }
        if let t = types.first(where: { $0.conforms(to: .image) }), let d = await data(p, t) {
            return image(d, source: source)
        }
        if p.canLoadObject(ofClass: String.self), let s = await object(p, String.self) { return text(s, source: source) }
        if let t = types.first(where: { $0.conforms(to: .data) }) {
            return await providedFile(p, t) { url, name in
                // Retain the provider's suggested filename for sync and paste.
                file(url, named: name, source: source)
            }
        }
        return nil
    }

    private static func object<T: _ObjectiveCBridgeable>(_ p: NSItemProvider, _: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { c in _ = p.loadObject(ofClass: T.self) { v, _ in c.resume(returning: v) } }
    }

    private static func data(_ p: NSItemProvider, _ t: UTType) async -> Data? {
        await withCheckedContinuation { c in _ = p.loadDataRepresentation(for: t) { d, _ in c.resume(returning: d) } }
    }

    /// The file URL is valid only during this callback. Keep the provider's suggested name and actual type.
    private static func providedFile(_ p: NSItemProvider, _ t: UTType,
                                     save: @escaping (URL, String) -> String?) async -> String? {
        let suggested = p.suggestedName
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(for: t, openInPlace: false) { url, _, _ in
                guard let url else { return c.resume(returning: nil) }
                var name = safeFileName(suggested ?? url.lastPathComponent)
                let ext = url.pathExtension.lowercased()
                let nameExt = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty, nameExt != ext {
                    let existingType = UTType(filenameExtension: nameExt)
                    if existingType == nil || existingType != UTType(filenameExtension: ext) {
                        name = safeFileName(name + "." + url.pathExtension)
                    }
                }
                c.resume(returning: save(url, name))
            }
        }
    }
}
