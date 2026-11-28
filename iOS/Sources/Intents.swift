import AppIntents
import SQLite3
import UIKit

/// Shortcuts, Siri, Back Tap and the Action button: send to the computers without opening ClipBubble.
struct SendToComputers: AppIntent {
    static let title: LocalizedStringResource = "Send to Computers"
    static let description = IntentDescription("Puts text or a file on the clipboard of your linked computers. With neither, it sends what's on this device's clipboard.")

    @Parameter(title: "Text") var text: String?
    @Parameter(title: "File") var file: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to computers") { \.$file }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (text, file) = (text, file)
        let message = await Courier.deliver {
            if let file {
                return await Task.detached { () -> [String] in
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: dir) }
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent(safeFileName(file.filename))
                        try file.data.write(to: url)
                        return Inbox.file(url, source: "Shortcuts").map { [$0] } ?? []
                    } catch {
                        return []
                    }
                }.value
            }
            if let text { return Inbox.text(text, source: "Shortcuts").map { [$0] } ?? [] }
            return await Inbox.add(UIPasteboard.general.itemProviders, source: "Clipboard")
        }
        return .result(dialog: "\(message)")
    }
}

/// The other way: whatever you copied last on a computer, onto this iPhone's clipboard.
struct CopyLatestFromComputers: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest from Computers"
    static let description = IntentDescription("Copies the newest item from a linked computer, or the newest item on this device if none came from a computer. Returns text when available.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let engine = SyncEngine.shared
        engine.hold(true)
        defer { engine.hold(false) }
        engine.start()
        let end = Date().addingTimeInterval(10)
        while Date() < end, !engine.statuses.values.contains(where: \.ok), !SyncEngine.enabledHosts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Long enough for the computers' recent history to arrive after the link comes up.
        if engine.statuses.values.contains(where: \.ok) { try await Task.sleep(nanoseconds: 1_500_000_000) }
        try Task.checkCancellation()

        let clip: Clip?
        do {
            let db = DB()
            clip = try Self.latestHash().flatMap { db.clip(hash: $0) }
        } catch {
            return .result(value: "", dialog: "Couldn't read ClipBubble's history.")
        }
        guard let clip else { return .result(value: "", dialog: "ClipBubble's history is empty.") }
        guard !clip.remote else {
            return .result(value: "", dialog: "This item is still on your computer. Open it in ClipBubble to get it.")
        }
        guard Clipboard.write(clip) else { return .result(value: "", dialog: "Couldn't copy that item.") }
        let value = clip.kind == "text" ? clip.text : clip.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return .result(value: value, dialog: "Copied \(value.isEmpty ? "an image" : String(value.prefix(80))).")
    }

    private enum HistoryError: Error { case readFailed }

    /// Select just the winning hash, even if thousands of newer clips came from this iPhone.
    private static func latestHash() throws -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(Paths.db.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw HistoryError.readFailed }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            SELECT hash FROM clips WHERE created >= ?\(Prefs.hiddenSQL)
            ORDER BY origin = '', created DESC, id DESC LIMIT 1
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970 - DB.retention) == SQLITE_OK else {
            throw HistoryError.readFailed
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_DONE: return nil
        default: throw HistoryError.readFailed
        }
    }
}

struct ClipBubbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToComputers(), phrases: ["Send clipboard with \(.applicationName)", "\(.applicationName) send clipboard"],
                    shortTitle: "Send Clipboard", systemImageName: "arrow.up.doc.on.clipboard")
        AppShortcut(intent: CopyLatestFromComputers(), phrases: ["Copy latest from \(.applicationName)", "\(.applicationName) get clipboard"],
                    shortTitle: "Copy Latest", systemImageName: "arrow.down.doc.on.clipboard")
    }
}
