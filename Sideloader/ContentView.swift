//
//  ContentView.swift
//  Sideloader
//
//  Created by hani on 11/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(InstallerModel.self) private var model
    @State private var isImporting = false
    @State private var isDropTargeted = false

    private static let ipaType = UTType(filenameExtension: "ipa") ?? .data

    var body: some View {
        @Bindable var model = model

        Form {
            Section("App") {
                PackageSection(isImporting: $isImporting)
            }

            Section {
                DeviceSection()
            } header: {
                HStack {
                    Text("Device")
                    Spacer()
                    if model.isRefreshingDevices {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("Install") {
                InstallSection()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 600)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
            Task { await model.open(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.ipaType]) { result in
            if case .success(let url) = result {
                Task { await model.open(url) }
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Installer", selection: $model.preference) {
                    Text(automaticTitle).tag(InstallerPreference.automatic)
                    Divider()
                    ForEach(InstallerKind.allCases) { kind in
                        Text(kind.title)
                            .tag(InstallerPreference(rawValue: kind.rawValue)!)
                            .selectionDisabled(model.unavailableReason(for: kind) != nil)
                    }
                }
                .help("Choose how apps are installed")
                .disabled(model.state.isRunning)
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingDevices || model.state.isRunning)
                .keyboardShortcut("r")
            }
        }
        .task { await model.refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !model.state.isRunning, !model.isRefreshingDevices else { return }
            Task { await model.refreshDevices() }
        }
    }

    private var automaticTitle: String {
        let resolved = InstallerKind.allCases.first { model.unavailableReason(for: $0) == nil }
        return "Automatic" + (resolved.map { " (\($0.title))" } ?? "")
    }
}

// MARK: - App

private struct PackageSection: View {
    @Environment(InstallerModel.self) private var model
    @Binding var isImporting: Bool

    var body: some View {
        if let package = model.package {
            HStack(alignment: .top, spacing: 14) {
                AppIcon(data: package.iconData)
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.name).font(.title3.weight(.semibold))
                    Text(package.bundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Version \(package.version) (\(package.build))  ·  \(package.fileSize.formatted(.byteCount(style: .file)))"
                         + (package.minimumOSVersion.map { "  ·  iOS \($0)+" } ?? ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { isImporting = true }
                    .disabled(model.state.isRunning)
            }
            .padding(.vertical, 4)

            if let profile = package.profile {
                ProfileRow(profile: profile)
            } else {
                Label("No embedded provisioning profile. The device may refuse this app.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a signed .ipa here")
                    .foregroundStyle(.secondary)
                Button("Choose IPA…") { isImporting = true }
                    .keyboardShortcut("o")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay {
                if model.isLoadingPackage {
                    ProgressView()
                }
            }
        }

        if let error = model.packageError {
            Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

private struct ProfileRow: View {
    let profile: ProvisioningProfile

    var body: some View {
        LabeledContent("Profile") {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(profile.kind.rawValue) · \(profile.name)")
                if let team = profile.teamName ?? profile.teamIdentifier {
                    Text(team).foregroundStyle(.secondary)
                }
                if let expiration = profile.expirationDate {
                    Text(profile.isExpired
                         ? "Expired \(expiration.formatted(date: .abbreviated, time: .omitted))"
                         : "Expires \(expiration.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(profile.isExpired ? .red : .secondary)
                }
            }
            .font(.callout)
        }
    }
}

private struct AppIcon: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data), image.isValid {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .fontWeight(.ultraLight)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Device

private struct DeviceSection: View {
    @Environment(InstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model

        if model.activeKind == nil {
            Label(noInstallerMessage, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if let error = model.deviceError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if model.devices.isEmpty {
            Text(model.isRefreshingDevices ? "Looking for devices…" : emptyMessage)
                .foregroundStyle(.secondary)
        } else {
            Picker("Device", selection: $model.selectedDeviceID) {
                ForEach(model.devices) { device in
                    DeviceRow(device: device).tag(Optional(device.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.state.isRunning)

            if let device = model.selectedDevice {
                DeviceWarnings(device: device)
            }
        }
    }

    private var noInstallerMessage: String {
        let kind = model.preference.kind
        return kind.flatMap(model.unavailableReason(for:)).map { "\(kind!.title) is unavailable: \($0)" }
            ?? "No installer is available. Install Xcode or rebuild with libimobiledevice bundled."
    }

    private var emptyMessage: String {
        model.activeKind == .libimobiledevice
            ? "No devices. Connect an iPhone or iPad with a cable and unlock it."
            : "No devices. Connect an iPhone or iPad, or pair one over Wi-Fi in Xcode."
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connectionSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(connectionHelp)
            Text(device.name)
            Text([device.model, device.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSymbol: String {
        switch device.connection {
        case .usb: "cable.connector"
        case .network: "wifi"
        case .unknown: "iphone"
        }
    }

    private var connectionHelp: String {
        switch device.connection {
        case .usb: "Connected with a cable"
        case .network: "Connected over Wi-Fi"
        case .unknown: "Connection unknown"
        }
    }
}

private struct DeviceWarnings: View {
    @Environment(InstallerModel.self) private var model
    let device: Device

    var body: some View {
        if let problem = device.problem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if device.developerModeEnabled == false, model.package?.profile?.kind == .development {
            Label("Developer Mode is off. Turn it on in Settings › Privacy & Security to run development builds.",
                  systemImage: "hammer")
                .foregroundStyle(.orange)
        }
        if let profile = model.package?.profile, !profile.allows(udid: device.udid) {
            Label("This device (\(device.udid)) isn't in the app's provisioning profile, so iOS will refuse it.",
                  systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.orange)
        }
        if device.connection == .network, model.activeKind == .libimobiledevice {
            Label("libimobiledevice usually can't install over Wi-Fi on iOS 17 and later. Use a cable.",
                  systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Install

private struct InstallSection: View {
    @Environment(InstallerModel.self) private var model
    @State private var showsLog = false

    var body: some View {
        HStack {
            status
            Spacer()
            if model.state.isRunning {
                Button("Cancel", role: .cancel) { model.cancelInstall() }
            } else {
                Button("Install") { model.install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canInstall)
            }
        }

        if case .running(let progress) = model.state {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }

        DisclosureGroup("Log", isExpanded: $showsLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { entry in
                            Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.message)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                }
                .frame(height: 140)
                .onChange(of: model.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .idle:
            Text(idleMessage).foregroundStyle(.secondary)
        case .running(let progress):
            Text(progress.message)
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private var idleMessage: String {
        guard let kind = model.activeKind else { return "No installer available" }
        if model.package == nil { return "Choose an app to install" }
        if model.selectedDevice == nil { return "Choose a device" }
        return "Ready to install with \(kind.title)"
    }
}

#Preview {
    ContentView()
        .environment(InstallerModel())
}
