//
//  LibIMobileDeviceInstaller.swift
//  Sideloader
//

import Foundation

/// Installs over usbmuxd with the bundled libimobiledevice: uploads the .ipa with AFC,
/// then asks installation_proxy to install it. Works without Xcode; USB only in practice.
nonisolated struct LibIMobileDeviceInstaller: Installer {
    let library: LibIMobileDevice

    var kind: InstallerKind { .libimobiledevice }

    private static let label = "Sideloader"
    private static let stagingDirectory = "PublicStaging"

    func devices() async throws -> [Device] {
        try await Task.detached(priority: .userInitiated) { try listDevices() }.value
    }

    func install(
        _ package: AppPackage,
        on device: Device,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws -> String {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try installBlocking(package, on: device, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Devices

    private func listDevices() throws -> [Device] {
        var list: UnsafeMutablePointer<LibIMobileDevice.Handle?>?
        var count: Int32 = 0
        let error = library.getDeviceListExtended(&list, &count)
        if error == LibIMobileDevice.deviceErrorNoDevice {
            return []
        }
        guard error == 0, let list else {
            throw InstallerError("usbmuxd didn't return a device list (error \(error)).")
        }
        defer { _ = library.deviceListExtendedFree(list) }

        // A device can be listed twice (USB and Wi-Fi); keep USB, which is what works.
        var connections: [(udid: String, network: Bool)] = []
        for index in 0..<Int(count) {
            guard let info = list[index],
                  let udid = info.load(as: UnsafePointer<CChar>?.self).map({ String(cString: $0) })
            else { continue }
            let type = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.stride, as: Int32.self)
            let network = type == LibIMobileDevice.connectionNetwork
            if let existing = connections.firstIndex(where: { $0.udid == udid }) {
                if !network { connections[existing].network = false }
            } else {
                connections.append((udid, network))
            }
        }
        return connections.map { describeDevice(udid: $0.udid, network: $0.network) }
    }

    private func describeDevice(udid: String, network: Bool) -> Device {
        let connection: Device.Connection = network ? .network : .usb
        func device(name: String = "iOS device", model: String = "Unknown model", os: String? = nil,
                    developerMode: Bool? = nil, problem: String? = nil) -> Device {
            Device(id: udid, udid: udid, name: name, model: model, osVersion: os,
                   connection: connection, developerModeEnabled: developerMode, problem: problem)
        }

        let session: Session
        do {
            session = try Session(library: library, udid: udid, network: network)
        } catch {
            return device(problem: error.localizedDescription)
        }
        defer { session.close() }

        let developerMode = session.boolValue(domain: "com.apple.security.mac.amfi", key: "DeveloperModeStatus")
        return device(
            name: session.stringValue(key: "DeviceName") ?? "iOS device",
            model: session.stringValue(key: "ProductType") ?? "Unknown model",
            os: session.stringValue(key: "ProductVersion"),
            developerMode: developerMode
        )
    }

    // MARK: - Install

    private func installBlocking(
        _ package: AppPackage,
        on device: Device,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) throws -> String {
        progress(InstallProgress(fraction: nil, message: "Connecting to \(device.name)…"))
        let session = try Session(library: library, udid: device.udid, network: device.connection == .network)
        defer { session.close() }

        let remotePath = "\(Self.stagingDirectory)/\(package.bundleIdentifier).ipa"
        try upload(package.ipaURL, to: remotePath, session: session, cancellation: cancellation) { fraction in
            progress(InstallProgress(fraction: fraction * 0.5, message: "Installing…"))
        }

        progress(InstallProgress(fraction: 0.5, message: "Installing…"))
        let service = try session.startService("com.apple.mobile.installation_proxy")
        defer { _ = library.lockdownServiceDescriptorFree(service) }

        var client: LibIMobileDevice.Handle?
        let clientError = library.instproxyClientNew(session.device, service, &client)
        guard clientError == 0, let client else {
            throw InstallerError("Couldn't start the installation service (error \(clientError)).")
        }
        defer { _ = library.instproxyClientFree(client) }

        let options = library.plistNewDict()
        defer { library.plistFree(options) }
        _ = library.plistDictSetItem(options, "CFBundleIdentifier", library.plistNewString(package.bundleIdentifier))

        // The device's own steps ("GeneratingApplicationMap"…) aren't shown: the log tracks the overall percentage.
        let operation = InstallOperation(library: library) { percent in
            progress(InstallProgress(fraction: 0.5 + Double(percent) / 200, message: "Installing…"))
        }
        let context = Unmanaged.passRetained(operation).toOpaque()
        let callback: LibIMobileDevice.StatusCallback = { _, status, context in
            guard let context else { return }
            Unmanaged<InstallOperation>.fromOpaque(context).takeUnretainedValue().handle(status)
        }

        let installError = library.instproxyInstall(client, remotePath, options, callback, context)
        guard installError == 0 else {
            Unmanaged<InstallOperation>.fromOpaque(context).release()
            throw InstallerError("The device refused the install request (error \(installError)).")
        }

        guard let result = operation.wait(timeout: .now() + 15 * 60, cancellation: cancellation) else {
            // The status thread may still call back, so the operation is deliberately not released.
            throw InstallerError(cancellation.isCancelled
                ? "Install cancelled. The device may still finish installing in the background."
                : "Timed out waiting for the device to finish installing.")
        }
        Unmanaged<InstallOperation>.fromOpaque(context).release()

        switch result {
        case .success:
            return "Installed \(package.bundleIdentifier) on \(device.name)."
        case .failure(let error):
            throw error
        }
    }

    private func upload(
        _ fileURL: URL,
        to remotePath: String,
        session: Session,
        cancellation: CancellationFlag,
        progress: (Double) -> Void
    ) throws {
        let service = try session.startService("com.apple.afc")
        defer { _ = library.lockdownServiceDescriptorFree(service) }

        var afc: LibIMobileDevice.Handle?
        let afcError = library.afcClientNew(session.device, service, &afc)
        guard afcError == 0, let afc else {
            throw InstallerError("Couldn't open a file connection to the device (AFC error \(afcError)).")
        }
        defer { _ = library.afcClientFree(afc) }

        _ = library.afcMakeDirectory(afc, Self.stagingDirectory)
        _ = library.afcRemovePath(afc, remotePath)

        var remoteFile: UInt64 = 0
        let openError = library.afcFileOpen(afc, remotePath, LibIMobileDevice.afcWriteOnly, &remoteFile)
        guard openError == 0 else {
            throw InstallerError("Couldn't create \(remotePath) on the device (AFC error \(openError)).")
        }
        defer { _ = library.afcFileClose(afc, remoteFile) }

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        let total = max(Double((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1), 1)
        var sent = 0.0

        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            if cancellation.isCancelled {
                throw CancellationError()
            }
            try chunk.withUnsafeBytes { buffer in
                let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                var offset = 0
                while offset < buffer.count {
                    var written: UInt32 = 0
                    let error = library.afcFileWrite(afc, remoteFile, base + offset, UInt32(buffer.count - offset), &written)
                    guard error == 0, written > 0 else {
                        throw InstallerError("Upload failed (AFC error \(error)). Is the device still connected?")
                    }
                    offset += Int(written)
                }
            }
            sent += Double(chunk.count)
            progress(sent / total)
        }
    }
}

// MARK: - Connection

/// An idevice plus a paired lockdownd client.
private nonisolated final class Session {
    let library: LibIMobileDevice
    let device: LibIMobileDevice.Handle
    let lockdown: LibIMobileDevice.Handle

    init(library: LibIMobileDevice, udid: String, network: Bool) throws {
        self.library = library

        var device: LibIMobileDevice.Handle?
        let options = network
            ? LibIMobileDevice.lookupNetwork | LibIMobileDevice.lookupPreferNetwork
            : LibIMobileDevice.lookupUSB
        guard library.deviceNew(&device, udid, options) == 0, let device else {
            throw InstallerError("The device isn't reachable. Connect it with a cable and unlock it.")
        }

        var lockdown: LibIMobileDevice.Handle?
        let error = library.lockdownClientNew(device, &lockdown, "Sideloader")
        guard error == 0, let lockdown else {
            _ = library.deviceFree(device)
            throw InstallerError(Self.lockdownMessage(error, library: library))
        }

        self.device = device
        self.lockdown = lockdown
    }

    func close() {
        _ = library.lockdownClientFree(lockdown)
        _ = library.deviceFree(device)
    }

    func startService(_ identifier: String) throws -> LibIMobileDevice.Handle {
        var service: LibIMobileDevice.Handle?
        let error = library.lockdownStartService(lockdown, identifier, &service)
        guard error == 0, let service else {
            throw InstallerError("Couldn't start \(identifier): \(Self.lockdownMessage(error, library: library))")
        }
        return service
    }

    func stringValue(domain: String? = nil, key: String) -> String? {
        var node: LibIMobileDevice.Handle?
        guard library.lockdownGetValue(lockdown, domain, key, &node) == 0, let node else { return nil }
        defer { library.plistFree(node) }
        var value: LibIMobileDevice.CString?
        library.plistGetStringValue(node, &value)
        return library.takeString(value)
    }

    func boolValue(domain: String? = nil, key: String) -> Bool? {
        var node: LibIMobileDevice.Handle?
        guard library.lockdownGetValue(lockdown, domain, key, &node) == 0, let node else { return nil }
        defer { library.plistFree(node) }
        var value: UInt8 = 0
        library.plistGetBoolValue(node, &value)
        return value != 0
    }

    private static func lockdownMessage(_ code: Int32, library: LibIMobileDevice) -> String {
        switch code {
        case -17: "The device is locked. Unlock it and try again."
        case -18: "The device declined to trust this Mac."
        case -19: "Tap Trust on the device, then try again."
        case -21, -4, -5: "This Mac isn't paired with the device. Connect it with a cable and tap Trust."
        default: library.lockdownMessage(code)
        }
    }
}

// MARK: - Install status

/// Receives installation_proxy status callbacks on libimobiledevice's thread.
private nonisolated final class InstallOperation: @unchecked Sendable {
    private let library: LibIMobileDevice
    private let onStatus: (Int32) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, InstallerError>?

    init(library: LibIMobileDevice, onStatus: @escaping (Int32) -> Void) {
        self.library = library
        self.onStatus = onStatus
    }

    func handle(_ status: LibIMobileDevice.Handle?) {
        var name: LibIMobileDevice.CString?
        var description: LibIMobileDevice.CString?
        var code: UInt64 = 0
        if library.instproxyStatusGetError(status, &name, &description, &code) != 0 {
            let name = library.takeString(name) ?? "InstallFailed"
            let description = library.takeString(description)
            finish(.failure(InstallerError([name, description].compactMap { $0 }.joined(separator: ": "))))
            return
        }

        var statusName: LibIMobileDevice.CString?
        library.instproxyStatusGetName(status, &statusName)
        let step = library.takeString(statusName) ?? ""
        if step == "Complete" {
            finish(.success(()))
            return
        }

        var percent: Int32 = -1
        library.instproxyStatusGetPercentComplete(status, &percent)
        if percent >= 0 {
            onStatus(percent)
        }
    }

    /// Returns nil on timeout or cancellation.
    func wait(timeout: DispatchTime, cancellation: CancellationFlag) -> Result<Void, InstallerError>? {
        while DispatchTime.now() < timeout {
            if done.wait(timeout: .now() + 0.25) == .success {
                return lock.withLock { result }
            }
            if cancellation.isCancelled {
                return nil
            }
        }
        return nil
    }

    private func finish(_ result: Result<Void, InstallerError>) {
        let first = lock.withLock {
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
        if first {
            done.signal()
        }
    }

    /// "InstallingEmbeddedProfile" → "Installing embedded profile"
}

nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
