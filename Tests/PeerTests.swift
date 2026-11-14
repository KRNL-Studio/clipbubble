import Foundation

/// Add a computer and link diagnostics: classified failures, short codes, saved peers and the status report.
func peerTests() {
    // Each way a link fails gets its own state, in the order a connection goes. Samples are what OpenSSH prints.
    let failures: [(String, String)] = [
        ("ssh: Could not resolve hostname old-mac: nodename nor servname provided, or not known", "unresolved"),
        ("ssh: connect to host 10.0.0.9 port 22: Connection refused", "refused"),
        ("No ED25519 host key is known for rog and you have requested strict checking.\nHost key verification failed.", "unknown-host"),
        ("@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@\nHost key verification failed.", "host-key-changed"),
        ("rohitgoyal@old-mac: Permission denied (publickey).", "needs-key"),
        ("CLIPBUBBLE_NOT_INSTALLED", "not-installed"),
        ("CLIPBUBBLE_NOT_RUNNING", "not-running"),
    ]
    for (err, kind) in failures {
        check(LinkState.failure(stderr: err, windows: false)?.kind == kind, "\(kind): \(LinkState.failure(stderr: err, windows: false)?.kind ?? "nil")")
    }
    check(LinkState.failure(stderr: "ssh: connect to host rog port 22: Operation timed out", windows: false) == nil, "a timeout is just offline")
    check(LinkState.failure(stderr: "rohitgoyal@old-mac: Permission denied (publickey).", windows: false) == .needsKeyAuth("rohitgoyal@old-mac"),
          "a refused login names the user and host")
    check(LinkState.needsKeyAuth("rohitgoyal@old-mac").text.contains("rohitgoyal@old-mac wasn't let in"), "and says so")
    check(LinkState.unresolved.transient && LinkState.refused.transient && !LinkState.hostKeyChanged.transient
          && !LinkState.unknownHost.transient && !LinkState.needsKeyAuth("").transient, "only network trouble retries soon")
    check(!LinkState.unknownHost.text.contains("Terminal") && LinkState.hostKeyChanged.text != LinkState.unknownHost.text,
          "a new host and a changed one read differently")

    // Short codes: eight unambiguous characters, typed in any case with or without the dash.
    let code = LinkCode.make()
    check(code.count == 8 && code.allSatisfy { LinkCode.alphabet.contains($0) }, "code alphabet")
    check(LinkCode.same(" " + LinkCode.display(code).lowercased() + " ", code), "typed code matches")
    check(!LinkCode.same("AAAAAAAA", code == "AAAAAAAA" ? "BBBBBBBB" : code), "wrong code doesn't")

    check(LinkClient.target(address: "rog.local", code: "k7qm-4ztd")! == (["rog.local"], 47821, "K7QM4ZTD"), "address and code")
    check(LinkClient.target(address: "10.0.0.9:5000", code: "K7QM4ZTD")! == (["10.0.0.9"], 5000, "K7QM4ZTD"), "address with port")
    check(LinkClient.target(address: "clipbubble://pair?h=a.local,10.0.0.9&p=47821&c=abc", code: "")! == (["a.local", "10.0.0.9"], 47821, "abc"),
          "a whole pairing link")
    check(LinkClient.target(address: "rog.local", code: "123") == nil, "short code too short")
    check(LinkClient.target(address: "-oProxyCommand=x", code: "K7QM4ZTD") == nil, "an address can't be an ssh option")

    // The same fingerprint ssh-keygen -l prints for this key.
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPqR3mUOcskK0AMMwJekuAgZW350J/juYdkvePQaexfg"
    check(fingerprint(key) == "SHA256:PTl11TrTbZVxMmYzWAEaSotTJsVhsO9OMdNsevMhAK0", "fingerprint: \(fingerprint(key) ?? "nil")")

    // A saved peer pins its key in ClipBubble's own known_hosts and never takes a name from ~/.ssh/config.
    let alias = Peers.freeAlias(for: "Rohit's MacBook Air", taken: ["clipbubble-rohit-s-macbook-air"])
    check(alias == "clipbubble-rohit-s-macbook-air-2", "alias avoids a taken name: \(alias)")
    let peer = Peer(alias: alias, name: "Rohit's MacBook Air", user: "rohit", host: "air.local", hostKey: key)
    Peers.save(peer)
    check(Peers.peer(alias) == peer, "peer saved")
    check((try? String(contentsOf: Peers.knownHosts, encoding: .utf8)) == "\(alias) \(key)\n", "known_hosts has its pinned key")
    let args = Peers.sshArguments(alias) ?? []
    check(args.contains("StrictHostKeyChecking=yes") && args.contains("HostKeyAlias=\(alias)") && args.contains("IdentitiesOnly=yes"),
          "strict checking against the pinned key")
    check(Array(args.suffix(4)) == ["-l", "rohit", "--", "air.local"], "connects as the user it reported")
    check(Peers.sshArguments("some-config-host") == nil, "other hosts keep ~/.ssh/config")
    check(Peers.keyPath.path.hasPrefix(Paths.dir.path), "tests never touch ~/.ssh")

    // The status report has link health and nothing from the history.
    DB().upsert(kind: "text", text: "secret clipboard text", file: nil, source: "Test", hash: "t:status-secret")
    let wasHosts = Platform.defaults.stringArray(forKey: "sync.hosts")
    Platform.defaults.set([alias], forKey: "sync.hosts")
    SyncStatus.write([alias: .needsKeyAuth("rohit@air.local")], paused: false, openAtLogin: "off")
    let written = (try? String(contentsOf: SyncStatus.file, encoding: .utf8)) ?? ""
    let report = SyncStatus.report(running: true)
    check(written.contains("needs-key") && report.contains("rohit@air.local wasn't let in"), "status names the problem")
    check(report.contains("Connects as rohit@air.local") && !written.contains("secret clipboard text") && !report.contains("secret"),
          "status has the connection and no history")
    Platform.defaults.set(wasHosts, forKey: "sync.hosts")
    Peers.remove(alias)
    check(Peers.peer(alias) == nil && (try? String(contentsOf: Peers.knownHosts, encoding: .utf8)) == "\n", "peer removed")

    // A pairing listener stops after a few wrong codes, and says why.
    let server = PairingServer()
    let ready = DispatchSemaphore(value: 0), gaveUp = DispatchSemaphore(value: 0)
    server.onReady = { _ in ready.signal() }
    server.onGaveUp = { gaveUp.signal() }
    server.start()
    let deadline = Date().addingTimeInterval(5)
    while ready.wait(timeout: .now()) == .timedOut, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    var last: Error?
    for _ in 0..<PairingServer.maxWrong {
        let done = DispatchSemaphore(value: 0)
        Task {
            do { _ = try await LinkClient.link(address: "127.0.0.1:\(server.port)", code: "WRONG222") } catch { last = error }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    check((last as? LinkError).map { if case .refused(let why) = $0 { return why.contains("Too many wrong codes") }; return false } ?? false,
          "too many wrong codes: \(String(describing: last))")
    let stopBy = Date().addingTimeInterval(5)
    while gaveUp.wait(timeout: .now()) == .timedOut, Date() < stopBy { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(Date() < stopBy, "the listener gave up")
    server.stop()
}
