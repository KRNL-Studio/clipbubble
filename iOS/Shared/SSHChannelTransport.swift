import Foundation
import NIOCore
import NIOSSH

/// The SSH child has autoRead disabled. Each manual read releases one SSH-window-bounded batch,
/// and the next read waits for Session to parse and handle that batch on its own queue.
final class SSHChannelTransport: SessionTransport {
    // NIOSSH sets the receive window to 64 packets. Use the RFC minimum to keep it at 2 MiB.
    static let maximumPacketSize = 32 * 1024

    private let loop: EventLoop
    private var child: Channel?
    private var receiver: (queue: DispatchQueue, read: (Data?) -> Void)?
    private var incoming = Data()
    private var reading = false
    private var delivering = false
    private var eof = false
    private var eofQueued = false
    private var ended = false
    private var afterEOF: () -> Void = {}

    // At most one frame is pending, including during exec and SSH window stalls.
    private struct Write {
        let bytes: Data
        let completion: (Bool) -> Void
        var offset = 0
    }
    private var pending: Write?
    private var writing = false

    // Installed before bootstrap. Called on the event loop.
    var onClose: () -> Void = {}
    // Installed before start, called on the Session queue after it handles a batch.
    var didReceive: () -> Void = {}

    init(loop: EventLoop) { self.loop = loop }

    func start(on queue: DispatchQueue, receive: @escaping (Data?) -> Void) {
        let didReceive = self.didReceive
        loop.execute { [self] in
            receiver = (queue, { bytes in
                receive(bytes)
                if bytes != nil { didReceive() }
            })
            deliver()
        }
    }

    func write(_ bytes: Data, completion: @escaping (Bool) -> Void) {
        loop.execute { [self] in
            guard !ended, pending == nil, bytes.count <= Sync.maxFrame + 4 else { return completion(false) }
            pending = Write(bytes: bytes, completion: completion)
            flush()
        }
    }

    func close() { loop.execute { [self] in onClose(); finish() } }

    // The methods below run on the child's event loop.

    func attach(_ child: Channel) {
        guard !ended else { return }
        self.child = child
        deliver()
        flush()
    }

    func received(_ bytes: Data) {
        guard !ended, !eof else { return }
        incoming.append(bytes)
    }

    func readComplete() {
        reading = false
        deliver()
    }

    func inputClosed() { eof = true }

    func finish(afterEOF: @escaping () -> Void = {}) {
        guard !ended else { return }
        ended = true
        child = nil
        eof = true
        let write = pending
        pending = nil
        if eofQueued {
            write?.completion(false)
            afterEOF()
        } else {
            self.afterEOF = {
                write?.completion(false)
                afterEOF()
            }
        }
        deliver()
    }

    private func deliver() {
        guard !delivering, let receiver else { return }
        if !incoming.isEmpty {
            let bytes = incoming
            incoming = Data()
            delivering = true
            receiver.queue.async { [self] in
                receiver.read(bytes)
                loop.execute { [self] in
                    delivering = false
                    deliver()
                }
            }
        } else if eof {
            self.receiver = nil
            eofQueued = true
            let afterEOF = self.afterEOF
            self.afterEOF = {}
            receiver.queue.async { receiver.read(nil); afterEOF() }
        } else if let child, !reading {
            reading = true
            loop.execute { [self] in
                if !eof { child.read() }
            }
        }
    }

    func writabilityChanged() { flush() }

    private func flush() {
        guard !writing, let child, child.isWritable, let write = pending else { return }
        let end = min(write.bytes.count, write.offset + 64 * 1024)
        let startIndex = write.bytes.startIndex
        let part = write.bytes[(startIndex + write.offset)..<(startIndex + end)]
        let message = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: part)))
        writing = true
        child.writeAndFlush(message).whenComplete { [self] result in
            // Avoid reentering the SSH pipeline while it is processing a write/window update.
            loop.execute { [self] in
                writing = false
                guard pending != nil else { return }
                switch result {
                case .success where end < write.bytes.count:
                    pending?.offset = end
                    flush()
                case .success:
                    pending = nil
                    write.completion(true)
                case .failure:
                    pending = nil
                    write.completion(false)
                }
            }
        }
    }
}
