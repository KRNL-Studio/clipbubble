import Foundation

func folderWatcherTests() {
    let folder = testHome.appendingPathComponent("folder-watch", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func add(_ name: String) {
        try? Data([1]).write(to: folder.appendingPathComponent(name))
    }
    add("existing.png")

    let entered = DispatchSemaphore(value: 0), allowList = DispatchSemaphore(value: 0)
    let snapshot = DispatchSemaphore(value: 0), allowReturn = DispatchSemaphore(value: 0)
    var first = true
    var delivered: [String] = []
    var onMain = true
    let started = Date()
    let watcher = FolderWatcher(folder: folder, maxAge: 120, include: { $0.pathExtension == "png" }, list: { url in
        guard first else { return FolderWatcher.listFiles(url) }
        first = false
        entered.signal()
        _ = allowList.wait(timeout: .now() + 3)
        let files = FolderWatcher.listFiles(url)
        snapshot.signal()
        _ = allowReturn.wait(timeout: .now() + 3)
        return files
    }) { url, _ in
        onMain = onMain && Thread.isMainThread
        delivered.append(url.lastPathComponent)
    }
    defer { watcher.stop() }

    check(Date().timeIntervalSince(started) < 1, "FolderWatcher init returns while its first listing is blocked")
    check(entered.wait(timeout: .now() + 2) == .success, "the first listing starts on a worker")
    add("before-snapshot.png")
    add("ignored.tmp")
    allowList.signal()
    check(snapshot.wait(timeout: .now() + 2) == .success, "the worker took its first snapshot")
    add("after-snapshot.png")
    allowReturn.signal()

    let deadline = Date().addingTimeInterval(3)
    while delivered.count < 2, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    var backfill: [String]?
    watcher.existing(days: 7) { backfill = $0.map { $0.0.lastPathComponent } }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    check(delivered.sorted() == ["after-snapshot.png", "before-snapshot.png"] && onMain,
          "files on both sides of the first snapshot arrive on main exactly once")
    check(backfill?.sorted() == ["after-snapshot.png", "before-snapshot.png", "existing.png"],
          "backfill includes existing files and respects the same filter")
}
