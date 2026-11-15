//
//  LibIMobileDevice.swift
//  Sideloader
//

import Foundation

/// Describes the libimobiledevice copy bundled in Contents/Frameworks.
/// Written by Scripts/update-libimobiledevice.sh.
nonisolated struct LibraryManifest: Decodable, Sendable {
    let updated: String
    let libimobiledeviceFile: String
    let libplistFile: String
    let minimumMacOS: String
    let architectures: String
    let versions: [String: String]

    /// libimobiledevice's upstream version, without Homebrew's `_N` revision suffix.
    var libimobiledeviceVersion: String? {
        versions["libimobiledevice"].map { String($0.split(separator: "_")[0]) }
    }

    static func bundled() -> LibraryManifest? {
        guard let url = Bundle.main.url(forResource: "libimobiledevice", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(LibraryManifest.self, from: data)
    }
}

/// The handful of libimobiledevice and libplist functions Sideloader uses, loaded with dlopen
/// so the app still launches (with devicectl only) when the libraries are missing or unusable.
nonisolated final class LibIMobileDevice: @unchecked Sendable {
    typealias Handle = UnsafeMutableRawPointer
    typealias CString = UnsafeMutablePointer<CChar>
    typealias StatusCallback = @convention(c) (Handle?, Handle?, Handle?) -> Void

    /// Whether the libraries came from Homebrew rather than the copy in Contents/Frameworks.
    let usesHomebrew: Bool
    let runtimeVersion: String?

    let getDeviceListExtended: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<Handle?>?>, UnsafeMutablePointer<Int32>) -> Int32
    let deviceListExtendedFree: @convention(c) (UnsafeMutablePointer<Handle?>?) -> Int32
    let deviceNew: @convention(c) (UnsafeMutablePointer<Handle?>, UnsafePointer<CChar>, Int32) -> Int32
    let deviceFree: @convention(c) (Handle?) -> Int32

    let lockdownClientNew: @convention(c) (Handle?, UnsafeMutablePointer<Handle?>, UnsafePointer<CChar>) -> Int32
    let lockdownClientFree: @convention(c) (Handle?) -> Int32
    let lockdownGetValue: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<Handle?>) -> Int32
    let lockdownStartService: @convention(c) (Handle?, UnsafePointer<CChar>, UnsafeMutablePointer<Handle?>) -> Int32
    let lockdownServiceDescriptorFree: @convention(c) (Handle?) -> Int32
    let lockdownStrerror: @convention(c) (Int32) -> UnsafePointer<CChar>?

    let afcClientNew: @convention(c) (Handle?, Handle?, UnsafeMutablePointer<Handle?>) -> Int32
    let afcClientFree: @convention(c) (Handle?) -> Int32
    let afcMakeDirectory: @convention(c) (Handle?, UnsafePointer<CChar>) -> Int32
    let afcRemovePath: @convention(c) (Handle?, UnsafePointer<CChar>) -> Int32
    let afcFileOpen: @convention(c) (Handle?, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UInt64>) -> Int32
    let afcFileWrite: @convention(c) (Handle?, UInt64, UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    let afcFileClose: @convention(c) (Handle?, UInt64) -> Int32

    let instproxyClientNew: @convention(c) (Handle?, Handle?, UnsafeMutablePointer<Handle?>) -> Int32
    let instproxyClientFree: @convention(c) (Handle?) -> Int32
    let instproxyInstall: @convention(c) (Handle?, UnsafePointer<CChar>, Handle?, StatusCallback?, Handle?) -> Int32
    let instproxyStatusGetError: @convention(c) (Handle?, UnsafeMutablePointer<CString?>, UnsafeMutablePointer<CString?>, UnsafeMutablePointer<UInt64>) -> Int32
    let instproxyStatusGetName: @convention(c) (Handle?, UnsafeMutablePointer<CString?>) -> Void
    let instproxyStatusGetPercentComplete: @convention(c) (Handle?, UnsafeMutablePointer<Int32>) -> Void

    let plistNewDict: @convention(c) () -> Handle?
    let plistNewString: @convention(c) (UnsafePointer<CChar>) -> Handle?
    let plistDictSetItem: @convention(c) (Handle?, UnsafePointer<CChar>, Handle?) -> Int32
    let plistGetStringValue: @convention(c) (Handle?, UnsafeMutablePointer<CString?>) -> Void
    let plistGetBoolValue: @convention(c) (Handle?, UnsafeMutablePointer<UInt8>) -> Void
    let plistFree: @convention(c) (Handle?) -> Void
    let plistMemFree: @convention(c) (Handle?) -> Void

    // libimobiledevice constants used below.
    static let lookupUSB: Int32 = 1 << 1
    static let lookupNetwork: Int32 = 1 << 2
    static let lookupPreferNetwork: Int32 = 1 << 3
    static let connectionNetwork: Int32 = 2
    static let deviceErrorNoDevice: Int32 = -3
    static let afcWriteOnly: Int32 = 3

    /// Loads the libraries once; the result is cached for the app's lifetime.
    static let shared: Result<LibIMobileDevice, InstallerError> = load()

    private static func load() -> Result<LibIMobileDevice, InstallerError> {
        // Homebrew's copy wins when it's installed, so `brew upgrade` is all an update takes.
        // Macs without Homebrew fall back to the copy bundled in Contents/Frameworks.
        if let prefix = Homebrew.prefix,
           case .success(let library) = open(
               imd: "\(prefix)/opt/libimobiledevice/lib/libimobiledevice-1.0.dylib",
               plist: "\(prefix)/opt/libplist/lib/libplist-2.0.dylib",
               usesHomebrew: true) {
            return .success(library)
        }

        guard let manifest = LibraryManifest.bundled(),
              let frameworks = Bundle.main.privateFrameworksURL
        else {
            return .failure(InstallerError(
                "libimobiledevice isn't installed with Homebrew or bundled with this build."))
        }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let required = manifest.minimumMacOS.split(separator: ".").compactMap { Int($0) }
        if let major = required.first,
           (os.majorVersion, os.minorVersion) < (major, required.count > 1 ? required[1] : 0) {
            return .failure(InstallerError(
                "The bundled libimobiledevice needs macOS \(manifest.minimumMacOS) or later."))
        }

        return open(
            imd: frameworks.appending(path: manifest.libimobiledeviceFile).path,
            plist: frameworks.appending(path: manifest.libplistFile).path,
            usesHomebrew: false)
    }

    private static func open(imd: String, plist: String, usesHomebrew: Bool) -> Result<LibIMobileDevice, InstallerError> {
        func open(_ path: String) -> Result<UnsafeMutableRawPointer, InstallerError> {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return .success(handle)
            }
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            return .failure(InstallerError("Couldn't load \(URL(filePath: path).lastPathComponent): \(reason)"))
        }

        return open(imd).flatMap { imd in
            open(plist).flatMap { plist in
                do {
                    return .success(try LibIMobileDevice(usesHomebrew: usesHomebrew, imd: imd, plist: plist))
                } catch let error as InstallerError {
                    return .failure(error)
                } catch {
                    return .failure(InstallerError(error.localizedDescription))
                }
            }
        }
    }

    private init(usesHomebrew: Bool, imd: UnsafeMutableRawPointer, plist: UnsafeMutableRawPointer) throws {
        func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw InstallerError("libimobiledevice is missing \(name). Update it in Settings.")
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        self.usesHomebrew = usesHomebrew

        getDeviceListExtended = try symbol(imd, "idevice_get_device_list_extended")
        deviceListExtendedFree = try symbol(imd, "idevice_device_list_extended_free")
        deviceNew = try symbol(imd, "idevice_new_with_options")
        deviceFree = try symbol(imd, "idevice_free")

        lockdownClientNew = try symbol(imd, "lockdownd_client_new_with_handshake")
        lockdownClientFree = try symbol(imd, "lockdownd_client_free")
        lockdownGetValue = try symbol(imd, "lockdownd_get_value")
        lockdownStartService = try symbol(imd, "lockdownd_start_service")
        lockdownServiceDescriptorFree = try symbol(imd, "lockdownd_service_descriptor_free")
        lockdownStrerror = try symbol(imd, "lockdownd_strerror")

        afcClientNew = try symbol(imd, "afc_client_new")
        afcClientFree = try symbol(imd, "afc_client_free")
        afcMakeDirectory = try symbol(imd, "afc_make_directory")
        afcRemovePath = try symbol(imd, "afc_remove_path")
        afcFileOpen = try symbol(imd, "afc_file_open")
        afcFileWrite = try symbol(imd, "afc_file_write")
        afcFileClose = try symbol(imd, "afc_file_close")

        instproxyClientNew = try symbol(imd, "instproxy_client_new")
        instproxyClientFree = try symbol(imd, "instproxy_client_free")
        instproxyInstall = try symbol(imd, "instproxy_install")
        instproxyStatusGetError = try symbol(imd, "instproxy_status_get_error")
        instproxyStatusGetName = try symbol(imd, "instproxy_status_get_name")
        instproxyStatusGetPercentComplete = try symbol(imd, "instproxy_status_get_percent_complete")

        plistNewDict = try symbol(plist, "plist_new_dict")
        plistNewString = try symbol(plist, "plist_new_string")
        plistDictSetItem = try symbol(plist, "plist_dict_set_item")
        plistGetStringValue = try symbol(plist, "plist_get_string_val")
        plistGetBoolValue = try symbol(plist, "plist_get_bool_val")
        plistFree = try symbol(plist, "plist_free")
        plistMemFree = try symbol(plist, "plist_mem_free")

        let version: (@convention(c) () -> UnsafePointer<CChar>?)? = try? symbol(imd, "libimobiledevice_version")
        runtimeVersion = version?().map { String(cString: $0) }
    }

    /// Copies a C string returned by libplist/libimobiledevice and frees the original.
    func takeString(_ pointer: CString?) -> String? {
        guard let pointer else { return nil }
        defer { plistMemFree(pointer) }
        return String(cString: pointer)
    }

    func lockdownMessage(_ code: Int32) -> String {
        lockdownStrerror(code).map { String(cString: $0) } ?? "lockdownd error \(code)"
    }
}
