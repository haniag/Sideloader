//
//  SettingsView.swift
//  Sideloader
//

import SwiftUI

struct SettingsView: View {
    @Environment(InstallerModel.self) private var model

    private var manifest: LibraryManifest? { model.libraryManifest }
    private static let updateCommand = "Scripts/update-libimobiledevice.sh"

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Installer") {
                Picker("Default installer", selection: $model.preference) {
                    Text("Automatic").tag(InstallerPreference.automatic)
                    ForEach(InstallerKind.allCases) { kind in
                        Text(kind.title).tag(InstallerPreference(rawValue: kind.rawValue)!)
                    }
                }
                Text("Automatic uses devicectl when Xcode is installed, and libimobiledevice otherwise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("devicectl") {
                if let deviceCtl = model.deviceCtl {
                    LabeledContent("Xcode", value: deviceCtl.xcodeURL.path)
                    Label("Available · USB and Wi-Fi", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Unavailable: Xcode isn't installed.", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let reason = model.unavailableReason(for: .libimobiledevice) {
                    Label(reason, systemImage: "xmark.circle").foregroundStyle(.orange)
                } else {
                    Label("Available · USB", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }

                LabeledContent("Loaded from", value: model.usesHomebrewLibrary ? "Homebrew" : "App bundle")

                if let manifest, !model.usesHomebrewLibrary {
                    LabeledContent("Bundled", value: manifest.updated.formatted(dateString: manifest.updated))
                    LabeledContent("Built for", value: "\(manifest.architectures), macOS \(manifest.minimumMacOS)+")
                }

                ForEach(rows) { status in
                    LabeledContent(status.project) {
                        HStack(spacing: 6) {
                            Text(status.inUse ?? "not installed")
                            if let latest = status.latest {
                                Text("· latest \(latest)").foregroundStyle(.secondary)
                            }
                            if status.usesHomebrew, let bundled = status.bundled {
                                Text("· bundled \(bundled)").foregroundStyle(.secondary)
                            } else if !status.usesHomebrew, let homebrew = status.homebrew {
                                Text("· Homebrew \(homebrew)").foregroundStyle(.secondary)
                            }
                            if model.libraryUpdatesCheckedAt != nil {
                                Image(systemName: status.isOutdated ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(status.isOutdated ? .orange : .green)
                            }
                        }
                        .font(.callout)
                    }
                }

                if model.canUpdateLibraries {
                    HStack {
                        if model.isUpdatingLibraries {
                            ProgressView().controlSize(.small)
                        }
                        if let message = model.libraryUpdateMessage {
                            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if model.libraryUpdateNeedsRelaunch {
                            Button("Relaunch") { model.relaunch() }
                        } else {
                            Button("Update with Homebrew") {
                                Task { await model.updateLibraries() }
                            }
                            .disabled(model.isUpdatingLibraries || model.state.isRunning)
                        }
                    }
                } else if rows.contains(where: \.isOutdated) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A newer version is available. Install Homebrew to update here, or in the Sideloader project folder run the following, then rebuild the app:")
                        HStack {
                            Text(Self.updateCommand).font(.callout.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.updateCommand, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                    .foregroundStyle(.orange)
                }

                HStack {
                    if let lastChecked = model.libraryUpdatesCheckedAt {
                        Text("Checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isCheckingLibraryUpdates {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check for Updates") {
                        Task { await model.checkLibraryUpdates() }
                    }
                    .disabled(model.isCheckingLibraryUpdates)
                }
            } header: {
                Text("libimobiledevice")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.checkLibraryUpdates() }
    }

    /// Bundled versions before the first check completes, then the full comparison.
    private var rows: [LibraryUpdates.Status] {
        if !model.libraryUpdates.isEmpty { return model.libraryUpdates }
        return LibraryUpdates.projects.map {
            LibraryUpdates.Status(project: $0, bundled: manifest?.versions[$0], latest: nil, homebrew: nil,
                                  usesHomebrew: model.usesHomebrewLibrary)
        }
    }
}

private extension String {
    /// Formats the manifest's ISO-8601 timestamp for display, falling back to the raw string.
    func formatted(dateString: String) -> String {
        (try? Date(dateString, strategy: .iso8601))?.formatted(date: .abbreviated, time: .shortened) ?? dateString
    }
}
