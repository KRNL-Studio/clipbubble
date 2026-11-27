import CoreFoundation
import Foundation
import Network

/// Routes pairing codes and manages nearby discovery. Legacy SSH codes also carry the computer's address and a
/// one-time token. The phone sends its SSH key and the computer answers with its user and host key.
enum Pairing {
    enum QRRoute: String {
        case direct
        case ssh = "pair"

        init?(_ url: URL) {
            guard url.scheme == "clipbubble", let host = url.host else { return nil }
            self.init(rawValue: host)
        }
    }

    static func displayName(for alias: String, reportedName: String? = nil) -> String {
        if DirectPeers.isDirect(alias) {
            let peer = DirectPeers.deviceId(from: alias).flatMap { DirectPeers.peer(id: $0) }
            return peer?.name ?? reportedName ?? "Computer"
        }
        return reportedName ?? Platform.defaults.string(forKey: "sync.name.\(alias)")
            ?? alias.split(separator: "@").last.map(String.init) ?? alias
    }

    static func displayName(of device: Hello) -> String {
        displayName(for: DirectPeers.alias(for: device.device), reportedName: device.name)
    }

    static func unlinkDirect(id: String) {
        SyncEngine.shared.setHost(DirectPeers.alias(for: id), on: false)
        DirectPeers.remove(id: id, engine: SyncEngine.shared)
    }

    /// Retry when a trusted computer becomes discoverable, so the next dial can use its current Bonjour endpoint.
    @MainActor
    static func browseNearby(onChange: @escaping ([DiscoveredPeer]) -> Void = { _ in }) -> DirectBrowser {
        let engine = SyncEngine.shared
        var previous: [DiscoveredPeer] = []
        return DirectBrowser(localDeviceId: engine.device) { found in
            for candidate in found where !previous.contains(candidate) {
                guard let peer = DirectPeers.peer(id: candidate.id),
                      peer.fingerprint.hasPrefix(candidate.fingerprintPrefix) else { continue }
                engine.redial(DirectPeers.alias(for: peer.id))
            }
            previous = found
            onChange(found)
        }
    }

    enum Failure: LocalizedError {
        case badLink, unreachable, keyUnavailable, refused(String)
        var errorDescription: String? {
            switch self {
            case .badLink: return "That isn't a ClipBubble pairing code."
            case .unreachable: return "Couldn't reach the computer. Check that this iPhone is on the same Wi-Fi, and that Local Network is on for ClipBubble in Settings."
            case .keyUnavailable: return "This iPhone's SSH key is unavailable. Unlock the iPhone and try again."
            case .refused(let why): return why
            }
        }
    }

    /// What a pairing link says. Any web page can open one, so all of it is the sender's claim until you've said yes.
    struct Link {
        let hosts: [String], port: UInt16, code: String, name: String?

        init?(_ url: URL) {
            guard url.scheme == "clipbubble", url.host == "pair",
                  let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let addresses = q.first(where: { $0.name == "h" })?.value?.split(separator: ","), !addresses.isEmpty,
                  let port = q.first(where: { $0.name == "p" })?.value.flatMap(UInt16.init),
                  port != 0,
                  let code = q.first(where: { $0.name == "c" })?.value else { return nil }
            let hosts = addresses.map { address in
                address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : String(address)
            }
            (self.hosts, self.port, self.code) = (hosts, port, code)
            name = q.first(where: { $0.name == "n" })?.value
        }
    }

    /// Returns the new link's alias (`user@host`) and the computer's name.
    static func pair(_ link: Link) async throws -> (alias: String, name: String) {
        let (hosts, port) = (link.hosts, link.port)
        guard let key = Keys.publicKey else { throw Failure.keyUnavailable }
        var req = try JSONSerialization.data(withJSONObject: ["code": link.code, "key": key, "name": Platform.deviceName])
        req.append(10)
        // Every address at once, so one a firewall drops costs nothing. The first (the .local name, which survives a
        // new IP address) gets a head start, since all of them reach the same computer.
        let replies = await withTaskGroup(of: (String, [String: Any]?).self) { group in
            for (i, host) in hosts.enumerated() {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 300_000_000)
                    guard !Task.isCancelled, let d = await exchange(host: host, port: port, send: req) else { return (host, nil) }
                    return (host, try? JSONSerialization.jsonObject(with: d) as? [String: Any])
                }
            }
            var out: [(String, [String: Any])] = []
            for await (host, r) in group {
                guard let r else { continue }
                out.append((host, r))
                if r["ok"] as? Bool == true { group.cancelAll(); break }
            }
            return out
        }
        guard let (host, r) = replies.first(where: { $0.1["ok"] as? Bool == true }), let user = r["user"] as? String else {
            guard let no = replies.first?.1 else { throw Failure.unreachable }
            throw Failure.refused(no["error"] as? String ?? "The computer said no. Show a new code there and scan it again.")
        }
        let sshPort: Int
        if let value = r["sshPort"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = number as? Int, (1...65535).contains(port) else {
                throw Failure.refused("The computer sent an invalid SSH port.")
            }
            sshPort = port
        } else {
            sshPort = 22
        }
        let address = sshPort == 22 ? host : "\(host.contains(":") ? "[\(host)]" : host):\(sshPort)"
        let alias = "\(user)@\(address)"
        guard let target = SSHTarget(alias) else { throw Failure.refused("The computer sent an invalid SSH address.") }
        // Trust exactly the key the computer reported, including on the first SSH connection.
        if let key = r["hostKey"] as? String, !key.isEmpty { Platform.defaults.set(key, forKey: target.hostKeyPreference) }
        Addresses.save([host] + hosts.filter { $0 != host }, for: alias)
        return (alias, r["name"] as? String ?? host)
    }

    /// Links to the same computer under an older address. A computer keeps one link per device, so they'd only compete.
    static func olderLinks(than alias: String) -> [String] {
        func key(_ a: String) -> String? { SSHTarget(a).flatMap { Platform.defaults.string(forKey: $0.hostKeyPreference) } }
        guard let k = key(alias) else { return [] }
        return SyncEngine.enabledHosts.filter { $0 != alias && key($0) == k }
    }

    /// One line out, one line back, or nil if the host can't be reached in 30 seconds, which leaves time to answer the
    /// Local Network prompt on a first link. Once connected it waits up to two minutes for the answer: Windows asks its
    /// user before adding the key.
    private static func exchange(host: String, port: UInt16, send: Data) async -> Data? {
        let c = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        return await withTaskCancellationHandler { await withCheckedContinuation { cont in
            let q = DispatchQueue(label: "clipbubble.pair")
            var done = false
            func finish(_ d: Data?) {
                guard !done else { return }
                done = true
                c.cancel()
                cont.resume(returning: d)
            }
            var buf = Data()
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, end, err in
                    if let d { buf.append(d) }
                    if let nl = buf.firstIndex(of: 10) { return finish(Data(buf[..<nl])) }
                    if end || err != nil { return finish(nil) }
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
            q.asyncAfter(deadline: .now() + 30) { if case .ready = c.state {} else { finish(nil) } }
            q.asyncAfter(deadline: .now() + 120) { finish(nil) }
        } } onCancel: { c.cancel() }
    }
}

extension LinkState {
    func phoneText(for alias: String) -> String {
        switch self {
        case .needsKeyAuth: return "Not allowed in. Link this iPhone again from the computer"
        case .unknownHost, .hostKeyChanged: return "The computer's identity changed. Link it again to trust it"
        case .unresolved where DirectPeers.isDirect(alias), .refused where DirectPeers.isDirect(alias):
            return "Can't reach the computer. Make sure ClipBubble is open there"
        case .unresolved: return "Can't find the computer. Is this iPhone on the same Wi-Fi?"
        case .refused: return "The computer isn't accepting connections. Turn on Remote Login or SSH there"
        case .notInstalled: return "ClipBubble isn't installed on the computer"
        case .appNotRunning: return "Open ClipBubble on the computer"
        case .live(let h): return "Linked with \(Pairing.displayName(for: alias, reportedName: h.name))"
        case .versionMismatch(let h): return "Update ClipBubble on \(Pairing.displayName(for: alias, reportedName: h.name)) (it has \(h.version))"
        default: return text
        }
    }
}
