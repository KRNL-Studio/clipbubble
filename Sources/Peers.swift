import CryptoKit
import Foundation
import Network
import ServiceManagement

/// A computer linked with Add a computer. It lives in ClipBubble's own settings and known_hosts, never in
/// ~/.ssh/config, so linking can't change or shadow a connection you set up yourself.
struct Peer: Codable, Equatable {
    /// What ClipBubble calls the link, like "clipbubble-rohits-macbook-air". Never the same as a host in ~/.ssh/config.
    var alias: String
    /// The computer's own name, as it reported it.
    var name: String
    var user: String
    /// The address you typed: a .local name or an IP address.
    var host: String
    /// Its SSH host key ("ssh-ed25519 AAAA…"), from the link. Connections fail if it ever shows a different one.
    var hostKey: String

    /// What the connection actually is, shown before it's saved and in diagnostics.
    var summary: String { "\(user)@\(host), with the key \(Peers.keyDisplay)" }
}

enum Peers {
    private static let key = "sync.peers"

    static var all: [Peer] {
        guard let d = Platform.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Peer].self, from: d)) ?? []
    }

    static func peer(_ alias: String) -> Peer? { all.first { $0.alias == alias } }

    /// Adds or replaces the peer with this alias, and rewrites ClipBubble's known_hosts to match.
    static func save(_ p: Peer) {
        var list = all.filter { $0.alias != p.alias }
        list.append(p)
        store(list)
    }

    static func remove(_ alias: String) {
        store(all.filter { $0.alias != alias })
        Platform.defaults.removeObject(forKey: "sync.lastLive." + alias)
    }

    private static func store(_ list: [Peer]) {
        Platform.defaults.set(try? JSONEncoder().encode(list), forKey: key)
        writeKnownHosts(list)
    }

    /// A name for a new link that's free both here and in ~/.ssh/config, so it never replaces another connection.
    static func freeAlias(for name: String, taken: [String]) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-").prefix(40)
        let base = "clipbubble-" + (slug.isEmpty ? "computer" : slug)
        let used = Set(taken + all.map(\.alias))
        var alias = base, n = 2
        while used.contains(alias) { alias = "\(base)-\(n)"; n += 1 }
        return alias
    }

    // MARK: Key

    /// ClipBubble's own SSH key. Only its public half ever leaves this computer.
    /// In ~/.ssh, except for tests and second instances (CLIPBUBBLE_HOME), which keep their own.
    static var keyPath: URL {
        ProcessInfo.processInfo.environment["CLIPBUBBLE_HOME"] != nil ? Paths.dir.appendingPathComponent("clipbubble_ed25519")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/clipbubble_ed25519")
    }

    static var keyDisplay: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return keyPath.path.hasPrefix(home + "/") ? "~" + keyPath.path.dropFirst(home.count) : keyPath.path
    }

    /// The public key line ("ssh-ed25519 AAAA… comment"), making the key first if there isn't one.
    static func publicKey() throws -> String {
        let pub = keyPath.appendingPathExtension("pub")
        if !FileManager.default.fileExists(atPath: keyPath.path) {
            try FileManager.default.createDirectory(at: keyPath.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "ClipBubble on \(SyncEngine.shared.name)", "-f", keyPath.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        let line = try String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // The pairing protocol carries the type and key only.
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519" else { throw LinkError.badKey }
        return parts.prefix(2).joined(separator: " ")
    }

    // MARK: Connection

    /// ClipBubble's own known_hosts: one line per linked computer, under its alias, so a new IP address doesn't matter.
    static var knownHosts: URL { Paths.dir.appendingPathComponent("known_hosts") }

    private static func writeKnownHosts(_ list: [Peer]) {
        let lines = list.filter { !$0.hostKey.isEmpty }.map { "\($0.alias) \($0.hostKey)" }
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)
    }

    /// ssh arguments for a linked computer: this key only, its pinned identity only, strict checking always.
    static func sshArguments(_ alias: String) -> [String]? {
        guard let p = peer(alias) else { return nil }
        return ["-i", keyPath.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=\(p.alias)", "-l", p.user, "--", p.host]
    }
}

enum LinkError: LocalizedError, Equatable {
    case badKey, badCode, unreachable, refused(String)

    var errorDescription: String? {
        switch self {
        case .badKey: return "Couldn't make this computer's ClipBubble key."
        case .badCode: return "Enter the address and code the other computer shows."
        case .unreachable: return "Couldn't reach it. Check the address, that Link iPhone… is open there, and that both are on the same network."
        case .refused(let why): return why
        }
    }
}

/// The SHA256 fingerprint of a public key line, as `ssh-keygen -l` and the ssh prompt show it.
func fingerprint(_ key: String) -> String? {
    let parts = key.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
    let b64 = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return "SHA256:" + b64
}

/// The short code a computer shows for linking: eight letters and digits that can't be misread, typed by hand.
enum LinkCode {
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    static func make() -> String { String((0..<8).map { _ in alphabet.randomElement()! }) }

    /// "K7QM-4ZTD" for showing.
    static func display(_ code: String) -> String { code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code }

    /// What someone typed, as the code: case, spaces and dashes don't matter.
    static func normalize(_ typed: String) -> String { typed.uppercased().filter { $0.isLetter || $0.isNumber } }

    /// Compares without stopping at the first difference.
    static func same(_ typed: String, _ code: String) -> Bool {
        let a = Array(normalize(typed).utf8), b = Array(code.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// This side of Add a computer: sends ClipBubble's public key to the other computer's pairing listener, which allows it
/// to run ClipBubble's relay only, and answers with its user, name and host key.
enum LinkClient {
    struct Answer: Equatable { var user: String; var name: String; var hostKey: String }

    static let port: UInt16 = 47821

    /// `address` is what the other computer shows (a name or IP address, optionally ":port"), or a whole
    /// clipbubble://pair link, which carries its own addresses, port and code.
    static func target(address: String, code: String) -> (hosts: [String], port: UInt16, code: String)? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: a), url.scheme == "clipbubble", url.host == "pair",
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let hosts = q.first(where: { $0.name == "h" })?.value?.split(separator: ",").map(String.init),
           let port = q.first(where: { $0.name == "p" })?.value.flatMap(UInt16.init),
           let c = q.first(where: { $0.name == "c" })?.value {
            return (hosts, port, c)
        }
        let c = LinkCode.normalize(code)
        guard !a.isEmpty, !a.contains(" "), !a.hasPrefix("-"), c.count == 8 else { return nil }
        // "host:port", but not a bare IPv6 address.
        if a.filter({ $0 == ":" }).count == 1, let i = a.lastIndex(of: ":"), let p = UInt16(a[a.index(after: i)...]) {
            return ([String(a[..<i])], p, c)
        }
        return ([a], port, c)
    }

    static func link(address: String, code: String) async throws -> (host: String, answer: Answer) {
        guard let t = target(address: address, code: code) else { throw LinkError.badCode }
        var req = try JSONSerialization.data(withJSONObject: ["code": t.code, "key": try Peers.publicKey(), "name": SyncEngine.shared.name])
        req.append(10)
        for host in t.hosts {
            guard let d = await exchange(host: host, port: t.port, send: req) else { continue }
            guard let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw LinkError.unreachable }
            guard r["ok"] as? Bool == true, let user = r["user"] as? String, !user.isEmpty else {
                throw LinkError.refused(r["error"] as? String ?? "It said no. Check the code, or show a new one there and try again.")
            }
            return (host, Answer(user: user, name: r["name"] as? String ?? host, hostKey: r["hostKey"] as? String ?? ""))
        }
        throw LinkError.unreachable
    }

    /// One line out, one line back. Waits up to two minutes once connected: Windows asks its user first.
    private static func exchange(host: String, port: UInt16, send: Data) async -> Data? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let c = NWConnection(host: .init(host), port: p, using: .tcp)
        return await withCheckedContinuation { cont in
            let q = DispatchQueue(label: "clipbubble.link")
            var done = false, buf = Data()
            func finish(_ d: Data?) {
                guard !done else { return }
                done = true
                c.cancel()
                cont.resume(returning: d)
            }
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, end, err in
                    if let d { buf.append(d) }
                    if let nl = buf.firstIndex(of: 10) { return finish(Data(buf[..<nl])) }
                    if end || err != nil || buf.count > 8192 { return finish(nil) }
                    read()
                }
            }
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: c.send(content: send, completion: .contentProcessed { _ in read() })
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 5) { if case .ready = c.state {} else { finish(nil) } }
            q.asyncAfter(deadline: .now() + 120) { finish(nil) }
        }
    }
}

/// Checking a host's identity by hand: what its SSH server presents, to compare with what that computer shows.
enum HostIdentity {
    /// The hostname and port ssh really uses for an alias, after ~/.ssh/config.
    static func resolve(_ alias: String) -> (host: String, port: Int)? {
        guard !alias.hasPrefix("-"), let out = run("/usr/bin/ssh", ["-G", "--", alias]) else { return nil }
        var host: String?, port = 22
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "hostname" { host = kv[1] }
            if kv[0] == "port" { port = Int(kv[1]) ?? 22 }
        }
        return host.map { ($0, port) }
    }

    /// The ed25519 key a host in ~/.ssh/config presents, with the known_hosts line that would trust it.
    static func scan(_ alias: String) -> (entry: String, key: String)? {
        guard let (host, port) = resolve(alias) else { return nil }
        return scan(host: host, port: port)
    }

    static func scan(host: String, port: Int = 22) -> (entry: String, key: String)? {
        guard !host.hasPrefix("-"),
              let out = run("/usr/bin/ssh-keyscan", ["-T", "5", "-t", "ed25519", "-p", String(port), host]) else { return nil }
        guard let line = out.split(separator: "\n").first(where: { !$0.hasPrefix("#") && $0.contains("ssh-ed25519") }) else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let name = port == 22 ? host : "[\(host)]:\(port)"
        return ("\(name) \(parts[1]) \(parts[2])", "\(parts[1]) \(parts[2])")
    }

    /// Adds a host you checked to ~/.ssh/known_hosts. Only ever appends: a key that's already there isn't touched.
    static func trust(_ entry: String) throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !old.contains(entry) else { return }
        let sep = old.isEmpty || old.hasSuffix("\n") ? "" : "\n"
        try (old + sep + entry + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// This computer's own identity, for the other side to compare.
    static var mine: String? { PairingServer.hostKey().flatMap(fingerprint) }

    private static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }
}

/// What `ClipBubble --status` reports: each link's health, never anything from the history. The running app writes it
/// whenever a link changes, so checking needs neither the panel nor a connection of its own.
enum SyncStatus {
    static var file: URL { Paths.dir.appendingPathComponent("status.json") }

    static func write(_ statuses: [String: LinkState], paused: Bool, openAtLogin: String) {
        let links: [[String: Any]] = SyncEngine.enabledHosts.map { alias in
            let state = statuses[alias] ?? .connecting
            var row: [String: Any] = ["alias": alias, "state": state.kind, "text": state.text]
            if let p = Peers.peer(alias) { row["name"] = p.name; row["connection"] = p.summary; row["identity"] = fingerprint(p.hostKey) ?? "" }
            if case .live(let h) = state { row["name"] = h.name; row["os"] = h.os; row["version"] = h.version }
            if case .versionMismatch(let h) = state { row["version"] = h.version }
            let last = Platform.defaults.double(forKey: "sync.lastLive." + alias)
            if last > 0 { row["lastLinked"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: last)) }
            return row
        }
        let out: [String: Any] = ["updated": ISO8601DateFormatter().string(from: Date()), "name": SyncEngine.shared.name,
                                  "identity": HostIdentity.mine ?? "", "paused": paused, "openAtLogin": openAtLogin, "links": links]
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: file, options: .atomic)
    }

    /// The report, for a terminal. `running` says whether the app is up to keep it current.
    static func report(running: Bool) -> String {
        guard let d = try? Data(contentsOf: file), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return running ? "ClipBubble is running but hasn't reported yet." : "ClipBubble isn't running, and has no status saved."
        }
        var lines = ["\(s["name"] as? String ?? "This computer")" + (running ? "" : " (ClipBubble isn't running; last known status)")]
        if let id = s["identity"] as? String, !id.isEmpty { lines.append("  Identity: \(id)") }
        lines.append("  Open at login: \(s["openAtLogin"] as? String ?? "unknown")")
        if s["paused"] as? Bool == true { lines.append("  Sync is paused") }
        let links = s["links"] as? [[String: Any]] ?? []
        if links.isEmpty { lines.append("  No computers linked. Add one in Settings → Sync over SSH.") }
        for l in links {
            let name = (l["name"] as? String).map { "\($0) (\(l["alias"] as? String ?? ""))" } ?? l["alias"] as? String ?? ""
            lines.append("")
            lines.append("\(name): \(l["text"] as? String ?? "")")
            if let c = l["connection"] as? String { lines.append("  Connects as \(c)") }
            if let v = l["version"] as? String { lines.append("  ClipBubble \(v)" + ((l["os"] as? String).map { " on \($0)" } ?? "")) }
            if let t = l["lastLinked"] as? String { lines.append("  Last linked \(t)") }
        }
        lines.append("")
        lines.append("Updated \(s["updated"] as? String ?? "never"). Nothing from your history is in this report.")
        return lines.joined(separator: "\n")
    }
}

/// Open at login, as macOS actually has it rather than as the switch was last set.
enum LoginItem {
    static var on: Bool { SMAppService.mainApp.status == .enabled }

    static func describe() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval in System Settings → General → Login Items"
        case .notRegistered: return "off"
        case .notFound: return "unavailable for this copy of ClipBubble"
        @unknown default: return "unknown"
        }
    }

    /// Turns it on or off and says what happened, if it isn't simply what was asked for.
    static func set(_ want: Bool) -> String? {
        do { try want ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
            return "macOS didn't allow that: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Approve ClipBubble in System Settings → General → Login Items to finish."
        }
        return on == want ? nil : "Open at login is \(describe())."
    }
}
