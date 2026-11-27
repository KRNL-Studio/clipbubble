import AppKit
import SwiftUI

/// Settings → Sync over SSH: computers linked with Add a computer, then one switch per host in ~/.ssh/config, each with
/// its live status and the one action that fixes what's wrong.
struct SyncSettings: View {
    @ObservedObject var model: Model
    @State private var configHosts: [String] = []
    @State private var peers: [Peer] = Peers.all
    @State private var enabled = Set(SyncEngine.enabledHosts)
    @State private var setup: [String: String] = [:]   // progress or result text per host
    @State private var installing: Set<String> = []
    @State private var adding = false
    @State private var relink: Peer?
    @State private var checking: String?

    private var hosts: [String] { peers.map(\.alias) + configHosts.filter { h in !peers.contains { $0.alias == h } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Copy on one machine, paste on another. Works with ClipBubble on your other Macs, Linux and Windows machines, and your iPhone.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            PhonePairing()
            HStack(spacing: 10) {
                SettingIcon(symbol: "desktopcomputer", tint: .green)
                Text("Another computer").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Button(adding ? "Cancel" : "Add a computer…") { relink = nil; adding.toggle() }.controlSize(.small)
            }
            .padding(.vertical, 5)
            if adding {
                AddComputer(relinking: relink, taken: configHosts) { peer, start in
                    adding = false
                    relink = nil
                    peers = Peers.all
                    if start { enabled.insert(peer.alias); SyncEngine.shared.setHost(peer.alias, on: true) }
                    SyncEngine.shared.redial(peer.alias)
                }
                .padding(.leading, 34).padding(.bottom, 6)
            }
            ForEach(hosts, id: \.self) { host in hostRow(host) }
            if hosts.isEmpty {
                Text("Computers you add show up here, along with any hosts in ~/.ssh/config.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !enabled.isEmpty {
                HStack(spacing: 10) {
                    SettingIcon(symbol: "pause.circle", tint: .green)
                    Text("Pause sync").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.syncPaused }, set: { model.syncPaused = $0; SyncEngine.shared.setPaused($0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                .padding(.vertical, 5)
            }
            Text("This Mac shows up as \(SyncEngine.shared.name). Files up to 25 MB move on their own. Password-manager copies never leave this Mac.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            if let id = HostIdentity.mine {
                Text("This Mac's identity: \(id)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled).padding(.top, 2)
            }
        }
        .onAppear { configHosts = SSHConfig.hosts(); peers = Peers.all }
    }

    private func hostRow(_ host: String) -> some View {
        let peer = peers.first { $0.alias == host }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                SettingIcon(symbol: peer == nil ? "server.rack" : "desktopcomputer", tint: .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer?.name ?? host).font(.system(size: 13, weight: .medium))
                    if enabled.contains(host) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let state = model.syncPaused ? nil : model.links[host]
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Circle().fill(state?.ok == true ? Color.green : state == nil ? Color.gray : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text(model.syncPaused ? "Paused" : state?.text ?? "Connecting…").fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else if let peer {
                        Text("Off. Connects as \(peer.user)@\(peer.host)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if let note = setup[host] {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if enabled.contains(host), !model.syncPaused { action(host, peer: peer, state: model.links[host]) }
                Toggle("", isOn: Binding(get: { enabled.contains(host) }, set: { on in
                    if on { enabled.insert(host) } else { enabled.remove(host) }
                    SyncEngine.shared.setHost(host, on: on)
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if checking == host {
                IdentityCheck(alias: host, peer: peer) { trusted in
                    checking = nil
                    peers = Peers.all
                    if trusted { SyncEngine.shared.redial(host) }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let peer {
                Button("Link again…") { relink = peer; adding = true }
                Button("Remove \(peer.name)") {
                    SyncEngine.shared.setHost(peer.alias, on: false)
                    enabled.remove(peer.alias)
                    Peers.remove(peer.alias)
                    peers = Peers.all
                }
            }
        }
    }

    /// The one button that fixes what's wrong, if there's something to press.
    @ViewBuilder private func action(_ host: String, peer: Peer?, state: LinkState?) -> some View {
        switch state {
        case .notInstalled?:
            Button("Set up") { install(host) }.controlSize(.small).disabled(installing.contains(host))
        case .versionMismatch(let h)? where h.os == "linux":
            Button("Update") { install(host) }.controlSize(.small).disabled(installing.contains(host))
        case .live(let h)? where RemoteSetup.isOutdated(h):
            Button("Update") { install(host) }.controlSize(.small).disabled(installing.contains(host))
        case .unknownHost?:
            Button("Check identity…") { checking = host }.controlSize(.small)
        case .hostKeyChanged?, .needsKeyAuth?:
            if let peer { Button("Link again…") { relink = peer; adding = true }.controlSize(.small) }
            else { Button("Try again") { SyncEngine.shared.redial(host) }.controlSize(.small) }
        case .unresolved?, .refused?, .appNotRunning?:
            Button("Try again") { SyncEngine.shared.redial(host) }.controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func install(_ host: String) {
        installing.insert(host)
        RemoteSetup.run(host, progress: { setup[host] = $0 }, done: { r in
            installing.remove(host)
            setup[host] = r.text
            if case .otherOS = r { NSWorkspace.shared.open(RemoteSetup.releases) }
            SyncEngine.shared.redial(host)
        })
    }
}

/// Add a computer: type the address and code the other computer shows, check who answered, then choose to sync.
struct AddComputer: View {
    /// Linking a computer again keeps its name in ClipBubble, and replaces its key only because you asked.
    let relinking: Peer?
    let taken: [String]
    let done: (Peer, Bool) -> Void
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var found: Peer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let found {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to link with \(found.name)").font(.system(size: 12, weight: .semibold))
                    detail("Connects as \(found.summary).")
                    if let id = fingerprint(found.hostKey) {
                        detail("Its identity is \(id). It should match the one in ClipBubble's settings on \(found.name).")
                    } else {
                        detail("It didn't send its identity, so you'll be asked to check it the first time it connects.")
                    }
                    detail("That key can only run ClipBubble there: no shell, no files, no forwarding.")
                    detail("Syncing shares what you copy, plus screenshots and downloads if they're on above. Nothing syncs until you start it.")
                }
                HStack {
                    Button("Start syncing") { finish(found, start: true) }.keyboardShortcut(.defaultAction)
                    Button("Not now") { finish(found, start: false) }
                }
                .controlSize(.small)
            } else {
                detail(relinking.map { "On \($0.name), open ClipBubble → Settings → Sync over SSH → Link iPhone…, then enter what it shows." }
                       ?? "On the other computer, open ClipBubble → Settings → Sync over SSH → Link iPhone…, then enter what it shows. On Linux without a desktop, run clipbubble --pair there.")
                HStack(spacing: 6) {
                    TextField("Address, like rohits-mac.local", text: $address).frame(minWidth: 170)
                    TextField("Code", text: $code).frame(width: 96)
                    Button(busy ? "Linking…" : "Link") { link() }
                        .disabled(busy || LinkClient.target(address: address, code: code) == nil)
                }
                .textFieldStyle(.roundedBorder).controlSize(.small)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                detail("This uses ClipBubble's own key, \(Peers.keyDisplay), and leaves ~/.ssh/config alone. Only the public half is sent.")
            }
        }
        .onAppear { if let relinking { address = relinking.host } }
    }

    private func detail(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func link() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let (host, a) = try await LinkClient.link(address: address, code: code)
                let alias = relinking?.alias ?? Peers.freeAlias(for: a.name, taken: taken)
                found = Peer(alias: alias, name: a.name, user: a.user, host: host, hostKey: a.hostKey)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func finish(_ p: Peer, start: Bool) {
        Peers.save(p)
        SyncLog.write("linked \(p.alias) as \(p.user)@\(p.host)")
        done(p, start)
    }
}

/// Unknown host: shows the identity its SSH server presents, to compare with what that computer shows, before trusting it.
struct IdentityCheck: View {
    let alias: String
    let peer: Peer?
    let done: (Bool) -> Void
    @State private var scanned: (entry: String, key: String)?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scanned, let id = fingerprint(scanned.key) {
                Text("It says its identity is").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("On that computer, ClipBubble shows its identity under Settings → Sync over SSH. Trust it only if they match.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("They match, trust it") { trust(scanned) }
                    Button("Cancel") { done(false) }
                }
                .controlSize(.small)
            } else if failed {
                Text("Couldn't ask it for its identity. Check that it's on and reachable, then try again.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Close") { done(false) }.controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let result = await Task.detached { [alias, peer] in
                peer.map { HostIdentity.scan(host: $0.host) } ?? HostIdentity.scan(alias)
            }.value
            if let result { scanned = result } else { failed = true }
        }
    }

    private func trust(_ s: (entry: String, key: String)) {
        if var p = peer {
            p.hostKey = s.key
            Peers.save(p)
        } else {
            do { try HostIdentity.trust(s.entry) } catch { failed = true; scanned = nil; return }
        }
        done(true)
    }
}

/// Settings → Sync over SSH → iPhone: shows a QR code for the ClipBubble iPhone app to scan, and the address and code
/// another computer types into Add a computer.
struct PhonePairing: View {
    @EnvironmentObject private var nav: AppNav
    @State private var server: PairingServer?
    @State private var qr: NSImage?
    @State private var note: String?
    @State private var phones: [(name: String, key: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SettingIcon(symbol: "iphone", tint: .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone").font(.system(size: 13, weight: .medium))
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Button(server == nil ? "Link iPhone…" : "Done") { server == nil ? start() : stop() }.controlSize(.small)
            }
            if let qr, let server {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                    .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8)).padding(.leading, 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Linking another computer instead? In its Add a computer…, enter")
                    HStack(spacing: 14) {
                        Text(server.typedAddress).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text(LinkCode.display(server.shortCode)).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 34)
            }
            ForEach(phones, id: \.key) { p in
                HStack {
                    Text(p.name).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 34)
                    Spacer(minLength: 8)
                    Button("Unlink") { unlink(p.key) }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 5)
        .onAppear { phones = AuthorizedKeys.phones() }
        .onReceive(nav.windowVisibility) { if !$0 { stop() } }
        .onDisappear(perform: stop)
    }

    private func unlink(_ key: String) {
        do {
            try AuthorizedKeys.remove(key: key)
            SyncEngine.shared.dropPhones()
            phones = AuthorizedKeys.phones()
        } catch {
            note = "Couldn't unlink it: \(error.localizedDescription)"
        }
    }

    private func start() {
        guard PairingServer.remoteLoginOn() else {
            note = "Turn on Remote Login first, in System Settings → General → Sharing."
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
            return
        }
        let s = PairingServer()
        s.onReady = { qr = PairingServer.qr($0); note = "Scan with the iPhone's Camera, or in ClipBubble on the iPhone. Same Wi-Fi as this Mac." }
        s.onPaired = { name in qr = nil; server = nil; phones = AuthorizedKeys.phones(); note = "Linked \(name). It syncs whenever ClipBubble is open there." }
        s.onGaveUp = { qr = nil; server = nil; note = "Too many wrong codes, so linking stopped. Press Link iPhone… for a new code." }
        server = s
        s.start()
    }

    private func stop() {
        server?.stop()
        server = nil
        qr = nil
    }
}

/// Click, then press the new shortcut. Esc cancels.

// MARK: - Building blocks

/// A page in the ClipBubble window: a big title and a line on what it's for, then its cards.
struct SettingsPage<Content: View>: View {
    let page: AppPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    SettingIcon(symbol: page.symbol, tint: page.tint, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title).font(.system(size: 22, weight: .bold))
                        Text(page.blurb).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
                content()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// A rounded group of settings with an optional heading and note, like a section in System Settings.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// A white symbol on a colored rounded square.
struct SettingIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom)))
    }
}

/// Icon, title and an optional line under it, with a control on the right.
struct SettingRow<Trailing: View>: View {
    let icon: String
    var tint: Color = .gray
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            SettingIcon(symbol: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 6)
    }
}

struct ToggleRow: View {
    let icon: String
    var tint: Color = .gray
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, tint: tint, title: title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// A feature that needs a folder or a permission: its switch, where it looks, and whether macOS lets it.
struct PermissionRow<Extra: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let folder: URL?
    let note: String?
    let ok: Bool?
    @Binding var isOn: Bool
    let fix: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingIcon(symbol: icon, tint: tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let folder {
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 6) {
                    switch ok {
                    case .some(true): Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false):
                        Label("No access", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Fix", action: fix).buttonStyle(.link)
                    case .none:
                        if isOn { Text("Checking…").foregroundStyle(.secondary) }
                        else { Label("Off", systemImage: "minus.circle").foregroundStyle(.tertiary) }
                    }
                }
                .font(.system(size: 11, weight: .medium)).labelStyle(.titleAndIcon)
                extra()
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.vertical, 6)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 34) }
}

/// Open panels, alerts and the like, as sheets on the ClipBubble window when it's open.
enum Dialogs {
    static var window: NSWindow? { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) } }

    static func open(_ panel: NSOpenPanel, done: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { r in if r == .OK, let url = panel.url { done(url) } }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: finish) } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(panel.runModal())
        }
    }

    static func confirm(_ title: String, _ info: String, ok: String, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        if let w = window {
            alert.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { done() } }
        } else if alert.runModal() == .alertFirstButtonReturn { done() }
    }

    static func show(_ error: Error) {
        let alert = NSAlert(error: error)
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }
}

/// Refreshes Accessibility status while Capture settings are visible. Folder status comes from the watchers.
final class Access: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { timer?.invalidate() }

    func refresh() {
        guard timer != nil, NSApp.isActive else { return }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
    }

    static func openFilesSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Pages

struct GeneralPage: View {
    @ObservedObject var model: Model
    @EnvironmentObject private var nav: AppNav
    @State private var openAtLogin = LoginItem.on
    @State private var loginNote: String?

    var body: some View {
        SettingsPage(page: .general) {
            SettingsCard(title: "Bubble") {
                ToggleRow(icon: "eye.slash", tint: .indigo, title: "Hide bubble until needed",
                          detail: "Shows up when you copy something or press \(model.bubbleShortcut.label).", isOn: $model.hideBubble)
                if model.hideBubble {
                    RowDivider()
                    SettingRow(icon: "keyboard", tint: .indigo, title: "Show or hide bubble", detail: model.shortcutNote) { ShortcutBox(model: model) }
                }
                RowDivider()
                SettingRow(icon: "command", tint: .indigo, title: "Open your history", detail: "Anywhere, then type to search and press ↩ to paste.") {
                    Text(Shortcut.panel.label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                }
            }
            SettingsCard(title: "App") {
                UpdateRow(updater: Updater.shared)
                RowDivider()
                ToggleRow(icon: "power", tint: .green, title: "Open at login", detail: loginNote, isOn: $openAtLogin)
                RowDivider()
                SettingRow(icon: "wand.and.stars", tint: .indigo, title: "ClipBubble setup") {
                    Button("Run setup…") { nav.runSetup() }
                }
            }
            SettingsCard(title: "History", footer: "Clearing removes every saved item and image, here and on your linked devices. It can't be undone.") {
                SettingRow(icon: "trash", tint: .red, title: "Clear all history") {
                    Button("Clear…") {
                        Dialogs.confirm("Clear all clipboard history?",
                                        "This removes every saved item and image, here and on your linked devices. It can't be undone.",
                                        ok: "Clear") { model.db.deleteAll(); model.reload(); model.reloadRecent(); model.historyChanged() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Quit ClipBubble") { NSApp.terminate(nil) }.controlSize(.regular)
            }
        }
        .onChange(of: openAtLogin) { _, on in loginNote = LoginItem.set(on) }
    }
}

struct CapturePage: View {
    @ObservedObject var model: Model
    @EnvironmentObject private var nav: AppNav
    @StateObject private var access = Access()
    @State private var autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true

    var body: some View {
        SettingsPage(page: .capture) {
            SettingsCard(title: "Save to history", footer: "Turning one off stops saving it and hides what's already there, for your agents too.") {
                let kinds = Prefs.categories.filter { !["screenshots", "downloads"].contains($0.key) }
                ForEach(Array(kinds.enumerated()), id: \.element.key) { i, c in
                    if i > 0 { RowDivider() }
                    ToggleRow(icon: c.icon, tint: .blue, title: c.title, detail: c.detail, isOn: model.pref(c.key))
                }
            }
            SettingsCard(title: "Permissions",
                         footer: "macOS doesn't let apps change these themselves. Switching one on asks for access; if it was blocked, Fix opens the right page in System Settings.") {
                PermissionRow(icon: "arrow.down.circle", tint: .teal, title: "Recent downloads", folder: FolderWatcher.downloadsFolder,
                              note: "New files in your Downloads folder", ok: model.folderAccess[.downloads], isOn: model.pref("downloads"),
                              fix: Access.openFilesSettings) { EmptyView() }
                RowDivider()
                PermissionRow(icon: "return", tint: .orange, title: "Auto-paste", folder: nil, note: autoPasteNote,
                              ok: autoPaste ? access.accessibility : nil, isOn: $autoPaste, fix: Access.openAccessibilitySettings) { EmptyView() }
            }
        }
        .onReceive(nav.windowVisibility) { $0 ? access.start() : access.stop() }
        .onDisappear { access.stop() }
        .onChange(of: autoPaste) { _, on in
            UserDefaults.standard.set(on, forKey: "autoPaste")
            if on && !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            access.refresh()
        }
    }

    /// macOS keeps a grant for each signature: an entry left by an older copy stays switched on but no longer counts.
    private var autoPasteNote: String {
        let what = "↩ pastes into the app you were in. Needs Accessibility access."
        guard autoPaste, access.accessibility == false else { return what }
        return what + " If ClipBubble is already switched on there, that's an older copy: select it, remove it with −, then switch Auto-paste off and on here."
    }
}

private extension Model {
    func pref(_ key: String) -> Binding<Bool> {
        Binding(get: { _ = self.prefsTick; return Prefs.on(key) }, set: { self.setPref(key, $0) })
    }
}

struct ScreenshotsPage: View {
    @ObservedObject var model: Model
    @EnvironmentObject private var nav: AppNav
    @State private var copyShots = UserDefaults.standard.bool(forKey: "copyScreenshots")
    @State private var polishCard = UserDefaults.standard.bool(forKey: "polishCard")
    @AppStorage(Screencapture.replacementKey) private var replaceThumbnail = true
    @State private var export1x = UserDefaults.standard.bool(forKey: "polish.export1x")
    @State private var polishFolder = UserDefaults.standard.string(forKey: "polish.folder") ?? ""
    @State private var startStyle = PolishPreset.all.first { $0.style == PolishPreset.last }?.name ?? ""
    private var customFolder: Bool { _ = model.prefsTick; return !(UserDefaults.standard.string(forKey: "screenshotFolder") ?? "").isEmpty }

    var body: some View {
        SettingsPage(page: .screenshots) {
            SettingsCard(title: "Screenshots") {
                PermissionRow(icon: "camera.viewfinder", tint: .pink, title: "Save every screenshot", folder: FolderWatcher.screenshotFolder,
                              note: customFolder ? "Folder you picked" : "From your macOS screenshot setting",
                              ok: model.folderAccess[.screenshots], isOn: model.pref("screenshots"), fix: Access.openFilesSettings) {
                    HStack(spacing: 12) {
                        Button("Change folder…", action: pickFolder)
                        if customFolder {
                            Button("Use macOS setting") {
                                UserDefaults.standard.removeObject(forKey: "screenshotFolder")
                                model.setPref("screenshots", true)
                            }
                        }
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
                RowDivider()
                ToggleRow(icon: "doc.on.clipboard", tint: .pink, title: "Also copy new ones to the clipboard",
                          detail: "Ready to paste the moment you take one.", isOn: $copyShots)
            }
            SettingsCard(title: "Polish", footer: "Polish copies an image using your starting style and export scale. Choose Edit to mark it up or hide private details in the editor.") {
                ToggleRow(icon: "sparkles", tint: .purple, title: "Offer to polish new screenshots",
                          detail: "A card with Polish and Copy slides out by the bubble for a few seconds.", isOn: $polishCard)
                RowDivider()
                ToggleRow(icon: "photo.on.rectangle", tint: .purple, title: "Replace macOS screenshot preview",
                          detail: "Turns off the floating thumbnail so ClipBubble’s preview appears right away.",
                          isOn: Binding(get: { replaceThumbnail }, set: setThumbnailReplacement))
                RowDivider()
                SettingRow(icon: "paintpalette", tint: .purple, title: "Starting style",
                           detail: "The editor remembers the last style you used, starting from this one.") {
                    Picker("", selection: $startStyle) {
                        if startStyle.isEmpty { Text("Last used").tag("") }
                        ForEach(PolishPreset.all) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow(icon: "folder", tint: .blue, title: "Save polished copies",
                           detail: polishFolder.isEmpty ? "Next to the original" : (polishFolder as NSString).abbreviatingWithTildeInPath) {
                    HStack(spacing: 10) {
                        if !polishFolder.isEmpty { Button("Next to Original") { polishFolder = "" }.buttonStyle(.link) }
                        Button("Change…", action: pickPolishFolder).controlSize(.small)
                    }
                    .font(.system(size: 11))
                }
                RowDivider()
                ToggleRow(icon: "arrow.down.right.and.arrow.up.left", tint: .gray, title: "Export at 1×",
                          detail: "Half the pixels of a Retina screenshot: smaller files that upload faster, a little softer up close.", isOn: $export1x)
            }
            if model.showsScreenshotThumbnail {
                SettingsCard(footer: "macOS waits for the floating thumbnail to close before saving the screenshot. Preview replacement requires Save every screenshot and Offer to polish new screenshots.") {
                    SettingRow(icon: "timer", tint: .yellow, title: "Screenshots arrive a few seconds late") {
                        HStack {
                            if Prefs.on("screenshots") && polishCard {
                                Button("Replace Preview") { setThumbnailReplacement(true) }
                            }
                            Button("Open Screenshot") { Screencapture.openApp() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(nav.windowVisibility) { visible in
            if visible { model.screenshotThumbnailChanged(false) }
        }
        .onChange(of: copyShots) { _, on in UserDefaults.standard.set(on, forKey: "copyScreenshots") }
        .onChange(of: polishCard) { _, on in
            UserDefaults.standard.set(on, forKey: "polishCard")
            model.screenshotThumbnailChanged(false)
        }
        .onChange(of: export1x) { _, on in UserDefaults.standard.set(on, forKey: "polish.export1x") }
        .onChange(of: polishFolder) { _, p in UserDefaults.standard.set(p, forKey: "polish.folder") }
        .onChange(of: startStyle) { _, name in
            if let p = PolishPreset.all.first(where: { $0.name == name }) { PolishPreset.last = p.style }
        }
    }

    private func setThumbnailReplacement(_ on: Bool) {
        replaceThumbnail = on
        model.screenshotThumbnailChanged(on)
    }

    private func pickPolishFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.message = "Pick where polished copies are saved."
        Dialogs.open(open) { url in polishFolder = url.path }
    }

    private func pickFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = FolderWatcher.screenshotFolder
        open.message = "Pick the folder ClipBubble should watch for screenshots."
        Dialogs.open(open) { url in
            UserDefaults.standard.set(url.path, forKey: "screenshotFolder")
            model.setPref("screenshots", true)
        }
    }
}

protocol ScreenshotThumbnailDefaults {
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func synchronize() -> Bool
}

extension UserDefaults: ScreenshotThumbnailDefaults {}

/// Temporarily replaces the floating thumbnail and records the exact value to restore after a quit or crash.
final class Screencapture {
    static let replacementKey = "replaceMacOSScreenshotThumbnail"
    private static let priorKey = "screenshotThumbnailPriorValue"
    private static let domain = "com.apple.screencapture" as CFString
    private static let key = "show-thumbnail" as CFString
    private enum Prior: String { case enabled, unset }
    private enum ReadError: Error { case syncFailed }

    private let defaults: ScreenshotThumbnailDefaults
    private let readThumbnail: () throws -> Bool?
    private let writeThumbnail: (Bool?) -> Bool
    private var wasSuppressed = false
    private(set) var showsThumbnail = true

    init(defaults: ScreenshotThumbnailDefaults, readThumbnail: @escaping () throws -> Bool?, writeThumbnail: @escaping (Bool?) -> Bool) {
        self.defaults = defaults
        self.readThumbnail = readThumbnail
        self.writeThumbnail = writeThumbnail
    }

    static func system() -> Screencapture {
        Screencapture(defaults: UserDefaults.standard, readThumbnail: {
            guard CFPreferencesAppSynchronize(domain) else { throw ReadError.syncFailed }
            return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
        }, writeThumbnail: { value in
            CFPreferencesSetAppValue(key, value.map { NSNumber(value: $0) }, domain)
            return CFPreferencesAppSynchronize(domain)
        })
    }

    func sync(saveScreenshots: Bool, applyRequested: Bool = false) {
        let active = saveScreenshots && defaults.bool(forKey: "polishCard") && defaults.bool(forKey: Self.replacementKey)
        update(active: active, applyRequested: applyRequested)
    }

    func restore() { update(active: false, applyRequested: false) }

    private func update(active: Bool, applyRequested: Bool) {
        let current: Bool?
        do { current = try readThumbnail() } catch { return }
        showsThumbnail = current ?? true
        var prior = defaults.string(forKey: Self.priorKey).flatMap(Prior.init(rawValue:))
        let reenabled = showsThumbnail && (prior != nil || wasSuppressed)
        wasSuppressed = active && !showsThumbnail
        if reenabled {
            defaults.removeObject(forKey: Self.priorKey)
            prior = nil
            // Honor a change in Screenshot Options until the user explicitly asks ClipBubble to replace it again.
            if !applyRequested {
                defaults.set(false, forKey: Self.replacementKey)
                return
            }
        }

        if active && showsThumbnail {
            let original: Prior = current == nil ? .unset : .enabled
            // Persist ownership before changing the other domain so a later launch can recover it.
            defaults.set(original.rawValue, forKey: Self.priorKey)
            guard defaults.synchronize() else { defaults.removeObject(forKey: Self.priorKey); return }
            if writeThumbnail(false) { showsThumbnail = false; wasSuppressed = true }
            else { defaults.removeObject(forKey: Self.priorKey) }
        } else if !active, let prior, writeThumbnail(prior == .enabled ? true : nil) {
            defaults.removeObject(forKey: Self.priorKey)
            showsThumbnail = true
        }
    }

    static func openApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }
}

struct DevicesPage: View {
    @ObservedObject var model: Model

    var body: some View {
        SettingsPage(page: .devices) {
            SettingsCard(title: "Sync over SSH") { SyncSettings(model: model) }
        }
    }
}

struct MascotPage: View {
    @ObservedObject var model: Model

    var body: some View {
        SettingsPage(page: .mascot) {
            SettingsCard(title: "Pick one", footer: "Agents connected through MCP can design new ones for you too.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(model.mascots) { m in
                        let on = m.id == model.mascot.id
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(Color(white: 0.09))
                                MascotView(mascot: m, hover: false, pressed: false, happy: false, hoverTicks: 0, happyTicks: 0)
                                    .scaleEffect(1.05)
                            }
                            .frame(width: 60, height: 60)
                            .overlay(Circle().strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 2.5 : 1))
                            Text(m.name).font(.system(size: 11)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                        }
                        .frame(width: 72)
                        .contentShape(Rectangle())
                        .onTapGesture { Mascots.setActive(m.id); model.loadMascots() }
                    }
                    Button(action: addMascot) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 60, height: 60)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                            Text("Add your own").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(width: 72).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("A PNG, GIF or SVG")
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// Picks an image or GIF and makes it the mascot.
    private func addMascot() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.png, .gif, .jpeg, .svg, .heic, .webP]
        open.message = "Pick an image or GIF for your mascot. Square with a transparent background looks best."
        Dialogs.open(open) { url in
            do {
                let m = try Mascots.add(name: url.deletingPathExtension().lastPathComponent, kind: "image", states: ["idle": url.path])
                Mascots.setActive(m.id)
                model.loadMascots()
            } catch {
                Dialogs.show(error)
            }
        }
    }
}

struct AgentsPage: View {
    @State private var copied = false
    private let command = Bundle.main.executablePath ?? "ClipBubble"
    private let args = ["--mcp"]

    private func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        SettingsPage(page: .agents) {
            SettingsCard(footer: "Paste it into Claude Code, Codex, Cursor or another agent, and it connects itself.") {
                SettingRow(icon: "sparkles", tint: .purple, title: "Connect an agent",
                           detail: "Agents can search your history, see your screenshots, put things on your clipboard and design mascots.") {
                    Button {
                        Board.writeText(MCP.setupPrompt(binary: command), transient: true)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy setup prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            SettingsCard(title: "For your MCP config") {
                SettingRow(icon: "terminal", tint: .gray, title: "Command", detail: command) {
                    Button("Copy command") { Board.writeText(command, transient: true) }.controlSize(.small)
                }
                RowDivider()
                if let arguments = json(args) {
                    SettingRow(icon: "list.bullet", tint: .gray, title: "Args", detail: arguments) {
                        Button("Copy args") { Board.writeText(arguments, transient: true) }.controlSize(.small)
                    }
                }
                RowDivider()
                if let config = json(["mcpServers": ["clipbubble": ["command": command, "args": args]]]) {
                    SettingRow(icon: "curlybraces", tint: .gray, title: "Full JSON config") {
                        Button("Copy JSON") { Board.writeText(config, transient: true) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct AboutPage: View {
    var body: some View {
        SettingsPage(page: .about) {
            SettingsCard {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ClipBubble").font(.system(size: 17, weight: .semibold))
                        Text("Version \(Updater.current)").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Your clipboard history on every computer and your iPhone, with no account and no cloud.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
            }
            SettingsCard {
                link("globe", .blue, "Website", "https://clipbubble.krnl.studio")
                RowDivider()
                link("iphone", .blue, "ClipBubble for iPhone", "https://clipbubble.krnl.studio")
                RowDivider()
                link("questionmark.circle", .blue, "Help and support", "https://clipbubble.krnl.studio/support")
                RowDivider()
                link("hand.raised", .blue, "Privacy policy", "https://clipbubble.krnl.studio/privacy")
            }
        }
    }

    private func link(_ icon: String, _ tint: Color, _ title: String, _ url: String) -> some View {
        SettingRow(icon: icon, tint: tint, title: title) {
            Link(destination: URL(string: url)!) { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
        }
    }
}
