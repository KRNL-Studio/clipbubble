import CoreFoundation
import Foundation
import SQLite3

/// The shared history row is the outbox entry. Its bytes are installed before the SQLite commit.
enum ShareOutbox {
    static let source = "Share"
    static let saved = Notification.Name("studio.krnl.clipbubble.share.saved")
    private static var sent: URL { Paths.dir.appendingPathComponent("sent") }

    private static let forwarding: Void = {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            NotificationCenter.default.post(name: saved, object: nil)
        }, saved.rawValue as CFString, nil, .deliverImmediately)
    }()

    static func forwardWakeups() { _ = forwarding }

    private static func signal() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(saved.rawValue as CFString), nil, nil, true)
    }

    static func saveText(_ text: String) -> String? {
        guard text.utf8.count <= Sync.maxText, !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hash = "t:" + sha(text)
        guard DB().upsert(kind: "text", text: text, file: nil, source: source, hash: hash) else { return nil }
        signal()
        return hash
    }

    /// Works inside a provider's completion handler, while its temporary file still exists.
    static func saveFile(_ original: URL, name: String) -> String? {
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let name = safeFileName(name)
        let id = "share-" + UUID().uuidString
        let scratch = sent.appendingPathComponent("." + id)
        let folder = sent.appendingPathComponent(id)
        let file = folder.appendingPathComponent(name)
        let hash = "f:" + sha(file.path)

        let saved = withLock {
            guard let input = try? fm.attributesOfItem(atPath: original.path),
                  input[.type] as? FileAttributeType == .typeRegular,
                  let size = input[.size] as? NSNumber else { return false }
            let db = DB()

            var committed = false
            defer {
                try? fm.removeItem(at: scratch)
                if !committed { try? fm.removeItem(at: folder) }
            }
            do {
                try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
                let staged = scratch.appendingPathComponent(name)
                try fm.copyItem(at: original, to: staged)
                let output = try fm.attributesOfItem(atPath: staged.path)
                guard output[.type] as? FileAttributeType == .typeRegular,
                      output[.size] as? NSNumber == size,
                      rename(scratch.path, folder.path) == 0 else { return false }
                committed = db.upsert(kind: "file", text: file.path, file: nil, source: source, hash: hash)
                return committed
            } catch {
                return false
            }
        }
        guard saved else { return nil }
        signal()
        return hash
    }

    /// Recover a process killed during copy or between rename and commit. A busy lock means a live writer.
    static func recover() {
        _ = withLock(nonblocking: true) {
            guard let kept = referencedFolders() else { return false }
            let fm = FileManager.default
            let folders = (try? fm.contentsOfDirectory(at: sent, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let name = folder.lastPathComponent
                let published = !name.hasPrefix(".")
                let id = published ? name : String(name.dropFirst())
                guard id.hasPrefix("share-"), UUID(uuidString: String(id.dropFirst(6))) != nil,
                      !published || !kept.contains(folder.resolvingSymlinksInPath().path) else { continue }
                try? fm.removeItem(at: folder)
            }
            return true
        }
    }

    /// Select including hidden and expired rows. A DB error must never be mistaken for an empty outbox.
    private static func referencedFolders() -> Set<String>? {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(Paths.db.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT text FROM clips WHERE kind = 'file'", -1, &statement, nil) == SQLITE_OK else { return nil }
        var folders: Set<String> = []
        let sentPath = sent.resolvingSymlinksInPath().path
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return folders
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(statement, 0) else { return nil }
                for path in String(cString: value).split(separator: "\n") where path.hasPrefix("/") {
                    let folder = URL(fileURLWithPath: String(path)).resolvingSymlinksInPath().deletingLastPathComponent()
                    if folder.deletingLastPathComponent().path == sentPath { folders.insert(folder.path) }
                }
            default: return nil
            }
        }
    }

    private static func withLock(nonblocking: Bool = false, _ body: () -> Bool) -> Bool {
        guard (try? FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true)) != nil else { return false }
        let lock = Paths.dir.appendingPathComponent("share-outbox.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else { return false }
        return body()
    }
}
