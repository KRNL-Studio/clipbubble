import CryptoKit
import Foundation
import Network
import NIOCore
import NIOPosix
import NIOSSH
import Security

/// This iPhone's SSH key: Ed25519, made once and kept in the Keychain, in the App Group so the extensions sign with it too.
enum Keys {
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "studio.krnl.clipbubble.ssh",
                                              kSecAttrAccessGroup as String: Platform.group]

    private static let lock = NSLock()
    private static var cachedKey: Curve25519.Signing.PrivateKey?

    static func loadOrCreateKey() -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        let (status, saved) = readKey()
        if status == errSecSuccess {
            cachedKey = saved
            return saved
        }
        guard status == errSecItemNotFound else {
            SyncLog.write("couldn't read the SSH key: \(status)")
            return nil
        }

        let key = Curve25519.Signing.PrivateKey()
        // Shortcuts can sign while the phone is locked after its first unlock.
        let added = SecItemAdd(item.merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                            kSecValueData as String: key.rawRepresentation]) { $1 } as CFDictionary, nil)
        switch added {
        case errSecSuccess: cachedKey = key
        // The app and an extension can both try to make a key. Keep the one that was saved first.
        case errSecDuplicateItem: cachedKey = readKey().key
        default: SyncLog.write("couldn't save the SSH key: \(added)")
        }
        return cachedKey
    }

    private static func readKey() -> (status: OSStatus, key: Curve25519.Signing.PrivateKey?) {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (status, nil) }
        return (status, try? Curve25519.Signing.PrivateKey(rawRepresentation: data))
    }

    static var publicKey: String? {
        loadOrCreateKey().map { String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: $0).publicKey) }
    }

    /// The line for a host's ~/.ssh/authorized_keys.
    static var publicLine: String? { publicKey.map { $0 + " ClipBubble on " + Platform.deviceName } }
}

/// A host as typed: DNS, IPv4 or IPv6, with brackets around IPv6 when specifying a port.
struct SSHTarget {
    let user: String
    let host: String
    let port: Int

    var hostKeyPreference: String { "sync.hostkey.\(host):\(port)" }

    init?(_ alias: String) {
        guard let at = alias.lastIndex(of: "@"), at != alias.startIndex else { return nil }
        let user = alias[..<at]
        let address = alias[alias.index(after: at)...]

        let host: Substring
        var suffix: Substring = ""
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else { return nil }
            host = address[address.index(after: address.startIndex)..<end]
            guard IPv6Address(String(host)) != nil else { return nil }
            suffix = address[address.index(after: end)...]
        } else if let colon = address.firstIndex(of: ":"), colon == address.lastIndex(of: ":") {
            host = address[..<colon]
            suffix = address[colon...]
        } else {
            host = address
            if host.contains(":"), IPv6Address(String(host)) == nil { return nil }
        }

        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" || $0 == "\0" }) else { return nil }
        var port = 22
        if !suffix.isEmpty {
            let digits = suffix.dropFirst()
            guard suffix.hasPrefix(":"), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), (1...65535).contains(value) else { return nil }
            port = value
        }
        self.user = String(user)
        self.host = String(host)
        self.port = port
    }
}

/// Runs the remote relay over an in-process SSH connection.
final class SSHTunnel: Tunnel {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let loop: EventLoop
    private let transport: SSHChannelTransport
    private let stderr: (Data) -> Void
    private let exited: () -> Void
    private let alias: String
    private let address: String

    // Bootstrap attempts (including Happy Eyeballs candidates) and relay state all live on the same loop.
    private var connecting: [ObjectIdentifier: Channel] = [:]
    private var connection: Channel?
    private var finished = false
    private var relayed = false
    private var stderrRemaining = 8192

    init(alias: String, command: String, stderr: @escaping (Data) -> Void, exited: @escaping () -> Void) throws {
        guard let target = SSHTarget(alias) else { throw SSHTunnelError.badAlias }
        let loop = Self.group.next()
        self.loop = loop
        transport = SSHChannelTransport(loop: loop)
        self.stderr = stderr
        self.exited = exited
        self.alias = alias
        let address = Addresses.next(for: alias, fallback: target.host)
        self.address = address
        transport.onClose = { [weak self] in self?.finish() }

        let say: (String) -> Void = { stderr(Data(($0 + "\n").utf8)) }
        let hostKeys = HostKeys(preference: target.hostKeyPreference, say: say)
        let auth = KeyAuth(user: target.user, say: say)
        var configuration = SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: hostKeys)
        configuration.maximumPacketSize = SSHChannelTransport.maximumPacketSize
        let role = SSHConnectionRole.client(configuration)

        ClientBootstrap(group: loop)
            .connectTimeout(.seconds(8))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            // Notices a computer that went away (Wi-Fi change, sleep) within about 30 s.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 15)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard !finished else { throw ChannelError.ioOnClosedChannel }
                    let id = ObjectIdentifier(channel)
                    connecting[id] = channel
                    channel.closeFuture.whenComplete { [weak self] _ in self?.connecting[id] = nil }
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: role,
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        CloseOnError())
                }
            }
            .connect(host: address, port: target.port)
            .whenComplete { [self] result in
                guard !finished else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error):
                    say("ssh: connect to host \(address) port \(target.port): \(error)")
                    finish()
                case .success(let channel):
                    connection = channel
                    connecting[ObjectIdentifier(channel)] = nil
                    channel.closeFuture.whenComplete { [self] _ in finish() }
                    open(command, on: channel)
                }
            }
    }

    private func open(_ command: String, on channel: Channel) {
        guard let ssh = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
            return finish()
        }
        let opened = channel.eventLoop.makePromise(of: Channel.self)
        opened.futureResult.whenFailure { [weak self] _ in self?.finish() }
        ssh.createChannel(opened, channelType: .session) { [self] child, _ in
            child.setOption(ChannelOptions.autoRead, value: false).flatMap {
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            }.flatMapThrowing {
                try child.pipeline.syncOperations.addHandler(RelayHandler(command: command, tunnel: self))
            }
        }
    }

    func makeSession(engine: SyncEngine) -> Session {
        // The session closes on input EOF, after consuming the last stdout batch.
        let session = Session(transport: transport, engine: engine)
        ShareSync.observe(session, over: transport)
        return session
    }

    fileprivate func received(_ bytes: Data, stderr isError: Bool) {
        if isError {
            guard stderrRemaining > 0 else { return }
            let limited = bytes.prefix(stderrRemaining)
            stderrRemaining -= limited.count
            stderr(limited)
        } else {
            transport.received(bytes)
        }
    }

    fileprivate func readComplete() { transport.readComplete() }
    fileprivate func writabilityChanged() { transport.writabilityChanged() }
    fileprivate func inputClosed() { transport.inputClosed() }

    fileprivate func relayStarted(_ child: Channel) {
        guard !finished, !relayed else { return }
        relayed = true
        Addresses.worked(address, for: alias)
        transport.attach(child)
    }

    fileprivate func relayEnded() { close() }

    func close() { loop.execute { [self] in finish() } }

    private func finish() {
        guard !finished else { return }
        finished = true
        if !relayed { Addresses.failed(address, for: alias) }
        transport.finish(afterEOF: exited)
        let candidates = Array(connecting.values)
        connecting.removeAll()
        for candidate in candidates { candidate.close(promise: nil) }
        let channel = connection
        connection = nil
        channel?.close(promise: nil)
    }
}

enum SSHTunnelError: Error { case badAlias, refused, hostKeyChanged, keyUnavailable }

/// Every address a computer offered when it linked, last one that worked first. Wi-Fi hands out new IP addresses, and
/// a .local name doesn't resolve on every network, so a dial that fails moves on to the next. They all reach one
/// computer: the host key is pinned to the link, not to an address.
enum Addresses {
    private static func key(_ alias: String) -> String { "sync.addresses." + alias }

    static func save(_ hosts: [String], for alias: String) { Platform.defaults.set(hosts, forKey: key(alias)) }
    static func forget(_ alias: String) { Platform.defaults.removeObject(forKey: key(alias)) }

    static func next(for alias: String, fallback: String) -> String {
        Platform.defaults.stringArray(forKey: key(alias))?.first ?? fallback
    }

    static func worked(_ address: String, for alias: String) {
        guard var all = Platform.defaults.stringArray(forKey: key(alias)), all.first != address, all.contains(address) else { return }
        all.removeAll { $0 == address }
        save([address] + all, for: alias)
    }

    static func failed(_ address: String, for alias: String) {
        guard var all = Platform.defaults.stringArray(forKey: key(alias)), all.count > 1, all.first == address else { return }
        all.removeFirst()
        save(all + [address], for: alias)
    }
}

/// One `exec` channel: the relay command's stdout goes to the session, its stderr to the link's status.
private final class RelayHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let tunnel: SSHTunnel

    init(command: String, tunnel: SSHTunnel) {
        self.command = command
        self.tunnel = tunnel
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            .whenFailure { _ in channel.close(promise: nil) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = msg.data, let bytes = buf.readData(length: buf.readableBytes) else { return }
        if msg.type == .channel || msg.type == .stdErr { tunnel.received(bytes, stderr: msg.type == .stdErr) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        tunnel.readComplete()
        context.fireChannelReadComplete()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        tunnel.writabilityChanged()
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnel.relayEnded()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The outbound write succeeding only means the request was sent. Wait for sshd to accept it.
        if event is ChannelSuccessEvent { tunnel.relayStarted(context.channel) }
        if (event as? ChannelEvent) == .inputClosed { tunnel.inputClosed() }
        if event is ChannelFailureEvent { tunnel.relayEnded() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { tunnel.relayEnded() }
}

/// A failed handshake or refused login surfaces as an error; without this the connection would sit open forever.
private final class CloseOnError: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Offers this iPhone's key once. A host that turns it down reads as "Permission denied", like OpenSSH says it.
private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate {
    private let user: String
    private let say: (String) -> Void
    private var offered = false

    init(user: String, say: @escaping (String) -> Void) {
        self.user = user
        self.say = say
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            say("\(user): Permission denied (publickey).")
            // NIOSSH waits forever on a nil offer; failing ends the connection.
            return nextChallengePromise.fail(SSHTunnelError.refused)
        }
        guard let key = Keys.loadOrCreateKey() else {
            say("The iPhone's SSH key is unavailable. Unlock the iPhone and try again.")
            return nextChallengePromise.fail(SSHTunnelError.keyUnavailable)
        }
        offered = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "",
                                           offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
    }
}

/// Trusts a host's key the first time and holds it to that key after, like OpenSSH's known_hosts.
private final class HostKeys: NIOSSHClientServerAuthenticationDelegate {
    private let preference: String
    private let say: (String) -> Void

    init(preference: String, say: @escaping (String) -> Void) {
        self.preference = preference
        self.say = say
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let seen = String(openSSHPublicKey: hostKey)
        if let known = Platform.defaults.string(forKey: preference), known != seen {
            say("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.")
            return validationCompletePromise.fail(SSHTunnelError.hostKeyChanged)
        }
        Platform.defaults.set(seen, forKey: preference)
        validationCompletePromise.succeed(())
    }
}
