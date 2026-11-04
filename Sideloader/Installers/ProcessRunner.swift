//
//  ProcessRunner.swift
//  Sideloader
//

import Foundation

/// Runs a command, streaming its combined stdout/stderr line by line as it arrives.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        keepsInputOpen: Bool = false,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // script(1) forwards end-of-file on its input to the terminal, which echoes "^D",
        // so give it an input that stays open until the process exits.
        let input = keepsInputOpen ? Pipe() : nil
        process.standardInput = input ?? FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    collector.finish()
                    try? input?.fileHandleForWriting.close()
                    continuation.resume(returning: Output(status: process.terminationStatus, text: collector.text))
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

private nonisolated final class ProcessBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    /// Bytes after the last line break, held until the line is complete so that
    /// lines and multi-byte characters are never split across chunks.
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines = lock.withLock {
            data.append(chunk)
            pending.append(chunk)
            // Carriage returns count as breaks too: progress output redraws its line with them.
            guard let end = pending.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return [Data]() }
            let complete = pending[..<end]
            pending = Data(pending[(end + 1)...])
            return complete.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }).map { Data($0) }
        }
        lines.forEach(emit)
    }

    /// Delivers a final line that had no trailing line break.
    func finish() {
        let rest = lock.withLock {
            defer { pending = Data() }
            return pending
        }
        if !rest.isEmpty {
            emit(rest)
        }
    }

    private func emit(_ line: Data) {
        onLine?(String(decoding: line, as: UTF8.self))
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
