import AppKit

enum OneShotStatus: Equatable {
    case rendering, copied, failed

    var symbol: String {
        switch self {
        case .rendering: return "sparkles"
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// A single export shared by the panel, History and the screenshot card. Call from the main thread.
final class OneShot {
    private static let queue = DispatchQueue(label: "clipbubble.oneshot", qos: .userInitiated)
    private var inFlight = false

    @discardableResult
    func start(_ url: URL, putOnClipboard: @escaping (Data) -> Bool,
               done: @escaping (NSImage?) -> Void) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        let startingStyle = PolishPreset.last
        let style = startingStyle.isPlain ? PolishPreset.gradient.style : startingStyle
        let scale = PolishRenderer.exportScale(for: style, retina: !UserDefaults.standard.bool(forKey: "polish.export1x"))
        Self.queue.async { [weak self] in
            let result = OneShot.export(url, style: style, scale: scale)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.inFlight = false }
                guard let (png, preview) = result, putOnClipboard(png) else { done(nil); return }
                done(NSImage(cgImage: preview, size: .zero))
            }
        }
        return true
    }

    private static func export(_ url: URL, style: PolishStyle, scale: CGFloat) -> (Data, CGImage)? {
        autoreleasepool {
            guard let source = PolishRenderer.load(url) else { return nil }
            let doc = PolishDoc(source: url, size: CGSize(width: source.width, height: source.height), style: style)
            guard let image = PolishRenderer.render(doc, source: source, scale: scale),
                  let png = PolishRenderer.png(image) else { return nil }
            let ratio = 520 / CGFloat(max(image.width, image.height))
            let preview = ratio < 1 ? PolishModel.scaled(image, ratio) ?? image : image
            return (png, preview)
        }
    }
}
