import Foundation
import Network
import Security

func directTests() {
    let first = String(repeating: "0", count: 64)
    let last = String(repeating: "0", count: 63) + "5"
    // SHA-256 starts ae76e70e. The leading zero checks padding as well as byte order.
    check(DirectSAS.code(localFP: first, peerFP: last) == "027982", "Direct SAS golden vector")
    check(DirectSAS.formatted(localFP: last, peerFP: first) == "027 982", "Direct SAS is symmetric and formatted")

    do { try directLoopbackTests() }
    catch { check(false, "Direct loopback setup: \(error)") }
}

private func directLoopbackTests() throws {
    let engine = SyncEngine.shared
    let clientId = UUID().uuidString.lowercased()
    let persistentId = engine.device
    // Use a dedicated test device ID, separate from any production Keychain item.
    defer { check(DirectIdentity.removeTestIdentity(deviceId: persistentId), "the test removes its Keychain identity") }
    let persisted = try DirectIdentity.shared(deviceId: persistentId)
    let serverIdentity = try DirectIdentity.loadOrCreate(deviceId: persistentId)
    let clientIdentity = try DirectIdentity.ephemeral(deviceId: clientId)
    check(serverIdentity.der == persisted.der, "a fresh Keychain read preserves the entire leaf certificate")
    check(serverIdentity.fingerprint != clientIdentity.fingerprint, "the loopback peers have distinct identities")
    check(DirectPeer.validHex(clientIdentity.fingerprint, length: 64), "fingerprint is lowercase SHA-256")
    let certificate = SecCertificateCreateWithData(nil, clientIdentity.der as CFData)
    check(certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } == "clipbubble-" + clientId,
          "the DER certificate has its device UUID in the common name")

    let alias = DirectPeers.alias(for: clientId.uppercased())
    check(DirectPeers.isDirect(alias) && DirectPeers.deviceId(from: alias) == clientId, "Direct aliases use lowercase UUIDs")
    check(DirectPeers.deviceId(from: "direct:invalid") == nil && !DirectPeers.isDirect("me@mac.local"), "Direct and SSH aliases stay distinct")
    let bonjour = NWEndpoint.service(name: "Direct Test", type: DirectBrowser.serviceType, domain: "local.", interface: nil)
    var txt = NWTXTRecord(["v": "2", "id": clientId, "name": "Test iPhone", "os": "ios",
                           "fp": String(clientIdentity.fingerprint.prefix(16))])
    check(DiscoveredPeer(endpoint: bonjour, txt: txt, localDeviceId: persistentId)?.endpoint == bonjour,
          "discovery retains the dialable Bonjour service endpoint")
    check(DiscoveredPeer(endpoint: bonjour, txt: txt, localDeviceId: clientId) == nil, "discovery filters out this device")
    txt["v"] = "1"
    check(DiscoveredPeer(endpoint: bonjour, txt: txt, localDeviceId: persistentId) == nil, "discovery filters other protocol versions")

    let suite = "clipbubble.direct.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let server = try DirectServer(engine: engine, identity: serverIdentity, name: "Direct Test Mac",
                                  defaults: defaults, port: .any, advertise: false)
    defer { server.stop(); engine.queue.sync {} }
    guard directWait("listener", { server.port != nil }), let port = server.port else {
        return check(false, "the Direct listener becomes ready")
    }
    let fallback = try DirectServer(engine: engine, identity: serverIdentity, defaults: defaults,
                                    port: NWEndpoint.Port(rawValue: port)!, advertise: false)
    check(directWait("fallback listener") { fallback.port != nil } && fallback.port != port,
          "a second listener chooses an ephemeral port when its preferred port is taken")
    fallback.stop()
    engine.queue.sync {}

    let originalApply = engine.apply
    engine.apply = { _ in }
    defer { engine.apply = originalApply }

    let unauthenticated = DirectTestSocket(port: port)
    if unauthenticated.ready() {
        _ = unauthenticated.write(directJSON(["mode": "sync", "v": 2]))
    }
    check(unauthenticated.reply() == nil, "the server refuses a connection without a client certificate")
    unauthenticated.close()

    let unknown = DirectTestSocket(port: port, identity: clientIdentity)
    check(unknown.ready(), "distinct persistent and ephemeral identities complete mutual TLS")
    check(unknown.tlsVersion == .TLSv13, "Apple peers negotiate TLS 1.3")
    check(unknown.write(directJSON(["mode": "sync", "v": 2, "device": clientId])), "unpaired peer sends a sync preamble")
    check(unknown.reply()?["error"] as? String == "unpaired", "a certificate alone does not authorize SyncEngine access")
    unknown.close()

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    var serverCode: String?
    var clientCode: String?
    server.onPairRequest = { request, decide in
        check(Thread.isMainThread, "the server presents the pairing request on main")
        check(request.deviceId == clientId && request.fingerprint == clientIdentity.fingerprint, "pairing shows the authenticated client fingerprint")
        serverCode = request.code
        decide(true)
        decide(false) // A repeated decision must leave the first one in effect.
    }
    let nearby = directAsync {
        try await DirectPairingClient.pairNearby(endpoint: endpoint, expectedFPPrefix: String(serverIdentity.fingerprint.prefix(16)),
                                                localIdentity: clientIdentity, deviceId: clientId, name: "Test iPhone", os: "ios") { code in
            check(Thread.isMainThread, "the client presents its pairing code on main")
            clientCode = code
        }
    }
    check(nearby?.id == persistentId && nearby?.fingerprint == serverIdentity.fingerprint, "nearby pairing returns the verified server")
    check(clientCode != nil && clientCode == serverCode, "both sides show the same formatted SAS")
    check(DirectPeers.peer(id: clientId, defaults: defaults)?.fingerprint == clientIdentity.fingerprint, "approval persists the client pin")

    for attempt in 2...6 {
        let socket = DirectTestSocket(port: port, identity: clientIdentity)
        check(socket.ready(), "rate limit attempt \(attempt) starts TLS")
        server.onPairRequest = { _, decide in decide(false) }
        _ = socket.write(directJSON(["mode": "pair", "v": 2, "device": clientId, "name": "iPhone", "os": "ios"]))
        let error = socket.reply()?["error"] as? String
        check(attempt < 6 ? error == "Declined on Direct Test Mac." : error?.hasPrefix("Too many pairing requests") == true,
              "interactive requests enforce the five-request window")
        socket.close()
    }

    guard let qr = server.startQRPairing(addresses: ["127.0.0.1", "::1"]) else {
        return check(false, "the server offers a QR link with its actual port")
    }
    let qrCode = URLComponents(url: qr, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value
    check(qrCode.map { DirectPeer.validHex($0, length: 32) } == true, "the QR link contains a 128-bit lowercase token")
    let badPin = directQR(qr, key: "fp", value: String(repeating: "a", count: 64))
    let mismatch = directResult {
        try await DirectPairingClient.pairQR(url: badPin, localIdentity: clientIdentity, deviceId: clientId, name: "iPhone", os: "ios")
    }
    if case .failure(DirectPairError.identityChanged) = mismatch {} else { check(false, "QR pairing rejects a mismatched TLS pin") }
    let qrPeer = directAsync {
        try await DirectPairingClient.pairQR(url: qr, localIdentity: clientIdentity, deviceId: clientId, name: "iPhone", os: "ios")
    }
    check(qrPeer?.addresses == ["127.0.0.1", "::1"] && qrPeer?.port == port && qrPeer?.fingerprint == serverIdentity.fingerprint,
          "the correct QR pin still works after a wrong-pin dial and keeps its address list")
    let replay = directResult {
        try await DirectPairingClient.pairQR(url: qr, localIdentity: clientIdentity, deviceId: clientId, name: "iPhone", os: "ios")
    }
    if case .failure(DirectPairError.rejected("Invalid or expired pairing code.")) = replay {} else {
        check(false, "an already-used QR code is rejected")
    }
    if let qr = server.startQRPairing(addresses: ["127.0.0.1"]) {
        for attempt in 1...6 {
            let url = attempt < 6 ? directQR(qr, key: "c", value: String(repeating: "0", count: 32)) : qr
            let wrong = directResult {
                try await DirectPairingClient.pairQR(url: url, localIdentity: clientIdentity, deviceId: clientId, name: "iPhone", os: "ios")
            }
            if case .failure(DirectPairError.rejected("Invalid or expired pairing code.")) = wrong {} else {
                check(false, "QR token is invalidated after five wrong guesses")
            }
        }
    } else {
        check(false, "a fresh QR link can follow a consumed one")
    }

    let spoof = DirectTestSocket(port: port, identity: clientIdentity)
    check(spoof.ready(), "the pinned certificate can reconnect")
    _ = spoof.write(directJSON(["mode": "sync", "v": 2, "device": UUID().uuidString.lowercased()]))
    check(spoof.reply()?["error"] as? String == "unpaired", "a trusted certificate cannot claim a different device ID")
    spoof.close()

    let sync = DirectTestSocket(port: port, identity: clientIdentity)
    defer { sync.close() }
    check(sync.ready(), "the paired client reconnects over TLS")
    let text = "Direct Sync incoming \(UUID())"
    let hash = "t:" + sha(text)
    defer { DB().delete(hash: hash) }
    let frames = directTestFrames(device: clientId, text: text)
    check(sync.write(directJSON(["mode": "sync", "v": 2]) + frames), "the request and the first binary frames share one TLS write")
    check(sync.reply()?["ok"] as? Bool == true, "the server accepts the paired TLS identity without an optional device field")
    check(directWait("incoming clip") { DB().clip(hash: hash)?.text == text },
          "SyncEngine receives binary frames buffered after the request newline")
    DirectPeers.remove(id: clientId, defaults: defaults, engine: engine)
    check(directWait("revocation") { !engine.linked.contains { $0.device == clientId } },
          "removing a peer closes its active direct session")
    check(DirectPeers.peer(fingerprint: clientIdentity.fingerprint, defaults: defaults) == nil, "the client's pin was revoked")

    if let peer = qrPeer {
        check(directTunnelFailure(peer, local: clientIdentity, engine: engine) == .needsKeyAuth(""),
              "an unpaired sync reply maps to HostLink authentication failure")
        let rotated = DirectPeer(id: peer.id, name: peer.name, os: peer.os, fingerprint: clientIdentity.fingerprint,
                                 addresses: peer.addresses, port: peer.port, lastSeen: peer.lastSeen)
        check(directTunnelFailure(rotated, local: clientIdentity, engine: engine) == .hostKeyChanged,
              "a changed pin maps to HostLink host-key-changed")
    }
    try directOutboundRemainder(local: clientIdentity, engine: engine)
    try directTwoEngines(server: server)
    try macDirectWiringTests(engine: engine, client: clientIdentity)
}

private func macDirectWiringTests(engine: SyncEngine, client: DirectIdentity) throws {
    do {
        let unavailable = engine.queue.sync {
            MacSyncListeners(engine: engine, identity: { _ in throw DirectPairError.invalidDevice })
        }
        check(unavailable.peer != nil && unavailable.direct == nil, "an unavailable Direct identity leaves the SSH relay listening")
    }
    guard let listeners = engine.queue.sync(execute: { Platform.listen(engine) as? MacSyncListeners }),
          let server = listeners.direct else { return check(false, "macOS starts a Direct listener") }
    defer { server.stop(); engine.queue.sync {} }
    check(listeners.peer != nil, "macOS binds the SSH relay with the Direct listener running")
    let runtime = DirectRuntime.shared
    guard directWait("macOS Direct listener", { runtime.server === server && server.port != nil }),
          let port = server.port else { return check(false, "the active Direct listener exposes its port") }
    let socket = DirectTestSocket(port: port, identity: client)
    check(socket.ready(), "the macOS listener accepts a mutually authenticated TLS connection")
    socket.close()

    let alias = DirectPeers.alias(for: client.deviceId)
    do {
        let tunnel = try Platform.dial(alias, "unused", stderr: { _ in }, exited: {})
        tunnel.close()
        check(false, "macOS rejects an unpaired Direct alias before dialing")
    } catch DirectPairError.unpaired {
        check(true, "macOS routes an unpaired Direct alias to Direct authentication")
    }

    let peer = DirectPeer(id: client.deviceId, name: "Test iPhone", os: "ios", fingerprint: client.fingerprint,
                          addresses: ["127.0.0.1"], port: port, lastSeen: 0)
    let endpoint = NWEndpoint.service(name: peer.name, type: DirectBrowser.serviceType, domain: "local.", interface: nil)
    let txt = NWTXTRecord(["v": "2", "id": peer.id, "name": peer.name, "os": peer.os,
                           "fp": String(peer.fingerprint.prefix(16))])
    let model = Model()
    model.discoveredPeers = [DiscoveredPeer(endpoint: endpoint, txt: txt, localDeviceId: engine.device)].compactMap { $0 }
    check(model.nearbyDevices.map(\.id) == [peer.id], "the Devices model lists an unpaired advertisement nearby")
    DirectPeers.save(peer)
    defer { model.unlinkDirect(peer) }
    model.refreshDirectPeers()
    check(model.directPeers.contains(peer) && model.nearbyDevices.isEmpty, "a paired device moves from Nearby to Linked")
    check(!model.isDirectConnected(peer), "a paired device starts as disconnected")
    let hello = Hello(proto: Sync.proto, device: peer.id, name: peer.name, os: peer.os, version: "test", clock: 0)
    model.linked = [hello]
    check(model.isDirectConnected(peer), "incoming Direct sessions mark a device connected")
    model.linked = []
    model.links[alias] = .live(hello)
    check(model.isDirectConnected(peer), "outbound Direct sessions also mark a device connected")
    let tunnel = try Platform.dial(alias, "unused", stderr: { _ in }, exited: {})
    check(tunnel is DirectTunnel, "a paired Direct alias creates a TLS tunnel")
    tunnel.close()
    let oldHosts = Platform.defaults.object(forKey: "sync.hosts")
    defer { Platform.defaults.set(oldHosts, forKey: "sync.hosts") }
    Platform.defaults.set(SyncEngine.enabledHosts + [alias], forKey: "sync.hosts")
    model.refreshDirectPeers()
    check(model.directHosts.contains(alias), "the Devices model reflects outbound enablement")
    model.unlinkDirect(peer)
    check(DirectPeers.peer(fingerprint: peer.fingerprint) == nil && !SyncEngine.enabledHosts.contains(alias),
          "unlinking revokes the stored certificate and disables outbound dialing")
    check(!model.directPeers.contains(peer) && model.nearbyDevices.map(\.id) == [peer.id], "unlinking refreshes both Devices lists")

    guard let qr = runtime.startQRPairing(addresses: ["127.0.0.1"]) else {
        return check(false, "macOS can offer a Direct QR code on a running listener")
    }
    let items = URLComponents(url: qr, resolvingAgainstBaseURL: false)?.queryItems ?? []
    check(qr.scheme == "clipbubble" && qr.host == "direct" && items.contains(URLQueryItem(name: "p", value: String(port))),
          "the macOS QR contains the Direct listener port without a Remote Login check")
    check(PairingServer.qr(qr) != nil, "the Direct URL renders as a QR image")
    runtime.stopQRPairing()
    let stopped = directResult {
        try await DirectPairingClient.pairQR(url: qr, localIdentity: client, deviceId: client.deviceId, name: peer.name, os: peer.os)
    }
    if case .failure(DirectPairError.rejected("Invalid or expired pairing code.")) = stopped {
        check(true, "dismissing the macOS QR code revokes its pairing token")
    } else {
        check(false, "dismissing the macOS QR code revokes its pairing token")
    }
}

private func directTunnelFailure(_ peer: DirectPeer, local: DirectIdentity, engine: SyncEngine) -> LinkState? {
    let completed = DirectTestValue<LinkState?>()
    var stderr = ""
    let tunnel = DirectTunnel(peer: peer, localIdentity: local, stderr: { stderr += String(decoding: $0, as: UTF8.self) },
                              exited: { completed.set(LinkState.failure(stderr: stderr, windows: false)) })
    engine.queue.async { tunnel.whenReady(on: engine.queue) { tunnel.close() } }
    _ = directWait("tunnel failure") { completed.value != nil }
    engine.queue.sync { tunnel.close() }
    return completed.value ?? nil
}

private func directOutboundRemainder(local: DirectIdentity, engine: SyncEngine) throws {
    let remote = try DirectIdentity.ephemeral(deviceId: UUID().uuidString.lowercased())
    let queue = DispatchQueue(label: "clipbubble.direct.test-responder")
    let port = DirectTestValue<UInt16>()
    let request = DirectTestValue<String>()
    let text = "Direct Sync outgoing \(UUID())"
    let hash = "t:" + sha(text)
    defer { DB().delete(hash: hash) }
    let listener = try NWListener(using: .directTLS(identity: remote, queue: queue), on: .any)
    defer { listener.cancel() }
    listener.stateUpdateHandler = { [weak listener] state in
        if case .ready = state, let number = listener?.port?.rawValue { port.set(number) }
    }
    let incoming = DirectTestValue<NWConnection>()
    defer { incoming.value?.cancel() }
    listener.newConnectionHandler = { connection in
        incoming.set(connection)
        connection.stateUpdateHandler = { [weak connection] state in
            guard case .ready = state, let connection else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_097) { [weak connection] bytes, _, _, _ in
                guard let connection, let bytes else { return }
                request.set(String(decoding: bytes, as: UTF8.self))
                let combined = directJSON(["ok": true]) + directTestFrames(device: remote.deviceId, text: text)
                connection.send(content: combined, completion: .contentProcessed { _ in })
            }
        }
        connection.start(queue: queue)
    }
    listener.start(queue: queue)
    guard directWait("outgoing test listener", { port.value != nil }), let port = port.value else {
        return check(false, "the outgoing test responder becomes ready")
    }
    let peer = DirectPeer(id: remote.deviceId, name: "Test", os: "macos", fingerprint: remote.fingerprint,
                          addresses: ["127.0.0.1"], port: port, lastSeen: 0)
    let unreachable = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
    let tunnel = DirectTunnel(peer: peer, localIdentity: local, endpoint: unreachable, stderr: { _ in }, exited: {})
    let session = DirectTestValue<Session>()
    defer { engine.queue.sync { session.value?.close(); tunnel.close() } }
    engine.queue.async {
        tunnel.whenReady(on: engine.queue) {
            let live = tunnel.makeSession(engine: engine)
            session.set(live)
            engine.begin(live)
        }
    }
    check(directWait("outgoing clip") { DB().clip(hash: hash)?.text == text },
          "a tunnel falls back to cached addresses and delivers frames buffered after the reply newline")
    check(request.value?.contains(local.deviceId) == true, "the sync preamble names the authenticated device")
}

private func directTestFrames(device: String, text: String) -> Data {
    let time = Date().timeIntervalSince1970 - 60
    let hello = Frame.hello(Hello(proto: Sync.proto, device: device, name: "Test peer", os: "ios", version: "test", clock: time + 60))
    let clip = Frame.put(Entry(hash: "t:" + sha(text), time: time, kind: "text", text: text, source: "DirectTests",
                               origin: device, blobs: []))
    return hello.encoded() + Frame.summary([]).encoded() + clip.encoded()
}

private func directTwoEngines(server: DirectServer) throws {
    guard let qr = server.startQRPairing(addresses: ["127.0.0.1"]) else {
        return check(false, "an end-to-end test QR code is ready")
    }
    let root = testHome.appendingPathComponent("direct-child")
    let parentText = "Direct parent \(UUID())"
    let childText = "Direct child \(UUID())"
    let parentHash = "t:" + sha(parentText), childHash = "t:" + sha(childText)
    let db = DB()
    db.insertIfMissing(kind: "text", text: parentText, source: "DirectTests", hash: parentHash,
                       created: Date().addingTimeInterval(-60))
    defer { db.delete(hash: parentHash); db.delete(hash: childHash) }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env["CLIPBUBBLE_CHILD"] = "direct"
    env["CLIPBUBBLE_HOME"] = root.path
    env["CLIPBUBBLE_DIRECT_QR"] = qr.absoluteString
    env["CLIPBUBBLE_DIRECT_SEND"] = childText
    env["CLIPBUBBLE_DIRECT_EXPECT"] = parentText
    child.environment = env
    try child.run()
    defer {
        if child.isRunning { child.terminate() }
        _ = directWait("Direct test child exit") { !child.isRunning }
    }
    check(directWait("the child engine's clip", { db.clip(hash: childHash)?.text == childText }),
          "two independent SyncEngines reconcile the child's clipboard over Direct Sync")
    check(directWait("the parent engine's clip", { FileManager.default.fileExists(atPath: root.appendingPathComponent("received-parent").path) }),
          "the second SyncEngine receives the parent's clipboard over the same Direct connection")
}

func runDirectChild() -> Never {
    let env = ProcessInfo.processInfo.environment
    guard let qr = env["CLIPBUBBLE_DIRECT_QR"].flatMap(URL.init(string:)), let send = env["CLIPBUBBLE_DIRECT_SEND"],
          let expect = env["CLIPBUBBLE_DIRECT_EXPECT"] else { exit(1) }
    let engine = SyncEngine.shared
    let db = DB()
    db.insertIfMissing(kind: "text", text: send, source: "DirectTests", hash: "t:" + sha(send),
                       created: Date().addingTimeInterval(-60))
    engine.apply = { _ in }
    Task<Void, Never> {
        do {
            let identity = try DirectIdentity.ephemeral(deviceId: engine.device)
            let peer = try await DirectPairingClient.pairQR(url: qr, localIdentity: identity,
                                                            deviceId: engine.device, name: engine.name, os: Platform.os)
            DirectPeers.save(peer)
            SyncEngine.shared.queue.async {
                let engine = SyncEngine.shared
                let tunnel = DirectTunnel(peer: peer, localIdentity: identity, defaults: Platform.defaults,
                                          stderr: { FileHandle.standardError.write($0) }, exited: { exit(1) })
                tunnel.whenReady(on: engine.queue) {
                    let session = tunnel.makeSession(engine: engine)
                    session.onClose = { tunnel.close() }
                    engine.begin(session)
                    DispatchQueue.main.async {
                        engine.onReceived = {
                            guard DB().clip(hash: "t:" + sha(expect))?.text == expect else { return }
                            try? Data().write(to: Paths.dir.appendingPathComponent("received-parent"), options: .atomic)
                        }
                        engine.onReceived()
                    }
                }
                // Keep the dial alive until it has created a session.
                engine.queue.asyncAfter(deadline: .now() + 15) { withExtendedLifetime(tunnel) {}; exit(1) }
            }
        } catch {
            FileHandle.standardError.write(Data(("Direct test child: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    dispatchMain()
}

private func directJSON(_ object: [String: Any]) -> Data {
    (try! JSONSerialization.data(withJSONObject: object)) + Data([10])
}

private func directQR(_ url: URL, key: String, value: String) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = components.queryItems?.map { $0.name == key ? URLQueryItem(name: key, value: value) : $0 }
    return components.url!
}

@discardableResult
private func directWait(_ description: String, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(7)
    while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    let success = condition()
    if !success { print("Timed out waiting for \(description)") }
    return success
}

private func directResult<T: Sendable>(_ operation: @escaping () async throws -> T) -> Result<T, Error>? {
    let result = DirectTestValue<Result<T, Error>>()
    let task = Task {
        do { result.set(.success(try await operation())) }
        catch { result.set(.failure(error)) }
    }
    if !directWait("pairing result", { result.value != nil }) { task.cancel() }
    return result.value
}

private func directAsync<T: Sendable>(_ operation: @escaping () async throws -> T) -> T? {
    do { return try directResult(operation)?.get() }
    catch { check(false, "pairing: \(error.localizedDescription)"); return nil }
}

private final class DirectTestValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

private final class DirectTestSocket {
    private let queue = DispatchQueue(label: "clipbubble.direct.test-socket")
    private let connection: NWConnection
    private let readyState = DirectTestValue<Bool>()

    init(port: UInt16, identity: DirectIdentity? = nil) {
        let parameters: NWParameters
        if let identity {
            parameters = .directTLS(identity: identity, queue: queue)
        } else {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            parameters = NWParameters(tls: options)
        }
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        connection.stateUpdateHandler = { [readyState] state in
            switch state {
            case .ready: readyState.set(true)
            case .failed, .cancelled: readyState.set(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    deinit { close() }

    var tlsVersion: tls_protocol_version_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
            .map { sec_protocol_metadata_get_negotiated_tls_protocol_version($0.securityProtocolMetadata) }
    }

    func ready() -> Bool {
        directWait("TLS handshake") { readyState.value != nil } && readyState.value == true
    }

    func write(_ data: Data) -> Bool {
        let sent = DirectTestValue<Bool>()
        connection.send(content: data, completion: .contentProcessed { sent.set($0 == nil) })
        return directWait("TLS write") { sent.value != nil } && sent.value == true
    }

    func reply() -> [String: Any]? {
        let response = DirectTestValue<Data?>()
        Self.readLine(connection, buffer: Data(), response: response)
        guard directWait("server reply", { response.value != nil }), let bytes = response.value ?? nil else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private static func readLine(_ connection: NWConnection, buffer: Data, response: DirectTestValue<Data?>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, error in
            let bytes = buffer + (data ?? Data())
            if let newline = bytes.firstIndex(of: 10) { response.set(Data(bytes.prefix(upTo: newline))) }
            else if eof || error != nil { response.set(nil) }
            else { readLine(connection, buffer: bytes, response: response) }
        }
    }

    func close() { connection.cancel() }
}
