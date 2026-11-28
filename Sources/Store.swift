import CryptoKit
import Foundation
import SQLite3

/// One clipboard entry. For files, `text` holds newline-separated paths.
struct Clip: Identifiable, Hashable {
    let id: Int64
    let kind: String          // "text" | "image" | "file"
    let text: String
    let file: String?         // stored PNG for images
    let source: String        // app name, or "iPhone" for Universal Clipboard
    let created: Date
    var hash = ""
    var origin = ""           // device id it was synced from; empty when copied on this machine
    var remote = false        // its image or files haven't arrived from that device yet
    var partial = false       // `text` is only the start of it; see DB.whole

    var paths: [String] { kind == "file" ? text.split(separator: "\n").map(String.init) : [] }
    var imagePath: String? { kind == "image" ? file : paths.first(where: isImagePath) }
}

let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
func isImagePath(_ p: String) -> Bool { imageExts.contains((p as NSString).pathExtension.lowercased()) }

func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
func sha(_ s: String) -> String { sha(Data(s.utf8)) }

enum Paths {
    /// `CLIPBUBBLE_HOME` points tests and a second local instance at their own data.
    static let dir = ProcessInfo.processInfo.environment["CLIPBUBBLE_HOME"].map { URL(fileURLWithPath: $0) }
        ?? Platform.dataDir
    static let images = dir.appendingPathComponent("images")
    static let db = dir.appendingPathComponent("clips.sqlite")
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite store shared by the app (writer) and the MCP server (reader).
final class DB {
    static let retention: TimeInterval = 7 * 24 * 3600
    /// Called with the hashes of every insert, bump or delete, from any DB in this process. Sync sets it;
    /// it stays nil (and costs nothing) when no device is linked.
    static var changed: (([String]) -> Void)?
    /// How much of a long text a list row holds.
    static let previewLength = 1000
    private var h: OpaquePointer?

    deinit { sqlite3_close_v2(h) }

    init() {
        // Clipboard history is private: keep the folder readable by this user only.
        try? FileManager.default.createDirectory(at: Paths.images, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.dir.path)
        guard sqlite3_open(Paths.db.path, &h) == SQLITE_OK else { return }
        sqlite3_busy_timeout(h, 3000)
        sqlite3_exec(h, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // A second process may have completed the schema while this one waited for the write lock.
        if let version = schemaVersion(), version >= 1 { return }
        _ = transaction {
            guard let version = schemaVersion() else { return false }
            guard version < 1 else { return true }
            // Keep existing row IDs when upgrading. Fresh databases never recycle deleted IDs.
            return run("""
                CREATE TABLE IF NOT EXISTS clips(
                  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT NOT NULL DEFAULT '',
                  file TEXT, source TEXT NOT NULL DEFAULT '', hash TEXT UNIQUE NOT NULL, created REAL NOT NULL)
                """)
                && run("CREATE INDEX IF NOT EXISTS clips_created ON clips(created)")
                && run("CREATE TABLE IF NOT EXISTS forgotten(hash TEXT PRIMARY KEY, at REAL NOT NULL)")
                && run("CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, os TEXT NOT NULL DEFAULT '')")
                && run("ALTER TABLE clips ADD COLUMN origin TEXT NOT NULL DEFAULT ''")
                && run("ALTER TABLE clips ADD COLUMN remote INTEGER NOT NULL DEFAULT 0")
                && run("PRAGMA user_version = 1")
        }
    }

    private func schemaVersion() -> Int? {
        let s = prepare("PRAGMA user_version", [])
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : nil
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard run("BEGIN IMMEDIATE") else { return false }
        if body(), run("COMMIT") { return true }
        _ = run("ROLLBACK")
        return false
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        Self.prepare(h, sql, args)
    }

    static func prepare(_ db: OpaquePointer?, _ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let result: Int32
            switch a {
            case let v as String: result = sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Double: result = sqlite3_bind_double(s, idx, v)
            case let v as Int64: result = sqlite3_bind_int64(s, idx, v)
            case let v as Int: result = sqlite3_bind_int64(s, idx, Int64(v))
            default: result = sqlite3_bind_null(s, idx)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(s); return nil }
        }
        return s
    }

    private func run(_ sql: String, _ args: Any?...) -> Bool { execute(sql, args) }

    private func execute(_ sql: String, _ args: [Any?]) -> Bool {
        guard let s = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_DONE
    }

    /// How many items are kept from before the last `hours`, for the iPhone's free tier.
    func count(olderThanHours hours: Double) -> Int {
        let now = Date().timeIntervalSince1970
        guard let s = prepare("SELECT COUNT(*) FROM clips WHERE created >= ? AND created < ?", [now - Self.retention, now - hours * 3600]) else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    private func select(_ tail: String, _ args: [Any?], preview: Bool = false) -> [Clip] {
        selectChecked(tail, args, preview: preview) ?? []
    }

    private func selectChecked(_ tail: String, _ args: [Any?], preview: Bool = false) -> [Clip]? {
        let n = Self.previewLength
        let text = preview ? "CASE WHEN kind = 'text' THEN substr(text, 1, \(n)) ELSE text END" : "text"
        let partial = preview ? "kind = 'text' AND length(text) > \(n)" : "0"
        let s = prepare("SELECT id,kind,\(text),file,source,created,hash,origin,remote,\(partial) FROM clips " + tail, args)
        defer { sqlite3_finalize(s) }
        var out: [Clip] = []
        while true {
            let result = sqlite3_step(s)
            if result == SQLITE_DONE { return out }
            guard result == SQLITE_ROW else { return nil }
            out.append(Self.readClip(s))
        }
    }

    static func readClip(_ s: OpaquePointer?) -> Clip {
        func col(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        return Clip(id: sqlite3_column_int64(s, 0), kind: col(1), text: col(2),
                    file: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : col(3),
                    source: col(4), created: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                    hash: col(6), origin: col(7), remote: sqlite3_column_int(s, 8) != 0,
                    partial: sqlite3_column_int(s, 9) != 0)
    }

    /// Inserts a clip, or moves an identical existing one to the top.
    @discardableResult
    func upsert(kind: String, text: String, file: String?, source: String, hash: String) -> Bool {
        guard run("""
            INSERT INTO clips(kind,text,file,source,hash,created) VALUES(?,?,?,?,?,?)
            ON CONFLICT(hash) DO UPDATE SET created=excluded.created, remote=0, origin='',
              file=COALESCE(excluded.file, clips.file),
              text=CASE WHEN clips.kind = 'file' THEN excluded.text ELSE clips.text END,
              source=CASE WHEN clips.source IN ('Screenshot', 'Downloads') THEN clips.source ELSE excluded.source END
            """, kind, text, file, source, hash, Date().timeIntervalSince1970) else { return false }
        DB.changed?([hash])
        return true
    }

    /// Adds a clip with its own timestamp, leaving any existing identical clip untouched,
    /// unless it was deleted after that time (a screenshot or download you removed stays removed).
    func insertIfMissing(kind: String, text: String, source: String, hash: String, created: Date) {
        if run("""
            INSERT OR IGNORE INTO clips(kind,text,source,hash,created)
            SELECT ?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM forgotten WHERE hash = ? AND at >= ?)
            """, kind, text, source, hash, created.timeIntervalSince1970, hash, created.timeIntervalSince1970), sqlite3_changes(h) > 0 { DB.changed?([hash]) }
    }

    /// `preview` trims long text for lists, which on iPhone can't hold thousands of megabyte-long items in memory.
    func clips(limit: Int = 300, kind: String? = nil, source: String? = nil,
               query: String? = nil, sinceHours: Double? = nil, preview: Bool = false) -> [Clip] {
        let (filter, args) = Self.clipFilter(kind: kind, source: source, query: query, sinceHours: sinceHours)
        let rows = select(filter + " ORDER BY created DESC LIMIT ?", args + [limit], preview: preview)
        // On iPhone a file's path is only the app's own folder, so its name is what a search means.
        guard Platform.os == "ios", let query, !query.isEmpty else { return rows }
        return rows.filter { c in
            c.kind != "file" || c.source.localizedCaseInsensitiveContains(query)
                || c.paths.contains { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(query) }
        }
    }

    static func clipFilter(kind: String?, source: String?, query: String?, sinceHours: Double? = nil) -> (String, [Any?]) {
        var filter = "WHERE created >= ?"
        var args: [Any?] = [Date().timeIntervalSince1970 - (sinceHours.map { $0 * 3600 } ?? Self.retention)]
        if kind == "image" {
            // Image files (like screenshots) count as images too.
            filter += " AND (kind = 'image' OR (kind = 'file' AND (" +
                imageExts.map { "text LIKE '%.\($0)'" }.joined(separator: " OR ") + ")))"
        } else if let kind {
            filter += " AND kind = ?"
            args.append(kind)
        }
        if let source {
            filter += " AND (source = ? COLLATE NOCASE OR origin IN (SELECT id FROM devices WHERE name = ? COLLATE NOCASE))"
            args += [source, source]
        }
        if let query, !query.isEmpty {
            // Match % and _ literally: search is plain text, not a pattern.
            let q = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            filter += " AND (text LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\')"
            args += [q, q]
        }
        return (filter + Prefs.hiddenSQL, args)
    }

    /// One clip by id. Items in categories switched off in Settings stay hidden here too (agents use this).
    func clip(id: Int64) -> Clip? { select("WHERE id = ?" + Prefs.hiddenSQL, [id]).first }

    func exists(hash: String) -> Bool { !select("WHERE hash = ?", [hash]).isEmpty }

    /// Removes a clip the app captured itself (a paste-through). Recorded as a delete so linked devices drop it too.
    func delete(hash: String) { delete("WHERE hash = ?", [hash]) }

    func delete(id: Int64) { delete("WHERE id = ?", [id]) }

    func deleteAll() { delete("", [], clearIncoming: true) }

    private func delete(_ filter: String, _ args: [Any?], clearIncoming: Bool = false) {
        guard let rows = removeRows(filter, args, at: Date().timeIntervalSince1970) else { return }
        cleanFiles(rows, sweepBefore: clearIncoming ? .infinity : nil)
        if !rows.isEmpty { DB.changed?(rows.map(\.hash)) }
    }

    /// Select the rows and record the delete while holding the same write lock.
    private func removeRows(_ filter: String, _ args: [Any?], at: Double, tombstone: Stamp? = nil,
                            expireForgottenBefore: Double? = nil) -> [Clip]? {
        var removed: [Clip] = []
        guard transaction({
            guard let rows = selectChecked(filter, args, preview: true) else { return false }
            removed = rows
            let upsert = "ON CONFLICT(hash) DO UPDATE SET at = max(at, excluded.at)"
            if let tombstone {
                guard run("INSERT INTO forgotten(hash, at) VALUES(?, ?) " + upsert, tombstone.hash, tombstone.time) else {
                    return false
                }
            } else if !rows.isEmpty {
                let source = filter.isEmpty ? "WHERE 1" : filter
                guard execute("INSERT INTO forgotten(hash, at) SELECT hash, ? FROM clips " + source + " " + upsert,
                              [at] + args) else { return false }
            }
            guard execute("DELETE FROM clips " + filter, args) else { return false }
            if let expireForgottenBefore { return run("DELETE FROM forgotten WHERE at < ?", expireForgottenBefore) }
            return true
        }) else { return nil }
        return removed
    }

    /// Check references after the deletion commits, under a write lock so another row can't claim a file during cleanup.
    private func cleanFiles(_ rows: [Clip], sweepBefore cutoff: Double? = nil) {
        guard cutoff != nil || rows.contains(where: {
            $0.kind == "image" && $0.file != nil || Platform.os == "ios" && $0.kind == "file"
        }) else { return }
        _ = transaction {
            guard let kept = referencedFiles() else { return false }
            removeFiles(rows, keeping: kept)
            if let cutoff { sweep(before: cutoff, keeping: kept) }
            return true
        }
    }

    private func referencedFiles() -> Set<String>? {
        var kept: Set<String> = []
        for (query, isPathList) in [("SELECT DISTINCT file FROM clips WHERE file IS NOT NULL", false),
                                    ("SELECT DISTINCT text FROM clips WHERE kind = 'file'", true)] {
            guard let s = prepare(query, []) else { return nil }
            defer { sqlite3_finalize(s) }
            while true {
                let result = sqlite3_step(s)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let value = sqlite3_column_text(s, 0) else { return nil }
                let text = String(cString: value)
                let paths = isPathList ? text.split(separator: "\n").map(String.init) : [text]
                kept.formUnion(paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            }
        }
        return kept
    }

    /// Only images ClipBubble stored itself and files sent or received on iOS belong to the store.
    private func removeFiles(_ clips: [Clip], keeping kept: Set<String>) {
        let sent = Paths.dir.appendingPathComponent("sent").resolvingSymlinksInPath().path
        let managed = [Paths.images.resolvingSymlinksInPath().path]
            + (Platform.os == "ios" ? [sent, receivedFolder("").deletingLastPathComponent().resolvingSymlinksInPath().path] : [])
        for c in clips {
            let files = c.kind == "image" ? [c.file].compactMap { $0 } : Platform.os == "ios" ? c.paths : []
            for f in files where f.hasPrefix("/") {
                let real = URL(fileURLWithPath: f).resolvingSymlinksInPath().path
                guard !kept.contains(real), managed.contains(where: { real.hasPrefix($0 + "/") }) else { continue }
                // unlink and rmdir won't recursively remove other entries sharing a folder.
                unlink(real)
                let parent = (real as NSString).deletingLastPathComponent
                if (parent as NSString).deletingLastPathComponent == sent { rmdir(parent) }
            }
        }
    }

    // MARK: Sync

    /// The winning event per hash over the retention window: copies (left out when their kind is switched off) and deletes.
    /// `includingWaiting: false` leaves out synced items whose bytes haven't arrived, so peers offer them again.
    func stamps(includingWaiting: Bool = true) -> [Stamp] {
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        var out: [String: Stamp] = [:]
        let s = prepare("""
            SELECT hash, created, 0 FROM clips WHERE created >= ?\(includingWaiting ? "" : " AND remote = 0")\(Prefs.hiddenSQL)
            UNION ALL SELECT hash, at, 1 FROM forgotten WHERE at >= ?
            """, [cutoff, cutoff])
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            let st = Stamp(hash: String(cString: sqlite3_column_text(s, 0)), time: sqlite3_column_double(s, 1),
                           deleted: sqlite3_column_int(s, 2) == 1)
            if st.beats(out[st.hash]) { out[st.hash] = st }
        }
        return Array(out.values)
    }

    func stamp(hash: String) -> Stamp? {
        let s = prepare("SELECT created, 0 FROM clips WHERE hash = ? UNION ALL SELECT at, 1 FROM forgotten WHERE hash = ?", [hash, hash])
        defer { sqlite3_finalize(s) }
        var best: Stamp?
        while sqlite3_step(s) == SQLITE_ROW {
            let st = Stamp(hash: hash, time: sqlite3_column_double(s, 0), deleted: sqlite3_column_int(s, 1) == 1)
            if st.beats(best) { best = st }
        }
        return best
    }

    func clip(hash: String) -> Clip? { select("WHERE hash = ?", [hash]).first }

    /// The full item behind a list row.
    func whole(_ c: Clip) -> Clip { c.partial ? clip(hash: c.hash) ?? c : c }

    /// Whether a kind of item from a source would be shown, under the Settings switches.
    func allowed(kind: String, source: String) -> Bool {
        let s = prepare("SELECT 1 FROM (SELECT ? AS kind, ? AS source) WHERE 1" + Prefs.hiddenSQL, [kind, source])
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW
    }

    /// Adds an item from a linked device. Its image or files are marked remote until they arrive.
    @discardableResult
    func insert(_ e: Entry, origin: String) -> Bool {
        let names = e.kind == "file" ? e.text : ""
        guard run("""
            INSERT INTO clips(kind,text,source,hash,created,origin,remote) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(hash) DO UPDATE SET created = max(created, excluded.created)
            """, e.kind, e.kind == "text" ? e.text : names, e.source, e.hash, e.time, origin, e.blobs.isEmpty ? 0 : 1) else { return false }
        DB.changed?([e.hash])
        return true
    }

    @discardableResult
    func bump(hash: String, to time: Double) -> Bool {
        guard run("UPDATE clips SET created = ? WHERE hash = ? AND created < ?", time, hash, time),
              sqlite3_changes(h) > 0 else { return false }
        DB.changed?([hash])
        return true
    }

    /// A delete from a linked device: removes the item unless it was copied again after that.
    @discardableResult
    func tombstone(_ st: Stamp) -> Bool {
        guard let rows = removeRows("WHERE hash = ? AND created <= ?", [st.hash, st.time], at: st.time,
                                    tombstone: st) else { return false }
        cleanFiles(rows)
        DB.changed?([st.hash])
        return true
    }

    /// An image or files arrived: point the item at them and make it pasteable.
    @discardableResult
    func received(hash: String, file: String?, text: String?) -> Bool {
        let saved: Bool
        if let text {
            saved = run("UPDATE clips SET remote = 0, text = ? WHERE hash = ? AND remote = 1", text, hash)
        } else {
            saved = run("UPDATE clips SET remote = 0, file = ? WHERE hash = ? AND remote = 1", file, hash)
        }
        guard saved, sqlite3_changes(h) > 0 else { return false }
        DB.changed?([hash])
        return true
    }

    /// Whether this was news: a device not seen before, or one with a new name.
    @discardableResult
    func saveDevice(id: String, name: String, os: String) -> Bool {
        return run("""
            INSERT INTO devices(id,name,os) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, os=excluded.os
            WHERE name != excluded.name OR os != excluded.os
            """, id, name, os) && sqlite3_changes(h) > 0
    }

    func devices() -> [(id: String, name: String, os: String)] {
        let s = prepare("SELECT id, name, os FROM devices", [])
        defer { sqlite3_finalize(s) }
        var out: [(id: String, name: String, os: String)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(s, 0)), String(cString: sqlite3_column_text(s, 1)), String(cString: sqlite3_column_text(s, 2))))
        }
        return out
    }

    func deviceNames() -> [String: String] {
        let s = prepare("SELECT id, name FROM devices", [])
        defer { sqlite3_finalize(s) }
        var out: [String: String] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(s, 0))] = String(cString: sqlite3_column_text(s, 1))
        }
        return out
    }

    /// Drops everything older than the 7-day retention window.
    func prune() {
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        // Expiration is local: its tombstones are already outside the sync window.
        guard let rows = removeRows("WHERE created < ?", [cutoff], at: cutoff,
                                    expireForgottenBefore: cutoff - 86400) else { return }
        cleanFiles(rows, sweepBefore: cutoff)
        if !rows.isEmpty { DB.changed?(rows.map(\.hash)) }
    }

    /// Clean orphan images and abandoned staging files. Clear all also removes recent staging files.
    private func sweep(before cutoff: Double, keeping kept: Set<String>) {
        let incoming = Paths.dir.appendingPathComponent("incoming")
        let clearIncoming = cutoff == .infinity
        for dir in clearIncoming ? [incoming] : [Paths.images, incoming] {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                guard !kept.contains(f.resolvingSymlinksInPath().path),
                      let at = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      at.timeIntervalSince1970 < cutoff else { continue }
                if dir == incoming {
                    let fd = open(f.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                    guard fd >= 0 else { continue }
                    if flock(fd, LOCK_EX | LOCK_NB) == 0 { unlink(f.path) }
                    close(fd)
                } else {
                    unlink(f.path)
                }
            }
        }
        if clearIncoming { rmdir(incoming.path) }
    }

}

/// What gets saved. Off means it isn't captured and existing items are hidden everywhere, MCP included.
enum Prefs {
    struct Category { let key, title, icon: String; let detail: String?; let sql: String }
    static let categories: [Category] = [
        .init(key: "text", title: "Copied text", icon: "text.alignleft", detail: nil, sql: "kind = 'text' AND source <> 'iPhone'"),
        .init(key: "images", title: "Copied images", icon: "photo", detail: nil, sql: "kind = 'image' AND source <> 'iPhone'"),
        .init(key: "files", title: "Copied files", icon: "doc", detail: "Files you copy in Finder",
              sql: "kind = 'file' AND source NOT IN ('Screenshot', 'Downloads', 'iPhone')"),
        .init(key: "screenshots", title: "Screenshots", icon: "camera.viewfinder", detail: "Every new screenshot, even ones you don't copy",
              sql: "source = 'Screenshot'"),
        .init(key: "downloads", title: "Recent downloads", icon: "arrow.down.circle", detail: "New files in your Downloads folder",
              sql: "source = 'Downloads'"),
        .init(key: "iphone", title: "Copies from iPhone", icon: "iphone", detail: "Through Universal Clipboard", sql: "source = 'iPhone'"),
    ]
    static func on(_ key: String) -> Bool { Platform.defaults.object(forKey: "save." + key) as? Bool ?? true }
    static func set(_ key: String, _ value: Bool) { Platform.defaults.set(value, forKey: "save." + key) }
    static var hiddenSQL: String { categories.filter { !on($0.key) }.map { " AND NOT (\($0.sql))" }.joined() }
}
