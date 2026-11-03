//
//  DeviceCtlInstaller.swift
//  Sideloader
//

import AppKit

/// Installs through Xcode's `devicectl`, which supports USB and Wi-Fi paired devices.
nonisolated struct DeviceCtlInstaller: Installer {
    let developerDirectory: URL

    var kind: InstallerKind { .devicectl }

    private var executable: URL {
        developerDirectory.appending(path: "usr/bin/devicectl")
    }

    /// Finds an Xcode that ships devicectl: the selected one first, then any installed copy.
    @MainActor
    static func locate() -> DeviceCtlInstaller? {
        var candidates: [URL] = []
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(URL(filePath: link))
        }
        candidates += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .map { $0.appending(path: "Contents/Developer") }
        candidates.append(URL(filePath: "/Applications/Xcode.app/Contents/Developer"))

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0.appending(path: "usr/bin/devicectl").path) }
            .map(DeviceCtlInstaller.init(developerDirectory:))
    }

    /// The Xcode app bundle that provides devicectl, for display.
    var xcodeURL: URL {
        developerDirectory.deletingLastPathComponent().deletingLastPathComponent()
    }

    func devices() async throws -> [Device] {
        let json = try await run(["list", "devices"])
        let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return devices.compactMap(Self.device(from:))
    }

    func install(
        _ package: AppPackage,
        on device: Device,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws -> String {
        progress(InstallProgress(fraction: nil, message: "Connecting to \(device.name)…"))
        // devicectl buffers its progress output unless it writes to a terminal,
        // so run it under script(1) to give it a pseudo-terminal.
        let json = try await run(
            ["device", "install", "app", "--device", device.id, package.appURL.path],
            usePseudoTerminal: true
        ) { chunk in
            if let update = Self.progress(from: chunk) {
                progress(update)
            }
        }

        let installed = ((json["result"] as? [String: Any])?["installedApplications"] as? [[String: Any]])?.first
        let bundleID = installed?["bundleID"] as? String ?? package.bundleIdentifier
        return "Installed \(bundleID) on \(device.name)."
    }

    /// Runs devicectl with `--json-output` and returns the parsed JSON, throwing its error if it failed.
    private func run(
        _ arguments: [String],
        usePseudoTerminal: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> [String: Any] {
        let jsonURL = FileManager.default.temporaryDirectory.appending(path: "devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let fullArguments = arguments + ["--json-output", jsonURL.path]
        let output: ProcessRunner.Output
        if usePseudoTerminal {
            output = try await ProcessRunner.run(
                URL(filePath: "/usr/bin/script"),
                arguments: ["-q", "/dev/null", executable.path] + fullArguments,
                onOutput: onOutput
            )
        } else {
            output = try await ProcessRunner.run(executable, arguments: fullArguments, onOutput: onOutput)
        }
        try Task.checkCancellation()

        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallerError(text.isEmpty ? "devicectl exited with status \(output.status)." : text)
        }

        let outcome = (json["info"] as? [String: Any])?["outcome"] as? String
        if outcome != "success" {
            throw InstallerError(Self.errorMessage(from: json) ?? "devicectl failed (\(outcome ?? "unknown outcome")).")
        }
        return json
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        let userInfo = error["userInfo"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            (userInfo[key] as? [String: Any])?["string"] as? String
        }
        let parts = [
            string("NSLocalizedDescription"),
            string("NSLocalizedFailureReason"),
            string("NSLocalizedRecoverySuggestion"),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func device(from json: [String: Any]) -> Device? {
        guard let identifier = json["identifier"] as? String else { return nil }
        // `properties` replaces the older *Properties dictionaries; read both.
        let properties = json["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any]
            ?? json["hardwareProperties"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let software = properties["software"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any]
            ?? json["connectionProperties"] as? [String: Any] ?? [:]
        let legacy = json["deviceProperties"] as? [String: Any] ?? [:]

        guard (hardware["reality"] as? String ?? "physical") == "physical" else { return nil }

        let osVersion = (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String
            ?? legacy["osVersionNumber"] as? String
        let developerMode: Bool? = {
            if let status = state["developerModeStatus"] as? [String: Any] {
                return status["enabled"] != nil
            }
            return (legacy["developerModeStatus"] as? String).map { $0 == "enabled" }
        }()
        let transport: Device.Connection = switch connection["transportType"] as? String {
        case "wired": .usb
        case "localNetwork": .network
        default: .unknown
        }
        let paired = (connection["pairingState"] as? String).map { $0 == "paired" } ?? true

        return Device(
            id: identifier,
            udid: hardware["udid"] as? String ?? identifier,
            name: state["name"] as? String ?? legacy["name"] as? String ?? "Unnamed device",
            model: hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "Unknown model",
            osVersion: osVersion,
            connection: transport,
            developerModeEnabled: developerMode,
            problem: paired ? nil : "Not paired with this Mac. Connect it with a cable and tap Trust."
        )
    }

    /// Pulls the latest percentage or status line out of a chunk of devicectl output.
    private static func progress(from chunk: String) -> InstallProgress? {
        let cleaned = chunk.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
        if let match = cleaned.matches(of: /(\d{1,3})%/).last, let percent = Double(match.1) {
            return InstallProgress(fraction: min(percent, 100) / 100, message: "Installing…")
        }
        let line = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.replacing(/^\d{2}:\d{2}:\d{2}\s+/, with: "").trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map { InstallProgress(fraction: nil, message: $0) }
    }
}
