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
        // A quick query opens the connection (a few seconds over Wi-Fi), so the install
        // that follows only covers the transfer and the log shows each stage when it starts.
        _ = try await run(["device", "info", "lockState", "--device", device.id])

        // devicectl reports no progress while it copies and installs (checked with --verbose too),
        // so this stage has no percentage.
        progress(InstallProgress(fraction: nil, message: "Installing…"))
        // devicectl buffers its output unless it writes to a terminal, so run it under script(1).
        let json = try await run(
            ["device", "install", "app", "--device", device.id, package.appURL.path],
            usePseudoTerminal: true
        ) { line in
            if let update = Self.progress(from: line) {
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
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> [String: Any] {
        let jsonURL = FileManager.default.temporaryDirectory.appending(path: "devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let fullArguments = arguments + ["--json-output", jsonURL.path]
        // Apps opened from Finder get no LANG or TERM. Without LANG devicectl prints "?" in place of
        // "•" and "…"; TERM tells its terminal output what the pseudo-terminal supports.
        let current = ProcessInfo.processInfo.environment
        let environment = [
            "LANG": current["LANG"] ?? "en_US.UTF-8",
            "TERM": current["TERM"] ?? "xterm-256color",
        ]
        let output: ProcessRunner.Output
        if usePseudoTerminal {
            output = try await ProcessRunner.run(
                URL(filePath: "/usr/bin/script"),
                arguments: ["-q", "/dev/null", executable.path] + fullArguments,
                environment: environment,
                keepsInputOpen: true,
                onLine: onLine
            )
        } else {
            output = try await ProcessRunner.run(
                executable, arguments: fullArguments, environment: environment, onLine: onLine
            )
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
        // An .ipa only installs on iPhones and iPads (both report "iOS"), not on a paired Watch, TV or Vision Pro.
        guard (hardware["platform"] as? String ?? "iOS") == "iOS" else { return nil }

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
        // devicectl also lists devices it remembers but can't reach right now.
        let reachable = connection["tunnelState"] as? String != "unavailable"
        let problem: String? = if !paired {
            "Not paired with this Mac. Connect it with a cable and tap Trust."
        } else if !reachable {
            "Not connected. Connect it with a cable, or unlock it on the same Wi-Fi network."
        } else {
            nil
        }

        return Device(
            id: identifier,
            udid: hardware["udid"] as? String ?? identifier,
            name: state["name"] as? String ?? legacy["name"] as? String ?? "Unnamed device",
            model: hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "Unknown model",
            osVersion: osVersion,
            connection: transport,
            developerModeEnabled: developerMode,
            problem: problem
        )
    }

    /// Turns one line of devicectl output into a progress update, or nil for lines not worth showing.
    private static func progress(from line: String) -> InstallProgress? {
        let cleaned = line
            .replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
            .filter { char in !(char.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false) }
            .replacing(/^\^D/, with: "")
            .replacing(/^\d{2}:\d{2}:\d{2}\s+/, with: "")
            .trimmingCharacters(in: .whitespaces)
        // The "App installed:" summary lists "• key: value" details ("?" in place of "•" without a
        // UTF-8 locale). Only the bundle ID means anything to a reader; the rest are internal paths and IDs.
        if let detail = cleaned.wholeMatch(of: /[•?]\s+(\w+):\s*(.*)/) {
            return detail.1 == "bundleID" ? InstallProgress(fraction: nil, message: "Bundle ID: \(detail.2)") : nil
        }
        // Other lines are the "App installed:" heading and devicectl's own status notes; the
        // Connecting/Installing stages already cover them, and failures come from the result JSON.
        return nil
    }
}
