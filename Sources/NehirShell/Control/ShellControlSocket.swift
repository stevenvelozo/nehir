// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Darwin
import Foundation

/// A Unix-domain control socket for the shell layer, speaking newline-delimited
/// JSON (`ShellRequest` → `ShellResponse`).
///
/// The POSIX accept/bind boilerplate mirrors the base manager's `IPCServer` (a
/// non-blocking listener feeding a `DispatchSource` accept loop, gated by a
/// peer-credential check), but this is a separate socket on a separate path with
/// its own protocol — no upstream code is touched or extended. Per-connection
/// reads run on a concurrent queue via a `static` handler that captures only
/// `Sendable` values (the file descriptor and the `@MainActor` router), so no
/// non-`Sendable` socket state ever crosses a thread boundary.
final class ShellControlSocket {
    let socketPath: String

    private let router: ShellCommandRouter
    private let queue = DispatchQueue(label: "dev.guria.nehir.shell.socket")
    private let connectionQueue = DispatchQueue(
        label: "dev.guria.nehir.shell.socket.connection",
        attributes: .concurrent
    )
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    @MainActor
    init(socketPath: String, router: ShellCommandRouter) {
        self.socketPath = socketPath
        self.router = router
    }

    @MainActor
    func start() throws {
        try ensureSocketDirectoryExists()
        try Self.removeStaleSocketIfNeeded(at: socketPath)

        var startError: Error?
        queue.sync {
            do {
                let fd = try Self.makeListeningSocket(at: socketPath)
                listenFD = fd
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler(handler: makeAcceptSourceHandler())
                acceptSource = source
                source.resume()
            } catch {
                startError = error
            }
        }
        if let startError {
            stop()
            throw startError
        }
    }

    @MainActor
    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            _ = unlink(socketPath)
        }
    }

    // MARK: - Accept loop (runs on `queue`)

    /// Built in a nonisolated method on purpose: a closure created inside the
    /// `@MainActor start()` would inherit main-actor isolation and then trip a
    /// runtime executor assertion when DispatchSource runs it on the socket queue.
    private func makeAcceptSourceHandler() -> () -> Void {
        { [weak self] in self?.acceptConnections() }
    }

    private func acceptConnections() {
        guard listenFD >= 0 else { return }
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                break // EAGAIN/EWOULDBLOCK on a drained non-blocking listener, or a transient error.
            }
            guard Self.isCurrentUser(clientFD) else {
                close(clientFD)
                continue
            }
            Self.configureBlocking(clientFD)
            let router = self.router
            connectionQueue.async { Self.serve(fd: clientFD, router: router) }
        }
    }

    // MARK: - Per-connection I/O (static; captures only Sendable values)

    private static func serve(fd: Int32, router: ShellCommandRouter) {
        defer { close(fd) }
        var buffer = Data()
        let chunkCapacity = 4096
        var chunk = [UInt8](repeating: 0, count: chunkCapacity)

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkCapacity) }
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0 ..< bytesRead])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex ..< newlineIndex]
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                let requestLine = String(bytes: lineData, encoding: .utf8) ?? ""
                let responseLine = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { router.handleLine(requestLine) }
                }
                write(fd: fd, string: responseLine + "\n")
            }
        }
    }

    private static func write(fd: Int32, string: String) {
        let data = Array(string.utf8)
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    // MARK: - POSIX setup

    @MainActor
    private func ensureSocketDirectoryExists() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func removeStaleSocketIfNeeded(at path: String) throws {
        var status = stat()
        if lstat(path, &status) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw POSIXError(.EEXIST)
        }
        guard unlink(path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func makeListeningSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        configureNonBlocking(fd)

        var address = try socketAddress(for: path)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            close(fd)
            throw POSIXError(error)
        }
        guard chmod(path, 0o600) == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .EPERM
            close(fd)
            throw POSIXError(error)
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            close(fd)
            throw POSIXError(error)
        }
        return fd
    }

    private static func socketAddress(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard utf8Path.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Path.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }

    private static func configureNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        applyCommonSocketOptions(fd)
    }

    private static func configureBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        applyCommonSocketOptions(fd)
    }

    private static func applyCommonSocketOptions(_ fd: Int32) {
        let descriptorFlags = fcntl(fd, F_GETFD, 0)
        if descriptorFlags >= 0 { _ = fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    /// Only accept connections from the same effective user — a local trust gate
    /// matching the base manager's IPC.
    private static func isCurrentUser(_ fd: Int32) -> Bool {
        var effectiveUserID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(fd, &effectiveUserID, &groupID) == 0 else { return false }
        return effectiveUserID == geteuid()
    }
}
