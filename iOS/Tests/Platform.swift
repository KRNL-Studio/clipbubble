import Foundation

// Run the shared iOS code on the host with isolated storage and no external SSH dials.
enum Platform {
    static let os = "ios"
    static let defaults = UserDefaults(suiteName: "clipbubble.host-tests." + UUID().uuidString)!
    static let deviceName = "iOS Host Test"
    static let retryCap: Double = 30
    static var dataDir: URL { fatalError("Run with isolated CLIPBUBBLE_HOME") }
    static var downloads: URL { Paths.dir }
    static func apply(_ clip: Clip) {}
    static func listen(_ engine: SyncEngine) -> AnyObject? { nil }
    static func onWake(_ callback: @escaping () -> Void) {}
    static func dial(_ alias: String, _ command: String, stderr: @escaping (Data) -> Void,
                     exited: @escaping () -> Void) throws -> Tunnel {
        throw POSIXError(.ECONNREFUSED)
    }
}

extension LinkState {
    var phoneText: String { text }
}
