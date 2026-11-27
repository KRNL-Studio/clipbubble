import Foundation
import Network
import Security

extension NWParameters {
    static func directTLS(identity: DirectIdentity, queue: DispatchQueue,
                          acceptsFingerprint: @escaping (String) -> Bool = { _ in true },
                          rejected: @escaping (DirectPairError) -> Void = { _ in }) -> NWParameters {
        let options = NWProtocolTLS.Options()
        let tls = options.securityProtocolOptions
        // TLS 1.3 when both sides support it. The only 1.2 suites are for older Windows SChannel.
        sec_protocol_options_set_min_tls_protocol_version(tls, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls, .TLSv13)
        for suite: tls_ciphersuite_t in [
            .AES_128_GCM_SHA256, .AES_256_GCM_SHA384, .CHACHA20_POLY1305_SHA256,
            .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        ] {
            sec_protocol_options_append_tls_ciphersuite(tls, suite)
        }
        // Every connection needs a fresh certificate check, including a sync dial right after pairing.
        sec_protocol_options_set_tls_resumption_enabled(tls, false)
        sec_protocol_options_set_local_identity(tls, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_peer_authentication_required(tls, true)
        sec_protocol_options_set_verify_block(tls, { _, trust, complete in
            guard let leaf = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate],
                  let certificate = leaf.first else {
                complete(false)
                rejected(.missingCertificate)
                return
            }
            let fingerprint = DirectIdentity.fingerprint(of: SecCertificateCopyData(certificate) as Data)
            let accepted = acceptsFingerprint(fingerprint)
            complete(accepted)
            if !accepted { rejected(.identityChanged) }
        }, queue)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }
}

private func directFingerprint(of connection: NWConnection) -> String? {
    guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
    var fingerprint: String?
    sec_protocol_metadata_access_peer_certificate_chain(tls.securityProtocolMetadata) { peer in
        if fingerprint == nil {
            let certificate = sec_certificate_copy_ref(peer).takeRetainedValue()
            fingerprint = DirectIdentity.fingerprint(of: SecCertificateCopyData(certificate) as Data)
        }
    }
    return fingerprint
}

/// A byte stream after the TLS handshake and JSON preamble. Network callbacks and
/// writes are serialized on the connection's queue. Each read waits for Session to handle it.
final class DirectTransport: SessionTransport {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var bytes: Data
    private var eof: Bool
    private var closed = false
    private var started = false
    private var delivering = false
    private var receiver: (DispatchQueue, (Data?) -> Void)?
    private var pendingWrite: ((Bool) -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue, initialBytes: Data = Data(), eof: Bool = false) {
        self.connection = connection
        self.queue = queue
        bytes = initialBytes
        self.eof = eof
    }

    deinit { connection.cancel() }

    func start(on queue: DispatchQueue, receive: @escaping (Data?) -> Void) {
        self.queue.async { [self] in
            guard !started else { return }
            started = true
            receiver = (queue, receive)
            deliver()
        }
    }

    func write(_ bytes: Data, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !closed, pendingWrite == nil else { return completion(false) }
            pendingWrite = completion
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, let written = pendingWrite else { return }
                pendingWrite = nil
                written(error == nil)
            })
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            eof = true
            connection.cancel()
            let write = pendingWrite
            pendingWrite = nil
            write?(false)
            deliver()
        }
    }

    private func deliver() {
        guard !delivering, let (target, receive) = receiver else { return }
        if !bytes.isEmpty {
            let delivered = bytes
            bytes = Data()
            delivering = true
            target.async { [self] in
                receive(delivered)
                queue.async { [self] in
                    delivering = false
                    deliver()
                }
            }
        } else if eof {
            receiver = nil
            target.async { receive(nil) }
        } else {
            delivering = true
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                delivering = false
                bytes = data ?? Data()
                eof = closed || complete || error != nil
                deliver()
            }
        }
    }
}

struct DirectPairRequest {
    let deviceId: String
    let name: String
    let os: String
    let fingerprint: String
    let code: String
}

enum DirectPairError: LocalizedError {
    case invalidURL, invalidDevice, noEndpoint, missingCertificate, identityChanged
    case timedOut, invalidPreamble, unpaired, rejected(String), network(NWError)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "This isn't a valid ClipBubble Direct pairing code."
        case .invalidDevice: return "The Direct Sync device information is invalid."
        case .noEndpoint: return "Can't find this device on the network."
        case .missingCertificate: return "The other device did not present a Direct Sync certificate."
        case .identityChanged: return "The other device's Direct Sync identity changed."
        case .timedOut: return "The other device did not answer in time."
        case .invalidPreamble: return "The other device sent an invalid Direct Sync message."
        case .unpaired: return "This device is no longer paired. Link it again."
        case .rejected(let message): return message
        case .network(let error): return String(describing: error)
        }
    }
}

private struct DirectDevice {
    let id: String
    let name: String
    let os: String

    init?(id: String?, name: String?, os: String?) {
        guard let id, DirectPeer.validID(id), let name, !name.isEmpty,
              let os, DirectPeer.validOS(os) else { return nil }
        self.id = id
        self.name = name
        self.os = os
    }

    func peer(fingerprint: String, addresses: [String], port: UInt16) -> DirectPeer {
        DirectPeer(id: id, name: name, os: os, fingerprint: fingerprint, addresses: addresses, port: port,
                   lastSeen: Date().timeIntervalSince1970)
    }

    static func displayName(_ name: String) -> String {
        var clipped = ""
        for scalar in name.unicodeScalars {
            if clipped.utf8.count + scalar.utf8.count > 48 { break }
            clipped.unicodeScalars.append(scalar)
        }
        return clipped.isEmpty ? "ClipBubble" : clipped
    }
}

private struct DirectRequest: Codable {
    let mode: String
    var v = 2
    var device: String?
    var name: String?
    var os: String?
    var code: String?

    var descriptor: DirectDevice? { DirectDevice(id: device, name: name, os: os) }
}

private struct DirectReply: Codable {
    let ok: Bool
    var error: String?
    var device: String?
    var name: String?
    var os: String?

    var descriptor: DirectDevice? { DirectDevice(id: device, name: name, os: os) }
}

private enum DirectWire {
    static let timeout = 15.0
    static let lineLimit = 4_096

    struct Line<Value> {
        let value: Value
        let remainder: Data
        let eof: Bool
    }

    static func read<Value: Decodable & Sendable>(_ connection: NWConnection, as _: Value.Type, buffer: Data = Data(),
                                       completion: @escaping (Result<Line<Value>, DirectPairError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if let end = bytes.firstIndex(of: 10) {
                guard end - bytes.startIndex <= lineLimit,
                      let value = try? JSONDecoder().decode(Value.self, from: bytes.prefix(upTo: end)) else {
                    return completion(.failure(.invalidPreamble))
                }
                completion(.success(Line(value: value, remainder: Data(bytes.suffix(from: end + 1)), eof: complete || error != nil)))
            } else if let error {
                completion(.failure(.network(error)))
            } else if complete || bytes.count > lineLimit {
                completion(.failure(.invalidPreamble))
            } else {
                read(connection, as: Value.self, buffer: bytes, completion: completion)
            }
        }
    }

    static func send<Value: Encodable>(_ value: Value, over connection: NWConnection, final: Bool = false,
                                       completion: @escaping (Result<Void, DirectPairError>) -> Void) {
        guard var bytes = try? JSONEncoder().encode(value), bytes.count <= lineLimit else {
            return completion(.failure(.invalidPreamble))
        }
        bytes.append(10)
        connection.send(content: bytes, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if let error { completion(.failure(.network(error))) }
            else { completion(.success(())) }
        })
    }

    static func endpoints(addresses: [String], port: UInt16) -> [NWEndpoint] {
        guard port != 0, let port = NWEndpoint.Port(rawValue: port) else { return [] }
        var seen: Set<String> = []
        return addresses.filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { .hostPort(host: NWEndpoint.Host($0), port: port) }
    }

    static func connectedAddress(_ connection: NWConnection) -> (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port) = (connection.currentPath?.remoteEndpoint ?? connection.endpoint) else { return nil }
        return (String(describing: host), port.rawValue)
    }
}

final class DirectServer {
    static let preferredPort: NWEndpoint.Port = 47822

    private let engine: SyncEngine
    private let identity: DirectIdentity
    private let device: DirectDevice
    private let defaults: UserDefaults
    private let advertise: Bool
    private var listener: NWListener?
    private var incoming: [UUID: Incoming] = [:]
    private var recentPairs: [TimeInterval] = []
    private let lock = NSLock()
    private var boundPort: UInt16?
    private var qr: QRToken?
    private var pairHandler: ((DirectPairRequest, @escaping (Bool) -> Void) -> Void)?

    var port: UInt16? { lock.withLock { boundPort } }

    var onPairRequest: ((DirectPairRequest, @escaping (Bool) -> Void) -> Void)? {
        get { lock.withLock { pairHandler } }
        set { lock.withLock { pairHandler = newValue } }
    }

    init(engine: SyncEngine, identity: DirectIdentity, name: String? = nil, os: String = Platform.os,
         defaults: UserDefaults = Platform.defaults, port: NWEndpoint.Port = DirectServer.preferredPort,
         advertise: Bool = true) throws {
        guard let device = DirectDevice(id: identity.deviceId, name: DirectDevice.displayName(name ?? engine.name), os: os) else {
            throw DirectPairError.invalidDevice
        }
        self.engine = engine
        self.identity = identity
        self.device = device
        self.defaults = defaults
        self.advertise = advertise
        do {
            try listen(on: port)
        } catch NWError.posix(.EADDRINUSE) where port != .any {
            try listen(on: .any)
        }
    }

    deinit { listener?.cancel() }

    func stop() {
        engine.queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            lock.withLock { self.boundPort = nil; self.qr = nil }
            for pending in Array(incoming.values) { pending.close() }
        }
    }

    private func listen(on port: NWEndpoint.Port) throws {
        let listener = try NWListener(using: .directTLS(identity: identity, queue: engine.queue), on: port)
        if advertise {
            listener.service = NWListener.Service(name: device.name, type: DirectBrowser.serviceType, txtRecord: NWTXTRecord([
                "v": "2", "id": device.id, "name": device.name, "os": device.os, "fp": String(identity.fingerprint.prefix(16))
            ]))
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                lock.withLock { self.boundPort = listener.port?.rawValue }
            case .failed(let error):
                listener.cancel()
                self.listener = nil
                lock.withLock { self.boundPort = nil; self.qr = nil }
                if error == .posix(.EADDRINUSE), port != .any {
                    do { try listen(on: .any) }
                    catch { SyncLog.write("Direct listener: \(error)") }
                } else {
                    SyncLog.write("Direct listener: \(error)")
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else { return connection.cancel() }
            let attempt = Incoming(connection: connection, server: self)
            incoming[attempt.id] = attempt
            attempt.start()
        }
        listener.start(queue: engine.queue)
    }

    private struct QRToken {
        let code: String
        let expires: TimeInterval
        var wrong = 0
    }

    func startQRPairing(addresses: [String]) -> URL? {
        guard !addresses.isEmpty, addresses.allSatisfy({ !$0.isEmpty && !$0.contains(",") }) else { return nil }
        var random = [UInt8](repeating: 0, count: 16)
        let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { return nil }
        let code = random.map { String(format: "%02x", $0) }.joined()
        return lock.withLock {
            guard let port = boundPort else { return nil }
            var url = URLComponents()
            url.scheme = "clipbubble"
            url.host = "direct"
            url.queryItems = [
                URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "id", value: device.id),
                URLQueryItem(name: "fp", value: identity.fingerprint), URLQueryItem(name: "h", value: addresses.joined(separator: ",")),
                URLQueryItem(name: "p", value: String(port)), URLQueryItem(name: "c", value: code),
                URLQueryItem(name: "n", value: device.name), URLQueryItem(name: "os", value: device.os)
            ]
            guard let result = url.url else { return nil }
            qr = QRToken(code: code, expires: ProcessInfo.processInfo.systemUptime + 600)
            return result
        }
    }

    func stopQRPairing() { lock.withLock { qr = nil } }

    private func consumeQR(_ code: String?) -> Bool {
        lock.withLock {
            guard var token = qr, ProcessInfo.processInfo.systemUptime < token.expires else {
                qr = nil
                return false
            }
            // Compare fixed-length codes without exposing where a guess differed.
            if let code, DirectPeer.validHex(code, length: 32),
               zip(token.code.utf8, code.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 {
                qr = nil
                return true
            }
            token.wrong += 1
            qr = token.wrong < 5 ? token : nil
            return false
        }
    }

    private func allowPairRequest() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        recentPairs.removeAll { now - $0 >= 60 }
        guard recentPairs.count < 5 else { return false }
        recentPairs.append(now)
        return true
    }

    private final class Incoming {
        let id = UUID()
        private let connection: NWConnection
        private weak var server: DirectServer?
        private var deadline: DispatchWorkItem?
        private var finished = false
        private var pairing = false

        init(connection: NWConnection, server: DirectServer) {
            self.connection = connection
            self.server = server
        }

        deinit { if !finished { connection.cancel() } }

        func start() {
            guard let server else { return close() }
            timeOut(after: DirectWire.timeout) { $0.close() }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !finished else { return }
                switch state {
                case .ready:
                    guard let fingerprint = directFingerprint(of: connection) else { return close() }
                    DirectWire.read(connection, as: DirectRequest.self) { [weak self] result in
                        guard let self, !finished else { return }
                        switch result {
                        case .success(let line): receive(line, fingerprint: fingerprint)
                        case .failure: close()
                        }
                    }
                case .failed, .cancelled:
                    close()
                default: break
                }
            }
            connection.start(queue: server.engine.queue)
        }

        private func receive(_ line: DirectWire.Line<DirectRequest>, fingerprint: String) {
            guard let server else { return close() }
            let request = line.value
            guard request.v == 2 else { return refuse("Unsupported Direct Sync version.") }
            if request.mode == "sync" {
                guard let peer = DirectPeers.peer(fingerprint: fingerprint, defaults: server.defaults),
                      request.device == nil || request.device == peer.id else { return refuse("unpaired") }
                DirectWire.send(DirectReply(ok: true), over: connection) { [weak self] result in
                    guard let self, !finished, let server = self.server else { return }
                    guard case .success = result,
                          DirectPeers.peer(id: peer.id, defaults: server.defaults)?.fingerprint == fingerprint else { return close() }
                    finish()
                    let session = Session(transport: DirectTransport(connection, queue: server.engine.queue,
                                                                      initialBytes: line.remainder, eof: line.eof), engine: server.engine)
                    session.directPeerID = peer.id
                    server.engine.begin(session)
                }
                return
            }
            guard request.mode == "pair" || request.mode == "pair-qr" else { return refuse("Unknown Direct Sync mode.") }
            if request.mode == "pair", !server.allowPairRequest() {
                return refuse("Too many pairing requests. Wait a moment and try again.")
            }
            guard let peer = request.descriptor, peer.id != server.device.id,
                  fingerprint != server.identity.fingerprint else { return refuse("Invalid pairing device.") }
            if request.mode == "pair-qr" {
                guard server.consumeQR(request.code) else { return refuse("Invalid or expired pairing code.") }
                return approve(peer, fingerprint: fingerprint)
            }
            let declined = "Declined on \(server.device.name)."
            guard let handler = server.onPairRequest, !line.eof, line.remainder.isEmpty else { return refuse(declined) }
            pairing = true
            timeOut(after: 90) { $0.refuse(declined) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                if self?.pairing == true { self?.close() }
            }
            let incoming = DirectPairRequest(deviceId: peer.id, name: peer.name, os: peer.os, fingerprint: fingerprint,
                code: DirectSAS.formatted(localFP: server.identity.fingerprint, peerFP: fingerprint))
            DispatchQueue.main.async { [weak self, weak server] in
                guard self != nil, let server else { return }
                handler(incoming) { [weak self, weak server] accepted in
                    server?.engine.queue.async { [weak self] in
                        guard let self, pairing else { return }
                        if accepted { approve(peer, fingerprint: fingerprint) }
                        else { refuse(declined) }
                    }
                }
            }
        }

        private func approve(_ device: DirectDevice, fingerprint: String) {
            guard let server else { return close() }
            let existing = DirectPeers.peer(id: device.id, defaults: server.defaults)
            let known = existing?.fingerprint == fingerprint ? existing : nil
            // The incoming TCP source port belongs to this connection, not to a peer's listener.
            let peer = device.peer(fingerprint: fingerprint, addresses: known?.addresses ?? [], port: known?.port ?? 0)
            DirectPeers.save(peer, defaults: server.defaults)
            reply(DirectReply(ok: true, device: server.device.id, name: server.device.name, os: server.device.os))
        }

        private func refuse(_ reason: String) { reply(DirectReply(ok: false, error: reason)) }

        private func reply(_ reply: DirectReply) {
            pairing = false
            timeOut(after: DirectWire.timeout) { $0.close() }
            DirectWire.send(reply, over: connection, final: true) { [weak self] _ in self?.close() }
        }

        private func timeOut(after seconds: Double, _ action: @escaping (Incoming) -> Void) {
            deadline?.cancel()
            let task = DispatchWorkItem { [weak self] in
                if let self, !finished { action(self) }
            }
            deadline = task
            server?.engine.queue.asyncAfter(deadline: .now() + seconds, execute: task)
        }

        func close() {
            guard !finished else { return }
            finish()
            connection.cancel()
        }

        private func finish() {
            finished = true
            pairing = false
            deadline?.cancel()
            connection.stateUpdateHandler = nil
            server?.incoming[id] = nil
        }
    }
}

/// Races TLS handshakes, then sends the application preamble on just the first
/// authenticated connection. In particular, QR codes never go to losing addresses.
// All mutable state is confined to queue, including cancellation from a Swift task.
private final class DirectExchange: @unchecked Sendable {
    struct Handshake {
        let connection: NWConnection
        let fingerprint: String
        let line: DirectWire.Line<DirectReply>
    }

    let queue: DispatchQueue
    private let identity: DirectIdentity
    private let acceptsFingerprint: (String) -> Bool
    private let request: DirectRequest
    private let onCode: ((String) -> Void)?
    private let preferred: NWEndpoint?
    private var fallback: [NWEndpoint]
    private var connections: [UUID: NWConnection] = [:]
    private var selected: UUID?
    private var deadline: DispatchWorkItem?
    private var fallbackTask: DispatchWorkItem?
    private var completion: ((Result<Handshake, Error>) -> Void)?
    private var finished = false
    private var lastFailure: DirectPairError?

    init(queue: DispatchQueue, identity: DirectIdentity, acceptsFingerprint: @escaping (String) -> Bool,
         preferred: NWEndpoint? = nil, endpoints: [NWEndpoint], request: DirectRequest,
         onCode: ((String) -> Void)? = nil) {
        self.queue = queue
        self.identity = identity
        self.acceptsFingerprint = acceptsFingerprint
        self.preferred = preferred
        fallback = endpoints.filter { $0 != preferred }
        self.request = request
        self.onCode = onCode
    }

    deinit { connections.values.forEach { $0.cancel() } }

    func start(_ completion: @escaping (Result<Handshake, Error>) -> Void) {
        guard !finished else { return completion(.failure(CancellationError())) }
        self.completion = completion
        timeOut(after: DirectWire.timeout)
        if let preferred {
            connect(preferred)
            if !fallback.isEmpty {
                let task = DispatchWorkItem { [weak self] in self?.startFallback() }
                fallbackTask = task
                queue.asyncAfter(deadline: .now() + 0.75, execute: task)
            }
        } else {
            startFallback()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func startFallback() {
        guard !finished, selected == nil else { return }
        fallbackTask?.cancel()
        let endpoints = fallback
        fallback.removeAll()
        for endpoint in endpoints { connect(endpoint) }
        if connections.isEmpty { finish(.failure(lastFailure ?? .noEndpoint)) }
    }

    private func connect(_ endpoint: NWEndpoint) {
        let id = UUID()
        let parameters = NWParameters.directTLS(identity: identity, queue: queue, acceptsFingerprint: acceptsFingerprint) {
            [weak self] error in
            self?.failed(id, error: error)
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connections[id] != nil else { return }
            switch state {
            case .ready: ready(id)
            case .failed(let error), .waiting(let error):
                failed(id, error: .network(error))
            case .cancelled: failed(id, error: .noEndpoint)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func failed(_ id: UUID, error: DirectPairError) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        if selected == id { return finish(.failure(error)) }
        if case .identityChanged = lastFailure {} else { lastFailure = error }
        if connections.isEmpty { startFallback() }
    }

    private func ready(_ id: UUID) {
        guard selected == nil, let connection = connections[id] else { return }
        guard let fingerprint = directFingerprint(of: connection) else { return failed(id, error: .missingCertificate) }
        guard acceptsFingerprint(fingerprint) else { return failed(id, error: .identityChanged) }
        selected = id
        fallbackTask?.cancel()
        for (other, candidate) in connections where other != id {
            candidate.stateUpdateHandler = nil
            candidate.cancel()
        }
        connections = [id: connection]
        if let onCode {
            let code = DirectSAS.formatted(localFP: identity.fingerprint, peerFP: fingerprint)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onCode(code)
                queue.async { [weak self] in self?.sendRequest(on: connection, fingerprint: fingerprint) }
            }
        } else {
            sendRequest(on: connection, fingerprint: fingerprint)
        }
    }

    private func sendRequest(on connection: NWConnection, fingerprint: String) {
        guard !finished else { return }
        DirectWire.send(request, over: connection) { [weak self] sent in
            guard let self, !finished else { return }
            if case .failure(let error) = sent { return finish(.failure(error)) }
            if request.mode == "pair" { timeOut(after: 100) }
            DirectWire.read(connection, as: DirectReply.self) { [weak self] received in
                guard let self, !finished else { return }
                switch received {
                case .failure(let error): finish(.failure(error))
                case .success(let line):
                    guard line.value.ok else {
                        let error = line.value.error ?? "The other device declined the link."
                        return finish(.failure(error == "unpaired" ? DirectPairError.unpaired : DirectPairError.rejected(error)))
                    }
                    finish(.success(Handshake(connection: connection, fingerprint: fingerprint, line: line)))
                }
            }
        }
    }

    private func timeOut(after seconds: TimeInterval) {
        deadline?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.finish(.failure(DirectPairError.timedOut))
        }
        deadline = task
        queue.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func finish(_ result: Result<Handshake, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        fallbackTask?.cancel()
        if case .success = result, let selected {
            connections.removeValue(forKey: selected)?.stateUpdateHandler = nil
        }
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        let completed = completion
        completion = nil
        completed?(result)
    }
}

final class DirectTunnel: Tunnel {
    private let peer: DirectPeer
    private let identity: DirectIdentity
    private let endpoint: NWEndpoint?
    private let defaults: UserDefaults?
    private let stderr: (Data) -> Void
    private let exited: () -> Void
    private var exchange: DirectExchange?
    private var transport: DirectTransport?
    private var closed = false

    init(peer: DirectPeer, localIdentity: DirectIdentity, endpoint: NWEndpoint? = nil, defaults: UserDefaults? = nil,
         stderr: @escaping (Data) -> Void, exited: @escaping () -> Void) {
        self.peer = peer
        identity = localIdentity
        self.endpoint = endpoint
        self.defaults = defaults
        self.stderr = stderr
        self.exited = exited
    }

    static func dial(_ alias: String, stderr: @escaping (Data) -> Void, exited: @escaping () -> Void) throws -> Tunnel {
        guard let id = DirectPeers.deviceId(from: alias), let peer = DirectPeers.peer(id: id) else {
            throw DirectPairError.unpaired
        }
        return DirectTunnel(peer: peer, localIdentity: try DirectIdentity.shared(deviceId: SyncEngine.shared.device),
                            defaults: Platform.defaults, stderr: stderr, exited: exited)
    }

    // HostLink invokes these methods on the SyncEngine queue.
    func whenReady(on queue: DispatchQueue, _ ready: @escaping () -> Void) {
        guard !closed, exchange == nil, transport == nil else { return }
        let fp = peer.fingerprint
        let dial = DirectExchange(queue: queue, identity: identity, acceptsFingerprint: { $0 == fp },
                                  preferred: endpoint ?? DirectBrowser.endpoint(for: peer),
                                  endpoints: DirectWire.endpoints(addresses: peer.addresses, port: peer.port),
                                  request: DirectRequest(mode: "sync", device: identity.deviceId))
        exchange = dial
        dial.start { [weak self] result in
            guard let self, !closed else { return }
            exchange = nil
            switch result {
            case .success(let handshake):
                let connection = handshake.connection
                if let defaults {
                    guard DirectPeers.peer(id: peer.id, defaults: defaults)?.fingerprint == fp else {
                        connection.cancel()
                        fail(DirectPairError.unpaired)
                        return
                    }
                    if let address = DirectWire.connectedAddress(connection) {
                        let addresses = peer.port == address.port
                            ? [address.host] + peer.addresses.filter { $0 != address.host } : [address.host]
                        DirectPeers.updateEndpoint(id: peer.id, addresses: addresses, port: address.port, fingerprint: fp, defaults: defaults)
                    }
                }
                transport = DirectTransport(connection, queue: queue, initialBytes: handshake.line.remainder, eof: handshake.line.eof)
                ready()
            case .failure(let error):
                fail(error)
            }
        }
    }

    func makeSession(engine: SyncEngine) -> Session {
        guard let transport else { preconditionFailure("DirectTunnel must be ready before creating a Session") }
        let session = Session(transport: transport, engine: engine)
        session.directPeerID = peer.id
        return session
    }

    func close() {
        guard !closed else { return }
        closed = true
        exchange?.cancel()
        exchange = nil
        transport?.close()
        transport = nil
        exited()
    }

    private func fail(_ error: Error) {
        switch error {
        case DirectPairError.identityChanged:
            stderr(Data("REMOTE HOST IDENTIFICATION HAS CHANGED (Direct Sync)\n".utf8))
        case DirectPairError.unpaired:
            stderr(Data("Permission denied (Direct Sync peer is unpaired)\n".utf8))
        default:
            stderr(Data((error.localizedDescription + "\n").utf8))
        }
        close()
    }
}

#if os(macOS)
extension ProcessTunnel {
    func makeSession(engine: SyncEngine) -> Session {
        Session(input: input, output: output, engine: engine)
    }
}
#endif

enum DirectPairingClient {
    static func pairNearby(endpoint: NWEndpoint, expectedFPPrefix: String, localIdentity: DirectIdentity,
                           deviceId: String, name: String, os: String, onCode: @escaping (String) -> Void) async throws -> DirectPeer {
        guard DirectPeer.validHex(expectedFPPrefix, length: 16) else { throw DirectPairError.invalidDevice }
        let request = try pairRequest(mode: "pair", identity: localIdentity, deviceId: deviceId, name: name, os: os)
        let exchange = DirectExchange(queue: .init(label: "clipbubble.direct.pairing"), identity: localIdentity,
                                      acceptsFingerprint: { $0.hasPrefix(expectedFPPrefix) },
                                      endpoints: [endpoint], request: request, onCode: onCode)
        let handshake = try await perform(exchange)
        defer { handshake.connection.cancel() }
        guard let server = handshake.line.value.descriptor, server.id != deviceId else { throw DirectPairError.invalidDevice }
        let address = DirectWire.connectedAddress(handshake.connection)
        return server.peer(fingerprint: handshake.fingerprint, addresses: address.map { [$0.host] } ?? [],
                           port: address?.port ?? 0)
    }

    static func pairQR(url: URL, localIdentity: DirectIdentity, deviceId: String, name: String, os: String) async throws -> DirectPeer {
        guard let qr = QRLink(url) else { throw DirectPairError.invalidURL }
        var request = try pairRequest(mode: "pair-qr", identity: localIdentity, deviceId: deviceId, name: name, os: os)
        request.code = qr.code
        let exchange = DirectExchange(queue: .init(label: "clipbubble.direct.qr"), identity: localIdentity,
                                      acceptsFingerprint: { $0 == qr.fingerprint },
                                      endpoints: DirectWire.endpoints(addresses: qr.addresses, port: qr.port), request: request)
        let handshake = try await perform(exchange)
        defer { handshake.connection.cancel() }
        guard let server = handshake.line.value.descriptor, server.id == qr.id, server.id != deviceId else {
            throw DirectPairError.invalidDevice
        }
        return server.peer(fingerprint: handshake.fingerprint, addresses: qr.addresses, port: qr.port)
    }

    private static func pairRequest(mode: String, identity: DirectIdentity, deviceId: String, name: String, os: String) throws -> DirectRequest {
        guard deviceId == identity.deviceId,
              let device = DirectDevice(id: deviceId, name: DirectDevice.displayName(name), os: os) else {
            throw DirectPairError.invalidDevice
        }
        return DirectRequest(mode: mode, device: device.id, name: device.name, os: device.os)
    }

    private static func perform(_ exchange: DirectExchange) async throws -> DirectExchange.Handshake {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.queue.async { exchange.start { continuation.resume(with: $0) } }
            }
        } onCancel: {
            exchange.queue.async { exchange.cancel() }
        }
    }

    private struct QRLink {
        let id: String
        let fingerprint: String
        let addresses: [String]
        let port: UInt16
        let code: String

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "clipbubble", components.host == "direct", components.path.isEmpty,
                  components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
                  let items = components.queryItems else { return nil }
            var values: [String: String] = [:]
            for item in items {
                guard values[item.name] == nil, let value = item.value else { return nil }
                values[item.name] = value
            }
            guard values["v"] == "2", let id = values["id"], DirectPeer.validID(id),
                  let fp = values["fp"], DirectPeer.validHex(fp, length: 64),
                  let hosts = values["h"], let port = values["p"].flatMap(UInt16.init), port != 0,
                  let code = values["c"], DirectPeer.validHex(code, length: 32),
                  let name = values["n"], !name.isEmpty, let os = values["os"], DirectPeer.validOS(os) else { return nil }
            let addresses = hosts.components(separatedBy: ",")
            guard addresses.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.id = id
            fingerprint = fp
            self.addresses = addresses
            self.port = port
            self.code = code
        }
    }
}
