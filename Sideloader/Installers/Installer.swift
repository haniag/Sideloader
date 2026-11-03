//
//  Installer.swift
//  Sideloader
//

import Foundation

nonisolated enum InstallerKind: String, CaseIterable, Identifiable, Sendable {
    case devicectl
    case libimobiledevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devicectl: "devicectl (Xcode)"
        case .libimobiledevice: "libimobiledevice"
        }
    }
}

/// Which installer the user wants; `.automatic` prefers devicectl when Xcode is installed.
nonisolated enum InstallerPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case devicectl
    case libimobiledevice

    var id: String { rawValue }

    var kind: InstallerKind? {
        switch self {
        case .automatic: nil
        case .devicectl: .devicectl
        case .libimobiledevice: .libimobiledevice
        }
    }
}

nonisolated struct Device: Identifiable, Hashable, Sendable {
    enum Connection: Sendable {
        case usb
        case network
        case unknown
    }

    /// The identifier the installer that listed the device uses to address it.
    let id: String
    let udid: String
    let name: String
    let model: String
    let osVersion: String?
    let connection: Connection
    let developerModeEnabled: Bool?
    /// Set when the device is listed but can't be used yet (locked, not trusted…).
    let problem: String?
}

nonisolated struct InstallProgress: Sendable {
    /// 0...1, or nil when the step has no measurable progress.
    var fraction: Double?
    var message: String
}

nonisolated protocol Installer: Sendable {
    var kind: InstallerKind { get }

    func devices() async throws -> [Device]

    /// Installs the package and returns a short summary of what was installed.
    func install(
        _ package: AppPackage,
        on device: Device,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws -> String
}

nonisolated struct InstallerError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
