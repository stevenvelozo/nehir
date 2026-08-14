// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Darwin
import Foundation
import NehirShellWire

/// Minimal blocking client for the shell control socket: one request, one
/// response, connection closed. Speaks the same newline-delimited JSON the
/// in-app `ShellControlSocket` serves.
struct ShellControlClient {
    let socketPath: String

    enum ClientError: Error, CustomStringConvertible {
        case connectFailed(String, Int32)
        case writeFailed
        case noResponse
        case decodeFailed(String)

        var description: String {
            switch self {
            case let .connectFailed(path, code):
                let hint = (code == ENOENT || code == ECONNREFUSED)
                    ? " — is Nehir running with the shell socket enabled?"
                    : ""
                return "cannot connect to shell socket at \(path) (errno \(code))\(hint)"
            case .writeFailed:
                return "failed to write request to the shell socket"
            case .noResponse:
                return "no response from the shell socket"
            case let .decodeFailed(raw):
                return "could not decode response: \(raw)"
            }
        }
    }

    func send(_ request: ShellRequest) throws -> ShellResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed(socketPath, errno) }
        defer { close(fd) }

        try connectSocket(fd)
        try writeAll(fd, data: try framed(request))

        let responseData = readLine(fd)
        guard !responseData.isEmpty else { throw ClientError.noResponse }
        do {
            return try JSONDecoder().decode(ShellResponse.self, from: responseData)
        } catch {
            throw ClientError.decodeFailed(String(bytes: responseData, encoding: .utf8) ?? "<non-utf8 response>")
        }
    }

    // MARK: - Internals

    private func connectSocket(_ fd: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.connectFailed(socketPath, ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ClientError.connectFailed(socketPath, errno) }
    }

    private func framed(_ request: ShellRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    private func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if written <= 0 { throw ClientError.writeFailed }
                offset += written
            }
        }
    }

    private func readLine(_ fd: Int32) -> Data {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if count <= 0 { break }
            out.append(contentsOf: chunk[0 ..< count])
            if let newline = out.firstIndex(of: 0x0A) {
                return out[..<newline]
            }
        }
        return out
    }
}
