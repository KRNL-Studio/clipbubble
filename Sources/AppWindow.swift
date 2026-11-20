import AppKit
import Combine
import SQLite3
import SwiftUI

// MARK: - Pages

enum AppPage: String, CaseIterable, Identifiable {
    case history, general, capture, screenshots, devices, mascot, agents, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .general: return "General"
        case .capture: return "Capture"
        case .screenshots: return "Screenshots"
        case .devices: return "Devices"
        case .mascot: return "Mascot"
        case .agents: return "AI Agents"
        case .about: return "About"
        }
    }

    var blurb: String {
        switch self {
        case .history: return "Everything you copied in the last 7 days."
        case .general: return "The bubble, shortcuts, updates and your history."
        case .capture: return "What ClipBubble saves, and the access it needs."
        case .screenshots: return "Every screenshot you take, ready to paste or share."
        case .devices: return "Your other computers and your iPhone, synced over your own network."
        case .mascot: return "Who lives in the bubble."
        case .agents: return "Let AI agents use your clipboard history."
        case .about: return "ClipBubble, and where to get help."
        }
    }

    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .general: return "gearshape.fill"
        case .capture: return "tray.and.arrow.down.fill"
        case .screenshots: return "camera.viewfinder"
        case .devices: return "laptopcomputer.and.iphone"
        case .mascot: return "face.smiling.inverse"
        case .agents: return "sparkles"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .history: return .blue
        case .general: return .gray
        case .capture: return .teal
        case .screenshots: return .pink
        case .devices: return .green
        case .mascot: return .orange
        case .agents: return .purple
        case .about: return .indigo
        }
    }

    /// The sidebar groups pages under these.
    static let groups: [(String?, [AppPage])] = [
        (nil, [.history]),
        ("Settings", [.general, .capture, .screenshots, .devices]),
        ("Extras", [.mascot, .agents]),
        (nil, [.about]),
    ]
}

final class AppNav: ObservableObject {
    @Published var page: AppPage = .history
    let windowVisibility = CurrentValueSubject<Bool, Never>(false)

    var sidebarSelection: Binding<AppPage?> {
        Binding(get: { self.page }, set: { self.page = $0 ?? self.page })
    }
}

// MARK: - Window

/// The ClipBubble window: history and settings, like any other Mac app. ClipBubble stays out of the Dock otherwise.
final class AppWindow: NSObject, NSWindowDelegate {
    private static let frameName = "ClipBubbleWindow"
    let model: Model
    let nav = AppNav()
    let history: HistoryBrowser
    private(set) var window: NSWindow?

    init(model: Model) {
        self.model = model
        history = HistoryBrowser(model: model)
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ page: AppPage? = nil) {
        if let page { nav.page = page }
        if nav.page == .history { history.reload() }
        let w = window ?? make()
        Presence.opened(w)
        w.makeKeyAndOrderFront(nil)
        if !nav.windowVisibility.value { nav.windowVisibility.send(true) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// History changed somewhere: the History page follows while it's on screen.
    func historyChanged() {
        guard isVisible, nav.page == .history else { return }
        history.reload()
    }

    func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window != nil, e.window === window, nav.page == .history,
              e.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              e.charactersIgnoringModifiers?.lowercased() == "c" else { return e }
        let responder = window?.firstResponder
        if responder is NSText || responder is NSTextField { return e }
        return history.copySelected() ? nil : e
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "ClipBubble"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 500)
        w.toolbarStyle = .unified
        w.contentViewController = NSHostingController(rootView: AppRootView(model: model, nav: nav, history: history).environmentObject(nav))
        w.setContentSize(NSSize(width: 1020, height: 660))
        w.delegate = self
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        window = w
        return w
    }

    func windowWillClose(_ n: Notification) {
        cancelRecording()
        nav.windowVisibility.send(false)
        if let w = n.object as? NSWindow { Presence.closed(w) }
    }

    func windowDidResignKey(_ n: Notification) { cancelRecording() }
    func windowWillMiniaturize(_ n: Notification) { cancelRecording() }
    func windowDidDeminiaturize(_ n: Notification) {
        if nav.page == .history { history.reload() }
    }

    private func cancelRecording() {
        if model.recordingShortcut { model.recordingShortcut = false }
    }
}

/// ClipBubble shows in the Dock, with a full menu bar, only while one of its windows is open.
enum Presence {
    private static var open = Set<ObjectIdentifier>()
    static var showing: Bool { !open.isEmpty }

    static func opened(_ w: NSWindow) {
        let first = open.isEmpty
        open.insert(ObjectIdentifier(w))
        guard first else { return }
        NSApp.setActivationPolicy(.regular)
        MainMenu.install(full: true)
    }

    static func closed(_ w: NSWindow) {
        open.remove(ObjectIdentifier(w))
        guard open.isEmpty else { return }
        MainMenu.install(full: false)
        // Straight after the window goes, or macOS keeps the Dock icon until the next activation.
        DispatchQueue.main.async { if open.isEmpty { NSApp.setActivationPolicy(.accessory) } }
    }
}

/// Edit is always there, because ⌘C/⌘V/⌘A in the panel's search field need it. The app and window menus join only
/// while a window is open: ⌘Q or ⌘W pressed in the panel must not quit ClipBubble or close anything.
enum MainMenu {
    static var openPage: (AppPage) -> Void = { _ in }

    static func install(full: Bool) {
        let main = NSMenu()
        if full {
            let app = NSMenu(title: "ClipBubble")
            app.addItem(item("About ClipBubble", #selector(Actions.about), ""))
            app.addItem(.separator())
            app.addItem(item("Settings…", #selector(Actions.settings), ","))
            app.addItem(.separator())
            app.addItem(item("Quit ClipBubble", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
            main.addItem(holder(app))
        }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(holder(edit))
        if full {
            let window = NSMenu(title: "Window")
            window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            main.addItem(holder(window))
            NSApp.windowsMenu = window
        }
        NSApp.mainMenu = main
    }

    private static func holder(_ m: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = Actions.shared) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }

    final class Actions: NSObject {
        static let shared = Actions()
        @objc func about() { MainMenu.openPage(.about) }
        @objc func settings() { MainMenu.openPage(.general) }
    }
}

// MARK: - Layout

struct AppRootView: View {
    @ObservedObject var model: Model
    @ObservedObject var nav: AppNav
    let history: HistoryBrowser

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, nav: nav)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch nav.page {
                case .history: HistoryPage(model: model, browser: history)
                case .general: GeneralPage(model: model)
                case .capture: CapturePage(model: model)
                case .screenshots: ScreenshotsPage(model: model)
                case .devices: DevicesPage(model: model)
                case .mascot: MascotPage(model: model)
                case .agents: AgentsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .id(nav.page)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.12), value: nav.page)
        .onChange(of: nav.page) { _, p in if p == .history { history.reload() } }
        .onChange(of: model.prefsTick) { history.reload() }
    }
}

struct Sidebar: View {
    @ObservedObject var model: Model
    @ObservedObject var nav: AppNav
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 0) {
            List(selection: nav.sidebarSelection) {
                ForEach(Array(AppPage.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.1) { page in
                            Label {
                                HStack {
                                    Text(page.title)
                                    Spacer()
                                    if page == .general, updateAvailable { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                                }
                            } icon: {
                                SettingIcon(symbol: page.symbol, tint: page.tint, size: 20)
                            }
                            .tag(page)
                        }
                    } header: {
                        if let title = group.0 { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            status
        }
    }

    private var updateAvailable: Bool { if case .available = updater.state { return true } else { return false } }

    /// How sync is doing, at a glance, under the pages.
    private var status: some View {
        let live = Set(model.linked.map(\.device)).count
        let connecting = !SyncEngine.enabledHosts.isEmpty
        let text = model.syncPaused ? "Sync paused"
            : live > 0 ? "\(live) \(live == 1 ? "device" : "devices") linked"
            : connecting ? "Connecting to your devices…" : "No devices linked"
        return Button { nav.page = .devices } label: {
            HStack(spacing: 8) {
                Circle().fill(model.syncPaused ? Color.gray : live > 0 ? Color.green : connecting ? Color.orange : Color.gray)
                    .frame(width: 7, height: 7)
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History

/// The History page's own search, filter and selection, so it never fights the panel over them.
final class HistoryBrowser: ObservableObject {
    private static let pageSize = 100
    let model: Model
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var count = 0
    @Published var query = "" { didSet { if query != oldValue { reload(resetPages: true) } } }
    @Published var filter = "all" { didSet { if filter != oldValue { reload(resetPages: true) } } }
    @Published var selection: Int64? { didSet { if selection != oldValue { clearCopyFeedback() } } }
    @Published private(set) var copyFeedback: Bool?
    private var copyFeedbackReset: DispatchWorkItem?
    private var matchingIDs: [Int64] = []
    private var loadedCount = 0

    init(model: Model) { self.model = model }

    var selected: Clip? {
        guard let selection else { return nil }
        return clips.first { $0.id == selection } ?? model.db.clip(id: selection)
    }

    func reload(resetPages: Bool = false) {
        model.refreshDeviceNames()
        guard let ids = matchingClipIDs() else { return }
        matchingIDs = ids
        count = ids.count
        loadedCount = min(ids.count, resetPages ? Self.pageSize : max(Self.pageSize, loadedCount))
        clips = ids.prefix(loadedCount).compactMap { model.db.clip(id: $0) }
        if let selection, !ids.contains(selection) { self.selection = nil }
        Thumbs.prewarm(clips.prefix(60))
    }

    func loadMore(after id: Int64) {
        guard id == clips.last?.id, loadedCount < count else { return }
        let end = min(loadedCount + Self.pageSize, count)
        let rows = matchingIDs[loadedCount..<end].compactMap { model.db.clip(id: $0) }
        loadedCount = end
        clips += rows
    }

    /// Keep the count and page boundaries from the same query without loading every clip's contents.
    private func matchingClipIDs() -> [Int64]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(Paths.db.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 3000)

        // Match the filters in DB.clips so History and the panel agree.
        var sql = "SELECT id FROM clips WHERE created >= ?"
        var args: [String] = []
        let kind = ["text", "image", "file"].contains(filter) ? filter : nil
        if kind == "image" {
            sql += " AND (kind = 'image' OR (kind = 'file' AND (" +
                imageExts.map { "text LIKE '%.\($0)'" }.joined(separator: " OR ") + ")))"
        } else if let kind {
            sql += " AND kind = ?"
            args.append(kind)
        }
        if let source = ["iphone": "iPhone", "shots": "Screenshot", "downloads": "Downloads"][filter] {
            sql += " AND (source = ? COLLATE NOCASE OR origin IN (SELECT id FROM devices WHERE name = ? COLLATE NOCASE))"
            args += [source, source]
        }
        if !query.isEmpty {
            let text = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            sql += " AND (text LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\')"
            args += [text, text]
        }
        sql += Prefs.hiddenSQL + " ORDER BY created DESC, id DESC"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970 - DB.retention)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(index + 2), value, -1, transient) }
        var ids: [Int64] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? ids : nil
    }

    /// Returns whether the keyboard shortcut had a selected item to copy.
    @discardableResult
    func copySelected() -> Bool {
        guard let clip = selected, !clip.remote else { return false }
        let feedback = model.pick(clip, false)
        clearCopyFeedback()
        copyFeedback = feedback
        let reset = DispatchWorkItem { [weak self] in self?.clearCopyFeedback() }
        copyFeedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
        return true
    }

    private func clearCopyFeedback() {
        copyFeedbackReset?.cancel()
        copyFeedbackReset = nil
        if copyFeedback != nil { copyFeedback = nil }
    }

    func delete(_ c: Clip) {
        model.db.delete(id: c.id)
        if selection == c.id { selection = nil }
        model.reloadRecent()
        reload()
    }
}

struct HistoryPage: View {
    @ObservedObject var model: Model
    @ObservedObject var browser: HistoryBrowser
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                bar
                Divider()
                content
            }
            if let c = browser.selected {
                Divider()
                HistoryInspector(clip: c, model: model, browser: browser)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: browser.selection)
        .onAppear { searching = true }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your history", text: $browser.query).textFieldStyle(.plain).font(.system(size: 14)).focused($searching)
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { chips }
                }
                Text("\(browser.count) \(browser.count == 1 ? "item" : "items")").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 14)
    }

    private var chips: some View {
                ForEach(Model.filters, id: \.tag) { f in
                    let on = browser.filter == f.tag
                    Button { browser.filter = f.tag } label: {
                        Text(f.title).font(.system(size: 12, weight: .medium)).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
    }

    @ViewBuilder private var content: some View {
        if browser.clips.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: browser.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text(browser.query.isEmpty ? "Copy anything, and it lands here" : "No matches").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], spacing: 14) {
                    ForEach(browser.clips) { c in
                        HistoryCard(clip: c, selected: c.id == browser.selection, device: model.devices[c.origin])
                            .onTapGesture(count: 2) { model.pick(c, false) }
                            .simultaneousGesture(TapGesture().onEnded { browser.selection = c.id })
                            .onDrag { dragItem(c) }
                            .contextMenu { HistoryActions(clip: c, model: model, browser: browser) }
                            .onAppear { browser.loadMore(after: c.id) }
                    }
                }
                .padding(20)
            }
        }
    }

    private func dragItem(_ c: Clip) -> NSItemProvider {
        if let p = c.imagePath ?? c.paths.first { return NSItemProvider(contentsOf: URL(fileURLWithPath: p)) ?? NSItemProvider() }
        return NSItemProvider(object: c.text as NSString)
    }
}

struct HistoryCard: View {
    let clip: Clip
    let selected: Bool
    let device: String?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(height: 118).frame(maxWidth: .infinity)
                .clipped()
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Text([device, clip.source, ago(clip.created)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(hover ? 1 : 0.6), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 8 : 3, y: hover ? 3 : 1)
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var preview: some View {
        if let p = clip.imagePath {
            ZStack {
                Color.primary.opacity(0.04)
                Thumb(path: p, px: 520)
            }
        } else if let p = clip.paths.first {
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 48, height: 48)
                Text(clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 11.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 10)
            }
        } else if let c = hexColor(clip.text) {
            ZStack(alignment: .bottomLeading) {
                c
                Text(clip.text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    .shadow(radius: 2).padding(10)
            }
        } else {
            Text(clip.text.prefix(600))
                .font(.system(size: 12, design: isURL(clip.text) ? .default : .monospaced))
                .foregroundStyle(isURL(clip.text) ? Color.accentColor : Color.primary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }

    private var symbol: String {
        if clip.remote { return "icloud.and.arrow.down" }
        switch clip.source {
        case "Screenshot": return "camera.viewfinder"
        case "Downloads": return "arrow.down.circle"
        case "iPhone": return "iphone"
        default: return clip.kind == "image" ? "photo" : clip.kind == "file" ? "doc" : isURL(clip.text) ? "link" : "text.alignleft"
        }
    }
}

/// Copy, open, send and delete, the same for a card's menu and the inspector.
struct HistoryActions: View {
    let clip: Clip
    let model: Model
    let browser: HistoryBrowser

    var body: some View {
        if clip.remote {
            Button("Get from \(model.devices[clip.origin] ?? "other device")") { SyncEngine.shared.get(clip.hash) }
        } else {
            Button("Copy") { model.pick(clip, false) }
            if clip.polishPath != nil { Button("Polish…") { model.polish(clip) } }
            if let p = clip.imagePath ?? clip.paths.first {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            if clip.kind != "text", !model.linked.isEmpty {
                Menu("Send to") {
                    ForEach(model.linked, id: \.device) { h in Button(h.name) { SyncEngine.shared.send(clip.hash, toDevice: h.device) } }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { browser.delete(clip) }
    }
}

struct HistoryInspector: View {
    let clip: Clip
    let model: Model
    let browser: HistoryBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { browser.selection = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            preview
                .frame(maxWidth: .infinity, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                fact("From", [model.devices[clip.origin], clip.source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                fact("Copied", clip.created.formatted(date: .abbreviated, time: .shortened))
                if let s = size { fact("Size", s) }
                if let p = clip.imagePath ?? clip.paths.first { fact("Where", (p as NSString).abbreviatingWithTildeInPath) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if clip.remote {
                    Button { SyncEngine.shared.get(clip.hash) } label: { Label("Get", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                } else {
                    Button { browser.copySelected() } label: {
                        let feedback = browser.copyFeedback
                        Label(feedback.map { $0 ? "Copied" : "Couldn't copy" } ?? "Copy",
                              systemImage: feedback.map { $0 ? "checkmark" : "exclamationmark.circle" } ?? "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    if clip.polishPath != nil {
                        Button { model.polish(clip) } label: { Label("Polish", systemImage: "sparkles") }
                            .controlSize(.large).keyboardShortcut("e", modifiers: .command).help("Open in the editor  ⌘E")
                    }
                }
                Menu {
                    HistoryActions(clip: clip, model: model, browser: browser)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .controlSize(.large)
            }
        }
        .padding(16).padding(.top, 24)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private var preview: some View {
        if let p = clip.imagePath {
            Thumb(path: p, px: 900, fit: true).id(p).padding(8)
        } else if let p = clip.paths.first {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 64, height: 64)
                Text(clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                    .font(.system(size: 12)).multilineTextAlignment(.center).textSelection(.enabled)
            }
            .padding(20)
        } else {
            ScrollView {
                Text(clip.text.prefix(50_000)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private var title: String {
        switch clip.kind {
        case "image": return "Image"
        case "file": return clip.source == "Screenshot" ? "Screenshot" : clip.paths.count > 1 ? "\(clip.paths.count) files" : "File"
        default: return isURL(clip.text) ? "Link" : "Text"
        }
    }

    private var size: String? {
        if let p = clip.imagePath, let s = Thumbs.size(of: p) { return "\(Int(s.width)) × \(Int(s.height))" }
        if clip.kind == "text" { return "\(clip.text.count) characters" }
        let bytes = clip.paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size]) as? Int64 }.reduce(0, +)
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).font(.system(size: 11.5)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
