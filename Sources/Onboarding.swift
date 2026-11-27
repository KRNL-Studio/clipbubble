import AppKit
import SwiftUI

enum OnboardingFolder: String, CaseIterable {
    case screenshots, downloads

    var title: String { self == .screenshots ? "Screenshots" : "Recent Downloads" }
    var symbol: String { self == .screenshots ? "camera.viewfinder" : "arrow.down.circle" }
    var tint: Color { self == .screenshots ? .pink : .teal }
    var url: URL? { self == .screenshots ? FolderWatcher.screenshotFolder : FolderWatcher.downloadsFolder }
    var allowLabel: String { self == .screenshots ? "Allow Screenshots" : "Allow Downloads" }
}

/// Shared by the window and the capture services. Changes and callbacks are delivered on the main thread.
final class OnboardingState: ObservableObject {
    static let completionKey = "onboarding.completed"
    static let shownWindowKey = "shownAppWindow"

    enum Step: Int, CaseIterable {
        case welcome, accessibility, folders, ready

        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .accessibility: return "Auto-paste"
            case .folders: return "Folders"
            case .ready: return "Ready"
            }
        }
    }

    enum FolderAccess {
        case unchecked, allowed, denied
    }

    @Published private(set) var step: Step = .welcome
    @Published private(set) var isRunning = false
    @Published private(set) var accessibility: Bool?
    @Published private(set) var autoPaste: Bool
    @Published private(set) var checkingFolder: OnboardingFolder?
    @Published private var chosenScreenshotFolder: URL?
    @Published private var folderResults: [OnboardingFolder: [String: FolderAccess]] = [:]

    private let defaults: UserDefaults
    private let isTrusted: () -> Bool
    private let readFolder: (URL?) -> Bool
    private let folderURL: (OnboardingFolder) -> URL?
    private let probeQueue = DispatchQueue(label: "clipbubble.setup.folder", qos: .userInitiated)
    private var session = UUID()
    private var accessibilityTimer: Timer?
    var setFolderPreference: (OnboardingFolder, Bool) -> Void = { Prefs.set($0.rawValue, $1) }
    var didCompleteFirstRun: () -> Void = {}
    var didGrantAccessibility: () -> Void = {}
    var didLeaveAccessibilityStep: () -> Void = {}

    init(defaults: UserDefaults = .standard, isTrusted: @escaping () -> Bool = AXIsProcessTrusted,
         readFolder: @escaping (URL?) -> Bool = FolderWatcher.canRead,
         folderURL: @escaping (OnboardingFolder) -> URL? = { $0.url }) {
        self.defaults = defaults
        self.isTrusted = isTrusted
        self.readFolder = readFolder
        self.folderURL = folderURL
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        if defaults.object(forKey: Self.completionKey) == nil, defaults.bool(forKey: Self.shownWindowKey) {
            defaults.set(true, forKey: Self.completionKey)
        }
    }

    deinit { accessibilityTimer?.invalidate() }

    var needsSetup: Bool { !defaults.bool(forKey: Self.completionKey) }

    func begin() {
        guard !isRunning else { return }
        session = UUID()
        step = .welcome
        accessibility = nil
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        checkingFolder = nil
        chosenScreenshotFolder = nil
        folderResults = [:]
        isRunning = true
    }

    func next() { move(to: Step(rawValue: step.rawValue + 1)) }
    func back() { move(to: Step(rawValue: step.rawValue - 1)) }
    func skip() { step == .welcome ? move(to: .ready) : next() }

    private func move(to target: Step?) {
        guard isRunning, checkingFolder == nil, let target else { return }
        if step == .accessibility { endAccessibilityStep() }
        step = target
        if target == .accessibility {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshAccessibility()
            }
            accessibilityTimer = timer
            // Keep polling during AppKit event tracking as well as normal run-loop activity.
            RunLoop.main.add(timer, forMode: .common)
        }
        if target == .accessibility || target == .ready { refreshAccessibility() }
    }

    func finish() {
        guard isRunning else { return }
        if step == .accessibility { endAccessibilityStep() }
        if needsSetup {
            // Materialize the choices before opening the gate for the normal capture services.
            for folder in OnboardingFolder.allCases where !canWatch(folder) {
                setFolderPreference(folder, false)
            }
            defaults.set(true, forKey: Self.completionKey)
            defaults.set(true, forKey: Self.shownWindowKey)
            didCompleteFirstRun()
        }
        isRunning = false
        checkingFolder = nil
    }

    private func endAccessibilityStep() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        didLeaveAccessibilityStep()
    }

    func refreshAccessibility() {
        guard isRunning, step == .accessibility || step == .ready else { return }
        let trusted = isTrusted()
        let granted = step == .accessibility && accessibility == false && trusted
        if step == .accessibility, trusted, accessibility == false || needsSetup { enableAutoPaste() }
        if accessibility != trusted { accessibility = trusted }
        if granted { didGrantAccessibility() }
    }

    func enableAutoPaste() {
        guard !autoPaste || defaults.object(forKey: "autoPaste") == nil else { return }
        defaults.set(true, forKey: "autoPaste")
        autoPaste = true
    }

    func displayedURL(_ folder: OnboardingFolder) -> URL? {
        if folder == .screenshots, let chosenScreenshotFolder { return chosenScreenshotFolder }
        return folderURL(folder)
    }

    func folderAccess(_ folder: OnboardingFolder, at url: URL?) -> FolderAccess {
        guard let path = url?.path else { return .unchecked }
        return folderResults[folder]?[path] ?? .unchecked
    }

    func canWatch(_ folder: OnboardingFolder) -> Bool {
        !needsSetup || folderAccess(folder, at: folderURL(folder)) == .allowed
    }

    func chooseScreenshotFolder(_ url: URL) {
        guard isRunning, step == .folders, checkingFolder == nil else { return }
        chosenScreenshotFolder = url
    }

    func requestFolder(_ folder: OnboardingFolder) {
        guard isRunning, step == .folders, checkingFolder == nil, let url = displayedURL(folder) else { return }
        let session = self.session
        let read = readFolder
        checkingFolder = folder
        probeQueue.async { [weak self] in
            let allowed = read(url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.session == session else { return }
                self.folderResults[folder, default: [:]][url.path] = allowed ? .allowed : .denied
                if allowed, url.path == self.displayedURL(folder)?.path {
                    if folder == .screenshots, let chosenURL = self.chosenScreenshotFolder {
                        self.defaults.set(chosenURL.path, forKey: "screenshotFolder")
                        self.chosenScreenshotFolder = nil
                    }
                    self.setFolderPreference(folder, true)
                }
                self.checkingFolder = nil
            }
        }
    }
}

/// Finder-style file URL drag. System Settings receives a reference to the actual installed app bundle.
struct AppBundleDragView: NSViewRepresentable {
    static var bundleFileURL: NSURL { Bundle.main.bundleURL as NSURL }
    let label: String

    func makeNSView(context: Context) -> DragSource {
        DragSource(frame: .zero)
    }

    func updateNSView(_ view: DragSource, context: Context) {
        view.setAccessibilityLabel(label)
        view.toolTip = Self.bundleFileURL.path
    }

    final class DragSource: NSView, NSDraggingSource {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: AppBundleDragView.bundleFileURL)
            let point = convert(event.locationInWindow, from: nil)
            let frame = NSRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64)
            item.setDraggingFrame(frame, contents: NSApp.applicationIconImage)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}

final class AccessibilityDragPanel: NSPanel {
    init(dismiss: @escaping () -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 310, height: 136)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true

        let container = glass(frame: frame, radius: 18, material: .popover, blendingMode: .behindWindow)
        let host = ClickThroughHostingView(rootView: AccessibilityDragCard(dismiss: dismiss))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
}

final class AccessibilityDragPanelController {
    private let state: OnboardingState
    private(set) var panel: AccessibilityDragPanel?

    init(state: OnboardingState, returnToSetup: @escaping () -> Void) {
        self.state = state
        state.didLeaveAccessibilityStep = { [weak self] in self?.dismiss() }
        state.didGrantAccessibility = { [weak self] in
            guard let self, self.panel != nil else { return }
            self.dismiss()
            returnToSetup()
        }
    }

    /// Returns whether setup is still waiting for access and should open System Settings.
    func show(on screen: NSScreen?) -> Bool {
        guard state.isRunning, state.step == .accessibility else { return false }
        state.refreshAccessibility()
        guard state.accessibility != true else {
            dismiss()
            return false
        }
        if let panel {
            panel.orderFrontRegardless()
            return true
        }

        let panel = AccessibilityDragPanel { [weak self] in self?.dismiss() }
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.minX + 24, y: area.midY - panel.frame.height / 2))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        return true
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct AppBundleDragTile: View {
    static let bundled = AppBundleDragView.bundleFileURL.pathExtension == "app"
    static let name = bundled ? "ClipBubble.app" : Bundle.main.bundleURL.lastPathComponent
    static let label = bundled ? "Drag ClipBubble into Accessibility" : "Drag \(name)"

    var width: CGFloat = 106

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            Text(Self.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .frame(width: width, height: 91)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityHidden(true)
        .overlay { AppBundleDragView(label: Self.label) }
    }
}

private struct AccessibilityDragArrow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}

private struct AccessibilityDragCard: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppBundleDragTile(width: 94)
            AccessibilityDragArrow(size: 15)
            VStack(alignment: .leading, spacing: 6) {
                Text("Drag into Accessibility").font(.system(size: 13, weight: .semibold))
                Text("Drop ClipBubble.app onto the list in System Settings.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Waiting for access…", systemImage: "clock")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.14))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .help("Dismiss drag card")
            .accessibilityLabel("Dismiss drag card")
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: Model
    @ObservedObject var state: OnboardingState
    let openAccessibilitySettings: () -> Void
    let finish: (AppPage) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Screencapture.replacementKey) private var replaceThumbnail = true
    @State private var loginEnabled = LoginItem.on
    @State private var loginNote: String?
    @State private var heroHover = false
    @State private var heroTicks = 0

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator.padding(.top, 38).padding(.bottom, 18)
            Divider()
            ScrollView {
                Group {
                    switch state.step {
                    case .welcome: welcome
                    case .accessibility: accessibility
                    case .folders: folders
                    case .ready: ready
                    }
                }
                .id(state.step)
                .transition(.opacity)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, 26).padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.step)
            }
            .defaultScrollAnchor(.top)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshAccessibility()
            loginEnabled = LoginItem.on
            if loginEnabled { loginNote = nil }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                let active = state.step == step
                let passed = state.step.rawValue > step.rawValue
                if step != .welcome {
                    Rectangle()
                        .fill(passed || active ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .padding(.bottom, 17)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 5) {
                    ZStack {
                        Circle().fill(active || passed ? Color.accentColor : Color.primary.opacity(0.08))
                        if passed {
                            Image(systemName: "checkmark")
                        } else {
                            Text("\(step.rawValue + 1)")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(active || passed ? Color.white : Color.secondary)
                    .frame(width: 20, height: 20)
                    Text(step.label)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                }
                .frame(width: 65)
            }
        }
        .frame(maxWidth: 372)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(state.step.rawValue + 1) of 4, \(state.step.label)")
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.indigo.opacity(0.85), Color(white: 0.12)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .indigo.opacity(0.25), radius: 10, y: 4)
                    mascot(model.mascot, hover: heroHover, happyTicks: heroTicks)
                        .scaleEffect(1.75)
                }
                .frame(width: 78, height: 78)
                .onHover { heroHover = $0 }
                .accessibilityHidden(true)
                heading("Welcome to ClipBubble", "Seven days of clipboard history, always within reach.")
            }
            Text("Find copied items, screenshots and downloads, then paste them instantly. Keep your history private on this Mac or sync it with your iPhone and other devices.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard(title: "Pick your bubble mascot") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 5) {
                        ForEach(model.mascots) { choice in mascotChoice(choice) }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 2)
                }
            }

            SettingsCard {
                ToggleRow(icon: "power", tint: .green, title: "Open at login", detail: loginNote,
                          isOn: Binding(get: { loginEnabled }, set: {
                              loginNote = LoginItem.set($0)
                              loginEnabled = LoginItem.on
                          }))
            }
        }
    }

    private func mascotChoice(_ choice: Mascot) -> some View {
        let selected = choice.id == model.mascot.id
        return Button {
            Mascots.setActive(choice.id)
            model.loadMascots()
            heroTicks += 1
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color(white: 0.12))
                    mascot(choice).scaleEffect(0.82)
                }
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(choice.name).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(width: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.name)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func mascot(_ choice: Mascot, hover: Bool = false, happy: Bool = false, happyTicks: Int = 0) -> some View {
        MascotView(mascot: choice, hover: hover, pressed: false, happy: happy, hoverTicks: 0,
                   happyTicks: reduceMotion ? 0 : happyTicks)
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Paste straight into any app",
                    "Press ↩ in the history panel to paste into the app you were using. Without Accessibility, ClipBubble copies the item for you to paste.")
            if state.accessibility == true {
                SettingsCard {
                    HStack(spacing: 12) {
                        mascot(model.mascot, happy: true, happyTicks: 1)
                            .frame(width: 38, height: 38)
                            .background(Color(white: 0.12), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            status("Allowed", symbol: "checkmark.circle.fill", tint: .green)
                            Text(state.autoPaste ? "Auto-paste is on. You’re ready for the next step." : "Auto-paste is off.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if !state.autoPaste { Button("Turn on Auto-paste") { state.enableAutoPaste() } }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                dragCard
                HStack {
                    Button("Open Accessibility Settings", action: openAccessibilitySettings)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    status("Waiting for access", symbol: "clock", tint: .secondary)
                }
                .controlSize(.large)
                Text("A floating drag card follows you to System Settings. If ClipBubble is already listed, turn it on. You can also add ClipBubble.app with the + button.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var dragCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                AppBundleDragTile()
                AccessibilityDragArrow()

                VStack(alignment: .leading, spacing: 5) {
                    SettingIcon(symbol: "gearshape", tint: .gray, size: 25).accessibilityHidden(true)
                    Text(AppBundleDragTile.label).font(.system(size: 13, weight: .semibold))
                    Text(AppBundleDragTile.bundled ? "Privacy & Security → Accessibility" : "Use the installed ClipBubble.app to grant access.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Bring files into your history",
                    "macOS protects folders like Desktop and Downloads individually. Choose which folders ClipBubble can read. Each Allow button checks only that folder.")
            ForEach(OnboardingFolder.allCases, id: \.self) { folder in folderCard(folder) }
            SettingsCard {
                ToggleRow(icon: "sparkles", tint: .purple, title: "Replace macOS screenshot preview",
                          detail: "Hides macOS’s floating thumbnail so ClipBubble’s Polish preview appears right away.",
                          isOn: Binding(get: { replaceThumbnail }, set: { on in
                              replaceThumbnail = on
                              model.screenshotThumbnailChanged(on)
                          }))
            }
        }
    }

    private func folderCard(_ folder: OnboardingFolder) -> some View {
        let url = state.displayedURL(folder)
        let access = state.folderAccess(folder, at: url)
        let path = url.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        return SettingsCard {
            SettingRow(icon: folder.symbol, tint: folder.tint, title: folder.title, detail: path ?? "Folder unavailable") {
                if state.checkingFolder == folder {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking access")
                } else {
                    switch access {
                    case .unchecked:
                        status(state.needsSetup ? "Not asked" : "Not checked", symbol: "circle.dotted", tint: .secondary)
                    case .allowed:
                        status("Allowed", symbol: "checkmark.circle.fill", tint: .green)
                    case .denied:
                        status("No access", symbol: "exclamationmark.circle", tint: .orange)
                    }
                }
            }
            HStack(spacing: 10) {
                if access != .allowed || url?.path != folder.url?.path {
                    Button(folder.allowLabel) { state.requestFolder(folder) }
                        .disabled(path == nil)
                }
                if folder == .screenshots { Button("Choose folder…", action: chooseScreenshotFolder) }
                if access == .denied {
                    Button("Open Files & Folders Settings", action: Access.openFilesSettings)
                        .buttonStyle(.link)
                }
            }
            .controlSize(.small)
            .disabled(state.checkingFolder != nil)
            .padding(.leading, 34).padding(.bottom, 5)
        }
    }

    private func chooseScreenshotFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = state.displayedURL(.screenshots)
        open.message = "Pick the folder ClipBubble should watch for screenshots."
        Dialogs.open(open) { state.chooseScreenshotFolder($0) }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SettingIcon(symbol: "checkmark", tint: .green, size: 42).accessibilityHidden(true)
                heading("You’re ready", "Here’s what’s set up on this Mac.")
            }
            SettingsCard {
                summaryRow("Accessibility", state.accessibility == true && state.autoPaste,
                           inactive: state.accessibility == true ? "Allowed · Auto-paste off" : "Off")
                ForEach(OnboardingFolder.allCases, id: \.self) { folder in
                    let enabled = Prefs.on(folder.rawValue) && state.canWatch(folder)
                    let access = state.folderAccess(folder, at: folder.url)
                    Divider()
                    summaryRow(folder.title, enabled && access == .allowed,
                               inactive: access == .denied ? "No access" : enabled ? "On · Access unchecked" : "Off")
                }
                Divider()
                summaryRow("Open at login", loginEnabled, inactive: loginNote == nil ? "Off" : "Needs attention")
            }
            SettingsCard(title: "A few shortcuts") {
                shortcut("⌃⌥V", "Open clipboard history anywhere")
                shortcut("Hover", "Move over the bubble for a quick peek")
                shortcut("⌘E / ✨", "Polish a screenshot from history")
            }
            HStack(spacing: 16) {
                Button { finish(.devices) } label: { Label("Link your iPhone", systemImage: "iphone") }
                Button { finish(.agents) } label: { Label("Connect AI Agents", systemImage: "sparkles") }
            }
            .buttonStyle(.link)
        }
    }

    private func summaryRow(_ label: String, _ active: Bool, inactive: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            status(active ? "On" : inactive, symbol: active ? "checkmark.circle.fill" : "circle",
                   tint: active ? .green : .secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func shortcut(_ key: String, _ description: String) -> some View {
        HStack(spacing: 9) {
            Text(key).font(.system(size: 11, weight: .medium)).monospaced()
                .frame(width: 68, alignment: .center).padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.step != .welcome { Button("Back") { state.back() } }
            Spacer()
            if state.step != .ready {
                if state.step == .welcome || state.step == .folders || state.accessibility != true {
                    Button(state.step == .welcome ? "Skip setup" : "Skip for now") { state.skip() }
                        .buttonStyle(.borderless)
                }
                Button("Continue") { state.next() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Start using ClipBubble") { finish(.history) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .disabled(state.checkingFolder != nil)
        .padding(.horizontal, 26).padding(.vertical, 14)
    }
}
