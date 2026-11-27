import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

private struct AcceptClient: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

private struct AcceptHost: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private struct TestPassword: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(.init(username: "loopback", serviceName: "", offer: .password(.init(password: "test"))))
    }
}

private final class ClientRelay: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let transport: SSHChannelTransport

    init(_ transport: SSHChannelTransport) { self.transport = transport }

    func channelActive(context: ChannelHandlerContext) {
        transport.attach(context.channel)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        transport.received(Data(buffer.readableBytesView))
    }
    func channelReadComplete(context: ChannelHandlerContext) { transport.readComplete() }
    func channelWritabilityChanged(context: ChannelHandlerContext) { transport.writabilityChanged() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == .inputClosed { transport.inputClosed() }
    }
    func channelInactive(context: ChannelHandlerContext) { transport.finish() }
}

final class FrameRecorder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let decode: Bool
    private var reader = FrameReader()
    private(set) var frames: [Frame] = []

    init(decode: Bool) { self.decode = decode }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard decode, case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        do { frames += try reader.feed(Data(buffer.readableBytesView)) }
        catch { fatalError("Malformed frame coming from the session: \(error)") }
    }
}

final class Loopback {
    let loop: EventLoop
    let transport: SSHChannelTransport
    let serverChild: Channel
    private let group: MultiThreadedEventLoopGroup
    private let listener: Channel
    private let clientParent: Channel
    private let recorder: FrameRecorder

    init(recordFrames: Bool = true) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        loop = group.next()
        transport = SSHChannelTransport(loop: loop)
        let serverReady = loop.makePromise(of: Channel.self)
        let recorder = FrameRecorder(decode: recordFrames)
        self.recorder = recorder
        var server = SSHServerConfiguration(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: AcceptClient())
        server.maximumPacketSize = SSHChannelTransport.maximumPacketSize
        let serverRole = SSHConnectionRole.server(server)
        listener = try ServerBootstrap(group: loop).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSHHandler(role: serverRole,
                                  allocator: channel.allocator, inboundChildChannelInitializer: { child, _ in
                        child.setOption(ChannelOptions.autoRead, value: false).flatMapThrowing {
                            try child.pipeline.syncOperations.addHandler(recorder)
                            serverReady.succeed(child)
                        }
                    })
                )
            }
        }.bind(host: "127.0.0.1", port: 0).wait()
        var client = SSHClientConfiguration(userAuthDelegate: TestPassword(), serverAuthDelegate: AcceptHost())
        client.maximumPacketSize = SSHChannelTransport.maximumPacketSize
        let clientRole = SSHConnectionRole.client(client)
        clientParent = try ClientBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSHHandler(role: clientRole,
                                  allocator: channel.allocator, inboundChildChannelInitializer: nil)
                )
            }
        }.connect(to: listener.localAddress!).wait()
        let parent = clientParent
        let transport = self.transport
        transport.onClose = { parent.close(promise: nil) }
        let clientReady = loop.makePromise(of: Channel.self)
        try loop.submit {
            let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            ssh.createChannel(clientReady, channelType: .session) { child, _ in
                child.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                }.flatMapThrowing {
                    try child.pipeline.syncOperations.addHandler(ClientRelay(transport))
                }
            }
        }.wait()
        _ = try clientReady.futureResult.wait()
        serverChild = try serverReady.futureResult.wait()
    }

    func beginServerReads() throws {
        try serverChild.setOption(ChannelOptions.autoRead, value: true).wait()
        serverChild.read()
    }

    func send(_ data: Data) -> EventLoopFuture<Void> {
        serverChild.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data))))
    }

    func frames() -> [Frame] { try! loop.submit { self.recorder.frames }.wait() }

    func disconnect() {
        clientParent.close(promise: nil)
    }

    func shutdown() {
        disconnect()
        try? listener.close().wait()
        try! group.syncShutdownGracefully()
    }
}

func transportTests() throws {
    do {
        let ssh = try Loopback()
        defer { ssh.shutdown() }
        let read = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let eof = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let bytes = Data(repeating: 0x65, count: 5 * 1024 * 1024)
        var count = 0
        ssh.transport.start(on: DispatchQueue(label: "wave3.slow-session")) { data in
            guard let data else { eof.signal(); return }
            if count == 0 {
                read.signal()
                require(release.wait(timeout: .now() + 5) == .success, "test resumes stalled reader")
            }
            require(data.allSatisfy { $0 == 0x65 }, "bytes survive the burst")
            count += data.count
        }
        ssh.send(bytes).whenSuccess { sent.signal() }
        require(read.wait(timeout: .now() + 5) == .success, "reader sees first batch")
        require(sent.wait(timeout: .now() + 0.15) == .timedOut, "SSH window backs up while Session is stalled")
        try ssh.loop.submit {}.wait()
        release.signal()
        require(sent.wait(timeout: .now() + 5) == .success, "burst drains after the reader resumes")
        try ssh.serverChild.close(mode: .output).wait()
        require(eof.wait(timeout: .now() + 5) == .success && count == bytes.count, "half-close follows the last byte")
        print("PASS SSH receive burst, backpressure, event-loop liveness, ordered EOF")
    }

    do {
        let ssh = try Loopback()
        defer { ssh.shutdown() }
        let engine = SyncEngine.shared
        let session = Session(transport: ssh.transport, engine: engine)
        let closed = DispatchSemaphore(value: 0)
        let bytes = Data(repeating: 0x77, count: 5 * 1024 * 1024)
        let file = Paths.dir.appendingPathComponent("upload.bin")
        try bytes.write(to: file)
        engine.queue.sync {
            session.onClose = { closed.signal() }
            engine.begin(session)
            require(session.upload(hash: "f:burst", index: 0, path: file.path, offset: 0), "begin a Session upload")
        }
        try ssh.beginServerReads()
        require(eventually {
            ssh.frames().reduce(0) { total, frame in
                if case .chunk(_, _, _, _, let data) = frame { return total + data.count }
                return total
            } == bytes.count
        }, "Session upload crosses fragment and SSH window boundaries")
        ssh.disconnect()
        require(closed.wait(timeout: .now() + 5) == .success, "peer disconnect closes Session")
        print("PASS Session upload frames and disconnect")
    }

    for _ in 0..<8 {
        let ssh = try Loopback(recordFrames: false)
        defer { ssh.shutdown() }
        let completion = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        ssh.transport.start(on: DispatchQueue(label: "wave3.close")) { if $0 == nil { ended.signal() } }
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                ssh.transport.write(Data(count: Sync.maxFrame)) { success in
                    require(!success, "a closing channel can't finish a window-blocked write")
                    completion.signal()
                }
            } else { ssh.transport.close() }
        }
        require(completion.wait(timeout: .now() + 5) == .success, "pending write completes on teardown")
        require(ended.wait(timeout: .now() + 5) == .success, "teardown sends EOF")
        require(completion.wait(timeout: .now()) == .timedOut, "write completion is once only")
    }
    print("PASS concurrent write and close across 8 SSH channels")
}
