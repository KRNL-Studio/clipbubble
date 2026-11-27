import AppKit

/// Writes clips back to the macOS clipboard.
enum Board {
    static let polishedType = NSPasteboard.PasteboardType("studio.krnl.clipbubble.polished")

    static func pngData(_ path: String) -> Data? {
        if (path as NSString).pathExtension.lowercased() == "png" { return FileManager.default.contents(atPath: path) }
        return NSImage(contentsOfFile: path)?.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }

    /// Puts a clip on the clipboard. Returns false, leaving the clipboard alone, when its image or files are gone,
    /// so a paste never lands whatever was copied before.
    @discardableResult
    static func write(_ c: Clip) -> Bool {
        switch c.kind {
        case "text":
            writeText(c.text)
            return true
        case "image":
            guard let f = c.file, let d = pngData(f) else { return false }
            return writePNG(d)
        default:
            let urls = c.paths.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return false }
            writeFiles(urls)
            return true
        }
    }

    @discardableResult
    static func writePNG(_ data: Data, to board: NSPasteboard = .general, polished: Bool = false) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return false }
        if polished, !item.setString("", forType: polishedType) { return false }
        board.clearContents()
        return board.writeObjects([item])
    }

    /// `transient` marks it so clipboard managers (ClipBubble included) don't save it.
    static func writeText(_ s: String, transient: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        if transient { NSPasteboard.general.setString("", forType: .init("org.nspasteboard.TransientType")) }
    }

    /// A single image file goes on as both the file and its pixels, so it pastes into Finder and into chat/web apps.
    static func writeFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if urls.count == 1, isImagePath(urls[0].path), let d = pngData(urls[0].path) {
            let item = NSPasteboardItem()
            item.setString(urls[0].absoluteString, forType: .fileURL)
            item.setData(d, forType: .png)
            pb.writeObjects([item])
        } else {
            pb.writeObjects(urls as [NSURL])
        }
    }
}
