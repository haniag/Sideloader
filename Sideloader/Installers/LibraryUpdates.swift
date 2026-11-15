//
//  LibraryUpdates.swift
//  Sideloader
//

import Foundation

/// Compares the bundled libimobiledevice libraries with the latest upstream releases
/// and with the copies in Homebrew, which Scripts/update-libimobiledevice.sh vendors from.
/// The Homebrew installation the app loads libimobiledevice from and updates it with.
nonisolated enum Homebrew {
    static let prefix: String? = ["/opt/homebrew", "/usr/local"].first {
        FileManager.default.isExecutableFile(atPath: "\($0)/bin/brew")
    }

    /// Installs the libraries, or upgrades the ones already installed, streaming brew's output.
    static func update(onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Output {
        guard let prefix else { throw InstallerError("Homebrew isn't installed.") }
        return try await ProcessRunner.run(
            URL(filePath: "\(prefix)/bin/brew"),
            arguments: ["install"] + LibraryUpdates.projects,
            environment: [
                "PATH": "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOMEBREW_NO_ENV_HINTS": "1",
                "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            ],
            onLine: onLine)
    }
}

nonisolated enum LibraryUpdates {
    static let projects = ["libimobiledevice", "libimobiledevice-glue", "libusbmuxd", "libplist"]

    struct Status: Identifiable, Sendable {
        let project: String
        let bundled: String?
        let latest: String?
        let homebrew: String?
        /// Whether the app loaded Homebrew's copy instead of the bundled one.
        let usesHomebrew: Bool

        var id: String { project }

        /// The version the app is running with.
        var inUse: String? { usesHomebrew ? homebrew : bundled }

        var isOutdated: Bool {
            guard let inUse = inUse.map(upstreamVersion) else { return false }
            return [latest, homebrew.map(upstreamVersion)]
                .compactMap { $0 }
                .contains { compare($0, inUse) == .orderedDescending }
        }
    }

    static func check(manifest: LibraryManifest?, usesHomebrew: Bool) async -> [Status] {
        await withTaskGroup(of: Status.self) { group in
            for project in projects {
                group.addTask {
                    Status(
                        project: project,
                        bundled: manifest?.versions[project],
                        latest: await latestTag(of: project),
                        homebrew: homebrewVersion(of: project),
                        usesHomebrew: usesHomebrew
                    )
                }
            }
            var statuses: [Status] = []
            for await status in group {
                statuses.append(status)
            }
            return statuses.sorted { projects.firstIndex(of: $0.project)! < projects.firstIndex(of: $1.project)! }
        }
    }

    /// Highest version-looking tag on github.com/libimobiledevice/<project>.
    private static func latestTag(of project: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/libimobiledevice/\(project)/tags?per_page=100") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return tags
            .compactMap { $0["name"] as? String }
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            .filter { $0.wholeMatch(of: /\d+(\.\d+)*/) != nil }
            .max { compare($0, $1) == .orderedAscending }
    }

    static func homebrewVersion(of project: String) -> String? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let link = "\(prefix)/opt/\(project)"
            if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
                return URL(filePath: resolved).lastPathComponent
            }
        }
        return nil
    }

    /// "1.4.0_2" → "1.4.0" (drops Homebrew's revision suffix).
    static func upstreamVersion(_ version: String) -> String {
        String(version.split(separator: "_").first ?? Substring(version))
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
