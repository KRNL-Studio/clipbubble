import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

@main
struct ClipBubbleApp: App {
    @StateObject private var model = Model()
    @AppStorage("appearance") private var appearance = Appearance.system
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HistoryView().environmentObject(model)
                .onOpenURL { model.open($0) }
                // Set on the window, not with preferredColorScheme, which leaves sheets behind and doesn't switch back to System.
                .onChange(of: appearance, initial: true) {
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        scene.windows.forEach { $0.overrideUserInterfaceStyle = appearance.style }
                    }
                }
                // While the app is open it holds the link, and the keyboard leaves it alone (see SyncEngine.suspend).
                .onChange(of: phase, initial: true) {
                    guard phase != .inactive else { return }
                    model.heartbeat(phase == .active)
                    SyncEngine.shared.suspend(phase == .background)
                }
        }
    }
}

enum Appearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// An alert in a window of its own. One in the app's window stays hidden behind an open sheet, or is lost while a sheet
/// opens, and a pairing link can arrive at any moment, even as the app launches.
@MainActor
enum Prompt {
    private static var window: UIWindow?
    private static var pendingAnswer: ((Bool) -> Void)?

    static func show(_ title: String, _ message: String, ok: String = "OK", cancel: String? = nil, answer: @escaping (Bool) -> Void = { _ in }) {
        finish(false)
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return answer(false) }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        w.rootViewController = UIViewController()
        w.isHidden = false
        window = w
        pendingAnswer = answer
        func button(_ title: String, _ style: UIAlertAction.Style, _ yes: Bool) -> UIAlertAction {
            UIAlertAction(title: title, style: style) { [weak w] _ in
                guard let w, window === w else { return }
                finish(yes)
            }
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let cancel { alert.addAction(button(cancel, .cancel, false)) }
        alert.addAction(button(ok, .default, true))
        w.rootViewController?.present(alert, animated: true)
    }

    private static func finish(_ yes: Bool) {
        let answer = pendingAnswer
        pendingAnswer = nil
        window?.isHidden = true
        window = nil
        answer?(yes)
    }
}

/// The short line at the bottom of every tab.
struct Line: Equatable {
    enum Look { case done, failed, busy }
    var text: String
    var look = Look.done
}

/// History and link state for the screens. Everything here is read and changed on the main thread.
@MainActor
final class Model: ObservableObject {
    @Published var clips: [Clip] = []
    @Published private(set) var revision = 0
    @Published var hosts: [String] = SyncEngine.enabledHosts
    @Published var statuses: [String: LinkState] = [:]
    @Published var devices: [String: String] = [:]
    @Published var query = "" { didSet { reload() } }
    @Published private(set) var transfers: [String: Transfer] = [:]
    @Published private var toast: Line?
    @Published private(set) var linking = false
    private var confirmingLink = false
    private let db = DB()
    private var toastTask: Task<Void, Never>?

    init() {
        #if DEBUG
        // `-demo YES` (debug builds only): a linked MacBook Pro without a computer, for App Store screenshots.
        if UserDefaults.standard.bool(forKey: "demo") {
            let mac = "you@macbook-pro.local"
            hosts = [mac]
            statuses = [mac: .live(Hello(proto: 1, device: "demo-mac", name: "MacBook Pro", os: "macos", version: "1.6.2", clock: 0))]
            reload()
            return
        }
        #endif
        let engine = SyncEngine.shared
        engine.onReceived = { [weak self] in self?.reload() }
        engine.onStatus = { [weak self] in self?.statuses = engine.statuses; self?.reload() }
        engine.onApplied = { [weak self] _, peer in self?.say("On \(peer)'s clipboard") }
        engine.onTransfers = { [weak self] in self?.transfers = $0 }
        engine.start()
        DB().prune()
        reload()
        // The share sheet and the keyboard write to the same history while the app is away.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in DB().prune(); self?.hosts = SyncEngine.enabledHosts; self?.reload() }
        }
    }

    /// While the app is open it stamps the time every few seconds. The keyboard trusts a recent stamp, so an app that
    /// crashed while open doesn't leave it waiting for a link nobody holds.
    private var beat: Timer?
    func heartbeat(_ on: Bool) {
        beat?.invalidate()
        Platform.defaults.set(on ? Date().timeIntervalSince1970 : 0, forKey: "app.alive")
        guard on else { return }
        beat = .scheduledTimer(withTimeInterval: 4, repeats: true) { _ in Platform.defaults.set(Date().timeIntervalSince1970, forKey: "app.alive") }
    }

    func reload() {
        clips = db.clips(query: query.isEmpty ? nil : query, preview: true)
        devices = db.deviceNames()
        revision += 1
    }

    /// Everything kept, for the Library.
    func library(query: String) -> [Clip] {
        db.clips(limit: 5000, query: query.isEmpty ? nil : query, preview: true)
    }

    func clip(_ hash: String) -> Clip? { db.clip(hash: hash) }
    func whole(_ c: Clip) -> Clip { db.whole(c) }

    func add(_ alias: String) {
        guard SSHTarget(alias) != nil, !hosts.contains(alias) else { return }
        hosts.append(alias)
        SyncEngine.shared.setHost(alias, on: true)
    }

    func remove(_ alias: String) {
        hosts.removeAll { $0 == alias }
        SyncEngine.shared.setHost(alias, on: false)
        Addresses.forget(alias)
        // Left behind, the old host key would refuse this computer if it came back after a reinstall.
        guard let t = SSHTarget(alias), !hosts.contains(where: { SSHTarget($0)?.host == t.host && SSHTarget($0)?.port == t.port }) else { return }
        Platform.defaults.removeObject(forKey: t.hostKeyPreference)
    }

    func redialAll() { hosts.forEach { SyncEngine.shared.redial($0) } }

    func delete(_ c: Clip) {
        db.delete(hash: c.hash)
        reload()
    }

    func clearHistory() {
        db.deleteAll()
        reload()
        say("History cleared")
    }

    func get(_ c: Clip) {
        let device = devices[c.origin] ?? "Your computer"
        SyncEngine.shared.get(c.hash) { [weak self] started in
            self?.say(started ? "Getting it from \(device)…" : "\(device) isn't connected", started ? .busy : .failed)
        }
    }

    func copy(_ c: Clip) {
        if c.remote { return get(c) }
        guard Clipboard.write(whole(c)) else { return say("Couldn't copy that", .failed) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("Copied")
    }

    /// Paste: what's on this iPhone's clipboard joins the history and goes to every linked computer.
    func paste(_ providers: [NSItemProvider]) {
        Task {
            let added = await Inbox.add(providers, source: "Clipboard")
            reload()
            if added.isEmpty { return say("Nothing to paste", .failed) }
            say(hosts.isEmpty ? "Saved" : statuses.values.contains { $0.ok } ? "Sending…" : "Saved, sends when linked")
        }
    }

    func addText(_ t: String) -> Bool {
        guard let hash = Inbox.text(t, source: "iPhone") else { return false }
        added([hash])
        return true
    }

    func addFiles(_ urls: [URL]) {
        say("Adding…", .busy)
        Task { added(await Task.detached { urls.compactMap { Inbox.file($0, source: "iPhone") } }.value) }
    }

    /// Pictures join as images, so they paste as pictures on the computer; videos join as files.
    func addPhotos(_ items: [PhotosPickerItem]) {
        say("Adding…", .busy)
        Task {
            var hashes: [String] = []
            for item in items {
                guard let f = try? await item.loadTransferable(type: PickedFile.self) else { continue }
                let isImage = item.supportedContentTypes.contains { $0.conforms(to: .image) }
                let h = await Task.detached {
                    if !isImage { return Inbox.moved(f.url, source: "iPhone") }
                    defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
                    return Inbox.image(f.url, source: "iPhone")
                }.value
                if let h { hashes.append(h) }
            }
            added(hashes)
        }
    }

    /// Something added by hand is meant for the computers now, so files go over without waiting for Get.
    private func added(_ hashes: [String]) {
        reload()
        guard !hashes.isEmpty else { return say("Couldn't add that", .failed) }
        let engine = SyncEngine.shared
        for h in hashes where h.hasPrefix("f:") { engine.linked.forEach { engine.send(h, toDevice: $0.device) } }
        say(hosts.isEmpty ? "Added" : statuses.values.contains { $0.ok } ? "Sent to your computers" : "Added, sends when linked")
    }

    /// A pairing link from the Camera, a scan or anywhere else. Nothing leaves this iPhone until you say yes, because
    /// the computer you link gets everything you copy. Its address leads, since it can call itself anything.
    func open(_ url: URL) {
        guard url.host == "pair", !linking, !confirmingLink else { return }
        guard let link = Pairing.Link(url) else { return Prompt.show("Link a computer", Pairing.Failure.badLink.localizedDescription) }
        confirmingLink = true
        let name = link.name.map { "It calls itself \($0). " } ?? ""
        Prompt.show("Link the computer at \(link.hosts[0])?",
                    name + "Linking syncs the clipboard history ClipBubble keeps from the last 7 days and new copies between this iPhone and the computer. Only link a computer you're setting up right now.",
                    ok: "Link", cancel: "Cancel") { [weak self] yes in
            self?.confirmingLink = false
            if yes { self?.pair(link) }
        }
    }

    private func pair(_ link: Pairing.Link) {
        linking = true
        Task {
            do {
                let (alias, name) = try await Pairing.pair(link)
                HostRow.remember(name, for: alias)
                add(alias)
                Pairing.olderLinks(than: alias).forEach(remove)
                SyncEngine.shared.redial(alias)
                linking = false
                say("Linked with \(name)")
            } catch {
                linking = false
                Prompt.show("Link a computer", error.localizedDescription)
            }
        }
    }

    /// What the bottom line shows: linking for as long as it lasts, or what just happened.
    var line: Line? { linking ? Line(text: "Linking…", look: .busy) : toast }

    func say(_ s: String, _ look: Line.Look = .done) {
        toast = Line(text: s, look: look)
        AccessibilityNotification.Announcement(s).post()
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if !Task.isCancelled { toast = nil } }
    }
}

/// The app: Recent, Library and Settings as tabs in the system tab bar, with Add as a tab that opens a panel.
struct HistoryView: View {
    @EnvironmentObject var model: Model
    @State private var tab = Tab.recent
    @State private var adding: Adding?
    /// What the Add panel asked for, opened once the panel has gone.
    @State private var next: Adding?
    @State private var photos: [PhotosPickerItem] = []
    @State private var viewing: Clip?
    @AppStorage("welcomed") private var welcomed = false

    enum Tab { case recent, library, add, settings }
    enum Adding { case panel, text, photos, files }

    var body: some View {
        // Add isn't a place to go, so choosing it opens the panel and leaves the current tab selected.
        TabView(selection: Binding(get: { tab }, set: { if $0 == .add { adding = .panel } else { tab = $0 } })) {
            NavigationStack { recent }
                .tabItem { Label("Recent", systemImage: "clock") }.tag(Tab.recent)
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(Tab.library)
            Color.clear
                .tabItem { Label("Add", systemImage: "plus.circle") }.tag(Tab.add)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .minimizesOnScroll()
        .sensoryFeedback(.selection, trigger: tab)
        .sheet(isPresented: shows(.panel), onDismiss: { adding = next; next = nil }) {
            AddPanel(paste: model.paste) { next = $0; adding = nil }
        }
        .sheet(isPresented: shows(.text)) { TextComposer(add: model.addText) }
        .sheet(isPresented: Binding(get: { !welcomed && model.hosts.isEmpty }, set: { if !$0 { welcomed = true } })) {
            Welcome { welcomed = true; tab = .settings }
        }
        .onChange(of: model.linking) { if model.linking { welcomed = true } }
        .photosPicker(isPresented: shows(.photos), selection: $photos, maxSelectionCount: 20,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photos) {
            guard !photos.isEmpty else { return }
            model.addPhotos(photos)
            photos = []
        }
        .fileImporter(isPresented: shows(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addFiles(urls)
            case .failure: model.say("Couldn't open that file", .failed)
            }
        }
    }

    private func shows(_ a: Adding) -> Binding<Bool> {
        Binding(get: { adding == a }, set: { if !$0, adding == a { adding = nil } })
    }

    private var recent: some View {
        List {
            if model.hosts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Copy on your iPhone, paste on your computer, and back.").font(.headline)
                        Text("Link a Mac, Windows PC or Linux computer running ClipBubble, and what you copy there shows up here. You can already add things with Add.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { tab = .settings } label: { Text("Link a computer").font(.body.weight(.semibold)).padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(model.hosts, id: \.self) { h in HostRow(alias: h, state: model.statuses[h]) }
                }
            }
            if !model.transfers.isEmpty {
                // A first link can queue hundreds, which would push the history off the screen.
                let moving = model.transfers.sorted { ($0.value.fraction, $0.key) > ($1.value.fraction, $1.key) }
                Section {
                    ForEach(moving.prefix(3), id: \.key) { TransferRow(hash: $0.key, transfer: $0.value) }
                    if moving.count > 3 {
                        Text("and \(moving.count - 3) more").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(model.clips, id: \.hash) { c in
                    HStack(spacing: 0) {
                        Button { model.copy(c) } label: {
                            ClipRow(clip: c, device: model.devices[c.origin])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { viewing = c } label: {
                            Image(systemName: "info.circle").frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Item details")
                    }
                    .swipeActions { Button("Delete", role: .destructive) { model.delete(c) } }
                    .clipMenu(c) { viewing = c }
                }
            } header: {
                if !model.clips.isEmpty { Text("Recent") }
            }
        }
        .animation(.snappy, value: model.clips.map(\.hash))
        .overlay {
            // Before anything is linked, the card above already says what to do.
            if model.clips.isEmpty && !(model.hosts.isEmpty && model.query.isEmpty) {
                ContentUnavailableView {
                    Label {
                        Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                    } icon: {
                        Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").accessibilityHidden(true)
                    }
                } description: {
                    Text(model.query.isEmpty ? "Copy something on a linked computer, or tap Add." : "Try other words.")
                }
                .padding(.top, model.hosts.isEmpty ? 220 : 120)
            }
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search history")
        .refreshable { model.redialAll() }
        .navigationTitle("ClipBubble")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PasteButton(supportedContentTypes: [.image, .fileURL, .url, .plainText, .data]) { model.paste($0) }
                    .labelStyle(.iconOnly).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityLabel("Paste into ClipBubble")
            }
        }
        .navigationDestination(item: $viewing) { ClipDetail(clip: $0) }
        .toast(model.line)
    }
}

/// First launch: ClipBubble needs its computer half, so say so before anything else.
struct Welcome: View {
    let link: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Welcome to ClipBubble").font(.largeTitle.bold())
                    Text("Copy on your iPhone, paste on your computer, and back.").font(.title3).foregroundStyle(.secondary)
                }
                point("desktopcomputer", "Get ClipBubble for your computer",
                      "It's free for Mac, Windows and Linux at clipbubble.krnl.studio, and keeps 7 days of what you copy.")
                point("qrcode.viewfinder", "Link them once", "Open Link iPhone in ClipBubble on your computer and scan the code. They talk directly over your Wi-Fi.")
                point("keyboard", "Reuse your history", "Save items from the share sheet, or use the ClipBubble keyboard to type text in supported fields and copy images and files for pasting.")
            }
            .padding(28).padding(.top, 20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button { link(); dismiss() } label: { Text("Link a computer").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                Button("Not now") { dismiss() }.font(.body.weight(.medium))
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            .background(.background)
        }
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add: paste what's on this iPhone's clipboard, type a note, or pick photos or files.
struct AddPanel: View {
    let paste: ([NSItemProvider]) -> Void
    let pick: (HistoryView.Adding) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        VStack(spacing: 18) {
            Text("Add to ClipBubble").font(.headline)
            // The system Paste button reads the clipboard without the "Allow Paste" prompt.
            PasteButton(supportedContentTypes: [.image, .fileURL, .url, .plainText, .data]) { p in
                paste(p)
                Task { @MainActor in dismiss() }
            }
            .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.extraLarge)
            (size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                option("Text", "text.cursor", .text)
                option("Photos", "photo.on.rectangle", .photos)
                option("Files", "folder", .files)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(size.isAccessibilitySize ? [.large] : [.height(270)])
        .presentationCornerRadius(32)
    }

    private func option(_ title: String, _ symbol: String, _ a: HistoryView.Adding) -> some View {
        Button { pick(a) } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(Pressable())
    }
}

/// Items dip when touched.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// The short "Copied" line, just above the tab bar.
    func toast(_ line: Line?) -> some View {
        safeAreaInset(edge: .bottom) {
            if let line {
                Label {
                    Text(line.text)
                } icon: {
                    switch line.look {
                    case .done: Image(systemName: "checkmark.circle.fill")
                    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case .busy: ProgressView().controlSize(.small)
                    }
                }
                .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: line)
    }

    /// iOS 26 shrinks the tab bar while you scroll down a list.
    @ViewBuilder func minimizesOnScroll() -> some View {
        if #available(iOS 26, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
}

/// Type or paste a note to add to the history.
struct TextComposer: View {
    let add: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal, 12)
                .navigationTitle("New text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            if add(text) { dismiss() } else { saveFailed = true }
                        }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
                .alert("Couldn't add that text", isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(text.utf8.count > Sync.maxText ? "This text is too long. Shorten it and try again." : "Try saving your draft again.")
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A photo or video copied somewhere that outlives the picker.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: received.file, to: dest)
                return PickedFile(url: dest)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }
    }
}

struct HostRow: View {
    let alias: String
    let state: LinkState?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.title3).foregroundStyle(.secondary).frame(minWidth: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Group {
                    if case .offline? = state {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in Text(subtitle) }
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if stuck { Button("Retry") { SyncEngine.shared.redial(alias) }.buttonStyle(.borderless).font(.caption) }
            Circle().fill(state?.ok == true ? Color.green : Color.orange).frame(width: 8, height: 8).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .onChange(of: state) { if case .live(let h) = state { Self.remember(h.name, for: alias) } }
    }

    private var subtitle: String {
        if case .live? = state { return "Linked" }
        return state?.phoneText ?? "Connecting…"
    }

    private var stuck: Bool {
        switch state {
        case nil, .connecting?, .live?: return false
        default: return true
        }
    }

    private var name: String {
        if case .live(let h) = state { return h.name }
        return Platform.defaults.string(forKey: "sync.name.\(alias)") ?? alias.split(separator: "@").last.map(String.init) ?? alias
    }

    /// The computer's own name, shown while it's offline instead of its address.
    static func remember(_ name: String, for alias: String) { Platform.defaults.set(name, forKey: "sync.name.\(alias)") }
}

struct ClipRow: View {
    let clip: Clip
    let device: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .frame(width: 30, height: 30).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                if let p = clip.imagePath, !clip.remote {
                    // The frame sets the size and the image fills it, so a wide screenshot can't push the row out.
                    Color.clear.frame(height: 150).frame(maxWidth: .infinity)
                        .overlay { Thumb(p, pixels: 900).scaledToFill() }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(clip.kind == "file" ? clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                         : clip.kind == "image" ? "Image" : clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body).lineLimit(3)
                }
                Text([device ?? clip.source, clip.created.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.spoken)
        .accessibilityValue([device ?? clip.source, clip.created.formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(clip.remote ? "Gets it from the computer" : "Copies it")
    }

    private var icon: String { clip.remote ? "icloud.and.arrow.down" : clip.look.symbol }
    private var color: Color { clip.remote ? .teal : clip.look.tint }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var confirmClear = false
    @State private var removing: String?
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            Form {
                // What's linked comes first: it's what you check most often.
                if !model.hosts.isEmpty {
                    Section {
                        ForEach(model.hosts, id: \.self) { h in HostRow(alias: h, state: model.statuses[h]) }
                            .onDelete { removing = $0.first.map { model.hosts[$0] } }
                    } header: { Text("Computers") } footer: {
                        Text("Swipe left on a computer to remove it.")
                    }
                }

                Section {
                    step(1, "On your computer, open ClipBubble → Devices (or Settings on Windows/Linux) → Sync over SSH → Link iPhone…")
                    step(2, DataScannerViewController.isSupported ? "Tap Scan code below, or point this iPhone's Camera at the code."
                         : "Point this iPhone's Camera at the code.")
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan code", systemImage: "qrcode.viewfinder").font(.body.weight(.semibold)) }
                    }
                    if scanFailed {
                        Text("The camera isn't available. Allow ClipBubble to use it in the Settings app, or use the Camera app instead.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.linking {
                        Label { Text("Linking…") } icon: { ProgressView() }
                    }
                } header: { Text(model.hosts.isEmpty ? "Link a computer" : "Link another computer") } footer: {
                    Text("Don't have ClipBubble on your computer yet? It's free at clipbubble.krnl.studio.")
                }

                Section {
                    Text("In the Settings app: General → Keyboard → Keyboards → Add New Keyboard → ClipBubble. Then turn on Allow Full Access so it can reach your computers.")
                    Button("Open the Settings app") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                } header: { Text("Clipboard keyboard") } footer: {
                    Text("Your history in any app: tap an item to type it. Full Access is what lets it reach your computers; ClipBubble never records what you type.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Clear history", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Removes everything ClipBubble has kept, here and on your linked devices.")
                }

                Section {
                    NavigationLink { ManualLink() } label: { Label("Link by hand with SSH", systemImage: "terminal") }
                    Link(destination: URL(string: "https://clipbubble.krnl.studio/support")!) { Label("Help and support", systemImage: "questionmark.circle") }
                    Link(destination: URL(string: "https://clipbubble.krnl.studio/privacy")!) { Label("Privacy policy", systemImage: "hand.raised") }
                } header: { Text("More") } footer: {
                    Text("ClipBubble \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""). History stays on your devices and is deleted after 7 days.")
                }
            }
            .navigationTitle("Settings")
            .toast(model.line)
            .confirmationDialog("Clear your history here and on your linked devices?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            }
            .confirmationDialog("Stop syncing with this computer?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let removing { model.remove(removing) } }
            } message: {
                Text("To also take this iPhone's access away, unlink it in ClipBubble on the computer.")
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    Scanner(found: { url in scanning = false; model.open(url) },
                            failed: { scanning = false; scanFailed = true })
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Open Link iPhone… in ClipBubble on your computer, then point the camera at its code.")
                                .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .padding(20)
                        }
                        .navigationTitle("Scan code").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityHidden(true)
            Text(text)
        }
    }
}

/// For a computer the QR code can't reach (a server, another network): this iPhone's key goes in its authorized_keys.
struct ManualLink: View {
    @EnvironmentObject var model: Model
    @State private var alias = ""
    @State private var publicLine: String?

    var body: some View {
        Form {
            Section {
                if let publicLine {
                    Text(publicLine).font(.caption.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = publicLine; model.say("Key copied") } label: {
                        Label("Copy this iPhone's key", systemImage: "doc.on.doc")
                    }
                } else {
                    Text("This iPhone's SSH key is unavailable. Unlock the iPhone and try again.")
                    Button("Try again") { publicLine = Keys.publicLine }
                }
            } header: { Text("1. Add this key on the computer") } footer: {
                Text("Add it as a line in ~/.ssh/authorized_keys, with SSH turned on there and ClipBubble installed. A key added this way can do anything your account can, so link with the code when you can.")
            }
            Section {
                HStack {
                    TextField("you@computer.local", text: $alias)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit(add)
                    Button("Link", action: add).disabled(SSHTarget(trimmed) == nil)
                }
            } header: { Text("2. Enter its user and address") } footer: {
                Text("Most people don't need this: Link iPhone… on the computer does both steps for you.")
            }
        }
        .navigationTitle("Link by hand")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { publicLine = Keys.publicLine }
        .toast(model.line)
    }

    private var trimmed: String { alias.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard SSHTarget(trimmed) != nil else { return }
        model.add(trimmed)
        SyncEngine.shared.redial(trimmed)
        model.say("Linking with \(trimmed)…")
        alias = ""
    }
}

/// The camera, looking for a computer's pairing code.
struct Scanner: UIViewControllerRepresentable {
    let found: (URL) -> Void
    let failed: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        v.delegate = context.coordinator
        // Unavailable means the camera is denied or busy; the sheet closes and Settings says what to do.
        let denied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
        if denied || (try? v.startScanning()) == nil {
            DispatchQueue.main.async(execute: failed)
        }
        return v
    }

    func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (URL) -> Void
        private var done = false
        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                guard !done, let v = b.payloadStringValue, let url = URL(string: v), url.scheme == "clipbubble" else { continue }
                done = true
                found(url)
            }
        }
    }
}
