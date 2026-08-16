// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import FableCore
import Foundation

/// Out-of-process retold runtime: spawns `node` running the bundled harness and
/// talks newline-delimited JSON over stdio. This is the home for work
/// JavaScriptCore cannot do — real async, network, filesystem, and full npm
/// modules such as meadow — behind the same `FableRuntime` surface as the
/// in-process `FableCore`.
public actor NodeSidecar: FableRuntime {
    public enum SidecarError: Error, CustomStringConvertible {
        case nodeNotFound
        case harnessMissing
        case notRunning
        case processExited(Int32)
        case remote(String)
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .nodeNotFound: "node executable not found (set NEHIR_NODE or install Node.js)"
            case .harnessMissing: "bundled sidecar harness (nehir-sidecar.js) is missing"
            case .notRunning: "sidecar is not running"
            case let .processExited(code): "sidecar process exited (status \(code))"
            case let .remote(message): message
            case let .decodeFailed(raw): "could not decode sidecar response: \(raw)"
            }
        }
    }

    private let nodePath: String
    private let harnessURL: URL
    private let bundleURL: URL?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readBuffer = Data()
    private var nextID = 1

    /// Create a sidecar. Throws if `node` cannot be located or the harness resource
    /// is missing, so a host can degrade gracefully to the in-process runtime.
    public init(
        nodePath: String? = nil,
        harnessURL: URL? = nil,
        bundleURL: URL? = FableCoreResources.pictBundleURL
    ) throws {
        guard let resolvedNode = nodePath ?? Self.locateNode() else {
            throw SidecarError.nodeNotFound
        }
        guard let resolvedHarness = harnessURL ?? Bundle.module.url(forResource: "nehir-sidecar", withExtension: "js")
        else {
            throw SidecarError.harnessMissing
        }
        self.nodePath = resolvedNode
        self.harnessURL = resolvedHarness
        self.bundleURL = bundleURL
    }

    /// Launch the node process and begin reading responses.
    public func start() throws {
        guard process == nil else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = [harnessURL.path]

        var environment = ProcessInfo.processInfo.environment
        if let bundleURL {
            environment["NEHIR_SIDECAR_BUNDLE"] = bundleURL.path
        }
        task.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        // Leave stderr inherited so harness/fable logs surface in the host's console.

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        task.terminationHandler = { [weak self] finished in
            Task { await self?.handleTermination(status: finished.terminationStatus) }
        }

        try task.run()
        process = task
        stdinHandle = stdinPipe.fileHandleForWriting
    }

    // swiftlint:disable:next async_without_await
    public func shutdown() async {
        guard let process else { return }
        stdinHandle?.closeFile()
        stdinHandle = nil
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        failAllPending(with: SidecarError.notRunning)
    }

    public func invoke(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let stdinHandle, process?.isRunning == true else {
            throw SidecarError.notRunning
        }
        let id = nextID
        nextID += 1

        let payload = SidecarRequest(id: id, method: method, params: params)
        var line = try JSONEncoder().encode(payload)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Response handling

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex ..< newline]
            readBuffer.removeSubrange(readBuffer.startIndex ... newline)
            guard !lineData.isEmpty else { continue }
            deliver(lineData)
        }
    }

    private func deliver(_ lineData: Data) {
        guard let response = try? JSONDecoder().decode(SidecarResponse.self, from: lineData) else {
            return
        }
        guard let id = response.id, let continuation = pending.removeValue(forKey: id) else {
            return
        }
        if response.ok {
            continuation.resume(returning: response.result ?? .null)
        } else {
            continuation.resume(throwing: SidecarError.remote(response.error ?? "sidecar error"))
        }
    }

    private func handleTermination(status: Int32) {
        stdinHandle = nil
        process = nil
        failAllPending(with: SidecarError.processExited(status))
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Node discovery

    private static func locateNode() -> String? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NEHIR_NODE"], !override.isEmpty {
            return override
        }
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                candidates.append("\(directory)/node")
            }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

private struct SidecarRequest: Encodable {
    let id: Int
    let method: String
    let params: JSONValue
}

private struct SidecarResponse: Decodable {
    let id: Int?
    let ok: Bool
    let result: JSONValue?
    let error: String?
}
