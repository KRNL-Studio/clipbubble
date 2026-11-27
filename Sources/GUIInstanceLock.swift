import Foundation

/// Holds the GUI's data-directory lock until this instance goes away.
final class GUIInstanceLock {
    private let fd: Int32

    init?(directory: URL = Paths.dir) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("app.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        self.fd = fd
    }

    // Leave the file in place so every opener locks the same inode.
    deinit { close(fd) }
}
