import Foundation
import Network

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(message) }
}

private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while !condition() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for \(description)")
        try await Task.sleep(nanoseconds: 25_000_000)
    }
}

private struct Device: Codable {
    let id: String
    let fingerprint: String
    let name: String
    let os: String
}

private struct ServerInfo: Codable {
    let device: Device
    let port: UInt16
    let qr: String
}

private struct Fixtures: Codable {
    let swift: String
    let python: String
}

private struct Exchange {
    let directory: URL

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func write<T: Encodable>(_ value: T, as name: String) throws {
        try JSONEncoder().encode(value).write(to: url(name), options: .atomic)
    }

    func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url(name)))
    }

    func awaitFile<T: Decodable>(_ type: T.Type, _ name: String) async throws -> T {
        try await waitFor(name) { FileManager.default.fileExists(atPath: url(name).path) }
        return try read(type, from: name)
    }
}

@main
private struct Driver {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            try require(args.count == 3 && ["client", "server"].contains(args[1]), "Expected role and exchange directory")
            let exchange = Exchange(directory: URL(fileURLWithPath: args[2], isDirectory: true))
            let engine = SyncEngine.shared
            engine.apply = { _ in } // Keep the host clipboard out of the test.
            let identity = try DirectIdentity.ephemeral(deviceId: engine.device)
            let suite = "clipbubble.direct-interop." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("Could not open test defaults") }
            defer { defaults.removePersistentDomain(forName: suite) }
            let db = DB()
            let fixtures = try exchange.read(Fixtures.self, from: "fixtures.json")
            try seed(db, text: fixtures.swift, image: exchange.url("swift.png"))

            if args[1] == "server" {
                try await serve(identity, engine: engine, defaults: defaults, exchange: exchange)
            } else {
                try await dial(identity, engine: engine, defaults: defaults, exchange: exchange)
            }
        } catch {
            FileHandle.standardError.write(Data("Swift interop: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func device(_ identity: DirectIdentity, name: String) -> Device {
        Device(id: identity.deviceId, fingerprint: identity.fingerprint, name: name, os: Platform.os)
    }

    @MainActor
    private static func serve(_ identity: DirectIdentity, engine: SyncEngine,
                              defaults: UserDefaults, exchange: Exchange) async throws {
        let server = try DirectServer(engine: engine, identity: identity, defaults: defaults, port: .any, advertise: false)
        defer { server.stop(); engine.queue.sync {} }
        try await waitFor("Swift listener") { server.port != nil }
        guard let port = server.port, let qr = server.startQRPairing(addresses: ["127.0.0.1"]) else {
            throw Failure("Could not create Swift QR invitation")
        }
        let nearby = try exchange.read(Device.self, from: "python-nearby.json")
        let remote = try exchange.read(Device.self, from: "python-device.json")
        server.onPairRequest = { request, approve in
            do {
                try require(request.deviceId == nearby.id && request.fingerprint == nearby.fingerprint
                            && request.name == nearby.name && request.os == nearby.os,
                            "Swift received the wrong Nearby client identity")
                let pythonCode = try exchange.read(String.self, from: "python-sas.json")
                let code = request.code.replacingOccurrences(of: " ", with: "")
                try require(code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } && code == pythonCode,
                            "SAS differs (Swift \(code), Python \(pythonCode))")
                try exchange.write(code, as: "swift-sas.json")
                approve(true)
            } catch {
                try? exchange.write(error.localizedDescription, as: "swift-error.json")
                approve(false)
            }
        }
        try exchange.write(ServerInfo(device: device(identity, name: engine.name), port: port, qr: qr.absoluteString),
                           as: "swift-server.json")

        _ = try await exchange.awaitFile(Bool.self, "python-paired.json")
        try verifyPeer(DirectPeers.peer(id: nearby.id, defaults: defaults), expected: nearby, context: "Swift Nearby server")
        try verifyPeer(DirectPeers.peer(id: remote.id, defaults: defaults), expected: remote, context: "Swift QR server")
        try exchange.write(true, as: "swift-paired.json")
        try await finish(exchange, origin: remote.id)
    }

    @MainActor
    private static func dial(_ identity: DirectIdentity, engine: SyncEngine,
                             defaults: UserDefaults, exchange: Exchange) async throws {
        let info = try exchange.read(ServerInfo.self, from: "python-server.json")
        let remote = info.device
        let nearby = try DirectIdentity.ephemeral(deviceId: UUID().uuidString.lowercased())
        let nearbyName = engine.name + " Nearby"
        try exchange.write(device(nearby, name: nearbyName), as: "swift-nearby.json")
        try exchange.write(device(identity, name: engine.name), as: "swift-device.json")
        guard let port = NWEndpoint.Port(rawValue: info.port), let qr = URL(string: info.qr) else {
            throw Failure("Invalid Python listener info")
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let target = DirectPeer(id: remote.id, name: remote.name, os: remote.os, fingerprint: remote.fingerprint,
                                addresses: ["127.0.0.1"], port: info.port, lastSeen: 0)
        try await verifyUnpaired(target, local: nearby, engine: engine)
        try exchange.write(true, as: "swift-unpaired.json")

        let confirmed = try await DirectPairingClient.pairNearby(
            endpoint: endpoint, expectedFPPrefix: String(remote.fingerprint.prefix(16)),
            localIdentity: nearby, deviceId: nearby.deviceId, name: nearbyName, os: Platform.os
        ) { shown in
            do {
                try exchange.write(shown.replacingOccurrences(of: " ", with: ""), as: "swift-sas.json")
            } catch {
                FileHandle.standardError.write(Data("Could not record Swift SAS: \(error)\n".utf8))
            }
        }
        try verifyPeer(confirmed, expected: remote, context: "Swift Nearby client")
        DirectPeers.save(confirmed, defaults: defaults)
        try require(DirectPeers.peer(id: remote.id, defaults: defaults) == confirmed, "Swift did not save the Nearby peer")
        try exchange.write(true, as: "swift-nearby-paired.json")

        DirectPeers.remove(id: remote.id, defaults: defaults, engine: engine)
        try require(DirectPeers.peer(id: remote.id, defaults: defaults) == nil, "Swift Nearby pin remains before QR pairing")
        let paired = try await DirectPairingClient.pairQR(url: qr, localIdentity: identity, deviceId: identity.deviceId,
                                                        name: engine.name, os: Platform.os)
        try verifyPeer(paired, expected: remote, context: "Swift QR client")
        try require(paired.addresses == ["127.0.0.1"] && paired.port == info.port, "Swift QR endpoint differs from Python listener")
        DirectPeers.save(paired, defaults: defaults)
        try require(DirectPeers.peer(id: remote.id, defaults: defaults) == paired, "Swift did not save the QR peer")
        try exchange.write(true, as: "swift-paired.json")

        let tunnel = DirectTunnel(peer: paired, localIdentity: identity, defaults: defaults,
                                  stderr: { FileHandle.standardError.write($0) }, exited: {})
        engine.queue.async(execute: DispatchWorkItem {
            tunnel.whenReady(on: engine.queue) {
                let session = tunnel.makeSession(engine: engine)
                session.onClose = { tunnel.close() }
                engine.begin(session)
            }
        })
        defer { engine.queue.sync { tunnel.close() } }
        try await finish(exchange, origin: remote.id)
    }

    private static func verifyUnpaired(_ peer: DirectPeer, local: DirectIdentity, engine: SyncEngine) async throws {
        let (diagnostics, writer) = AsyncStream<String>.makeStream()
        let tunnel = DirectTunnel(peer: peer, localIdentity: local,
                                  stderr: { writer.yield(String(decoding: $0, as: UTF8.self)) },
                                  exited: { writer.finish() })
        engine.queue.async(execute: DispatchWorkItem {
            tunnel.whenReady(on: engine.queue) { tunnel.close() }
        })
        var diagnostic = ""
        for await line in diagnostics {
            diagnostic += line
        }
        // DirectTunnel emits this diagnostic only for the wire error "unpaired".
        try require(diagnostic == "Permission denied (Direct Sync peer is unpaired)\n",
                    "Expected Python sync error 'unpaired'; got \(diagnostic.debugDescription)")
    }

    private static func verifyPeer(_ peer: DirectPeer?, expected: Device, context: String) throws {
        try require(peer?.id == expected.id && peer?.fingerprint == expected.fingerprint
                    && peer?.name == expected.name && peer?.os == expected.os,
                    "\(context) did not find \(expected.name) with its authenticated certificate")
    }

    private static func seed(_ db: DB, text: String, image: URL) throws {
        let digest = sha(try Data(contentsOf: image))
        let path = Paths.images.appendingPathComponent(digest + ".png")
        try FileManager.default.copyItem(at: image, to: path)
        try require(db.upsert(kind: "text", text: text, file: nil, source: "Interop", hash: "t:" + sha(text)),
                    "Could not seed Swift text")
        try require(db.upsert(kind: "image", text: "", file: path.path, source: "Interop", hash: "i:" + digest),
                    "Could not seed Swift PNG")
    }

    private static func finish(_ exchange: Exchange, origin: String) async throws {
        let db = DB()
        let text = try exchange.read(Fixtures.self, from: "fixtures.json").python
        let expected = try Data(contentsOf: exchange.url("python.png"))
        let textHash = "t:" + sha(text)
        let imageHash = "i:" + sha(expected)
        try await waitFor("Swift SQLite text \(textHash)") { db.clip(hash: textHash) != nil }
        try await waitFor("Swift SQLite PNG \(imageHash)") { db.clip(hash: imageHash)?.remote == false }
        let storedText = db.clip(hash: textHash)
        try require(storedText?.kind == "text" && storedText?.origin == origin && storedText?.hash == textHash
                    && storedText.map { Data($0.text.utf8) == Data(text.utf8) } == true,
                    "Swift stored different text, hash or origin")
        guard let storedImage = db.clip(hash: imageHash), let path = storedImage.file else {
            throw Failure("Swift did not store a downloaded PNG path")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try require(storedImage.kind == "image" && storedImage.origin == origin && storedImage.hash == "i:" + sha(data)
                    && data == expected, "Swift stored different PNG bytes, hash or origin")
        try exchange.write(true, as: "swift-received.json")
        _ = try await exchange.awaitFile(Bool.self, "python-received.json")
    }
}
