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

/// Runs the remote relay over an in-process SSH connection, and joins its stdio to pipes the shared `Session` reads and writes.
/// Failures are reported the way OpenSSH words them, so `HostLink` reads them like it does on the Mac.
final class SSHTunnel: Tunnel {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let input: FileHandle
    let output: FileHandle
    private let toSession = Pipe()
    private let fromSession = Pipe()
    private var connection: Channel?
    private let lock = NSLock()
    private var ended = false
    private var finished = false
    private let stderr: (Data) -> Void
    private let exited: () -> Void
    private let alias: String
    private let address: String
    private var relayed = false

    init(alias: String, command: String, stderr: @escaping (Data) -> Void, exited: @escaping () -> Void) throws {
        // The pipes below outlive a dropped link for a moment, and a write to a closed one would otherwise kill the process.
        signal(SIGPIPE, SIG_IGN)
        guard let target = SSHTarget(alias) else { throw SSHTunnelError.badAlias }
        input = toSession.fileHandleForReading
        output = fromSession.fileHandleForWriting
        self.stderr = stderr
        self.exited = exited
        let say: (String) -> Void = { stderr(Data(($0 + "\n").utf8)) }
        let hostKeys = HostKeys(preference: target.hostKeyPreference, say: say)
        let auth = KeyAuth(user: target.user, say: say)
        let address = Addresses.next(for: alias, fallback: target.host)
        self.alias = alias
        self.address = address

        ClientBootstrap(group: Self.group)
            .connectTimeout(.seconds(8))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            // Notices a computer that went away (Wi-Fi change, sleep) within about 30 s, like ssh's ServerAliveInterval on the Mac.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 15)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostKeys)),
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        CloseOnError())
                }
            }
            .connect(host: address, port: target.port)
            .whenComplete { [self] result in
                switch result {
                case .failure(let e):
                    say("ssh: connect to host \(address) port \(target.port): \(e)")
                    finish()
                case .success(let channel):
                    lock.lock(); connection = channel; let stop = ended; lock.unlock()
                    channel.closeFuture.whenComplete { [self] _ in finish() }
                    if stop { channel.close(promise: nil); return }
                    open(command, on: channel)
                }
            }
    }

    private func open(_ command: String, on channel: Channel) {
        guard let ssh = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
            return channel.close(promise: nil)
        }
        let opened = channel.eventLoop.makePromise(of: Channel.self)
        opened.futureResult.whenFailure { _ in channel.close(promise: nil) }
        ssh.createChannel(opened, channelType: .session) { [self] child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(RelayHandler(command: command, tunnel: self))
            }
        }
    }

    /// Bytes from the host's stdout, for the session.
    fileprivate func received(_ d: Data) {
        do { try toSession.fileHandleForWriting.write(contentsOf: d) } catch { close() }
    }

    fileprivate func receivedError(_ d: Data) { stderr(d) }

    /// Starts sending what the session writes, once the relay is running.
    fileprivate func relayStarted(_ child: Channel) {
        lock.lock()
        guard !ended, !finished, !relayed else { lock.unlock(); return }
        relayed = true
        lock.unlock()
        Addresses.worked(address, for: alias)
        fromSession.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; child.close(promise: nil); return }
            // Waiting backs up into the pipe and then the session, which keeps a big upload out of memory and lets a ping overtake it.
            do {
                try child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: d)))).wait()
            } catch {
                h.readabilityHandler = nil
                child.close(promise: nil)
            }
        }
    }

    fileprivate func relayEnded() {
        lock.lock(); let c = connection; lock.unlock()
        c?.close(promise: nil)
        finish()
    }

    func close() {
        lock.lock(); ended = true; let c = connection; lock.unlock()
        c?.close(promise: nil)
    }

    /// Once: the session sees end of file, and the link hears it's over.
    private func finish() {
        lock.lock()
        let first = !finished
        finished = true
        connection = nil
        let worked = relayed
        lock.unlock()
        guard first else { return }
        if !worked { Addresses.failed(address, for: alias) }
        fromSession.fileHandleForReading.readabilityHandler = nil
        try? toSession.fileHandleForWriting.close()
        exited()
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
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        let channel = context.channel
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            .whenFailure { _ in channel.close(promise: nil) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = msg.data, let bytes = buf.readData(length: buf.readableBytes) else { return }
        if msg.type == .channel { tunnel.received(bytes) } else if msg.type == .stdErr { tunnel.receivedError(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnel.relayEnded()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The outbound write succeeding only means the request was sent. Wait for sshd to accept it.
        if event is ChannelSuccessEvent { tunnel.relayStarted(context.channel) }
        if event is ChannelFailureEvent || (event as? ChannelEvent) == .inputClosed { context.close(promise: nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
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
