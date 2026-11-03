//
//  ProcessRunner.swift
//  Sideloader
//

import Foundation

/// Runs a command, streaming its combined stdout/stderr as it arrives.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onOutput: onOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
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
    private let onOutput: (@Sendable (String) -> Void)?

    init(onOutput: (@Sendable (String) -> Void)?) {
        self.onOutput = onOutput
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
        onOutput?(String(decoding: chunk, as: UTF8.self))
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
