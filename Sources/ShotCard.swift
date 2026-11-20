import AppKit
import SwiftUI

// The card that slides out beside the bubble when you take a screenshot: drag it, polish it, or copy it.
// It leaves on its own after a few seconds, but never while the pointer is on it.

final class ShotCardState: ObservableObject {
    enum CopyFeedback { case copied, failed }

    @Published var url: URL?
    @Published var copyFeedback: CopyFeedback?
    var copyLabel: String {
        switch copyFeedback {
        case .copied: return "Copied"
        case .failed: return "Copy failed"
        case nil: return "Copy"
        }
    }
    var copyIcon: String {
        switch copyFeedback {
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case nil: return "doc.on.doc"
        }
    }
    var polish: () -> Void = {}
    var copy: () -> Void = {}
    var close: () -> Void = {}
    var hovered: (Bool) -> Void = { _ in }
}

final class ShotCard {
    static let size = NSSize(width: 280, height: 218)
    private let panel = FloatingPanel(size: ShotCard.size, keyable: false)
    let state = ShotCardState()
    private var hideWork: DispatchWorkItem?
    private var copyFeedbackWork: DispatchWorkItem?
    private var hovering = false

    var onPolish: (URL) -> Void = { _ in }
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
        state.polish = { [weak self] in
            guard let self, let url = self.state.url else { return }
            self.hide()
            self.onPolish(url)
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
                let work = DispatchWorkItem { [weak self] in self?.state.copyFeedback = nil }
                self.copyFeedbackWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
        }
        state.close = { [weak self] in self?.hide() }
        state.hovered = { [weak self] on in
            guard let self else { return }
            self.hovering = on
            if on { self.hideWork?.cancel() } else { self.schedule(after: 2.5) }
        }
    }

    /// Slides out of the bubble's side of the screen, level with the bubble.
    func show(_ url: URL, beside b: NSRect, in area: NSRect) {
        state.url = url
        copyFeedbackWork?.cancel()
        state.copyFeedback = nil
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
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(f.offsetBy(dx: 0, dy: -8), display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.panel.isVisible, self.panel.alphaValue < 0.01 else { return }
            self.finishHide()
        })
    }

    private func finishHide() {
        panel.orderOut(nil)
        copyFeedbackWork?.cancel()
        state.url = nil
        hovering = false
        onHidden()
    }

    private func schedule(after s: Double) {
        hideWork?.cancel()
        guard !hovering else { return }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
}

private struct ShotCardView: View {
    @ObservedObject var state: ShotCardState
    @State private var hoverThumb = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if let url = state.url {
                    Thumb(path: url.path, px: 640, fit: true)
                        .id(url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                        .overlay(alignment: .bottomLeading) {
                            Label("Drag me", systemImage: "hand.draw")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(8)
                                .opacity(hoverThumb ? 1 : 0)
                        }
                        .scaleEffect(hoverThumb ? 1.015 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hoverThumb)
                        .onHover { hoverThumb = $0 }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
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
                    Label("Polish", systemImage: "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.84, green: 0.43, blue: 0.99)],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressStyle())
                .help("Open in the editor")
                Button(action: state.copy) {
                    Label(state.copyLabel, systemImage: state.copyIcon)
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 92, height: 30)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(12)
        .onHover { state.hovered($0) }
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
