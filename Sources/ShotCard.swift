import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

// The card that slides out beside the bubble when you take a screenshot: drag it, polish it, or copy it.
// It leaves on its own after a few seconds, but never while the pointer is on it.

final class ShotCardState: ObservableObject {
    enum CopyFeedback { case copied, failed }

    @Published var url: URL?
    @Published var copyFeedback: CopyFeedback?
    @Published var polishStatus: OneShotStatus?
    @Published var polished: OneShot.Output? {
        didSet { polishedDragFile = nil }
    }
    private var polishedDragFile: PolishedDragFile?
    var polishedThumbnail: NSImage? { polished?.thumbnail }
    var polishLabel: String {
        switch polishStatus {
        case .copied: return "Copied"
        case .failed: return "Polish failed"
        default: return "Polish"
        }
    }
    var copyLabel: String {
        switch copyFeedback {
        case .copied: return "Copied"
        case .failed: return "Copy failed"
        case nil: return polished == nil ? "Copy" : "Copy original"
        }
    }
    var copyIcon: String {
        switch copyFeedback {
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case nil: return "doc.on.doc"
        }
    }

    func dragWriter(for url: URL) -> NSPasteboardWriting {
        guard let polished else { return url as NSURL }
        let name = PolishRenderer.polishedFilename(base: url.deletingPathExtension().lastPathComponent)
        let file = polishedDragFile ?? PolishedDragFile(png: polished.png, name: name)
        polishedDragFile = file
        return PolishedDragWriter(file: file)
    }

    var polish: () -> Void = {}
    var edit: () -> Void = {}
    var copy: () -> Void = {}
    var close: () -> Void = {}
    var hovered: (Bool) -> Void = { _ in }
    var dragStarted: () -> Void = {}
    var dragEnded: (_ dropped: Bool) -> Void = { _ in }
}

/// A drag retains the export and its cache even if the card closes or shows a new screenshot.
private final class PolishedDragWriter: NSObject, NSPasteboardWriting {
    private static let image = NSPasteboard.PasteboardType(UTType.image.identifier)
    private let file: PolishedDragFile

    init(file: PolishedDragFile) {
        self.file = file
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.png, Self.image, .fileURL]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        .promised
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .png, Self.image: return file.png
        case .fileURL:
            // A file-URL-only receiver needs a synchronous answer. The handoff I/O still runs on the worker.
            return file.fileURL()?.pasteboardPropertyList(forType: type)
        default: return nil
        }
    }
}

private final class PolishedDragFile: @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "clipbubble.polish-drag"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    let png: Data
    private let name: String
    private var cached: URL? // Accessed on queue.

    init(png: Data, name: String) {
        self.png = png
        self.name = name
    }

    func fileURL() -> NSURL? {
        let result = OSAllocatedUnfairLock(initialState: nil as URL?)
        let operation = BlockOperation {
            let url = try? self.load()
            result.withLock { $0 = url }
        }
        Self.queue.addOperations([operation], waitUntilFinished: true)
        return result.withLock { $0 as NSURL? }
    }

    private func load() throws -> URL {
        let fm = FileManager.default
        if let cached, let written = (try? fm.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(written) < 50 * 60 { return cached }
        let url = try PolishHandoffs.write(png, name: name)
        cached = url
        return url
    }
}

final class ShotCard {
    static let size = NSSize(width: 280, height: 218)
    private let panel = FloatingPanel(size: ShotCard.size, keyable: false)
    let state = ShotCardState()
    private var hideWork: DispatchWorkItem?
    private var copyFeedbackWork: DispatchWorkItem?
    private var polishFeedbackWork: DispatchWorkItem?
    private var hovering = false
    private var dragging = false
    private var generation = 0

    var onPolish: (URL, @escaping (OneShot.Output?) -> Void) -> Bool = { _, _ in false }
    var onEdit: (URL) -> Void = { _ in }
    var onCopy: (URL) -> Bool = { _ in false }
    var onHidden: () -> Void = {}

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        let container = glass(frame: NSRect(origin: .zero, size: ShotCard.size), radius: 16)
        let host = ClickThroughHostingView(rootView: ShotCardView(state: state))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        state.polish = { [weak self] in self?.polish() }
        state.edit = { [weak self] in
            guard let self, let url = self.state.url else { return }
            self.onEdit(url)
        }
        state.copy = { [weak self] in
            guard let self, let url = self.state.url else { return }
            self.copyFeedbackWork?.cancel()
            if self.onCopy(url) {
                self.state.copyFeedback = .copied
                self.schedule(after: 1)
            } else {
                self.state.copyFeedback = .failed
                self.schedule(after: 6)
                self.copyFeedbackWork = .onMain(after: 1.5) { [weak self] in self?.state.copyFeedback = nil }
            }
        }
        state.close = { [weak self] in self?.hide() }
        state.hovered = { [weak self] on in
            guard let self else { return }
            self.hovering = on
            if on || self.dragging { self.hideWork?.cancel() } else { self.schedule(after: 2.5) }
        }
    }

    private func polish() {
        guard let url = state.url else { return }
        let generation = self.generation
        guard onPolish(url, { [weak self] output in
            guard let self, self.generation == generation else { return }
            if output != nil {
                self.copyFeedbackWork?.cancel()
                self.state.copyFeedback = nil
            }
            self.state.polished = output
            self.state.polishStatus = output == nil ? .failed : .copied
            self.schedule(after: 6)
            if output == nil {
                self.polishFeedbackWork = .onMain(after: 1.5) { [weak self] in self?.state.polishStatus = nil }
            }
        }) else { return }
        polishFeedbackWork?.cancel()
        copyFeedbackWork?.cancel()
        hideWork?.cancel()
        state.copyFeedback = nil
        state.polishStatus = .rendering
    }

    /// Slides out of the bubble's side of the screen, level with the bubble.
    func show(_ url: URL, beside b: NSRect, in area: NSRect) {
        generation += 1
        let generation = self.generation
        state.dragStarted = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.dragging = true
            self.hideWork?.cancel()
        }
        state.dragEnded = { [weak self] dropped in
            guard let self, self.generation == generation else { return }
            self.dragging = false
            if dropped { self.hide(animated: false) }
            else if !self.hovering { self.schedule(after: 2.5) }
        }
        state.url = url
        dragging = false
        copyFeedbackWork?.cancel()
        polishFeedbackWork?.cancel()
        state.copyFeedback = nil
        state.polishStatus = nil
        state.polished = nil
        let s = ShotCard.size
        let right = b.midX > area.midX, top = b.midY > area.midY
        var x = right ? b.minX - s.width - 6 : b.maxX + 6
        var y = top ? b.maxY - 9 - s.height : b.minY + 9
        x = min(max(x, area.minX + 8), area.maxX - s.width - 8)
        y = min(max(y, area.minY + 8), area.maxY - s.height - 8)
        let end = NSRect(x: x, y: y, width: s.width, height: s.height)
        let start = end.offsetBy(dx: right ? 24 : -24, dy: 0)
        let wasVisible = panel.isVisible
        if !wasVisible {
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 1
        }
        schedule(after: 6)
    }

    func hide(animated: Bool = true) {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        guard animated else { finishHide(); return }
        let generation = self.generation
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(f.offsetBy(dx: 0, dy: -8), display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.generation == generation, self.panel.isVisible, self.panel.alphaValue < 0.01 else { return }
            self.finishHide()
        })
    }

    private func finishHide() {
        panel.orderOut(nil)
        copyFeedbackWork?.cancel()
        polishFeedbackWork?.cancel()
        generation += 1
        state.url = nil
        state.polishStatus = nil
        state.polished = nil
        hovering = false
        dragging = false
        onHidden()
    }

    private func schedule(after s: Double) {
        hideWork?.cancel()
        guard !hovering, !dragging, state.polishStatus != .rendering else { return }
        let generation = self.generation
        hideWork = .onMain(after: s) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.hide()
        }
    }
}

private struct ShotCardView: View {
    @ObservedObject var state: ShotCardState
    @State private var hoverThumb = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if let url = state.url {
                    ZStack {
                        Thumb(path: url.path, px: 640, fit: true)
                            .id(url)
                            .opacity(state.polishedThumbnail == nil ? 1 : 0)
                        if let thumbnail = state.polishedThumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                                .transition(.opacity)
                        }
                    }
                        .animation(.easeInOut(duration: 0.22), value: state.polishedThumbnail != nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                        .overlay(alignment: .bottomLeading) {
                            Label("Drag", systemImage: "hand.draw")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(8)
                                .opacity(hoverThumb ? 1 : 0)
                        }
                        .scaleEffect(hoverThumb ? 1.015 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hoverThumb)
                        .onHover { hoverThumb = $0 }
                        .overlay { ShotDragView(state: state) }
                        .help("Drag it anywhere")
                }
                Button(action: state.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Dismiss")
            }
            .frame(height: 150)
            HStack(spacing: 8) {
                Button(action: state.polish) {
                    Group {
                        if state.polishStatus == .rendering {
                            ProgressView().controlSize(.small).colorScheme(.dark)
                        } else if state.polishStatus == .copied {
                            HStack(spacing: 4) {
                                Text("Copied")
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Label(state.polishLabel, systemImage: state.polishStatus?.symbol ?? "sparkles")
                        }
                    }
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.84, green: 0.43, blue: 0.99)],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressStyle())
                .disabled(state.polishStatus == .rendering)
                .accessibilityLabel(state.polishLabel)
                .help("Polish and copy")
                Button("Edit", action: state.edit)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .help("Edit in Polish")
                Button(action: state.copy) {
                    Label(state.copyLabel, systemImage: state.copyIcon)
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: state.polished == nil ? 92 : 108, height: 30)
                        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressStyle())
                .help("Copy the original screenshot")
            }
        }
        .padding(12)
        .onHover { state.hovered($0) }
    }
}

/// The AppKit session reports whether the receiver accepted the file.
struct ShotDragView: NSViewRepresentable {
    private let url: URL
    private let writer: NSPasteboardWriting
    private let thumbnail: NSImage?
    private let onStart: () -> Void
    private let onEnd: (_ dropped: Bool) -> Void

    init?(state: ShotCardState) {
        guard let url = state.url else { return nil }
        self.url = url
        writer = state.dragWriter(for: url)
        thumbnail = state.polishedThumbnail
        onStart = state.dragStarted
        onEnd = state.dragEnded
    }

    func makeNSView(context: Context) -> Source { Source(drag: self) }

    func updateNSView(_ view: Source, context: Context) { view.drag = self }

    final class Source: NSView, NSDraggingSource {
        var drag: ShotDragView
        private var activeDragEnd: ((_ dropped: Bool) -> Void)?

        init(drag: ShotDragView) {
            self.drag = drag
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}

        func startDrag() -> NSDraggingItem? {
            guard activeDragEnd == nil else { return nil }
            // SwiftUI may update this view before AppKit finishes the drag.
            activeDragEnd = drag.onEnd
            drag.onStart()
            return NSDraggingItem(pasteboardWriter: drag.writer)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let item = startDrag() else { return }
            let url = drag.url
            let preview = drag.thumbnail ?? Thumbs.cached(url.path, 640)
                ?? NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 110
            let ratio = preview.size.height > 0 ? preview.size.width / preview.size.height : 1
            let size = ratio >= 1 ? NSSize(width: side, height: max(44, side / ratio))
                : NSSize(width: max(44, side * ratio), height: side)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                                  contents: preview)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            endDrag(operation: operation)
        }

        func endDrag(operation: NSDragOperation) {
            let finish = activeDragEnd
            activeDragEnd = nil
            finish?(!operation.isEmpty)
        }
    }
}

/// A button that gives a little under the finger.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
