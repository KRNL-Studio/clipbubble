import Foundation
import Network

struct DirectPeer: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let os: String
    let fingerprint: String
    var addresses: [String]
    var port: UInt16
    var lastSeen: Double

    static func validID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    static func validHex(_ string: String, length: Int) -> Bool {
        string.utf8.count == length && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validOS(_ os: String) -> Bool { ["macos", "ios", "linux", "windows"].contains(os) }
}

enum DirectPeers {
    static let prefix = "direct:"
    private static let key = "sync.directPeers"
    private static let lock = NSLock()

    static func alias(for id: String) -> String { prefix + id.lowercased() }

    static func deviceId(from alias: String) -> String? {
        guard isDirect(alias) else { return nil }
        let id = String(alias.dropFirst(prefix.count))
        return DirectPeer.validID(id) ? id : nil
    }

    static func isDirect(_ alias: String) -> Bool { alias.hasPrefix(prefix) }

    static var all: [DirectPeer] { all(defaults: Platform.defaults) }

    static func all(defaults: UserDefaults) -> [DirectPeer] {
        lock.withLock { read(defaults) }
    }

    static func peer(id: String, defaults: UserDefaults = Platform.defaults) -> DirectPeer? {
        all(defaults: defaults).first { $0.id == id }
    }

    static func peer(fingerprint: String, defaults: UserDefaults = Platform.defaults) -> DirectPeer? {
        all(defaults: defaults).first { $0.fingerprint == fingerprint }
    }

    static func save(_ peer: DirectPeer, defaults: UserDefaults = Platform.defaults) {
        guard DirectPeer.validID(peer.id), DirectPeer.validHex(peer.fingerprint, length: 64) else { return }
        lock.withLock {
            var peers = read(defaults)
            peers.removeAll { $0.id == peer.id || $0.fingerprint == peer.fingerprint }
            peers.append(peer)
            write(peers, to: defaults)
        }
    }

    static func remove(id: String, defaults: UserDefaults = Platform.defaults, engine: SyncEngine = .shared) {
        lock.withLock {
            write(read(defaults).filter { $0.id != id }, to: defaults)
        }
        engine.dropDirect(id)
    }

    static func updateEndpoint(id: String, addresses: [String], port: UInt16, fingerprint: String? = nil,
                               defaults: UserDefaults = Platform.defaults) {
        lock.withLock {
            var peers = read(defaults)
            guard let index = peers.firstIndex(where: { $0.id == id && (fingerprint == nil || $0.fingerprint == fingerprint) }) else { return }
            peers[index].addresses = addresses
            peers[index].port = port
            peers[index].lastSeen = Date().timeIntervalSince1970
            write(peers, to: defaults)
        }
    }

    private static func read(_ defaults: UserDefaults) -> [DirectPeer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DirectPeer].self, from: data)) ?? []
    }

    private static func write(_ peers: [DirectPeer], to defaults: UserDefaults) {
        if let bytes = try? JSONEncoder().encode(peers) { defaults.set(bytes, forKey: key) }
    }
}

struct DiscoveredPeer: Equatable, Identifiable {
    let id: String
    let name: String
    let os: String
    let fingerprintPrefix: String
    let endpoint: NWEndpoint

    init?(endpoint: NWEndpoint, txt: NWTXTRecord, localDeviceId: String) {
        guard case .service = endpoint,
              txt["v"] == "2", let id = txt["id"], id != localDeviceId, DirectPeer.validID(id),
              let name = txt["name"], !name.isEmpty, name.utf8.count <= 48,
              let os = txt["os"], DirectPeer.validOS(os),
              let fp = txt["fp"], DirectPeer.validHex(fp, length: 16) else { return nil }
        self.id = id
        self.name = name
        self.os = os
        fingerprintPrefix = fp
        self.endpoint = endpoint
    }
}

#if DEBUG
extension DiscoveredPeer {
    /// App Store screenshots only: a computer listed under Nearby Computers that isn't on the network.
    init(demo name: String, os: String) {
        id = "demo-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        self.name = name
        self.os = os
        fingerprintPrefix = String(repeating: "0", count: 16)
        endpoint = .hostPort(host: "127.0.0.1", port: 9)
    }
}
#endif

final class DirectBrowser {
    static let serviceType = "_clipbubble._tcp"
    private static let lock = NSLock()
    private static var live: [UUID: [DiscoveredPeer]] = [:]

    private let localDeviceId: String
    private let token = UUID()
    private var browser: NWBrowser?
    private var peers: [DiscoveredPeer] = []
    var onChange: ([DiscoveredPeer]) -> Void

    init(localDeviceId: String, onChange: @escaping ([DiscoveredPeer]) -> Void = { _ in }) {
        self.localDeviceId = localDeviceId
        self.onChange = onChange
        start()
    }

    deinit {
        browser?.cancel()
        Self.lock.withLock { Self.live[token] = nil }
    }

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let found = results.compactMap { result -> DiscoveredPeer? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return DiscoveredPeer(endpoint: result.endpoint, txt: txt, localDeviceId: self.localDeviceId)
            }
            var ids: Set<String> = []
            publish(found.sorted { $0.endpoint.debugDescription < $1.endpoint.debugDescription }
                .filter { ids.insert($0.id).inserted }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) })
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .failed(let error) = state {
                SyncLog.write("Direct discovery: \(error)")
                stop()
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        browser?.cancel()
        browser = nil
        publish([])
    }

    private func publish(_ found: [DiscoveredPeer]) {
        Self.lock.withLock { Self.live[token] = found.isEmpty ? nil : found }
        guard peers != found else { return }
        peers = found
        onChange(found)
    }

    static func endpoint(for peer: DirectPeer) -> NWEndpoint? {
        lock.withLock {
            live.values.lazy.flatMap { $0 }
                .first { $0.id == peer.id && peer.fingerprint.hasPrefix($0.fingerprintPrefix) }?.endpoint
        }
    }
}
