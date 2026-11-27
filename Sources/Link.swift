import Foundation
import Network

/// Links this Mac's history with ClipBubble on other machines over SSH (docs/sync-protocol.md).
/// Everything here runs on `queue`. Nothing connects until a host is switched on or a peer dials in.
final class SyncEngine {
    static let shared = SyncEngine()

    let queue = DispatchQueue(label: "clipbubble.sync", qos: .utility)
    let device: String
    let name: String
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Puts a synced item on the clipboard. Tests and `--peer-stdio` swap it so they never touch the real one.
    var apply: (Clip) -> Void = Platform.apply
    /// Main thread: history changed, or a link's state changed (for Settings).
    var onReceived: () -> Void = {}
    /// Main thread, after `onReceived`: that change was an item arriving or moving up (for the bubble).
    var onNew: () -> Void = {}
    var onStatus: () -> Void = {}
    /// Main thread: files moving right now, about four times a second while any are.
    var onTransfers: ([String: Transfer]) -> Void = { _ in }
    /// Main thread: a device put one of this machine's items on its clipboard, with that device's name.
    var onApplied: (String, String) -> Void = { _, _ in }

    private lazy var db = DB()
    private var sessions: [Session] = []
    private var links: [String: HostLink] = [:]
    private var server: AnyObject?
    private var pathMonitor: NWPathMonitor?
    private var hooked = false
    /// When each outgoing item was sent, to log copy-to-applied latency.
    private var sentAt: [String: Double] = [:]
    /// Items you pressed Get on: they download whatever their size, again after a dropped link.
    private var wanted: Set<String> = []
    private var progressTimer: DispatchSourceTimer?
    private var lastTransfers: [String: Transfer] = [:]
    private var suspended = false
    private var holds = 0

    private init() {
        device = Self.loadDeviceID()
        name = ProcessInfo.processInfo.environment["CLIPBUBBLE_DEVICE_NAME"] ?? Platform.deviceName
    }

    private static func loadDeviceID() -> String {
        let newID = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        let path = Paths.dir.appendingPathComponent("device-id").path
        var fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_EXLOCK, 0o600)
        if fd < 0, errno == EEXIST { fd = open(path, O_RDWR | O_EXLOCK | O_NOFOLLOW) }
        guard fd >= 0 else {
            // A read-only store can still use an established identity.
            return readDeviceID(path) ?? newID
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // An opener may acquire the lock first after another process creates the file.
        if let existing = readDeviceID(path) { return existing }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: Data(newID.utf8))
        return newID
    }

    private static func readDeviceID(_ path: String) -> String? {
        guard let id = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    // MARK: Hosts

    static var enabledHosts: [String] { Platform.defaults.stringArray(forKey: "sync.hosts") ?? [] }
    static var paused: Bool { Platform.defaults.bool(forKey: "sync.paused") }

    /// Called at launch: listens for peers (no CPU while idle) and dials the hosts switched on.
    func start() {
        queue.async { [self] in
            if server == nil { server = Platform.listen(self) }
            reconcileLinks()
        }
    }

    func setHost(_ alias: String, on: Bool) {
        var hosts = Self.enabledHosts.filter { $0 != alias }
        if on { hosts.append(alias) }
        Platform.defaults.set(hosts, forKey: "sync.hosts")
        queue.async { self.reconcileLinks() }
    }

    /// Tries a host again now, say right after setting it up.
    func redial(_ alias: String) { queue.async { self.links[alias]?.redial() } }

    // MARK: Manual transfers

    /// Get: downloads an item that's still on another device, whatever its size. `started` says on the main thread
    /// whether a linked device has it to send; if none does, it comes over once one offers it.
    func get(_ hash: String, started: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            wanted.insert(hash)
            guard let s = sessions.first(where: { $0.offered[hash] != nil }), let e = s.offered[hash] else {
                return DispatchQueue.main.async { started(false) }
            }
            s.download(makeDownload(e, from: s, apply: false))
            watchTransfers()
            DispatchQueue.main.async { started(true) }
        }
    }

    /// Send to: asks a linked device to fetch one of this machine's items now.
    func send(_ hash: String, toDevice device: String) {
        queue.async { [self] in
            guard let s = sessions.first(where: { $0.peer?.device == device && $0.summarized }) else { return }
            if let st = db.stamp(hash: hash), st.beats(s.known[hash]) { send(st, to: s) }
            s.send(.offer(hash: hash))
        }
    }

    /// Stops a transfer either way and throws away what arrived.
    func cancelTransfer(_ hash: String) {
        queue.async { [self] in
            wanted.remove(hash)
            for s in sessions where s.isTransferring(hash) {
                s.cancelDownload(hash)
                s.cancelUpload(hash)
                s.send(.cancel(hash: hash))
            }
            publishTransfers()
        }
    }


    private func makeDownload(_ e: Entry, from s: Session, apply: Bool) -> Download {
        Download(hash: e.hash, kind: e.kind, names: e.blobs.map(\.name), shas: e.blobs.map(\.sha), sizes: e.blobs.map(\.size),
                 from: s.peer?.name ?? "Device", apply: apply)
    }

    /// Progress ticks only while something is moving, so an idle link costs nothing.
    func watchTransfers() {
        guard progressTimer == nil else { return publishTransfers() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.publishTransfers() }
        progressTimer = t
        t.resume()
    }

    private func publishTransfers() {
        var all: [String: Transfer] = [:]
        for s in sessions { all.merge(s.transfers()) { a, _ in a } }
        if all.isEmpty { progressTimer?.cancel(); progressTimer = nil }
        guard all != lastTransfers else { return }
        lastTransfers = all
        DispatchQueue.main.async { self.onTransfers(all) }
    }

    /// An iPhone's app and keyboard share one device ID, and a computer keeps only the newest link from a device,
    /// so two of them linked at once knock each other off. Only the one on screen links; the other suspends.
    func suspend(_ on: Bool) {
        queue.async { [self] in
            guard on != suspended else { return }
            suspended = on
            if on, holds == 0 { sessions.forEach { $0.close() } }
            reconcileLinks()
        }
    }

    /// A Shortcut can run while the app sits suspended in the background, and needs the link for as long as it runs.
    func hold(_ on: Bool) {
        queue.async { [self] in
            holds += on ? 1 : -1
            reconcileLinks()
        }
    }

    /// A paired device lost its key. Close incoming sessions so still-authorized peers reconnect.
    func dropPhones() {
        queue.async { [self] in sessions.filter { $0.link == nil }.forEach { $0.close() } }
    }

    func setPaused(_ paused: Bool) {
        Platform.defaults.set(paused, forKey: "sync.paused")
        queue.async { [self] in
            if paused { sessions.forEach { $0.close() } }
            reconcileLinks()
        }
    }

    /// Statuses for Settings, read on the main thread.
    private(set) var statuses: [String: LinkState] = [:]

    private func reconcileLinks() {
        let want = Self.paused || (suspended && holds == 0) ? [] : Set(Self.enabledHosts)
        for (alias, link) in links where !want.contains(alias) {
            link.stop()
            links[alias] = nil
        }
        for alias in want where links[alias] == nil {
            let link = HostLink(alias: alias, engine: self)
            links[alias] = link
            link.connect()
        }
        if !links.isEmpty { watchNetwork() }
        publishStatus()
    }

    /// Devices linked right now, for Send to. Read on the main thread.
    private(set) var linked: [Hello] = []

    func publishStatus() {
        var s: [String: LinkState] = [:]
        for (alias, link) in links { s[alias] = link.state }
        let peers = sessions.compactMap(\.peer)
        DispatchQueue.main.async { self.statuses = s; self.linked = peers; self.onStatus() }
    }

    /// Wake and network changes redial right away instead of waiting out the backoff.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            guard p.status == .satisfied else { return }
            self?.queue.async { self?.links.values.forEach { $0.networkChanged() } }
        }
        m.start(queue: queue)
        pathMonitor = m
        Platform.onWake { [weak self] in self?.queue.async { self?.links.values.forEach { $0.redial() } } }
    }

    // MARK: Sessions

    /// A peer dialled in through `--peer`, or a host link's ssh came up.
    func begin(_ s: Session) {
        if Self.paused && s.link == nil { s.close(); return }
        sessions.append(s)
        hookChanges()
        s.start(hello: Hello(proto: Sync.proto, device: device, name: name, os: Platform.os, version: version,
                             clock: Date().timeIntervalSince1970), summary: db.stamps(includingWaiting: false))
    }

    func ended(_ s: Session) {
        sessions.removeAll { $0 === s }
        s.link?.sessionEnded(s)
        let peers = Set(sessions.compactMap { $0.peer?.device })
        links.values.forEach { $0.takeOver(unlessLinked: peers) }
        publishStatus()
    }

    /// The change hook is installed once, the first time a link opens, and only queues work after that.
    private func hookChanges() {
        guard !hooked else { return }
        hooked = true
        DB.changed = { [weak self] hashes in self?.queue.async { self?.broadcast(hashes) } }
    }

    /// Sends local changes, and relays changes from one peer, to every peer that doesn't have them yet.
    private func broadcast(_ hashes: [String]) {
        let ready = sessions.filter(\.summarized)
        guard !ready.isEmpty else { return }
        for hash in Set(hashes) {
            guard let st = db.stamp(hash: hash) else { continue }
            for s in ready where st.beats(s.known[hash]) { send(st, to: s) }
        }
    }

    private func send(_ st: Stamp, to s: Session) {
        if st.deleted {
            s.fetchable[st.hash] = nil
            s.known[st.hash] = st
            s.send(.tombstone(st))
            return
        }
        guard let c = db.clip(hash: st.hash), db.allowed(kind: c.kind, source: c.source), let (e, paths) = entry(c) else { return }
        s.known[st.hash] = st
        s.fetchable[st.hash] = paths.isEmpty ? nil : paths
        // Only fresh copies get acked, so only they are timed.
        if c.origin.isEmpty, Date().timeIntervalSince(c.created) < 10 { sentAt[st.hash] = Date().timeIntervalSince1970 }
        s.send(.put(e))
    }

    private func entry(_ c: Clip) -> (Entry, [String])? {
        var paths: [String] = []
        var e = Entry(hash: c.hash, time: c.created.timeIntervalSince1970, kind: c.kind, text: "", source: c.source,
                      origin: c.origin.isEmpty ? device : c.origin, blobs: [])
        switch c.kind {
        case "text":
            // Only an old version stores more than this. Sent, it would drop the link on every reconnect.
            guard c.text.utf8.count <= Sync.maxText else { return nil }
            e.text = c.text
        case "image":
            // Offered before its bytes are here, an item is a dead end for every device after this one.
            guard !c.remote, let f = c.file, let size = regularFileSize(f) else { return nil }
            paths = [f]
            e.blobs = [Blob(name: String(c.hash.dropFirst(2)) + ".png", size: size, sha: String(c.hash.dropFirst(2)))]
        default:
            guard !c.remote else { return nil }
            let files = blobFiles(c)
            e.text = c.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
            paths = files.map(\.path)
            e.blobs = files.map { Blob(name: ($0.path as NSString).lastPathComponent, size: $0.size, sha: "") }
        }
        return (e, paths)
    }

    /// The files an item can send: regular files only, in order. Folders show by name but don't transfer.
    private func blobFiles(_ c: Clip) -> [(path: String, size: Int64)] {
        c.paths.compactMap { path in regularFileSize(path).map { (path, $0) } }
    }

    private func regularFileSize(_ path: String) -> Int64? {
        guard path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    // MARK: Frames

    func handle(_ f: Frame, from s: Session) {
        switch f {
        case .hello(let h):
            guard h.proto == Sync.proto else {
                SyncLog.write("\(h.name) speaks protocol \(h.proto), this device \(Sync.proto)")
                s.link?.versionMismatch(h)
                s.close()
                return
            }
            guard h.device != device else { s.close(); return }
            let old = sessions.first { $0 !== s && $0.peer?.device == h.device }
            // A device dialling in again has given up on its old link (an iPhone that slept), and two names for one
            // computer look the same from there: either way the far end keeps the new link, so this end has to as well.
            if let old, (old.link == nil) != (s.link == nil) {
                // Both peers keep the connection dialled by the device with the smaller ID.
                guard (s.link != nil) == (device < h.device) else {
                    s.link?.standBy(for: h)
                    s.close()
                    return
                }
            }
            s.peer = h
            old?.link?.standBy(for: h)
            old?.close()
            s.offset = h.clock - Date().timeIntervalSince1970
            if abs(s.offset) > 30 { SyncLog.write("\(h.name)'s clock is \(s.offset.rounded()) s off") }
            if db.saveDevice(id: h.device, name: h.name, os: h.os) { share(id: h.device, name: h.name, os: h.os, from: s) }
            if h.readsDevices {
                for d in db.devices() where d.id != h.device { s.send(.device(id: d.id, name: d.name, os: d.os)) }
            }
            s.link?.helloReceived(h)
            SyncLog.write("linked with \(h.name) (\(h.os) \(h.version))")
            publishStatus()
        case .summary(let stamps):
            guard s.peer != nil else { s.close(); return }
            s.known = Dictionary(stamps.map { ($0.hash, $0) }, uniquingKeysWith: { $0.beats($1) ? $0 : $1 })
            s.summarized = true
            let mine = reconcile(local: db.stamps(), remote: stamps)
            for st in mine.sorted(by: { $0.time < $1.time }) { send(st, to: s) }
            SyncLog.write("reconciled with \(s.peer!.name): sent \(mine.count) of \(stamps.count) known there")
        case .put(let e):
            received(e, from: s)
        case .tombstone(let st):
            guard st.deleted else { s.close(); return }
            if st.beats(s.known[st.hash]) { s.known[st.hash] = st }
            if merge(local: db.stamp(hash: st.hash), hasRow: db.clip(hash: st.hash) != nil, incoming: st) == .delete {
                guard db.tombstone(st) else { return }
                wanted.remove(st.hash)
                for peer in sessions {
                    peer.offered[st.hash] = nil
                    if peer.cancelDownload(st.hash) { peer.send(.cancel(hash: st.hash)) }
                }
                publishTransfers()
                notifyUI()
            }
        case .fetch(let hash, let index, let offset):
            // A `put` on this link is the only way in, so naming a hash or a path reaches nothing else.
            guard let path = s.fetchable[hash]?[safe: index],
                  let c = db.clip(hash: hash), !c.remote, db.allowed(kind: c.kind, source: c.source),
                  s.upload(hash: hash, index: index, path: path, offset: offset) else {
                s.send(.cancel(hash: hash))
                return
            }
            watchTransfers()
        case .chunk(let hash, let index, let offset, let total, let bytes):
            if let done = s.chunk(hash: hash, index: index, offset: offset, total: total, bytes: bytes) { finished(done, from: s) }
        case .cancel(let hash):
            s.cancelUpload(hash)
            s.cancelDownload(hash)
        case .applied(let hash):
            let peer = s.peer?.name ?? "peer"
            DispatchQueue.main.async { self.onApplied(hash, peer) }
            if let t = sentAt.removeValue(forKey: hash) {
                SyncLog.write("applied on \(s.peer?.name ?? "peer") in \(Int((Date().timeIntervalSince1970 - t) * 1000)) ms")
            }
        case .ping(let t):
            s.send(.pong(t))
        case .pong:
            break
        case .offer(let hash):
            guard let e = s.offered[hash], db.clip(hash: hash)?.remote == true else { return }
            s.download(makeDownload(e, from: s, apply: false))
            watchTransfers()
        case .device(let id, let name, let os):
            guard let peer = s.peer else { s.close(); return }
            guard id != device, id != peer.device, db.saveDevice(id: id, name: name, os: os) else { return }
            share(id: id, name: name, os: os, from: s)
            notifyUI()
        }
    }

    /// Passes news of a device on to the other links, so a device two hops away still shows its name.
    /// Only news travels, so names settle after one pass however the devices are linked.
    private func share(id: String, name: String, os: String, from s: Session) {
        for o in sessions where o !== s && o.peer.map({ $0.readsDevices && $0.device != id }) == true {
            o.send(.device(id: id, name: name, os: os))
        }
    }

    private func received(_ e: Entry, from s: Session) {
        let st = e.stamp
        if st.beats(s.known[e.hash]) { s.known[e.hash] = st }
        guard e.time >= Date().timeIntervalSince1970 - DB.retention else { return }
        let row = db.clip(hash: e.hash)
        // Copied seconds ago on its device, and newer than anything here: it's what you just copied, so it goes on the clipboard.
        let now = Date().timeIntervalSince1970
        let localTime = e.time - s.offset
        let fresh = localTime > now - 10 && localTime <= now + 300
            && e.time > (db.clips(limit: 1).first?.created.timeIntervalSince1970 ?? 0)
        var new = false
        switch merge(local: db.stamp(hash: e.hash), hasRow: row != nil, incoming: st) {
        case .delete:
            return
        case .ignore:
            guard row?.remote == true else { return }
        case .bump:
            guard let row, db.allowed(kind: e.kind, source: e.source), db.allowed(kind: row.kind, source: row.source) else { return }
            guard db.bump(hash: e.hash, to: e.time) else { return }
            new = true
            if fresh, let c = db.clip(hash: e.hash), !c.remote { applyNow(c, to: s) }
        case .insert:
            guard db.allowed(kind: e.kind, source: e.source) else { return }
            var named = e
            if e.kind == "file" { named.text = e.text.split(separator: "\n").map { safeFileName(String($0)) }.joined(separator: "\n") }
            guard db.insert(named, origin: e.origin == device ? "" : e.origin) else { return }
            new = true
            if e.kind == "text", fresh, let c = db.clip(hash: e.hash) { applyNow(c, to: s) }
        }
        // Still missing its bytes, whether new here or left over from a link that dropped mid-download.
        if !e.blobs.isEmpty, db.clip(hash: e.hash)?.remote == true {
            s.offered[e.hash] = e
            if e.size <= Sync.autoFetchLimit || wanted.contains(e.hash) {
                s.download(makeDownload(e, from: s, apply: fresh))
                watchTransfers()
            }
        }
        notifyUI(new: new)
    }

    private func applyNow(_ c: Clip, to s: Session) {
        apply(c)
        s.send(.applied(hash: c.hash))
    }

    private func finished(_ d: Download, from s: Session) {
        let image = d.kind == "image"
        guard db.received(hash: d.hash, file: image ? d.paths.first : nil,
                          text: image ? nil : d.paths.joined(separator: "\n")) else { return }
        wanted.remove(d.hash)
        s.offered[d.hash] = nil
        // Still the newest item once the bytes are here: put it on the clipboard.
        if d.apply, !d.bounced, let c = db.clip(hash: d.hash), db.clips(limit: 1).first?.hash == d.hash { applyNow(c, to: s) }
        notifyUI()
    }

    private func notifyUI(new: Bool = false) { DispatchQueue.main.async { self.onReceived(); if new { self.onNew() } } }

    /// `--peer-stdio`: one session on this process's stdin and stdout, with no UI. For tests and interop checks.
    func serveStdio() {
        queue.async { [self] in
            let s = Session(input: .standardInput, output: .standardOutput, engine: self)
            s.onClose = { exit(0) }
            begin(s)
        }
    }
}

// MARK: - Link state

/// Where a link stands. The failures follow the order a connection goes through: finding the host, reaching its SSH
/// server, checking its identity, logging in, finding ClipBubble there, then agreeing on a version.
enum LinkState: Equatable {
    case connecting
    case live(Hello)
    /// The name doesn't resolve: not on this network, or a typo.
    case unresolved
    /// Something answered but refused SSH: Remote Login or the SSH server is off there.
    case refused
    /// Its identity isn't known yet: check its fingerprint before trusting it.
    case unknownHost
    /// Its identity is different from the one trusted before. Never fixed by retrying.
    case hostKeyChanged
    /// The login was turned down, for this user and host ("you@mac.local") when SSH says which.
    case needsKeyAuth(String)
    case notInstalled
    case appNotRunning
    case versionMismatch(Hello)
    case offline(Date)

    var text: String {
        switch self {
        case .connecting: return "Connecting…"
        case .live(let h): return "Linked with \(h.name)"
        case .unresolved: return "Can't find it on this network. Check the name, or that it's on"
        case .refused: return "It's not accepting connections. Turn on Remote Login or SSH there"
        case .unknownHost: return "Not trusted yet. Check its identity to trust it"
        case .hostKeyChanged: return "Its identity changed. Don't trust it unless you reinstalled it, then link it again"
        case .needsKeyAuth(let who):
            return who.isEmpty ? "Wasn't let in. Link it again, or add this computer's key there"
                : "\(who) wasn't let in. Check the user name, or link it again"
        case .notInstalled: return "ClipBubble isn't installed there"
        case .appNotRunning: return "ClipBubble isn't running there"
        case .versionMismatch(let h): return "Update needed (it has \(h.version))"
        case .offline(let at):
            let s = max(0, Int(at.timeIntervalSinceNow))
            return s > 0 ? "Offline, retrying in \(s < 60 ? "\(s) s" : "\(s / 60) min")" : "Offline"
        }
    }

    var ok: Bool { if case .live = self { true } else { false } }

    /// A short name for diagnostics, the same on every platform.
    var kind: String {
        switch self {
        case .connecting: return "connecting"
        case .live: return "live"
        case .unresolved: return "unresolved"
        case .refused: return "refused"
        case .unknownHost: return "unknown-host"
        case .hostKeyChanged: return "host-key-changed"
        case .needsKeyAuth: return "needs-key"
        case .notInstalled: return "not-installed"
        case .appNotRunning: return "not-running"
        case .versionMismatch: return "version"
        case .offline: return "offline"
        }
    }

    /// Network trouble that often clears by itself, so it keeps retrying soon, as does ClipBubble not running there yet,
    /// so the link comes back as soon as it's opened. Everything else waits for a person.
    var transient: Bool {
        switch self {
        case .offline, .unresolved, .refused, .connecting, .appNotRunning: return true
        default: return false
        }
    }

    /// Reads why ssh (or the iPhone's own SSH) ended, from what it printed. Nil means it just dropped or timed out.
    /// Nothing here ever turns host checking off or replaces a trusted key: those are left to the person.
    static func failure(stderr err: String, windows: Bool) -> LinkState? {
        if err.contains("CLIPBUBBLE_NOT_INSTALLED") || (windows && err.contains("cannot find the path")) { return .notInstalled }
        if err.contains("CLIPBUBBLE_NOT_RUNNING") { return .appNotRunning }
        if err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || err.contains("Host key for") && err.contains("has changed") {
            return .hostKeyChanged
        }
        if err.contains("Host key verification failed") || err.contains("host key is known") { return .unknownHost }
        if err.contains("Permission denied") || err.contains("Too many authentication failures") {
            // OpenSSH says "you@host: Permission denied (publickey)."
            let line = err.split(whereSeparator: \.isNewline).first { $0.contains("Permission denied") }.map(String.init) ?? ""
            let who = line.components(separatedBy: ": Permission denied").first ?? ""
            return .needsKeyAuth(who.contains("@") && who.count < 200 && !who.contains(" ") ? who : "")
        }
        if err.contains("Could not resolve hostname") || err.contains("nodename nor servname") { return .unresolved }
        if err.contains("Connection refused") { return .refused }
        return nil
    }
}

/// A relay running on a host over SSH: frames in on `input`, frames out on `output`.
protocol Tunnel: AnyObject {
    var input: FileHandle { get }
    var output: FileHandle { get }
    func close()
}

/// One host: runs `--peer` there over SSH, retries with backoff, and turns SSH's errors into a status.
final class HostLink {
    let alias: String
    private unowned let engine: SyncEngine
    private var tunnel: Tunnel?
    private var session: Session?
    private var stderr = ""
    private var lastError = ""
    private var backoff: Double = 1
    private var retry: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var pulse: DispatchSourceTimer?
    private var stopped = false
    private var mismatch: Hello?
    /// Redial was asked for while an attempt was still running.
    private var again = false
    /// The device another alias already reached, which keeps only one link. This one waits for that link to end.
    private var standby: String?
    private(set) var state: LinkState = .connecting

    private static let helloLimit: Double = 20
    private static let pingEvery: Double = 15
    private static let probeLimit: Double = 5

    private var windows: Bool {
        get { Platform.defaults.string(forKey: "sync.os." + alias) == "windows" }
        set { Platform.defaults.set(newValue ? "windows" : "posix", forKey: "sync.os." + alias) }
    }

    init(alias: String, engine: SyncEngine) {
        self.alias = alias
        self.engine = engine
    }

    /// Finds ClipBubble where each platform installs it and runs its relay. Nothing from the clipboard goes in this string.
    private var remoteCommand: String {
        windows
            ? #""%LOCALAPPDATA%\Programs\ClipBubble\ClipBubble.exe" --peer"#
            : #"sh -c 'for p in "$HOME/.local/bin/clipbubble" "$HOME/Applications/ClipBubble.app/Contents/MacOS/ClipBubble" /Applications/ClipBubble.app/Contents/MacOS/ClipBubble; do [ -x "$p" ] && exec "$p" --peer; done; echo CLIPBUBBLE_NOT_INSTALLED >&2; exit 127'"#
    }

    func connect() {
        guard !stopped, tunnel == nil, !alias.hasPrefix("-") else { return }
        retry?.cancel()
        set(.connecting)
        stderr = ""
        let t: Tunnel
        do {
            t = try Platform.dial(alias, remoteCommand,
                stderr: { [weak self] d in self?.engine.queue.async { if (self?.stderr.count ?? 0) < 8192 { self?.stderr += String(decoding: d, as: UTF8.self) } } },
                exited: { [weak self] in self?.engine.queue.async { self?.exited() } })
        } catch { set(.offline(Date().addingTimeInterval(backoff))); scheduleRetry(); return }
        tunnel = t
        let s = Session(input: t.input, output: t.output, engine: engine)
        s.link = self
        session = s
        engine.begin(s)
        // The connect timeout ends at TCP. A computer that accepts and then says nothing would read "Connecting…" forever.
        let d = DispatchWorkItem { [weak self] in
            guard let self else { return }
            logError("no answer in \(Int(Self.helloLimit)) s")
            hangUp()
        }
        deadline = d
        engine.queue.asyncAfter(deadline: .now() + Self.helloLimit, execute: d)
    }

    func helloReceived(_ h: Hello) {
        deadline?.cancel()
        backoff = 1
        lastError = ""
        mismatch = nil
        Platform.defaults.set(Date().timeIntervalSince1970, forKey: "sync.lastLive." + alias)
        set(.live(h))
        watchPeer()
    }

    /// SSH's keepalives only prove the connection. A ping proves ClipBubble is answering at the far end, and an idle
    /// link has no other way to find out. Anything heard counts, so a long download never looks silent.
    private func watchPeer() {
        let t = DispatchSource.makeTimerSource(queue: engine.queue)
        t.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        pulse = t
    }

    private func beat() {
        guard let s = session else { return }
        if s.silence < Self.pingEvery * 2 { return s.send(.ping(Date().timeIntervalSince1970)) }
        SyncLog.write("\(alias): no answer to pings")
        hangUp()
    }

    private func hangUp() {
        if let s = session { s.close() } else { tunnel?.close() }
    }

    /// Another alias reached this computer: stop retrying, and show the link as up, since it is.
    func standBy(for h: Hello) {
        standby = h.device
        set(.live(h))
    }

    func takeOver(unlessLinked peers: Set<String>) {
        guard let d = standby, !peers.contains(d) else { return }
        standby = nil
        backoff = 1
        connect()
    }

    func versionMismatch(_ h: Hello) { mismatch = h }

    func sessionEnded(_ s: Session) {
        guard session === s else { return }
        session = nil
        tunnel?.close()
    }

    private func exited() {
        let wasLive = state.ok
        tunnel = nil
        deadline?.cancel()
        pulse?.cancel()
        pulse = nil
        if let s = session { session = nil; s.close() }
        guard !stopped, standby == nil else { return }
        if again { again = false; return connect() }
        let err = stderr
        if !windows && (err.contains("is not recognized") || err.contains("CommandNotFoundException")) {
            windows = true
            connect()
            return
        }
        let next = mismatch.map(LinkState.versionMismatch) ?? LinkState.failure(stderr: err, windows: windows)
            ?? .offline(Date().addingTimeInterval(wasLive ? 1 : backoff))
        logError(String(err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))
        // Problems only you can fix retry slowly; a dropped link comes back fast.
        if !next.transient { backoff = max(backoff, 60) }
        if wasLive { backoff = 1 }
        set(next)
        scheduleRetry()
    }

    private func logError(_ message: String) {
        guard !message.isEmpty, lastError != message else { return }
        lastError = message
        SyncLog.write("\(alias): \(message)")
    }

    private func scheduleRetry() {
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        retry = w
        engine.queue.asyncAfter(deadline: .now() + backoff, execute: w)
        backoff = min(backoff * 2, Platform.retryCap)
    }

    /// A link that looks fine may have died with the old network, so it has one ping to prove otherwise.
    func networkChanged() {
        switch state {
        case .offline, .unresolved, .refused: return redial()
        default: break
        }
        guard state.ok, let s = session else { return }
        let asked = DispatchTime.now()
        s.send(.ping(Date().timeIntervalSince1970))
        engine.queue.asyncAfter(deadline: asked + Self.probeLimit) { [weak self, weak s] in
            guard let self, let s, session === s, s.heardAt < asked else { return }
            SyncLog.write("\(alias): no answer after the network changed")
            hangUp()
        }
    }

    func redial() {
        guard !stopped, standby == nil else { return }
        backoff = 1
        if tunnel == nil { connect() }
        // Asking again means this attempt isn't getting anywhere, or may not be.
        else if !state.ok { again = true; hangUp() }
    }

    func stop() {
        stopped = true
        retry?.cancel()
        deadline?.cancel()
        pulse?.cancel()
        session?.close()
        tunnel?.close()
    }

    private func set(_ s: LinkState) {
        state = s
        engine.publishStatus()
    }
}

// MARK: - Session

/// One peer: reads frames, and writes them with control frames always ahead of file chunks.
final class Session {
    private let input: FileHandle
    private let output: FileHandle
    private unowned let engine: SyncEngine
    weak var link: HostLink?
    var onClose: () -> Void = {}
    var peer: Hello?
    var offset: Double = 0
    var summarized = false
    /// The latest event the peer is known to have per hash, so nothing is sent twice or echoed back.
    var known: [String: Stamp] = [:]
    /// Items the peer has bytes for that haven't come over yet, with their blob sizes, for Get and Send to.
    var offered: [String: Entry] = [:]
    /// Items sent to the peer with bytes on this link: the only ones it may fetch. `known` won't do, since the peer's summary fills it.
    var fetchable: [String: [String]] = [:]
    private var reader = FrameReader()
    private var downloads: [String: Download] = [:]
    private var pendingDownloads: [Download] = []

    private let lock = NSLock()
    private var control: [Data] = []
    private var uploads: [Upload] = []
    private var writing = false
    private(set) var heardAt = DispatchTime.now()
    private(set) var closed = false
    private let writeQueue = DispatchQueue(label: "clipbubble.sync.write", qos: .utility)

    init(input: FileHandle, output: FileHandle, engine: SyncEngine) {
        self.input = input
        self.output = output
        self.engine = engine
    }

    func start(hello: Hello, summary: [Stamp]) {
        input.readabilityHandler = { [weak self] h in
            guard let self, let d = self.readReady(h) else { return }
            self.engine.queue.async {
                guard !self.closed else { return }
                if d.isEmpty { self.close(); return }
                self.heardAt = .now()
                do { for f in try self.reader.feed(d) where !self.closed { self.engine.handle(f, from: self) } }
                catch { SyncLog.write("dropped \(self.peer?.name ?? "peer"): malformed frame"); self.close() }
            }
        }
        send(.hello(hello))
        send(.summary(summary))
    }

    private func readReady(_ handle: FileHandle) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        // Read once: FileHandle's throwing read can wait to fill the buffer, and availableData raises on error.
        var data = Data(count: 64 * 1024)
        let n = data.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if n < 0, errno == EINTR || errno == EAGAIN { return nil }
        if n <= 0 { return Data() }
        data.count = n
        return data
    }

    /// Seconds since anything arrived, not counting sleep. Read on the engine's queue.
    var silence: Double { Double(DispatchTime.now().uptimeNanoseconds - heardAt.uptimeNanoseconds) / 1e9 }

    func send(_ f: Frame) {
        lock.lock()
        control.append(f.encoded())
        lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        guard !writing, !closed else { lock.unlock(); return }
        writing = true
        lock.unlock()
        writeQueue.async { [self] in
            while let data = next() {
                do { try output.write(contentsOf: data) }
                catch { engine.queue.async { self.close() }; break }
            }
        }
    }

    /// The next bytes to write: any control frame first, else one chunk of the oldest upload.
    private func next() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if closed { writing = false; return nil }
        if !control.isEmpty { return control.removeFirst() }
        while let u = uploads.first {
            if let frame = u.nextChunk() {
                if u.done { uploads.removeFirst() }
                return frame.encoded()
            }
            uploads.removeFirst()
            control.append(Frame.cancel(hash: u.hash).encoded())
            return control.removeFirst()
        }
        writing = false
        return nil
    }

    func upload(hash: String, index: Int, path: String, offset: Int64) -> Bool {
        guard let u = Upload(hash: hash, index: index, path: path, offset: offset) else { return false }
        lock.lock()
        uploads.append(u)
        lock.unlock()
        pump()
        return true
    }

    func cancelUpload(_ hash: String) {
        lock.lock()
        uploads.removeAll { $0.hash == hash }
        lock.unlock()
    }

    func isTransferring(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return downloads[hash] != nil || pendingDownloads.contains { $0.hash == hash } || uploads.contains { $0.hash == hash }
    }

    func transfers() -> [String: Transfer] {
        let name = peer?.name ?? "Device"
        var out: [String: Transfer] = [:]
        for d in downloads.values { out[d.hash] = Transfer(done: d.doneBytes, total: d.total, peer: name, sending: false) }
        for d in pendingDownloads { out[d.hash] = Transfer(done: d.doneBytes, total: d.total, peer: name, sending: false) }
        lock.lock()
        for u in uploads { out[u.hash] = Transfer(done: u.sent, total: u.total, peer: name, sending: true) }
        lock.unlock()
        return out
    }

    // Downloads run one at a time per peer, so a backlog can't flood the link.

    func download(_ d: Download) {
        guard downloads[d.hash] == nil, !pendingDownloads.contains(where: { $0.hash == d.hash }) else { return }
        if downloads.isEmpty { begin(d) } else { pendingDownloads.append(d) }
    }

    private func begin(_ d: Download) {
        d.resume()
        downloads[d.hash] = d
        send(.fetch(hash: d.hash, index: d.index, offset: d.received))
    }

    @discardableResult
    func cancelDownload(_ hash: String) -> Bool {
        pendingDownloads.removeAll { $0.hash == hash }
        guard let d = downloads.removeValue(forKey: hash) else { return false }
        d.discard()
        startNext()
        return true
    }

    private func startNext() {
        guard downloads.isEmpty, !pendingDownloads.isEmpty else { return }
        begin(pendingDownloads.removeFirst())
    }

    /// Writes a chunk. Returns the download once its last file is in place.
    func chunk(hash: String, index: Int, offset: Int64, total: Int64, bytes: Data) -> Download? {
        guard let d = downloads[hash], index == d.index, offset == d.received else { return nil }
        switch d.write(bytes, total: total) {
        case .more:
            return nil
        case .failed:
            SyncLog.write("couldn't save \(d.names[safe: index] ?? hash) from \(d.from)")
            d.discard()
            send(.cancel(hash: hash))
            downloads[hash] = nil
            startNext()
            return nil
        case .nextFile:
            send(.fetch(hash: hash, index: d.index, offset: 0))
            return nil
        case .done:
            downloads[hash] = nil
            startNext()
            return d
        }
    }

    func close() {
        lock.lock()
        let was = closed
        closed = true
        uploads.removeAll()
        lock.unlock()
        guard !was else { return }
        input.readabilityHandler = nil
        try? output.close()
        try? input.close()
        // Partial files stay, so the next link resumes them from where this one stopped.
        downloads.values.forEach { $0.suspend() }
        downloads.removeAll()
        engine.ended(self)
        onClose()
    }
}

/// Reads one file out in chunks as the link has room. Lives on the session's write queue.
final class Upload {
    let hash: String
    let index: Int
    private let handle: FileHandle
    private var offset: Int64
    let total: Int64
    var sent: Int64 { offset }
    private var sentEmpty = false
    var done: Bool { offset >= total && (total > 0 || sentEmpty) }

    init?(hash: String, index: Int, path: String, offset: Int64) {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              offset >= 0, offset <= info.st_size, (try? h.seek(toOffset: UInt64(offset))) != nil else { return nil }
        self.hash = hash
        self.index = index
        self.handle = h
        self.offset = offset
        self.total = info.st_size
    }

    deinit { try? handle.close() }

    /// nil when the file shrank under us: the transfer is cancelled rather than sent short.
    func nextChunk() -> Frame? {
        let n = Int(min(Int64(Sync.chunkSize), total - offset))
        let bytes = n > 0 ? ((try? handle.read(upToCount: n)) ?? Data()) : Data()
        guard bytes.count == n else { return nil }
        let f = Frame.chunk(hash: hash, index: index, offset: offset, total: total, bytes: bytes)
        offset += Int64(n)
        if n == 0 { sentEmpty = true }
        return f
    }
}

/// An item's image or files arriving, one file after another, into a temp file and then their final place.
final class Download {
    enum Step { case more, nextFile, done, failed }
    let hash: String
    let kind: String
    let names: [String]
    let shas: [String]
    let sizes: [Int64]
    let from: String
    let apply: Bool
    var total: Int64 { Sync.blobSize(sizes) ?? .max }
    var doneBytes: Int64 {
        guard let completed = Sync.blobSize(sizes.prefix(index)), received <= Int64.max - completed else { return .max }
        return completed + received
    }
    private(set) var index = 0
    private(set) var received: Int64 = 0
    private(set) var paths: [String] = []
    /// A file was already here from a moment ago, so this is the same file coming back: it doesn't go on the clipboard.
    private(set) var bounced = false
    private var handle: FileHandle?
    private let stagingHash: String
    private var stagingSuffix = ""
    private var temp: URL { Paths.dir.appendingPathComponent("incoming/\(stagingHash)\(stagingSuffix)-\(index)") }

    init(hash: String, kind: String, names: [String], shas: [String], sizes: [Int64], from: String, apply: Bool) {
        self.hash = hash
        self.kind = kind
        self.names = names
        self.shas = shas
        self.sizes = sizes
        self.from = from
        self.apply = apply
        stagingHash = sha(hash)
    }

    /// Keep the resume file locked until it is placed or discarded. A concurrent
    /// transfer starts from zero in its own file.
    func resume() {
        guard index == 0, handle == nil else { return }
        handle = openStaging()
        if handle == nil {
            stagingSuffix = "-" + UUID().uuidString
            handle = openStaging()
        }
        guard let handle else { return }
        do {
            let size = try handle.seekToEnd()
            if let expected = sizes.first, expected >= 0, size <= UInt64(expected) {
                received = Int64(size)
            } else {
                try reset(handle)
            }
        } catch { discard() }
    }

    private func openStaging() -> FileHandle? {
        try? FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(temp.path, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return nil }
        return handle
    }

    func write(_ bytes: Data, total: Int64) -> Step {
        guard index < names.count, let expected = sizes[safe: index], total == expected,
              received <= total, Int64(bytes.count) <= total - received else { return .failed }
        if handle == nil {
            handle = openStaging()
            guard let handle, (try? reset(handle)) != nil else { return .failed }
        }
        guard let h = handle, (try? h.write(contentsOf: bytes)) != nil else { return .failed }
        received += Int64(bytes.count)
        guard received == total else { return .more }
        guard let dest = place() else { return .failed }
        suspend()
        paths.append(dest)
        index += 1
        received = 0
        return index < names.count ? .nextFile : .done
    }

    private func reset(_ handle: FileHandle) throws {
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
    }

    /// Images go next to ClipBubble's own; files go to Downloads/ClipBubble/<device>/ under a safe, unique name.
    private func place() -> String? {
        if kind == "image" {
            let expected = shas[safe: index] ?? ""
            guard let data = FileManager.default.contents(atPath: temp.path) else { return nil }
            let digest = sha(data)
            guard expected.isEmpty || digest == expected else { return nil }
            let dest = Paths.images.appendingPathComponent(digest + ".png")
            guard rename(temp.path, dest.path) == 0 else { return nil }
            return dest.path
        }
        let dir = receivedFolder(from)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = safeFileName(names[index])
        // The same bytes under the same name are already here: keep that one copy instead of saving another.
        if let same = sameFile(as: temp.path, named: name, in: dir) {
            try? FileManager.default.removeItem(at: temp)
            // Saved moments ago, it's bouncing back: two Macs on one Apple ID pass every clipboard write on through
            // Universal Clipboard, so putting it on the clipboard again would send it round once more.
            let saved = (try? FileManager.default.attributesOfItem(atPath: same.path))?[.modificationDate] as? Date
            if let saved, Date().timeIntervalSince(saved) < 60 { bounced = true }
            return same.path
        }
        let dest = uniqueURL(in: dir, name: name)
        guard (try? FileManager.default.moveItem(at: temp, to: dest)) != nil else { return nil }
        return dest.path
    }

    func suspend() {
        try? handle?.close()
        handle = nil
    }

    func discard() {
        if handle != nil { unlink(temp.path) }
        suspend()
    }
}

/// A file moving between devices, for progress in the panel.
struct Transfer: Equatable {
    var done: Int64
    var total: Int64
    var peer: String
    var sending: Bool
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// Where files from another device land.
func receivedFolder(_ device: String) -> URL {
    let downloads = ProcessInfo.processInfo.environment["CLIPBUBBLE_DOWNLOADS"].map { URL(fileURLWithPath: $0) }
        ?? Platform.downloads
    return downloads.appendingPathComponent("ClipBubble").appendingPathComponent(safeFileName(device))
}

/// A name from another machine can't climb out of its folder or hide itself.
func safeFileName(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        .replacingOccurrences(of: ":", with: "_").filter { !$0.isNewline && $0 != "\0" }
    while let first = s.first, first == "." || first.isWhitespace { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // A long name is cut before its extension, so the file still opens with the right app.
    if s.count > 200 {
        let ext = numbered(s).ext
        let tail = ext.isEmpty ? "" : "." + ext
        s = String(s.prefix(200 - tail.count)).trimmingCharacters(in: .whitespaces) + tail
    }
    return s.isEmpty || s == "." || s == ".." ? "file" : s
}

/// A name split for numbering: "shot (3).png" is "shot", 3, "png". Extensions are short and have no spaces.
func numbered(_ name: String) -> (base: String, n: Int, ext: String) {
    var ext = (name as NSString).pathExtension
    if ext.count > 10 { ext = "" }
    var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    guard let r = base.range(of: #" \([0-9]{1,6}\)$"#, options: .regularExpression), r.lowerBound > base.startIndex,
          let n = Int(base[r].dropFirst(2).dropLast()) else { return (base, 1, ext) }
    base.removeSubrange(r)
    return (base, n, ext)
}

/// A free name in `dir`. A clash gets " (2)", " (3)" and so on, counting on from a number the name already has
/// rather than stacking another one on.
func uniqueURL(in dir: URL, name: String) -> URL {
    var url = dir.appendingPathComponent(name)
    let (base, start, ext) = numbered(name)
    var n = max(2, start + 1)
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        n += 1
    }
    return url
}

/// A file in `dir` with the same name, give or take a " (n)", and the same bytes as `file`.
func sameFile(as file: String, named name: String, in dir: URL) -> URL? {
    let key = numbered(name)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for other in names {
        let k = numbered(other)
        guard k.base == key.base, k.ext == key.ext else { continue }
        let url = dir.appendingPathComponent(other)
        if sameBytes(url.path, file) { return url }
    }
    return nil
}

/// Whether two regular files hold the same bytes, compared a megabyte at a time.
func sameBytes(_ a: String, _ b: String) -> Bool {
    let fm = FileManager.default
    guard let x = try? fm.attributesOfItem(atPath: a), let y = try? fm.attributesOfItem(atPath: b),
          x[.type] as? FileAttributeType == .typeRegular, y[.type] as? FileAttributeType == .typeRegular,
          (x[.size] as? NSNumber)?.int64Value == (y[.size] as? NSNumber)?.int64Value,
          let ha = FileHandle(forReadingAtPath: a), let hb = FileHandle(forReadingAtPath: b) else { return false }
    defer { try? ha.close(); try? hb.close() }
    while true {
        let ca = (try? ha.read(upToCount: 1 << 20)) ?? Data(), cb = (try? hb.read(upToCount: 1 << 20)) ?? Data()
        if ca != cb { return false }
        if ca.isEmpty { return true }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Log

enum SyncLog {
    private static let queue = DispatchQueue(label: "clipbubble.synclog", qos: .background)
    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let url = Paths.dir.appendingPathComponent("sync.log")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let h = FileHandle(forWritingAtPath: url.path) else { return }
            h.seekToEndOfFile()
            h.write(Data("\(stamp) \(line)\n".utf8))
            try? h.close()
        }
    }
}
