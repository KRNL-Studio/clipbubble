import Foundation
import SQLite3

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        exit(1)
    }
}

func eventually(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(5)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < end
    return false
}

@main
struct Wave3Tests {
    static func main() async throws {
        if CommandLine.arguments.count > 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            guard let hash = ShareOutbox.saveFile(file, name: "shared-original.bin") else { exit(1) }
            print(hash)
            return
        }
        try transportTests()
        try await outboxTests()
        print("All Wave 3 Swift host tests passed")
    }

    @MainActor
    private static func outboxTests() async throws {
        let fm = FileManager.default
        let origin = Paths.dir.appendingPathComponent("provider.bin")
        require(fm.createFile(atPath: origin.path, contents: nil), "create a provider file")
        let file = try FileHandle(forWritingTo: origin)
        let size = UInt64(Sync.autoFetchLimit) + 1024
        try file.truncate(atOffset: size)
        try file.close()

        ShareOutbox.forwardWakeups()
        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: ShareOutbox.saved, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { notified = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let hash = try saveFromOtherProcess(origin.path)
        let db = DB()
        guard let clip = db.clip(hash: hash), let path = clip.paths.first else {
            require(false, "main process reads committed share from SQLite")
            return
        }
        require(clip.source == ShareOutbox.source && !clip.remote && clip.origin.isEmpty, "share is a local outbox item")
        let stagedSize = try fm.attributesOfItem(atPath: path)[.size] as? NSNumber
        require(stagedSize?.uint64Value == size, "the committed row references a complete file")
        try fm.removeItem(at: origin)
        let wakeDeadline = ContinuousClock.now + .seconds(3)
        while !notified, ContinuousClock.now < wakeDeadline { try await Task.sleep(for: .milliseconds(20)) }
        require(notified, "share process wakes the main process via Darwin notification")

        Platform.defaults.set(["loopback-test"], forKey: "sync.hosts")
        let timedOut = await Courier.deliverSaved([hash], timeout: 0.1)
        require(timedOut.contains("will sync when connected"), "timeout reports the item was saved")
        let cancelled = Task { await Courier.deliverSaved([hash]) }
        try await Task.sleep(for: .milliseconds(150))
        cancelled.cancel()
        let early = await cancelled.value
        require(early == timedOut, "early cancellation reports durable save")
        Platform.defaults.removeObject(forKey: "sync.hosts")
        require(DB().clip(hash: hash)?.paths == [path] && fm.fileExists(atPath: path), "timeout and cancellation preserve the row and bytes")
        print("PASS cross-process Share commit and wakeup, timeout and early cancellation")

        let sent = Paths.dir.appendingPathComponent("sent")
        var sqlite: OpaquePointer?
        require(sqlite3_open(Paths.db.path, &sqlite) == SQLITE_OK, "open real SQLite database")
        defer { sqlite3_close_v2(sqlite) }
        let reject = """
            CREATE TRIGGER reject_share BEFORE INSERT ON clips WHEN NEW.source = 'Share'
            BEGIN SELECT RAISE(ABORT, 'test DB failure'); END;
            """
        require(sqlite3_exec(sqlite, reject, nil, nil, nil) == SQLITE_OK, "inject a SQLite failure")
        require(ShareOutbox.saveFile(URL(fileURLWithPath: path), name: "rejected.bin") == nil, "surface DB write failure")
        require(sqlite3_exec(sqlite, "DROP TRIGGER reject_share", nil, nil, nil) == SQLITE_OK, "restore writes")
        let abandoned = sent.appendingPathComponent("share-" + UUID().uuidString)
        let scratch = sent.appendingPathComponent(".share-" + UUID().uuidString)
        for orphan in [abandoned, scratch] { try fm.createDirectory(at: orphan, withIntermediateDirectories: false) }
        ShareOutbox.recover()
        let folders = try fm.contentsOfDirectory(atPath: sent.path)
        require(folders == [URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent],
                "failed stage and interrupted stages leave only the committed file")
        print("PASS SQLite failure rollback and orphan recovery")

        try syncOutbox(hash, path: path, tick: clip.created.timeIntervalSince1970)
        db.delete(hash: hash)
        require(db.stamp(hash: hash)?.deleted == true && !fm.fileExists(atPath: path), "tombstone removes the staged file")
        print("PASS automatic large-file offer, idempotent reconciliation, tombstone cleanup")
    }

    private static func saveFromOtherProcess(_ path: String) throws -> String {
        let extensionProcess = Process()
        extensionProcess.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        extensionProcess.arguments = [path]
        let result = Pipe()
        extensionProcess.standardOutput = result
        try extensionProcess.run()
        extensionProcess.waitUntilExit()
        require(extensionProcess.terminationStatus == 0, "separate share process commits before exiting")
        return String(decoding: result.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func syncOutbox(_ hash: String, path: String, tick: Double) throws {
        let engine = SyncEngine.shared
        let stamp = Stamp(hash: hash, time: tick, deleted: false)
        for peerHasItem in [false, true] {
            let ssh = try Loopback()
            defer { ssh.shutdown() }
            let s = Session(transport: ssh.transport, engine: engine)
            let closed = DispatchSemaphore(value: 0)
            engine.queue.sync {
                ShareSync.observe(s, over: ssh.transport)
                s.onClose = { closed.signal() }
                engine.begin(s)
            }
            try ssh.beginServerReads()
            let hello = Hello(proto: Sync.proto, device: "share-peer", name: "Receiver", os: "macos", version: "test",
                              clock: Date().timeIntervalSince1970)
            try ssh.send(Frame.hello(hello).encoded() + Frame.summary(peerHasItem ? [stamp] : []).encoded()).wait()
            require(eventually { engine.queue.sync { s.summarized } }, "peer is reconciled")
            if !peerHasItem {
                require(eventually { ssh.frames().contains(.offer(hash: hash)) }, "offline outbox automatically offers a large shared file")
            }
            ShareSync.refresh()
            ShareSync.refresh()
            engine.queue.sync {}
            engine.queue.sync { s.send(.ping(42)) }
            require(eventually { ssh.frames().contains(.ping(42)) }, "replay flushes")
            let frames = ssh.frames()
            require(frames.filter { $0 == .offer(hash: hash) }.count == (peerHasItem ? 0 : 1), "only one offer for a peer missing the item")
            let puts = frames.filter { if case .put(let entry) = $0 { return entry.hash == hash }; return false }
            require(puts.count == (peerHasItem ? 0 : 1), "same hash converges without duplicate puts")
            if peerHasItem {
                let live = try saveFromOtherProcess(path)
                ShareSync.refresh()
                require(eventually { ssh.frames().contains(.offer(hash: live)) }, "wake picks up a new share on an existing link")
                let db = DB()
                db.delete(hash: live)
                require(eventually {
                    ssh.frames().contains { if case .tombstone(let stamp) = $0 { return stamp.hash == live }; return false }
                }, "deletion propagates on the existing link")
            }
            ssh.disconnect()
            require(closed.wait(timeout: .now() + 5) == .success, "session closes before reconnect")
        }
    }
}
