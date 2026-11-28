import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lets keys play the system click, which follows the person's Keyboard Clicks setting. Only this keyboard's own
/// process sees it.
extension UIInputView: @retroactive UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}

/// The clipboard keyboard: your history in any app, fresh from your computers. Tap text to type it; pictures and
/// files go on the clipboard to paste, since a keyboard can only type text.
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(keyboard: self)
    private var preferredHeight: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardModel.height(compact: false))
        height.priority = .defaultHigh
        preferredHeight = height
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appear(fullAccess: hasFullAccess, globe: needsInputModeSwitchKey)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.traitCollection.verticalSizeClass == .compact
        let height = KeyboardModel.height(compact: compact)
        if preferredHeight?.constant != height { preferredHeight?.constant = height }
        if model.compact != compact { model.compact = compact }
        updateGlobe()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateGlobe()
        model.fieldChanged()
    }

    private func updateGlobe() {
        if model.globe != needsInputModeSwitchKey { model.globe = needsInputModeSwitchKey }
    }

    /// A dismissed keyboard can stay alive in the background; it lets go of the link so the app can have it.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
        if hasFullAccess { SyncEngine.shared.suspend(true) }
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var status = ""
    @Published var linked = false
    @Published var hasComputers = true
    @Published var fullAccess = true
    @Published var globe = false
    @Published var compact = false
    @Published var note: Note?
    /// Kept items older than free ClipBubble shows.
    @Published var locked = 0
    /// Counts each time the keyboard comes up.
    @Published var opened = 0

    // Typing
    @Published var typing = false
    @Published var symbols = false
    @Published var more = false
    @Published var shift = false
    @Published var capsLock = false
    /// The return key's word ("go", "search", "send"), or nil for the return arrow.
    @Published var returnTitle: String?
    @Published var returnProminent = false

    struct Note: Equatable {
        var text: String
        var ok = true
    }

    static func height(compact: Bool) -> CGFloat { compact ? 216 : 296 }

    private var viaApp = false
    private weak var keyboard: UIInputViewController?
    private var started = false
    private var browser: DirectBrowser?
    private lazy var db = DB()
    /// A picture fetched from a computer by a tap goes on the clipboard as soon as it arrives.
    private var fetching: String?
    private var lastSpace: Date?
    private var lastShift: Date?

    init(keyboard: UIInputViewController) { self.keyboard = keyboard }

    private var proxy: UITextDocumentProxy? { keyboard?.textDocumentProxy }

    /// Number, phone and decimal fields want digits, not a history.
    private var numeric: Bool {
        switch proxy?.keyboardType {
        case .numberPad?, .decimalPad?, .phonePad?, .asciiCapableNumberPad?, .numbersAndPunctuation?: return true
        default: return false
        }
    }

    /// Without Full Access a keyboard can't see the App Group or the network, so there's nothing to show yet.
    func appear(fullAccess: Bool, globe: Bool) {
        self.fullAccess = fullAccess
        self.globe = globe
        haptic.prepare()
        if numeric {
            typing = true
            symbols = true
            more = false
        }
        fieldChanged()
        guard fullAccess else { return }
        opened += 1
        checkApp()
        let engine = SyncEngine.shared
        reload()
        if !started {
            started = true
            engine.onReceived = { [weak self] in self?.reload() }
            engine.onStatus = { [weak self] in self?.reload() }
            engine.start()
        } else {
            SyncEngine.enabledHosts.forEach(engine.redial)
        }
    }

    /// Inside the ClipBubble app, the app holds the link and this keyboard reads what it syncs. Checked again every few
    /// seconds, so if the app quits or crashes the keyboard takes the link back.
    private var watching: Timer?
    private func checkApp() {
        let was = viaApp
        viaApp = Date().timeIntervalSince1970 - Platform.defaults.double(forKey: "app.alive") < 10
        if was != viaApp || watching == nil { SyncEngine.shared.suspend(viaApp) }
        if !viaApp && SyncEngine.enabledHosts.contains(where: DirectPeers.isDirect) {
            if browser == nil { browser = Pairing.browseNearby() }
        } else {
            browser?.stop()
            browser = nil
        }
        if viaApp && watching == nil {
            watching = .scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkApp() } }
        } else if !viaApp {
            watching?.invalidate()
            watching = nil
            reload()
        }
    }

    func disappear() {
        browser?.stop()
        browser = nil
        fetching = nil
        watching?.invalidate()
        watching = nil
    }

    func reload() {
        let since = Tier.sinceHours
        clips = db.clips(limit: 60, sinceHours: since, preview: true)
        locked = since.map { db.count(olderThanHours: $0) } ?? 0
        if let h = fetching, let c = clips.first(where: { $0.hash == h && !$0.remote }) {
            fetching = nil
            deliver(c)
        }
        #if DEBUG
        if Platform.defaults.bool(forKey: "demo") || FileManager.default.fileExists(atPath: Paths.dir.appendingPathComponent(".demo").path) {
            linked = true
            hasComputers = true
            status = "MacBook Pro, Studio PC, Dev Workstation"
            return
        }
        #endif
        let hosts = SyncEngine.enabledHosts
        let states = SyncEngine.shared.statuses
        let live = hosts.compactMap { alias -> String? in
            guard case .live(let h)? = states[alias] else { return nil }
            return Pairing.displayName(for: alias, reportedName: h.name)
        }
        // Short enough for one line: the computer's name and whether it's there.
        let firstStatus = hosts.first.map { alias -> String in
            let name = Pairing.displayName(for: alias)
            switch states[alias] {
            case nil, .connecting?: return "Connecting to \(name)…"
            case .versionMismatch?: return "Update ClipBubble on \(name)"
            case let state? where state.transient: return "\(name) is offline"
            default: return "Open ClipBubble to reconnect \(name)"
            }
        }
        hasComputers = !hosts.isEmpty
        linked = !hosts.isEmpty && (viaApp || !live.isEmpty)
        status = hosts.isEmpty ? "No computers linked yet"
            : viaApp ? "Synced by the ClipBubble app"
            : !live.isEmpty ? live.joined(separator: ", ") : firstStatus ?? "Connecting…"
    }

    func tap(_ c: Clip) {
        tick()
        if c.kind == "text" {
            proxy?.insertText(db.whole(c).text)
            lastSpace = nil
        } else if c.remote {
            fetching = c.hash
            SyncEngine.shared.get(c.hash) { [weak self] in
                self?.flash($0 ? "Getting it from your computer…" : "Your computer isn't connected", ok: $0)
            }
        } else {
            deliver(c)
        }
    }

    /// A text file is typed as what's in it; anything else goes on the clipboard.
    private func deliver(_ c: Clip) {
        guard let text = Self.typeable(c) else { return copy(c) }
        proxy?.insertText(text)
        lastSpace = nil
        flash("Typed \(Self.fileName(c))")
    }

    /// Small enough to type in one go without stalling the app being typed into.
    private nonisolated static let typeLimit = 100_000

    /// The contents of a text file (notes, code, JSON, CSV…), or nil when it isn't one or is too big to type.
    nonisolated static func typeable(_ c: Clip) -> String? {
        guard isTypeableFile(c), let path = c.paths.first, let data = FileManager.default.contents(atPath: path),
              data.count <= typeLimit else { return nil }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        // Files end with a newline; typing it would leave the cursor on an empty line.
        while text.last?.isNewline == true { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// One text file of a typeable size, from what it's called and its size alone.
    nonisolated static func isTypeableFile(_ c: Clip) -> Bool {
        guard c.kind == "file", c.paths.count == 1, let path = c.paths.first else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        // Rich text is markup, not something to type.
        guard !["rtf", "rtfd", "doc", "docx", "pages"].contains(ext),
              let type = UTType(filenameExtension: ext), type.conforms(to: .text) else { return false }
        if c.remote { return true }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        return (size ?? .max) <= typeLimit
    }

    private static func fileName(_ c: Clip) -> String {
        c.paths.first.map { ($0 as NSString).lastPathComponent } ?? "file"
    }

    /// iOS lets a keyboard type text but not insert pictures or files, so those go on the clipboard to paste.
    private func copy(_ c: Clip) {
        guard Clipboard.write(c) else { return flash("Couldn't copy that", ok: false) }
        flash(c.imagePath != nil ? "Image copied. Touch and hold the text box, then Paste." : "File copied. Touch and hold the text box, then Paste.")
    }

    // MARK: Typing

    /// Text from a key. Two quick spaces after a word end the sentence, as on the system keyboard.
    func type(_ s: String) {
        tick()
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        if s == " ", let last = lastSpace, Date().timeIntervalSince(last) < 0.5, before.hasSuffix(" "),
           let c = before.dropLast().last, c.isLetter || c.isNumber {
            proxy.deleteBackward()
            proxy.insertText(". ")
            lastSpace = nil
        } else {
            proxy.insertText(s)
            lastSpace = s == " " ? Date() : nil
        }
        if shift && !capsLock { shift = false }
        // After a space, back to letters, like the system keyboard. Not in number fields.
        if symbols && (s == " " || s == "\n") && !numeric {
            symbols = false
            more = false
        }
        autoShift()
    }

    func backspace() {
        tick()
        proxy?.deleteBackward()
        lastSpace = nil
        autoShift()
    }

    /// Held delete speeds up to whole words.
    func deleteWord() {
        tick()
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return proxy.deleteBackward() }
        var n = 0
        var chars = Array(before)
        while let c = chars.last, c.isWhitespace { chars.removeLast(); n += 1 }
        while let c = chars.last, !c.isWhitespace { chars.removeLast(); n += 1 }
        for _ in 0..<max(n, 1) { proxy.deleteBackward() }
        autoShift()
    }

    /// One tap for a capital, two quick taps to lock caps.
    func tapShift() {
        click()
        let now = Date()
        if capsLock {
            capsLock = false
            shift = false
        } else if shift, let last = lastShift, now.timeIntervalSince(last) < 0.35 {
            capsLock = true
        } else {
            shift.toggle()
        }
        lastShift = now
    }

    func toggleSymbols() {
        click()
        symbols.toggle()
        more = false
        if !symbols { autoShift() }
    }

    func toggleMore() { click(); more.toggle() }

    func toggleTyping() {
        click()
        typing.toggle()
        if typing { autoShift() }
    }

    func nextKeyboard() { keyboard?.advanceToNextInputMode() }

    /// The field changed (another field, or the app moved the cursor): match its return key and capitals.
    func fieldChanged() {
        let title: String?
        switch proxy?.returnKeyType ?? .default {
        case .go: title = "go"
        case .google, .yahoo, .search: title = "search"
        case .join: title = "join"
        case .next: title = "next"
        case .route: title = "route"
        case .send: title = "send"
        case .done: title = "done"
        case .emergencyCall: title = "emergency"
        case .continue: title = "continue"
        default: title = nil
        }
        if returnTitle != title { returnTitle = title }
        let prominent = title != nil && title != "next"
        if returnProminent != prominent { returnProminent = prominent }
        autoShift()
    }

    /// Capitals where the field asks for them: every word, every sentence, or all.
    private func autoShift() {
        guard !capsLock else { return }
        let before = proxy?.documentContextBeforeInput ?? ""
        let on: Bool
        switch proxy?.autocapitalizationType ?? .sentences {
        case .allCharacters:
            on = true
        case .words:
            on = before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            on = trimmed.isEmpty || trimmed.hasSuffix("\n")
                || (before.last == " " && [".", "!", "?"].contains(trimmed.last))
        default:
            on = false
        }
        if shift != on { shift = on }
    }

    // MARK: Feedback

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// The system click, if Keyboard Clicks is on.
    func click() { UIDevice.current.playInputClick() }

    private func tick() {
        click()
        haptic.impactOccurred(intensity: 0.55)
    }

    private func flash(_ s: String, ok: Bool = true) {
        let n = Note(text: s, ok: ok)
        withAnimation(.snappy) { note = n }
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if note == n { withAnimation(.snappy) { note = nil } }
        }
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    private var showsKeys: Bool { !model.fullAccess || model.typing }
    /// Each key's touch area, including the gap around what's drawn, so there's no dead space between keys.
    private var row: CGFloat { model.compact ? 40 : 56 }

    var body: some View {
        GeometryReader { geo in
            let unit = max(0, (geo.size.width - 6) / 10)
            VStack(spacing: 0) {
                if model.typing && model.fullAccess && model.note == nil && model.clips.contains(where: { $0.kind == "text" }) {
                    recentStrip
                } else {
                    statusBar
                }
                if showsKeys {
                    keys(unit: unit)
                } else {
                    history
                }
                bottomRow(unit: unit)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 2)
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 7) {
            if let note = model.note {
                Image(systemName: note.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(note.ok ? Color.green : Color.orange)
                Text(note.text).foregroundStyle(.primary)
            } else {
                Mascot(size: 17, ring: false)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(model.linked ? Color.green : Color.orange).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(KeyColor.background, lineWidth: 1.5))
                            .offset(x: 2, y: 1)
                    }
                Text(model.fullAccess ? model.status : "ClipBubble").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold)).lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: model.compact ? 26 : 30)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    /// While typing, the latest text items sit where the system keyboard puts its suggestions.
    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Mascot(size: 17, ring: false)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(model.linked ? Color.green : Color.orange).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(KeyColor.background, lineWidth: 1.5))
                            .offset(x: 2, y: 1)
                    }
                    .padding(.trailing, 2)
                    .accessibilityLabel(model.status)
                ForEach(model.clips.filter { $0.kind == "text" }.prefix(8), id: \.hash) { c in
                    Button { model.tap(c) } label: {
                        Text(c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                            .font(.subheadline).lineLimit(1)
                            .foregroundStyle(c.look == .link ? Brand.tint : Color(.label))
                            .frame(maxWidth: 170)
                            .padding(.horizontal, 12).frame(height: model.compact ? 28 : 34)
                            .background(KeyColor.chip, in: Capsule())
                            .shadow(color: KeyColor.shadow, radius: 0, x: 0, y: 1)
                    }
                    .buttonStyle(ChipPress())
                    .accessibilityHint("Types it")
                }
            }
            .padding(.horizontal, 9)
        }
        .frame(height: model.compact ? 34 : 44)
        .crispEdges()
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        if model.clips.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.hasComputers ? "doc.on.clipboard" : "laptopcomputer.and.iphone")
                    .font(.title2).foregroundStyle(Brand.tint)
                Text(emptyText)
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(model.clips, id: \.hash) { c in
                            Button { model.tap(c) } label: { KeyboardChip(clip: c, compact: model.compact) }
                                .buttonStyle(ChipPress())
                                .id(c.hash)
                        }
                    }
                    .padding(.horizontal, 3).padding(.top, 2)
                    if model.locked > 0 {
                        Label("Showing the last 24 hours. ClipBubble Pro shows all 7 days.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 10).padding(.horizontal, 12)
                    }
                }
                .scrollIndicators(.hidden)
                .crispEdges()
                // The newest copy is what you're most likely after, so every time the keyboard opens it's in view.
                .onChange(of: model.opened) { scroll.scrollTo(model.clips.first?.hash, anchor: .top) }
                .onChange(of: model.clips.first?.hash) { withAnimation(.snappy) { scroll.scrollTo(model.clips.first?.hash, anchor: .top) } }
            }
            .padding(.bottom, 4)
        }
    }

    private var emptyText: String {
        if !model.hasComputers { return "Link a computer in the ClipBubble app, and what you copy there shows up here." }
        if model.locked > 0 { return "Nothing from the last 24 hours. ClipBubble Pro shows all 7 days." }
        return "Nothing copied yet. Copy something on your computer and it shows up here."
    }

    // MARK: Keys

    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    private static let more = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]

    private func keys(unit: CGFloat) -> some View {
        let rows = model.symbols ? (model.more ? Self.more : Self.symbols) : Self.letters
        return VStack(spacing: 0) {
            if !model.fullAccess {
                ViewThatFits(in: .vertical) {
                    Text("Turn on Allow Full Access in Settings → General → Keyboard → Keyboards → ClipBubble to see your history.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Turn on Allow Full Access in ClipBubble's keyboard settings.")
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 12).frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            // Top row
            HStack(spacing: 0) {
                ForEach(chars(rows[0]), id: \.self) { s in character(s, slot: unit) }
            }
            // Middle row: the letters sit half a key in, but the outer two reach the edges.
            HStack(spacing: 0) {
                let middle = chars(rows[1])
                ForEach(Array(middle.enumerated()), id: \.offset) { i, s in
                    if middle.count == 9 && (i == 0 || i == 8) {
                        character(s, slot: unit * 1.5, visual: unit, align: i == 0 ? .trailing : .leading)
                    } else {
                        character(s, slot: unit)
                    }
                }
            }
            // Bottom row: shift or more symbols, the letters, delete.
            HStack(spacing: 0) {
                if model.symbols {
                    KeyCap(kind: .function, slot: unit * 1.5, visual: unit * 1.3, align: .leading, height: row,
                           onDown: model.toggleMore) {
                        Text(model.more ? "123" : "#+=").font(.system(size: 16))
                    }
                    .accessibilityLabel(model.more ? "Numbers" : "More symbols")
                    ForEach(chars(rows[2]), id: \.self) { s in character(s, slot: unit * 1.4) }
                } else {
                    KeyCap(kind: .function, slot: unit * 1.5, visual: unit * 1.3, align: .leading, height: row,
                           selected: model.shift, onDown: model.tapShift) {
                        Image(systemName: model.capsLock ? "capslock.fill" : model.shift ? "shift.fill" : "shift")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel(model.capsLock ? "Caps lock" : "Shift")
                    .accessibilityAddTraits(model.shift ? .isSelected : [])
                    ForEach(chars(rows[2]), id: \.self) { s in character(s, slot: unit) }
                }
                deleteKey(slot: unit * 1.5, visual: unit * 1.3, align: .trailing)
            }
        }
    }

    private func chars(_ row: String) -> [String] { row.map(String.init) }

    private func character(_ s: String, slot: CGFloat, visual: CGFloat? = nil, align: Alignment = .center) -> some View {
        let shown = model.shift && !model.symbols ? s.uppercased() : s
        return KeyCap(kind: .letter, slot: slot, visual: visual, align: align, height: row,
                      popup: model.compact ? nil : shown, onUp: { model.type(shown) }) {
            Text(shown).font(.system(size: model.symbols ? 22 : 23, weight: .regular))
        }
        .accessibilityLabel(shown)
    }

    private func deleteKey(slot: CGFloat, visual: CGFloat? = nil, align: Alignment = .center) -> some View {
        KeyCap(kind: .function, slot: slot, visual: visual, align: align, height: row,
               onDown: model.backspace, onRepeat: { n in n < 14 ? model.backspace() : model.deleteWord() }) {
            Image(systemName: "delete.left").font(.system(size: 18, weight: .medium))
        }
        .accessibilityLabel("Delete")
    }

    private func bottomRow(unit: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.fullAccess {
                KeyCap(kind: .function, slot: unit * 1.25, height: row, onDown: model.toggleTyping) {
                    Image(systemName: model.typing ? "square.grid.2x2" : "keyboard").font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel(model.typing ? "Show history" : "Show keyboard")
            }
            if showsKeys {
                KeyCap(kind: .function, slot: unit * 1.25, height: row, onDown: model.toggleSymbols) {
                    Text(model.symbols ? "ABC" : "123").font(.system(size: 16))
                }
                .accessibilityLabel(model.symbols ? "Letters" : "Numbers")
            }
            if model.globe {
                KeyCap(kind: .function, slot: unit * 1.25, height: row, onUp: model.nextKeyboard) {
                    Image(systemName: "globe").font(.system(size: 18))
                }
                .accessibilityLabel("Next keyboard")
            }
            KeyCap(kind: .letter, slot: nil, height: row, onUp: { model.type(" ") }) {
                Text("space").font(.system(size: 16))
            }
            .accessibilityLabel("Space")
            if !showsKeys { deleteKey(slot: unit * 1.5) }
            KeyCap(kind: model.returnProminent ? .action : .function, slot: unit * (model.returnTitle == nil ? 1.75 : 2.25), height: row,
                   onUp: { model.type("\n") }) {
                if let t = model.returnTitle {
                    Text(t).font(.system(size: 16)).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "return").font(.system(size: 18, weight: .medium))
                }
            }
            .accessibilityLabel(model.returnTitle?.capitalized ?? "Return")
        }
    }
}

/// One key: drawn like the system keyboard's, with a touch area that fills its whole slot.
private struct KeyCap<Label: View>: View {
    enum Kind { case letter, function, action }

    let kind: Kind
    /// The touch area's width; nil fills the space left in the row.
    let slot: CGFloat?
    /// The drawn key's width, when narrower than its slot.
    let visual: CGFloat?
    let align: Alignment
    let height: CGFloat
    /// The bigger letter shown above the key while it's held.
    let popup: String?
    let selected: Bool
    let onDown: (() -> Void)?
    let onUp: (() -> Void)?
    /// Called again and again while the key is held, with how many times so far.
    let onRepeat: ((Int) -> Void)?
    let label: Label

    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    init(kind: Kind, slot: CGFloat?, visual: CGFloat? = nil, align: Alignment = .center, height: CGFloat,
         popup: String? = nil, selected: Bool = false, onDown: (() -> Void)? = nil, onUp: (() -> Void)? = nil,
         onRepeat: ((Int) -> Void)? = nil, @ViewBuilder label: () -> Label) {
        self.kind = kind
        self.slot = slot
        self.visual = visual
        self.align = align
        self.height = height
        self.popup = popup
        self.selected = selected
        self.onDown = onDown
        self.onUp = onUp
        self.onRepeat = onRepeat
        self.label = label()
    }

    private static var gap: CGFloat { 6 }
    private static var vgap: CGFloat { 12 }

    var body: some View {
        // Before the keyboard has a width, every size is zero; never negative.
        let drawn = (visual ?? slot).map { max(Self.gap, $0) }
        let slot = self.slot.map { max(Self.gap, $0) }
        let shape = RoundedRectangle(cornerRadius: 8.5, style: .continuous)
        ZStack {
            shape.fill(fill).shadow(color: KeyColor.shadow, radius: 0, x: 0, y: 1)
            label.foregroundStyle(kind == .action ? Color.white : Color(.label))
        }
        .overlay(alignment: .top) {
            if pressed, let popup, let drawn, drawn > Self.gap {
                let w = drawn - Self.gap
                let h = max(0, height - Self.vgap)
                Text(popup).font(.system(size: 32, weight: .regular)).foregroundStyle(Color(.label))
                    .frame(width: w + 14, height: h * 1.2)
                    .background(KeyColor.letter, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .offset(y: -(h * 1.2) + 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Self.gap / 2).padding(.vertical, Self.vgap / 2)
        .frame(width: drawn).frame(maxWidth: drawn == nil ? .infinity : nil)
        .frame(width: slot, height: height, alignment: align)
        .frame(maxWidth: slot == nil ? .infinity : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    onDown?()
                    startRepeating()
                }
                .onEnded { _ in
                    pressed = false
                    repeater?.cancel()
                    repeater = nil
                    onUp?()
                }
        )
        .zIndex(pressed ? 1 : 0)
        .onDisappear { repeater?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onDown?(); onUp?() }
    }

    private var fill: Color {
        switch kind {
        case .action: return pressed ? KeyColor.pressed : Color(.systemBlue)
        case .function: return pressed ? KeyColor.pressed : selected ? KeyColor.letter : KeyColor.function
        case .letter: return pressed && popup == nil ? KeyColor.pressed : KeyColor.letter
        }
    }

    private func startRepeating() {
        guard let onRepeat else { return }
        repeater?.cancel()
        repeater = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            var n = 0
            while !Task.isCancelled {
                onRepeat(n)
                n += 1
                try? await Task.sleep(nanoseconds: n < 14 ? 85_000_000 : 230_000_000)
            }
        }
    }
}

/// The system keyboard's colors, so ClipBubble sits right next to it in light and dark.
private enum KeyColor {
    static let letter = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
    /// A key while it's held, and the system's darker keys before iOS 26.
    static let pressed = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1) })
    /// Since iOS 26 every key is the same color.
    static var function: Color {
        if #available(iOS 26, *) { return letter }
        return pressed
    }
    static let chip = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : .white })
    static let shadow = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.45) : UIColor(red: 0.53, green: 0.54, blue: 0.56, alpha: 0.6) })
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1) })
}

/// Items dip when touched.
private struct ChipPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// iOS 26 blurs and fades content scrolling under the edges, which smears the top row of items.
    @ViewBuilder func crispEdges() -> some View {
        if #available(iOS 26, *) { scrollEdgeEffectHidden(true, for: .all) } else { self }
    }
}

/// An item in the keyboard's history: what it is, how long ago, and the text or picture itself.
struct KeyboardChip: View {
    let clip: Clip
    var compact = false

    var body: some View {
        Group {
            if let p = clip.imagePath, !clip.remote {
                Color.clear
                    .overlay { Thumb(p, pixels: 540).scaledToFill() }
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        meta.padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(5)
                    }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(clip.look == .text && !clip.remote ? .footnote : .footnote.weight(.medium))
                        .foregroundStyle(clip.look == .link ? Brand.tint : Color(.label))
                        .lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
                    Spacer(minLength: 2)
                    meta
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: compact ? 50 : 64)
        .frame(maxWidth: .infinity)
        .background(KeyColor.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: KeyColor.shadow, radius: 0, x: 0, y: 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.kind == "text" ? String(clip.text.prefix(300)) : clip.remote ? "\(clip.look.name) on your computer" : clip.look.name)
        .accessibilityValue(clip.created.formatted(.relative(presentation: .named)))
        .accessibilityHint(clip.kind == "text" || KeyboardModel.isTypeableFile(clip) ? "Types it" : "Copies it to paste")
    }

    private var title: String {
        switch clip.kind {
        case "text": return clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "image": return clip.remote ? "Image on your computer" : "Image"
        default: return clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Image(systemName: clip.remote ? "icloud.and.arrow.down" : clip.look.symbol)
                .font(.system(size: 8, weight: .bold)).foregroundStyle(Brand.ink)
                .frame(width: 15, height: 15)
                .background(clip.remote ? Brand.mint : clip.look.pastel, in: Circle())
            Text(Self.age(clip.created)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    /// "now", "5m", "3h", "2d": short enough for a key.
    static func age(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
