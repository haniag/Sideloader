//
//  AppPackage.swift
//  Sideloader
//

import Foundation
import Security

/// A signed .ipa, extracted to a temporary folder so both installers can use it.
nonisolated struct AppPackage: Identifiable, Sendable {
    let id = UUID()
    let ipaURL: URL
    let appURL: URL
    let workDirectory: URL
    let name: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String?
    let iconData: Data?
    let fileSize: Int64
    let profile: ProvisioningProfile?

    static func load(from ipaURL: URL) async throws -> AppPackage {
        try await Task.detached(priority: .userInitiated) {
            try extract(ipaURL)
        }.value
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private static func extract(_ ipaURL: URL) throws -> AppPackage {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appending(path: "Sideloader", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", ipaURL.path, workDirectory.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            try? fileManager.removeItem(at: workDirectory)
            throw InstallerError("\(ipaURL.lastPathComponent) could not be unzipped. Is it a valid .ipa?")
        }

        let payload = workDirectory.appending(path: "Payload", directoryHint: .isDirectory)
        let apps = (try? fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let appURL = apps.first else {
            try? fileManager.removeItem(at: workDirectory)
            throw InstallerError("\(ipaURL.lastPathComponent) must contain exactly one app in its Payload folder.")
        }

        guard let infoData = try? Data(contentsOf: appURL.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String
        else {
            try? fileManager.removeItem(at: workDirectory)
            throw InstallerError("The app's Info.plist is missing or unreadable.")
        }

        let name = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let profileData = try? Data(contentsOf: appURL.appending(path: "embedded.mobileprovision"))
        let fileSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        return AppPackage(
            ipaURL: ipaURL,
            appURL: appURL,
            workDirectory: workDirectory,
            name: name,
            bundleIdentifier: bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String ?? "–",
            build: info["CFBundleVersion"] as? String ?? "–",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            iconData: iconData(in: appURL, info: info),
            fileSize: fileSize,
            profile: profileData.flatMap(ProvisioningProfile.init(data:))
        )
    }

    /// Picks the largest PNG named by CFBundleIcons. Xcode-optimized PNGs may not
    /// decode on macOS, so callers should be ready for an unreadable image.
    private static func iconData(in appURL: URL, info: [String: Any]) -> Data? {
        let icons = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let prefixes = icons?["CFBundleIconFiles"] as? [String] ?? []
        guard !prefixes.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: appURL, includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }

        let candidates = files.filter { file in
            file.pathExtension == "png" && prefixes.contains { file.lastPathComponent.hasPrefix($0) }
        }
        let largest = candidates.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return left < right
        }
        return largest.flatMap { try? Data(contentsOf: $0) }
    }
}

/// The parts of embedded.mobileprovision that decide whether an install can work.
nonisolated struct ProvisioningProfile: Sendable {
    enum Kind: String, Sendable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case enterprise = "Enterprise"
        case distribution = "Distribution"
    }

    let name: String
    let teamName: String?
    let teamIdentifier: String?
    let expirationDate: Date?
    let provisionedDevices: [String]
    let kind: Kind

    var isExpired: Bool {
        expirationDate.map { $0 < .now } ?? false
    }

    func allows(udid: String) -> Bool {
        kind == .enterprise || kind == .distribution
            || provisionedDevices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    init?(data: Data) {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { buffer in
            CMSDecoderUpdateMessage(decoder, buffer.baseAddress!, buffer.count)
        }
        var content: CFData?
        guard updated == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content,
              let plist = try? PropertyListSerialization.propertyList(from: content as Data, format: nil)
                as? [String: Any]
        else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let devices = plist["ProvisionedDevices"] as? [String] ?? []

        name = plist["Name"] as? String ?? "Unnamed profile"
        teamName = plist["TeamName"] as? String
        teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        expirationDate = plist["ExpirationDate"] as? Date
        provisionedDevices = devices

        if plist["ProvisionsAllDevices"] as? Bool == true {
            kind = .enterprise
        } else if entitlements["get-task-allow"] as? Bool == true {
            kind = .development
        } else if !devices.isEmpty {
            kind = .adHoc
        } else {
            kind = .distribution
        }
    }
}
