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

    init() { Brand.styleBars() }

    var body: some Scene {
        WindowGroup {
            HistoryView().environmentObject(model)
                .tint(Brand.tint)
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
                    model.setForeground(phase == .active)
                    model.heartbeat(phase == .active)
                    SyncEngine.shared.suspend(phase == .background)
                    if phase == .active { model.refreshSharedHistory() }
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
    @Published var showingLinkSheet = false { didSet { updateDiscovery() } }
    @Published private(set) var nearby: [DiscoveredPeer] = []
    @Published private(set) var verification: Verification?
    @Published private var pairingTask: Task<Void, Never>?
    var linking: Bool { pairingTask != nil }

    struct Verification {
        let name: String
        var code: String?
    }

    private enum PairedComputer {
        case direct(DirectPeer)
        case ssh(alias: String, name: String)
    }

    private var confirmingLink = false
    private var inForeground = false
    private var browser: DirectBrowser?
    private var demo = false
    private let db = DB()
    private var toastTask: Task<Void, Never>?
    private var shareObserver: NSObjectProtocol?

    init() {
        #if DEBUG
        // `-demo YES` (debug builds only): a linked Mac, Windows PC and Linux computer, and more nearby, without any
        // computers, for App Store screenshots.
        if UserDefaults.standard.bool(forKey: "demo") {
            let linked = [("you@macbook-pro.local", "MacBook Pro", "macos"), ("you@studio-pc", "Studio PC", "windows"),
                          ("you@dev-workstation", "Dev Workstation", "linux")]
            hosts = linked.map(\.0)
            statuses = Dictionary(uniqueKeysWithValues: linked.map { alias, name, os in
                (alias, LinkState.live(Hello(proto: 1, device: "demo-\(os)", name: name, os: os, version: "2.0.0", clock: 0)))
            })
            nearby = [DiscoveredPeer(demo: "Gaming PC", os: "windows"), DiscoveredPeer(demo: "MacBook Air", os: "macos"),
                      DiscoveredPeer(demo: "Home Server", os: "linux")]
            demo = true
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
        shareObserver = NotificationCenter.default.addObserver(forName: ShareOutbox.saved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSharedHistory() }
        }
        ShareOutbox.forwardWakeups()
        // The share sheet and the keyboard write to the same history while the app is away.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                DB().prune()
                self?.hosts = SyncEngine.enabledHosts
                self?.refreshSharedHistory()
            }
        }
    }

    deinit {
        if let shareObserver { NotificationCenter.default.removeObserver(shareObserver) }
    }

    func refreshSharedHistory() {
        reload()
        ShareSync.refresh()
        DispatchQueue.global(qos: .utility).async { ShareOutbox.recover() }
    }

    func setForeground(_ active: Bool) {
        inForeground = active
        updateDiscovery()
    }

    private func updateDiscovery() {
        if inForeground && !demo && (showingLinkSheet || !DirectPeers.all.isEmpty) {
            if browser == nil { browser = Pairing.browseNearby { [weak self] in self?.nearby = $0 } }
        } else {
            browser?.stop()
            browser = nil
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

    /// The operating system of the device an item came from: "ios" for this iPhone, nil when unknown.
    func os(of origin: String) -> String? {
        guard !origin.isEmpty else { return "ios" }
        for case .live(let h) in statuses.values where h.device == origin || h.name == devices[origin] { return h.os }
        return DirectPeers.peer(id: origin)?.os
    }

    /// Everything kept, for the Library.
    func library(query: String) -> [Clip] {
        db.clips(limit: 5000, query: query.isEmpty ? nil : query, preview: true)
    }

    func clip(_ hash: String) -> Clip? { db.clip(hash: hash) }
    func whole(_ c: Clip) -> Clip { db.whole(c) }

    func add(_ alias: String) {
        let valid: Bool
        if DirectPeers.isDirect(alias) {
            valid = DirectPeers.deviceId(from: alias).flatMap { DirectPeers.peer(id: $0) } != nil
        } else {
            valid = SSHTarget(alias) != nil
        }
        guard valid, !hosts.contains(alias) else { return }
        hosts.append(alias)
        SyncEngine.shared.setHost(alias, on: true)
    }

    func remove(_ alias: String) {
        hosts.removeAll { $0 == alias }
        if let id = DirectPeers.deviceId(from: alias) {
            Pairing.unlinkDirect(id: id)
            updateDiscovery()
            return
        }
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
        guard let route = Pairing.QRRoute(url), !linking, !confirmingLink else { return }
        switch route {
        case .direct:
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let address = items?.first(where: { $0.name == "h" })?.value?.split(separator: ",").first else {
                return Prompt.show("Link a computer", Pairing.Failure.badLink.localizedDescription)
            }
            confirmQR(address: String(address), name: items?.first(where: { $0.name == "n" })?.value) { [weak self] in
                self?.pairDirectQR(url)
            }
        case .ssh:
            guard let link = Pairing.Link(url) else {
                return Prompt.show("Link a computer", Pairing.Failure.badLink.localizedDescription)
            }
            confirmQR(address: link.hosts[0], name: link.name) { [weak self] in
                self?.beginPairing {
                    let (alias, name) = try await Pairing.pair(link)
                    return .ssh(alias: alias, name: name)
                }
            }
        }
    }

    private func confirmQR(address: String, name: String?, onConfirm: @escaping () -> Void) {
        confirmingLink = true
        let claimedName = name.map { "The code says this computer is named \($0). " } ?? ""
        Prompt.show("Link the computer at \(address)?",
                    claimedName + "Linking syncs new copies and the last 7 days of ClipBubble history between this iPhone and the computer. Only link a computer you're setting up right now.",
                    ok: "Link", cancel: "Cancel") { [weak self] yes in
            self?.confirmingLink = false
            if yes { onConfirm() }
        }
    }

    func pairNearby(_ computer: DiscoveredPeer) {
        guard !linking, !confirmingLink else { return }
        verification = Verification(name: computer.name)
        beginPairing { [weak self] in
            let engine = SyncEngine.shared
            let peer = try await DirectPairingClient.pairNearby(
                endpoint: computer.endpoint, expectedFPPrefix: computer.fingerprintPrefix,
                localIdentity: DirectIdentity.shared(deviceId: engine.device),
                deviceId: engine.device, name: engine.name, os: Platform.os
            ) { code in
                guard let self, self.pairingTask?.isCancelled == false else { return }
                self.verification?.code = code
            }
            guard peer.id == computer.id else { throw DirectPairError.invalidDevice }
            return .direct(peer)
        }
    }

    private func pairDirectQR(_ url: URL) {
        beginPairing {
            let engine = SyncEngine.shared
            let peer = try await DirectPairingClient.pairQR(
                url: url, localIdentity: DirectIdentity.shared(deviceId: engine.device),
                deviceId: engine.device, name: engine.name, os: Platform.os
            )
            return .direct(peer)
        }
    }

    func cancelPairing() { pairingTask?.cancel() }

    private func beginPairing(_ pair: @escaping @MainActor () async throws -> PairedComputer) {
        guard !linking else { return }
        pairingTask = Task {
            defer {
                pairingTask = nil
                verification = nil
            }
            do {
                let computer = try await pair()
                try Task.checkCancellation()
                let alias: String
                switch computer {
                case .direct(let peer):
                    DirectPeers.save(peer)
                    alias = DirectPeers.alias(for: peer.id)
                    add(alias)
                case .ssh(let host, let name):
                    alias = host
                    HostRow.remember(name, for: alias)
                    add(alias)
                    Pairing.olderLinks(than: alias).forEach(remove)
                }
                SyncEngine.shared.redial(alias)
                showingLinkSheet = false
                say("Linked with \(Pairing.displayName(for: alias))")
            } catch is CancellationError {
                return
            } catch DirectPairError.network(_) {
                if !Task.isCancelled {
                    Prompt.show("Link a computer", "Can't reach the computer. Make sure ClipBubble is open there.")
                }
            } catch {
                if !Task.isCancelled { Prompt.show("Link a computer", error.localizedDescription) }
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
    @State private var linkAfterWelcome = false
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
        .sheet(isPresented: Binding(get: { !welcomed && model.hosts.isEmpty }, set: { if !$0 { welcomed = true } }),
               onDismiss: {
                   if linkAfterWelcome {
                       linkAfterWelcome = false
                       model.showingLinkSheet = true
                   }
               }) {
            Welcome { linkAfterWelcome = true; tab = .settings }
        }
        .sheet(isPresented: $model.showingLinkSheet) { LinkSheet() }
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
            Group {
                if model.hosts.isEmpty {
                    LinkHero { model.showingLinkSheet = true }
                } else {
                    Computers(hosts: model.hosts, statuses: model.statuses) { model.showingLinkSheet = true }
                }
                if !model.transfers.isEmpty {
                    // A first link can queue hundreds, which would push the history off the screen.
                    let moving = model.transfers.sorted { ($0.value.fraction, $0.key) > ($1.value.fraction, $1.key) }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(moving.prefix(3), id: \.key) { TransferRow(hash: $0.key, transfer: $0.value) }
                        if moving.count > 3 {
                            Text("and \(moving.count - 3) more").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .brandCard()
                }
                if !model.clips.isEmpty {
                    Text("Recent").font(.title3.weight(.bold)).fontDesign(.rounded)
                        .padding(.top, 6).padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            ForEach(model.clips, id: \.hash) { c in
                ZStack(alignment: .topTrailing) {
                    Button { model.copy(c) } label: {
                        ClipRow(clip: c, device: model.devices[c.origin], os: model.os(of: c.origin))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { viewing = c } label: {
                        Image(systemName: "ellipsis")
                            .font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 30, height: 30).background(.thinMaterial, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(-7)
                    .accessibilityLabel("Item details")
                }
                .brandCard(padding: 14)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions { Button("Delete", role: .destructive) { model.delete(c) } }
                .clipMenu(c) { viewing = c }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.background)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Mascot(size: 26)
                    Text("ClipBubble").font(.system(.title3, design: .rounded).weight(.heavy))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                PasteButton(supportedContentTypes: [.image, .fileURL, .url, .plainText, .data]) { model.paste($0) }
                    .labelStyle(.iconOnly).buttonBorderShape(.capsule).controlSize(.small).tint(Brand.tint)
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
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    Mascot(size: 84)
                    Text("Welcome to\nClipBubble").font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Copy on your iPhone, paste on your computer, and back. Mac, Windows and Linux.")
                        .font(.title3.weight(.medium)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 12) {
                    point("arrow.down.circle.fill", Brand.sky, "Get ClipBubble for your computer",
                          "It's free for Mac, Windows and Linux at clipbubble.krnl.studio, and keeps 7 days of what you copy.")
                    point("link.circle.fill", Brand.lavender, "Link a nearby computer",
                          "Open ClipBubble on your computer, then select it on your iPhone and confirm the matching code.")
                    point("keyboard.fill", Brand.peach, "Reuse your history", "Save items from the share sheet, or use the ClipBubble keyboard to type text in supported fields and copy images and files for pasting.")
                }
            }
            .padding(24).padding(.top, 24)
        }
        .background(alignment: .top) {
            Circle().fill(Brand.sky.opacity(0.35)).frame(width: 420).blur(radius: 90).offset(x: 140, y: -200)
                .accessibilityHidden(true)
        }
        .background(Brand.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button { link(); dismiss() } label: { Text("Link a computer").frame(maxWidth: .infinity) }
                    .buttonStyle(GlowButton())
                Button("Not now") { dismiss() }.font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
            .background(Brand.background)
        }
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).fontDesign(.rounded)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .brandCard()
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
            Text("Add to ClipBubble").font(.headline).fontDesign(.rounded)
            // The system Paste button reads the clipboard without the "Allow Paste" prompt.
            PasteButton(supportedContentTypes: [.image, .fileURL, .url, .plainText, .data]) { p in
                paste(p)
                Task { @MainActor in dismiss() }
            }
            .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.extraLarge).tint(Brand.tint)
            (size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                option("Text", "text.cursor", Brand.sky, .text)
                option("Photos", "photo.on.rectangle", Brand.lavender, .photos)
                option("Files", "folder.fill", Brand.peach, .files)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(size.isAccessibilitySize ? [.large] : [.height(270)])
        .presentationCornerRadius(32)
        .presentationBackground(Brand.background)
    }

    private func option(_ title: String, _ symbol: String, _ color: Color, _ a: HistoryView.Adding) -> some View {
        Button { pick(a) } label: {
            VStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: 40, filled: true)
                Text(title).font(.subheadline.weight(.semibold)).fontDesign(.rounded).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5))
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
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.sky)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Brand.peach)
                    case .busy: ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .font(.subheadline.weight(.semibold)).fontDesign(.rounded)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Brand.ink.opacity(0.94), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
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
                .scrollContentBackground(.hidden)
                .background(Brand.background)
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

/// Before anything is linked: what ClipBubble does and the one thing to do next.
struct LinkHero: View {
    let link: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Mascot(size: 40)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer()
                HStack(spacing: 6) {
                    ForEach(["macos", "windows", "linux"], id: \.self) { os in
                        Image(systemName: ComputerOS.symbol(os)).font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32).background(.white.opacity(0.55), in: Circle())
                    }
                }
                .foregroundStyle(Brand.ink).accessibilityHidden(true)
            }
            Text("Copy on any computer.\nPaste on your iPhone.").font(.title2.weight(.heavy)).fontDesign(.rounded)
                .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            Text("Open ClipBubble on a nearby Mac, Windows or Linux computer, then link it to sync what you copy, both ways.")
                .font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: link) {
                Label("Link a computer", systemImage: "plus").font(.body.weight(.bold)).fontDesign(.rounded)
                    .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Brand.ink, in: Capsule())
            }
            .buttonStyle(Pressable())
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Brand.sky.opacity(0.35), radius: 20, y: 10)
        .padding(.vertical, 4)
    }
}

/// Linked computers as a row of cards you can scroll sideways, with a card to link another.
struct Computers: View {
    let hosts: [String]
    let statuses: [String: LinkState]
    let link: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(live > 0 ? Color.green : .orange).frame(width: 7, height: 7)
                Text(live == hosts.count ? (live == 1 ? "Syncing with 1 computer" : "Syncing with \(live) computers")
                     : "\(live) of \(hosts.count) computers online")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(hosts, id: \.self) { h in HostCard(row: HostRow(alias: h, state: statuses[h])) }
                    Button(action: link) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(Brand.ink)
                                .frame(width: 40, height: 40).background(Brand.sky, in: Circle())
                            Text("Link").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 78, height: 112)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Brand.sky, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                    }
                    .buttonStyle(Pressable())
                    .accessibilityLabel("Link a computer")
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .padding(.horizontal, -16)
        }
    }

    private var live: Int { hosts.filter { statuses[$0]?.ok == true }.count }
}

struct HostCard: View {
    let row: HostRow

    var body: some View {
        let ok = row.state?.ok == true
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: row.icon).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 40, height: 40)
                    .background(ok ? Brand.sky : Brand.butter, in: Circle())
                Spacer()
                Circle().fill(ok ? Color.green : .orange).frame(width: 8, height: 8)
                    .overlay(Circle().stroke((ok ? Color.green : .orange).opacity(0.3), lineWidth: 4))
                    .padding(6)
            }
            Spacer(minLength: 10)
            Text(row.name).font(.subheadline.weight(.bold)).fontDesign(.rounded).lineLimit(1)
            Group {
                if row.stuck {
                    Button("Retry") { SyncEngine.shared.redial(row.alias) }.font(.caption.weight(.semibold))
                } else if case .offline? = row.state {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(row.subtitle) }
                } else {
                    Text(row.subtitle)
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(width: 148, height: 112)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .onChange(of: row.state) {
            if !DirectPeers.isDirect(row.alias), case .live(let h) = row.state { HostRow.remember(h.name, for: row.alias) }
        }
    }
}

struct HostRow: View {
    let alias: String
    let state: LinkState?

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: icon, color: state?.ok == true ? Brand.sky : Brand.butter, size: 36, filled: true)
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
        .onChange(of: state) {
            if !DirectPeers.isDirect(alias), case .live(let h) = state { Self.remember(h.name, for: alias) }
        }
    }

    /// A laptop for a Mac, a PC for Windows and a desktop for Linux, as in Nearby Computers.
    var icon: String {
        var os: String?
        if case .live(let h) = state { os = h.os }
        if os == nil, DirectPeers.isDirect(alias) { os = DirectPeers.deviceId(from: alias).flatMap { DirectPeers.peer(id: $0) }?.os }
        return ComputerOS.symbol(os)
    }

    var subtitle: String {
        if case .live? = state { return "Linked" }
        return state?.phoneText(for: alias) ?? "Connecting…"
    }

    var stuck: Bool {
        switch state {
        case nil, .connecting?, .live?: return false
        default: return true
        }
    }

    var name: String {
        if case .live(let h) = state { return Pairing.displayName(for: alias, reportedName: h.name) }
        return Pairing.displayName(for: alias)
    }

    /// The computer's own name, shown while it's offline instead of its address.
    static func remember(_ name: String, for alias: String) { Platform.defaults.set(name, forKey: "sync.name.\(alias)") }
}

struct ClipRow: View {
    let clip: Clip
    let device: String?
    var os: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = clip.imagePath, !clip.remote {
                // The frame sets the size and the image fills it, so a wide screenshot can't push the row out.
                Color.clear.frame(height: 170).frame(maxWidth: .infinity)
                    .overlay { Thumb(p, pixels: 900).scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Text(clip.kind == "file" ? clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                     : clip.kind == "image" ? "Image" : clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(clip.look == .text && looksLikeCode ? .callout.monospaced() : .body.weight(.medium))
                    .foregroundStyle(clip.look == .link ? Brand.tint : .primary)
                    .lineLimit(3)
                    .padding(.trailing, 30)
            }
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(clip.remote ? "On computer" : clip.look.name)
                }
                    .font(.caption.weight(.semibold)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(pastel, in: Capsule())
                if let from = device ?? (clip.source.isEmpty ? nil : clip.source) {
                    HStack(spacing: 4) {
                        if let os, os != "ios" { Image(systemName: ComputerOS.symbol(os)) }
                        Text(from).lineLimit(1)
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(clip.created.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.spoken)
        .accessibilityValue([device ?? clip.source, clip.created.formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(clip.remote ? "Gets it from the computer" : "Copies it")
    }

    /// Commands and code read better in a fixed-width font.
    private var looksLikeCode: Bool {
        let t = clip.text.prefix(200)
        return ["git ", "npm ", "cd ", "ssh ", "sudo ", "brew ", "$ ", "{", "func ", "let ", "const ", "import "].contains { t.hasPrefix($0) }
    }

    private var icon: String { clip.remote ? "icloud.and.arrow.down" : clip.look.symbol }
    private var pastel: Color { clip.remote ? Brand.mint : clip.look.pastel }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @State private var confirmClear = false
    @State private var removing: String?
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Mascot(size: 40)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ClipBubble").font(.title3.weight(.heavy)).fontDesign(.rounded).foregroundStyle(Brand.ink)
                            Text(model.hosts.isEmpty ? "No computers linked yet"
                                 : model.hosts.count == 1 ? "Syncing with 1 computer" : "Syncing with \(model.hosts.count) computers")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Brand.gradient)

                // What's linked comes first: it's what you check most often.
                if !model.hosts.isEmpty {
                    Section {
                        ForEach(model.hosts, id: \.self) { h in HostRow(alias: h, state: model.statuses[h]) }
                            .onDelete { removing = $0.first.map { model.hosts[$0] } }
                    } header: { Text("Computers") } footer: {
                        Text("Swipe left on a computer to remove it.")
                    }
                    .listRowBackground(Brand.card)
                }

                Section {
                    Button { model.showingLinkSheet = true } label: {
                        Label { Text("Link a computer").foregroundStyle(.primary) } icon: { IconTile(symbol: "plus", color: Brand.sky, filled: true) }
                    }
                } footer: {
                    Text("Link a nearby Mac, Windows or Linux computer running ClipBubble. Get the free app at clipbubble.krnl.studio.")
                }
                .listRowBackground(Brand.card)

                Section {
                    Label { Text("In the Settings app: General → Keyboard → Keyboards → Add New Keyboard → ClipBubble. Then turn on Allow Full Access so it can reach your computers.") }
                        icon: { IconTile(symbol: "keyboard.fill", color: Brand.peach, filled: true) }
                    Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                        Label { Text("Open the Settings app").foregroundStyle(.primary) } icon: { IconTile(symbol: "gearshape.fill", color: Brand.cloud, filled: true) }
                    }
                } header: { Text("Clipboard keyboard") } footer: {
                    Text("Your history in any app: tap an item to type it. Full Access is what lets it reach your computers; ClipBubble never records what you type.")
                }
                .listRowBackground(Brand.card)

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Brand.card)

                Section {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label { Text("Clear history") } icon: { IconTile(symbol: "trash.fill", color: Brand.rose, filled: true) }
                    }
                } footer: {
                    Text("Removes everything ClipBubble has kept, here and on your linked devices.")
                }
                .listRowBackground(Brand.card)

                Section {
                    Link(destination: URL(string: "https://clipbubble.krnl.studio/support")!) {
                        Label { Text("Help and support").foregroundStyle(.primary) } icon: { IconTile(symbol: "questionmark", color: Brand.lavender, filled: true) }
                    }
                    Link(destination: URL(string: "https://clipbubble.krnl.studio/privacy")!) {
                        Label { Text("Privacy policy").foregroundStyle(.primary) } icon: { IconTile(symbol: "hand.raised.fill", color: Brand.mint, filled: true) }
                    }
                } header: { Text("More") } footer: {
                    Text("ClipBubble \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""). History stays on your devices and is deleted after 7 days.")
                }
                .listRowBackground(Brand.card)
            }
            .brandForm()
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
        }
    }
}

struct LinkSheet: View {
    @EnvironmentObject private var model: Model
    @State private var scanning = false
    @State private var scanFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let verification = model.verification {
                        verificationCard(verification)
                    } else if model.linking {
                        HStack {
                            ProgressView()
                            Text("Linking…")
                            Spacer()
                            Button("Cancel", action: model.cancelPairing).buttonStyle(.borderless)
                        }
                    } else {
                        let computers = model.nearby.filter { $0.os != "ios" }
                        if computers.isEmpty {
                            Searching()
                        }
                        ForEach(computers) { computer in
                            computerRow(computer)
                        }
                    }
                } header: {
                    Text("Nearby Computers")
                } footer: {
                    if !model.linking {
                        Text("Open ClipBubble on your Mac, Windows or Linux computer. Linking syncs new copies and the last 7 days of ClipBubble history between your devices.")
                    }
                }
                .listRowBackground(Brand.card)

                Section {
                    Button {
                        scanFailed = !DataScannerViewController.isSupported
                        scanning = !scanFailed
                    } label: {
                        Label { Text("Scan QR Code").foregroundStyle(.primary) } icon: { IconTile(symbol: "qrcode.viewfinder", color: Brand.sky, filled: true) }
                    }
                    if scanFailed {
                        Text("Use the Camera app to scan the code, or allow camera access for ClipBubble in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Brand.card)
                .disabled(model.linking)

                Section {
                    DisclosureGroup("Advanced (SSH)") {
                        NavigationLink { ManualLink() } label: {
                            Label("Enter a user and address", systemImage: "terminal")
                        }
                    }
                }
                .listRowBackground(Brand.card)
                .disabled(model.linking)
            }
            .brandForm()
            .navigationTitle("Link a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.linking {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.showingLinkSheet = false }
                    }
                }
            }
            .sheet(isPresented: $scanning) { scanner }
        }
        .interactiveDismissDisabled(model.linking)
    }

    private func computerRow(_ computer: DiscoveredPeer) -> some View {
        let alias = DirectPeers.alias(for: computer.id)
        let linked = model.statuses[alias]?.ok == true
        return HStack(spacing: 12) {
            Image(systemName: ComputerOS.symbol(computer.os))
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.ink)
                .frame(width: 44, height: 44)
                .background(Brand.sky, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(computer.name).font(.body.weight(.semibold)).fontDesign(.rounded)
                Text(ComputerOS.name(computer.os))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Brand.wash, in: Capsule())
            }
            Spacer()
            if linked {
                Label("Linked", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else {
                Button("Link") { model.pairNearby(computer) }
                    .font(.subheadline.weight(.bold)).fontDesign(.rounded).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Brand.sky, in: Capsule())
                    .buttonStyle(Pressable())
                    .accessibilityLabel("Link \(computer.name)")
            }
        }
        .padding(.vertical, 6)
    }

    private func verificationCard(_ verification: Model.Verification) -> some View {
        VStack(spacing: 12) {
            if let code = verification.code {
                Text("Confirm this code on \(verification.name)").font(.headline)
                Text(code)
                    .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Brand.tint)
                    .accessibilityLabel(code.filter(\.isNumber).map(String.init).joined(separator: " "))
                Text("Tap Allow on your computer.").foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Connecting to \(verification.name)…").font(.headline)
            }
            Button("Cancel", action: model.cancelPairing).buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var scanner: some View {
        NavigationStack {
            Scanner(found: { url in scanning = false; model.open(url) },
                    failed: { scanning = false; scanFailed = true })
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Text("Point the camera at the pairing code shown in ClipBubble on your computer.")
                        .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .padding(20)
                }
                .navigationTitle("Scan QR Code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
        }
    }
}

/// While nothing nearby has shown up: the mascot with rings rippling out from it.
struct Searching: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(Brand.sky, lineWidth: 1.5)
                        .scaleEffect(on ? 2.2 : 0.7).opacity(on ? 0 : 0.9)
                        .animation(still ? nil : .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: on)
                }
                Mascot(size: 52, ring: false)
            }
            .frame(width: 52, height: 52).frame(height: 110)
            Text("Looking for nearby computers…").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear { on = true }
        .accessibilityElement(children: .combine)
    }
}

/// For a computer the QR code can't reach (a server, another network), add this iPhone's SSH key.
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
            } header: { Text("2. Enter its user and address") }
        }
        .brandForm()
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
                guard !done, let v = b.payloadStringValue, let url = URL(string: v), Pairing.QRRoute(url) != nil else { continue }
                done = true
                found(url)
            }
        }
    }
}
