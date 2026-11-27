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
        guard first else { return try FolderWatcher.listFiles(url) }
        first = false
        entered.signal()
        _ = allowList.wait(timeout: .now() + 3)
        let files = try FolderWatcher.listFiles(url)
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

    folderWatcherRetryTest()
    folderWatcherMissingFolderTest()
    folderWatcherPermissionTests()
    folderWatcherRevokedPermissionTest()
}

private func folderWatcherRetryTest() {
    let folder = testHome.appendingPathComponent("folder-watch-retry", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let shot = folder.appendingPathComponent("retry.png")
    let ready = DispatchSemaphore(value: 0)
    let failed = DispatchSemaphore(value: 0)
    var scans = 0
    var injectedFailure = false
    var delivered: [String] = []
    let watcher = FolderWatcher(folder: folder, maxAge: 120, include: { $0.pathExtension == "png" }, retryDelay: 0.05, list: { url in
        let files = try FolderWatcher.listFiles(url)
        scans += 1
        if scans == 2 { ready.signal() }
        if !injectedFailure, files.contains(where: { $0.lastPathComponent == shot.lastPathComponent }) {
            injectedFailure = true
            failed.signal()
            throw POSIXError(.EIO)
        }
        return files
    }) { url, _ in delivered.append(url.lastPathComponent) }
    defer { watcher.stop() }

    check(ready.wait(timeout: .now() + 3) == .success, "folder watch finished its startup scans")
    try? Data([1]).write(to: shot)
    check(failed.wait(timeout: .now() + 3) == .success, "the first scan after a write hit the injected error")
    let deadline = Date().addingTimeInterval(3)
    while delivered.isEmpty, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(delivered == ["retry.png"], "a failed scan retries and delivers the screenshot once without another write")
}

private func folderWatcherMissingFolderTest() {
    let folder = testHome.appendingPathComponent("folder-watch-missing", isDirectory: true)
    let opens = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var attempts: [TimeInterval] = []
    var granted = false
    let watcher = FolderWatcher(folder: folder, maxAge: nil, include: { _ in true }, retryDelay: 0.1,
                                openFolder: { url in
        defer {
            lock.withLock { attempts.append(ProcessInfo.processInfo.systemUptime) }
            opens.signal()
        }
        return try FolderWatcher.openFolder(url)
    }, onAccessChanged: { granted = $0 }) { _, _ in }
    defer { watcher.stop() }

    check(opens.wait(timeout: .now() + 2) == .success, "the watcher tries to open a missing folder")
    check(opens.wait(timeout: .now() + 2) == .success, "a missing folder is retried automatically")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let deadline = Date().addingTimeInterval(3)
    while !granted, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let times = lock.withLock { attempts }
    check(times.count >= 3 && times[2] - times[1] >= 0.18, "the next attempt backs off from 0.1s to 0.2s")
    check(granted, "a folder created after a failed open is watched automatically")
}

private func folderWatcherPermissionTests() {
    let errors: [(String, NSError, Bool)] = [
        ("open EPERM", NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), true),
        ("list EACCES", NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), false),
        ("list Cocoa no permission", NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), false),
    ]
    for (index, (label, error, denyOpen)) in errors.enumerated() {
        let folder = testHome.appendingPathComponent("folder-watch-permission-\(index)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let denied = DispatchSemaphore(value: 0)
        let permission = NSLock()
        var allowed = false
        func checkPermission() throws {
            guard permission.withLock({ allowed }) else { denied.signal(); throw error }
        }
        var statuses: [Bool] = []
        var delivered: [String] = []
        let watcher = FolderWatcher(folder: folder, maxAge: nil, include: { _ in true }, retryDelay: 0.05,
                                    openFolder: { url in
            if denyOpen { try checkPermission() }
            return try FolderWatcher.openFolder(url)
        }, list: { url in
            if !denyOpen { try checkPermission() }
            return try FolderWatcher.listFiles(url)
        }, onAccessChanged: { statuses.append($0) }) { url, _ in delivered.append(url.lastPathComponent) }
        defer { watcher.stop() }

        check(denied.wait(timeout: .now() + 2) == .success, "\(label) reaches the watcher")
        watcher.existing(days: 7) { _ in check(false, "backfill should skip a paused watcher") }
        try? Data([1]).write(to: folder.appendingPathComponent("while-paused.png"))
        check(denied.wait(timeout: .now() + 0.5) == .timedOut, "\(label) pauses timer, file event, and backfill reads")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(statuses == [false] && delivered.isEmpty, "\(label) reports no access while paused")

        permission.withLock { allowed = true }
        watcher.retryIfPaused()
        let deadline = Date().addingTimeInterval(3)
        while delivered.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(statuses == [false, true] && delivered == ["while-paused.png"], "\(label) resumes and imports files added during the pause")
    }
}

private func folderWatcherRevokedPermissionTest() {
    let folder = testHome.appendingPathComponent("folder-watch-revoked", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lock = NSLock()
    let denied = DispatchSemaphore(value: 0)
    var allowed = true
    var statuses: [Bool] = []
    var delivered: [String] = []
    let watcher = FolderWatcher(folder: folder, maxAge: nil, include: { _ in true }, retryDelay: 0.05, list: { url in
        guard lock.withLock({ allowed }) else { denied.signal(); throw POSIXError(.EACCES) }
        return try FolderWatcher.listFiles(url)
    }, onAccessChanged: { statuses.append($0) }) { url, _ in delivered.append(url.lastPathComponent) }
    defer { watcher.stop() }

    let initialDeadline = Date().addingTimeInterval(3)
    while statuses.isEmpty, Date() < initialDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(statuses == [true], "the folder is readable before permission is revoked")
    lock.withLock { allowed = false }
    try? Data([1]).write(to: folder.appendingPathComponent("after-revocation.png"))
    check(denied.wait(timeout: .now() + 2) == .success, "the event scan detects revoked access")
    check(denied.wait(timeout: .now() + 0.5) == .timedOut, "revoked access cancels automatic retries")
    lock.withLock { allowed = true }
    watcher.retryIfPaused()
    let deadline = Date().addingTimeInterval(3)
    while delivered.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(statuses == [true, false, true] && delivered == ["after-revocation.png"], "the resumed watch delivers files it missed during revocation")
}

func guiInstanceLockTests() {
    do {
        var first = try GUIInstanceLock()
        check(first != nil, "the first GUI acquires the lock")
        let path = Paths.dir.appendingPathComponent("app.lock").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "the lock file is private")

        let second = try GUIInstanceLock()
        check(second == nil, "a second descriptor cannot lock the same data directory")
        let other = try GUIInstanceLock(directory: testHome.appendingPathComponent("isolated-gui"))
        check(other != nil, "an isolated data directory has its own lock")
        first = nil
        check(FileManager.default.fileExists(atPath: path), "releasing the lock leaves the file in place")
        let reopened = try GUIInstanceLock()
        check(reopened != nil, "the same lock file can be acquired again after close")
    } catch {
        check(false, "GUI lock setup failed: \(error)")
    }
}
