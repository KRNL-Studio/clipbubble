import SwiftUI
import UIKit

/// Share → ClipBubble: anything shareable goes into the history and onto your computers' clipboard.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let state = ShareState()
    private var delivery: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(state: state) { [weak self] in self?.close() })
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)

        #if DEBUG
        if Platform.defaults.bool(forKey: "demo") || FileManager.default.fileExists(atPath: Paths.dir.appendingPathComponent(".demo").path) {
            state.saved = true
            state.text = "On the clipboard of MacBook Pro."
            state.done = true
            return
        }
        #endif
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { item -> [NSItemProvider] in
            if let attachments = item.attachments, !attachments.isEmpty { return attachments }
            if let text = item.attributedContentText?.string { return [NSItemProvider(object: text as NSString)] }
            return []
        }
        delivery = Task { @MainActor [weak self, state] in
            let hashes = await Inbox.share(providers)
            guard !Task.isCancelled else { return }
            state.saved = !hashes.isEmpty
            let count = hashes.count < providers.count && !hashes.isEmpty ? " \(hashes.count) of \(providers.count) items saved." : ""
            if state.saved, !SyncEngine.enabledHosts.isEmpty, !SyncEngine.paused {
                state.text = "Saved in ClipBubble. Trying to sync…" + count
            }
            let message = await Courier.deliverSaved(hashes)
            guard !Task.isCancelled else { return }
            state.text = message + count
            state.done = true
            guard hashes.count == providers.count, state.saved else { return }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { self?.close() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        delivery?.cancel()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Keep the sharing app visible behind the card when UIKit adds an opaque extension container.
        var container: UIView? = view
        while let current = container {
            current.backgroundColor = .clear
            container = current.superview
        }
    }

    private func close() {
        guard !state.closed else { return }
        state.closed = true
        let task = delivery
        task?.cancel()
        delivery = nil
        Task { [extensionContext] in
            await task?.value
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

final class ShareState: ObservableObject {
    @Published var text = "Saving to ClipBubble…"
    @Published var done = false
    /// Hiding before this would close the share sheet with nothing saved.
    @Published var saved = false
    var closed = false
}

struct ShareCard: View {
    @ObservedObject var state: ShareState
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if state.done {
                    Image(systemName: state.saved ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.title2)
                        .foregroundStyle(state.saved ? .green : .orange).accessibilityHidden(true)
                } else {
                    ProgressView()
                }
                Text(state.text).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(state.done ? "Done" : "Hide", action: close).font(.subheadline).disabled(!state.saved && !state.done)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(16)
        }
    }
}
