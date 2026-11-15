//
//  InstallerModel.swift
//  Sideloader
//

import AppKit
import Observation

@Observable
final class InstallerModel {
    enum InstallState {
        case idle
        case running(InstallProgress)
        case succeeded(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let message: String
    }

    // MARK: Installers

    let deviceCtl = DeviceCtlInstaller.locate()
    let libIMobileDevice = LibIMobileDevice.shared

    var preference: InstallerPreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: "installerPreference")
            if oldValue != preference {
                Task { await refreshDevices() }
            }
        }
    }

    /// The installer in use: the preferred one, else devicectl when Xcode is present, else libimobiledevice.
    var activeKind: InstallerKind? {
        if let preferred = preference.kind {
            return unavailableReason(for: preferred) == nil ? preferred : nil
        }
        return InstallerKind.allCases.first { unavailableReason(for: $0) == nil }
    }

    func unavailableReason(for kind: InstallerKind) -> String? {
        switch kind {
        case .devicectl:
            deviceCtl == nil ? "Xcode isn't installed." : nil
        case .libimobiledevice:
            switch libIMobileDevice {
            case .success: nil
            case .failure(let error): error.message
            }
        }
    }

    private var installer: (any Installer)? {
        switch activeKind {
        case .devicectl: deviceCtl
        case .libimobiledevice: (try? libIMobileDevice.get()).map(LibIMobileDeviceInstaller.init(library:))
        case nil: nil
        }
    }

    // MARK: State

    var package: AppPackage?
    var packageError: String?
    var isLoadingPackage = false

    var devices: [Device] = []
    var selectedDeviceID: Device.ID?
    var deviceError: String?
    var isRefreshingDevices = false

    var state: InstallState = .idle
    var log: [LogEntry] = []

    // MARK: Library updates

    /// Whether the bundled libimobiledevice libraries match the latest upstream and Homebrew versions.
    enum LibraryHealth {
        case checking
        case upToDate
        case outdated([String])
        /// The last check couldn't reach GitHub or find Homebrew for every library.
        case unknown
    }

    let libraryManifest = LibraryManifest.bundled()
    private(set) var libraryUpdates: [LibraryUpdates.Status] = []
    private(set) var isCheckingLibraryUpdates = false
    private(set) var libraryUpdatesCheckedAt: Date?

    var libraryHealth: LibraryHealth {
        let outdated = libraryUpdates.filter { $0.isOutdated || $0.inUse == nil }.map(\.project)
        if !outdated.isEmpty { return .outdated(outdated) }
        if isCheckingLibraryUpdates || libraryUpdatesCheckedAt == nil { return .checking }
        let allCompared = libraryUpdates.allSatisfy { $0.latest != nil || $0.homebrew != nil }
        return allCompared && !libraryUpdates.isEmpty ? .upToDate : .unknown
    }

    func checkLibraryUpdates() async {
        guard !isCheckingLibraryUpdates else { return }
        isCheckingLibraryUpdates = true
        libraryUpdates = await LibraryUpdates.check(manifest: libraryManifest, usesHomebrew: usesHomebrewLibrary)
        libraryUpdatesCheckedAt = .now
        isCheckingLibraryUpdates = false
    }

    /// Whether the running app loaded Homebrew's libimobiledevice rather than the bundled copy.
    var usesHomebrewLibrary: Bool { (try? libIMobileDevice.get())?.usesHomebrew ?? false }
    let canUpdateLibraries = Homebrew.prefix != nil
    private(set) var isUpdatingLibraries = false
    private(set) var libraryUpdateMessage: String?
    /// Set once Homebrew has newer libraries than the ones this process already loaded.
    private(set) var libraryUpdateNeedsRelaunch = false

    /// Installs or upgrades the libraries with Homebrew. They load at launch, so a change needs a relaunch.
    func updateLibraries() async {
        guard !isUpdatingLibraries else { return }
        isUpdatingLibraries = true
        defer { isUpdatingLibraries = false }
        libraryUpdateMessage = "Asking Homebrew for updates…"
        func versions() -> [String?] { LibraryUpdates.projects.map(LibraryUpdates.homebrewVersion(of:)) }
        let before = versions()
        do {
            let output = try await Homebrew.update { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return }
                Task { @MainActor in
                    if self.isUpdatingLibraries { self.libraryUpdateMessage = line }
                }
            }
            if output.status != 0 {
                let last = output.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(output.status)"
                libraryUpdateMessage = "Homebrew couldn't update: \(last)"
            } else if versions() != before || !usesHomebrewLibrary {
                libraryUpdateNeedsRelaunch = true
                libraryUpdateMessage = "Updated. Relaunch Sideloader to use the new libraries."
            } else {
                libraryUpdateMessage = "Homebrew has nothing newer."
            }
        } catch {
            libraryUpdateMessage = "Couldn't run Homebrew: \(error.localizedDescription)"
        }
        await checkLibraryUpdates()
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private var installTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// The last progress milestone written to the log, in percent.
    private var loggedPercent = 0
    private static let logStep = 20

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    var canInstall: Bool {
        package != nil && selectedDevice != nil && selectedDevice?.problem == nil && installer != nil && !state.isRunning
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "installerPreference")
        preference = stored.flatMap(InstallerPreference.init(rawValue:)) ?? .automatic

        // Don't leave the extracted app in the temporary folder after quitting.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.package?.cleanUp() }
        }
    }

    // MARK: Actions

    func open(_ url: URL) async {
        guard !state.isRunning else { return }
        isLoadingPackage = true
        packageError = nil
        defer { isLoadingPackage = false }
        do {
            let loaded = try await AppPackage.load(from: url)
            package?.cleanUp()
            package = loaded
            state = .idle
            append("Loaded \(url.lastPathComponent) (\(loaded.bundleIdentifier) \(loaded.version))")
        } catch {
            packageError = error.localizedDescription
        }
    }

    func refreshDevices() async {
        guard let installer else {
            devices = []
            deviceError = "No installer is available."
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshingDevices = true
        defer {
            if generation == refreshGeneration { isRefreshingDevices = false }
        }

        do {
            let found = try await installer.devices()
            // Ignore results from a refresh that a newer one (e.g. after switching installers) superseded.
            guard generation == refreshGeneration else { return }
            devices = found
            deviceError = nil
            if selectedDevice == nil {
                selectedDeviceID = (found.first { $0.problem == nil } ?? found.first)?.id
            }
        } catch {
            guard generation == refreshGeneration else { return }
            devices = []
            deviceError = error.localizedDescription
        }
    }

    func install() {
        guard canInstall, let installer, let package, let device = selectedDevice else { return }
        state = .running(InstallProgress(fraction: nil, message: "Starting…"))
        loggedPercent = 0
        log.removeAll()
        append("Installing \(package.bundleIdentifier) on \(device.name) with \(installer.kind.title)")

        installTask = Task {
            do {
                let summary = try await installer.install(package, on: device) { update in
                    Task { @MainActor in self.report(update) }
                }
                // The last progress update can stop short of 100% when the final step finishes quickly.
                if loggedPercent > 0 {
                    logMilestones(upTo: 100)
                }
                state = .succeeded(summary)
                append(summary)
            } catch is CancellationError {
                state = .failed("Install cancelled.")
                append("Install cancelled.")
            } catch {
                state = .failed(error.localizedDescription)
                append("Failed: \(error.localizedDescription)")
            }
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func report(_ update: InstallProgress) {
        guard case .running(let current) = state else { return }
        // Keep the last known percentage when a step only reports a message.
        let fraction = update.fraction ?? current.fraction
        state = .running(InstallProgress(fraction: fraction, message: update.message))
        if update.message != current.message {
            append(update.message)
        }
        if let fraction {
            logMilestones(upTo: Int(fraction * 100))
        }
    }

    /// Logs "Installing 20%", "Installing 40%"… for each step reached since the last one logged.
    private func logMilestones(upTo percent: Int) {
        while loggedPercent + Self.logStep <= percent {
            loggedPercent += Self.logStep
            append("Installing \(loggedPercent)%")
        }
    }

    private func append(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }
}
