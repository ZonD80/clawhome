import AppKit
import Carbon.HIToolbox.Events
import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import IOSurface
import Metal
import Virtualization

/// Virtual display resolution. 1920×1200 (16:10) regardless of VM console window size.
private let virtualDisplayWidth: Double = 1920
private let virtualDisplayHeight: Double = 1200

/// Display pixel density (PPI). ~92 matches a typical 24" Full HD monitor. Higher = smaller UI elements.
private let virtualDisplayPixelsPerInch: Int = 92

private func createDockIcon(for displayName: String) -> NSImage {
    let size = NSSize(width: 512, height: 512)
    let image = NSImage(size: size)
    image.lockFocus()
    let label = displayName.isEmpty ? "?" : String(displayName.prefix(1)).uppercased()
    let hash = displayName.utf8.reduce(0) { $0 &+ Int($1) }
    let hue = (hash & 0xFFFF) % 360
    let color = NSColor(hue: CGFloat(hue) / 360, saturation: 0.6, brightness: 0.8, alpha: 1)
    color.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let font = NSFont.systemFont(ofSize: 220, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let strSize = (label as NSString).size(withAttributes: attrs)
    let pt = NSPoint(
        x: (size.width - strSize.width) / 2,
        y: (size.height - strSize.height) / 2 - 20
    )
    (label as NSString).draw(at: pt, withAttributes: attrs)
    image.unlockFocus()
    return image
}

public enum ClawVMConstants {
    /// Base dir: ~/clawhome/homes. Each subdir = one VM. Folder name = VM id.
    static var vmsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("clawhome")
            .appendingPathComponent("homes")
    }
    static let diskSizeGb: UInt64 = 20
    static let macDiskSizeGb: UInt64 = 32
    /// Shared clipboard directory: ~/clawhome/Shared/clipboard (automounts in guest at /Volumes/My Shared Files)
    static var clipboardSharedDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("clawhome")
            .appendingPathComponent("Shared")
            .appendingPathComponent("clipboard")
    }
    /// IPSW cache: ~/clawhome/IPSWCache (reused across VMs when filename matches)
    static var ipswCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("clawhome")
            .appendingPathComponent("IPSWCache")
    }
    static let vmRamMb: UInt64 = 4096
    /// Use all available host CPU cores.
    static var vmCpus: Int { max(2, ProcessInfo.processInfo.processorCount) }
}

public struct VMConfig: Codable {
    let id: String
    var name: String
    var ramMb: Int
    var diskGb: Int
    var guestType: String?  // "linux" | "macos", default linux
    var isoPath: String?
    var ipswPath: String?
    var macAddress: String?  // Persistent MAC for NAT-DHCP (same MAC -> same IP across restarts)
}

@MainActor
public class ClawVMManager {
    public static let shared = ClawVMManager()
    /// Set when user confirms closing VM window. Self-closure timer checks this and exits when VM has stopped.
    public var isAboutToClose = false
    var runningVM:
        (
            id: String, vm: VZVirtualMachine, view: VZVirtualMachineView, automator: VZAutomator,
            delegate: VMDelegate, windowDelegate: VMWindowDelegate, serialHandle: FileHandle?,
            clipboardSync: ClipboardSync?
        )?
    /// True when a VM is running (Runner mode). Used by Runner for self-closure check.
    public var hasRunningVM: Bool { runningVM != nil }
    /// Display name of the running VM, or nil if none. Used for dock menu.
    public var displayNameForRunningVM: String? { runningVM.map { displayName(for: $0.id) } }
    var installingMacOS:
        [String: (progress: Progress, window: NSWindow, windowDelegate: InstallerWindowDelegate)] =
            [:]
    var macOSCreatingProgress: [String: (phase: String, fractionCompleted: Double)] = [:]
    /// Stored error when install fails (e.g. IPSW fetch/download). Cleared when client reads or VM deleted.
    var macOSInstallError: [String: String] = [:]
    public func installProgress(id: String) -> (
        fractionCompleted: Double, phase: String, error: String?
    )? {
        if let err = macOSInstallError[id] {
            return (0, "failed", err)
        }
        if let entry = macOSCreatingProgress[id] {
            return (entry.fractionCompleted, entry.phase, nil)
        }
        guard let entry = installingMacOS[id] else { return nil }
        let name = displayName(for: id)
        let phase = entry.progress.localizedDescription ?? "Setting up \(name)'s home"
        let friendlyPhase =
            phase.lowercased().contains("install") ? "Setting up \(name)'s home" : phase
        return (entry.progress.fractionCompleted, friendlyPhase, nil)
    }

    private init() {}

    /// Cancels an in-progress macOS installation (e.g. when user closes the Preparing window).
    public func cancelInstall(id: String) {
        guard let entry = installingMacOS[id] else { return }
        entry.progress.cancel()
        entry.window.orderOut(nil)
        installingMacOS.removeValue(forKey: id)
        macOSInstallError[id] = "Installation cancelled"
        macOSCreatingProgress.removeValue(forKey: id)
    }

    /// Paste host clipboard into guest. Call from dock menu "Paste to [name]'s home".
    public func pasteIntoGuest() {
        guard let rv = runningVM else { return }
        let str = NSPasteboard.general.string(forType: .string) ?? ""
        guard !str.isEmpty else { return }
        Task { @MainActor in
            try? await typeText(id: rv.id, text: str)
        }
    }

    /// Returns a persistent MAC address for the VM. Reads from config if present; otherwise generates one and saves it.
    /// Same MAC across restarts -> NAT DHCP typically assigns the same IP.
    private func getOrCreateMacAddress(vmDir: URL) throws -> VZMACAddress {
        let configPath = vmDir.appendingPathComponent("config.json")
        var vmConfig: VMConfig?
        if let data = try? Data(contentsOf: configPath),
            let c = try? JSONDecoder().decode(VMConfig.self, from: data)
        {
            vmConfig = c
            if let macStr = c.macAddress, let addr = VZMACAddress(string: macStr) {
                return addr
            }
        }
        let mac = VZMACAddress.randomLocallyAdministered()
        let macString = mac.string
        guard var c = vmConfig else {
            return mac  // No config yet, use random but can't persist
        }
        c.macAddress = macString
        try? JSONEncoder().encode(c).write(to: configPath)
        print("[ClawVM]   network: NAT with persistent MAC \(macString)")
        return mac
    }

    /// Returns display name (claw's name) for a VM by id. Reads from config.json.
    public func displayName(for vmId: String) -> String {
        let configPath = ClawVMConstants.vmsDir.appendingPathComponent(vmId).appendingPathComponent(
            "config.json")
        guard let data = try? Data(contentsOf: configPath),
            let config = try? JSONDecoder().decode(VMConfig.self, from: data)
        else { return vmId }
        return config.name
    }

    /// Returns guestType for a VM by id. Reads from config.json.
    func guestType(forVMId id: String) -> String {
        let vmDir = ClawVMConstants.vmsDir.appendingPathComponent(id)
        let configPath = vmDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configPath),
            let config = try? JSONDecoder().decode(VMConfig.self, from: data)
        else { return "linux" }
        return config.guestType ?? "linux"
    }

    /// When runningIds is non-nil (Manager mode), use it for running status. Otherwise use runningVM (Runner mode).
    public func listVMs(runningIds: Set<String>? = nil) -> [[String: Any]] {
        var result: [[String: Any]] = []
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: ClawVMConstants.vmsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return result }

        let isRunning: (String) -> Bool
        if let ids = runningIds {
            isRunning = { ids.contains($0) }
        } else {
            isRunning = { [weak self] id in self?.runningVM?.id == id }
        }

        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let id = url.lastPathComponent
            guard id != "ISOs" else { continue }
            let configPath = url.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else { continue }
            var ramMb = 2048
            var diskGb = 20
            var displayName = id
            var guestType = "macos"
            if let data = try? Data(contentsOf: configPath),
                let config = try? JSONDecoder().decode(VMConfig.self, from: data)
            {
                ramMb = config.ramMb
                diskGb = config.diskGb
                displayName = config.name
                guestType = config.guestType ?? "linux"
            }

            var status = isRunning(id) ? "running" : "stopped"
            if installingMacOS[id] != nil || macOSCreatingProgress[id] != nil {
                status = "installing"
            }
            result.append([
                "id": id,
                "name": displayName,
                "path": url.path,
                "status": status,
                "ramMb": ramMb,
                "diskGb": diskGb,
                "guestType": guestType,
            ])
        }

        return result.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }

    private func createClipboardShareConfig() -> VZVirtioFileSystemDeviceConfiguration {
        let clipboardDir = ClawVMConstants.clipboardSharedDir
        try? FileManager.default.createDirectory(
            at: clipboardDir, withIntermediateDirectories: true)
        let downloadsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Downloads")
        try? FileManager.default.createDirectory(
            at: downloadsDir, withIntermediateDirectories: true)
        let directories: [String: VZSharedDirectory] = [
            "clipboard": VZSharedDirectory(url: clipboardDir, readOnly: false),
            "Downloads": VZSharedDirectory(url: downloadsDir, readOnly: false),
        ]
        let share = VZMultipleDirectoryShare(directories: directories)
        let config = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        config.share = share
        return config
    }

    /// Sanitize name for use as folder: alphanumeric, dash, underscore only.
    private func sanitizeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return
            name
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public func createVM(
        name: String, ramMb: Int? = nil, diskGb: Int? = nil, ipswPath: String? = nil
    ) throws -> [String: Any] {
        try FileManager.default.createDirectory(
            at: ClawVMConstants.vmsDir, withIntermediateDirectories: true)
        let id = sanitizeName(name)
        guard !id.isEmpty else {
            throw NSError(
                domain: "ClawVM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid name"])
        }
        let vmDir = ClawVMConstants.vmsDir.appendingPathComponent(id)

        guard !FileManager.default.fileExists(atPath: vmDir.path) else {
            throw NSError(
                domain: "ClawVM", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "VM already exists"])
        }

        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let dataDir = vmDir.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let effectiveRamMb = ramMb ?? 4096
        let effectiveDiskGb = diskGb ?? 32

        let config = VMConfig(
            id: id, name: name, ramMb: effectiveRamMb, diskGb: effectiveDiskGb,
            guestType: "macos", isoPath: nil, ipswPath: ipswPath, macAddress: nil)
        let configData = try JSONEncoder().encode(config)
        try configData.write(to: vmDir.appendingPathComponent("config.json"))
        Task { await createMacOSVMAndInstall(id: id, vmDir: vmDir, ipswPath: ipswPath) }
        return [
            "id": id, "name": name, "path": vmDir.path, "status": "installing",
            "ramMb": effectiveRamMb, "diskGb": effectiveDiskGb, "guestType": "macos",
        ]
    }

    /// Check if an IPSW file is supported on this host (mostFeaturefulSupportedConfiguration != nil).
    func checkIpswSupported(path: String) async -> Bool {
        guard let resolved = resolveIpswPath(path) else { return false }
        let url = URL(fileURLWithPath: resolved)
        do {
            let img = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<VZMacOSRestoreImage, Error>) in
                VZMacOSRestoreImage.load(from: url) { result in
                    switch result {
                    case .success(let img): cont.resume(returning: img)
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
            return img.mostFeaturefulSupportedConfiguration != nil
        } catch {
            return false
        }
    }

    /// Resolves user-provided IPSW path: expands ~, strips file://, standardizes.
    private func resolveIpswPath(_ path: String?) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        var resolved = p.trimmingCharacters(in: .whitespaces)
        if resolved.hasPrefix("file://") {
            if let url = URL(string: resolved) {
                resolved = url.path
            }
        }
        resolved = (resolved as NSString).expandingTildeInPath
        resolved = (resolved as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: resolved) else { return nil }
        return resolved
    }

    func createMacOSVMAndInstall(id: String, vmDir: URL, ipswPath: String? = nil) async {
        let dataDir = vmDir.appendingPathComponent("Data")
        let diskPath = dataDir.appendingPathComponent("disk.img")
        let auxPath = dataDir.appendingPathComponent("auxiliary_storage")
        let configPath = vmDir.appendingPathComponent("config.json")

        print("[ClawVM] createMacOSVMAndInstall \(id) ipswPath=\(ipswPath ?? "nil")")
        fflush(stdout)

        do {
            let name = displayName(for: id)
            macOSCreatingProgress[id] = ("Preparing \(name)'s home", 0)

            var restoreImage: VZMacOSRestoreImage?
            var ipswURL: URL?

            if let path = resolveIpswPath(ipswPath) {
                let url = URL(fileURLWithPath: path)
                do {
                    let img = try await withCheckedThrowingContinuation {
                        (cont: CheckedContinuation<VZMacOSRestoreImage, Error>) in
                        VZMacOSRestoreImage.load(from: url) { result in
                            switch result {
                            case .success(let img): cont.resume(returning: img)
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                    }
                    if img.mostFeaturefulSupportedConfiguration != nil {
                        restoreImage = img
                        ipswURL = url
                        print("[ClawVM]   using selected ipsw: \(path)")
                    } else {
                        print(
                            "[ClawVM]   selected ipsw has no supported config for this host (try a different IPSW or let it auto-download): \(path)"
                        )
                    }
                } catch {
                    print(
                        "[ClawVM]   failed to load selected ipsw \(path): \(error.localizedDescription)"
                    )
                }
            } else if let p = ipswPath, !p.isEmpty {
                print("[ClawVM]   ipsw path not found or invalid: \(p)")
            }

            if restoreImage == nil {
                macOSCreatingProgress[id] = ("Getting \(name)'s home ready", 0)
                let fetched = try await withCheckedThrowingContinuation { cont in
                    VZMacOSRestoreImage.fetchLatestSupported { result in
                        switch result {
                        case .success(let img): cont.resume(returning: img)
                        case .failure(let err): cont.resume(throwing: err)
                        }
                    }
                }
                restoreImage = fetched
                let fetchedURL = fetched.url

                if fetchedURL.isFileURL {
                    print("[ClawVM]   using local ipsw: \(fetchedURL.path)")
                    ipswURL = fetchedURL
                } else {
                    let ipswFilename =
                        fetchedURL.lastPathComponent.components(separatedBy: "?").first
                        ?? fetchedURL.lastPathComponent
                    let cacheDir = ClawVMConstants.ipswCacheDir
                    try FileManager.default.createDirectory(
                        at: cacheDir, withIntermediateDirectories: true)
                    let cachedIpswPath = cacheDir.appendingPathComponent(ipswFilename)
                    if FileManager.default.fileExists(atPath: cachedIpswPath.path) {
                        print("[ClawVM]   using cached ipsw: \(cachedIpswPath.path)")
                        ipswURL = cachedIpswPath
                    } else {
                        print("[ClawVM]   downloading ipsw...")
                        macOSCreatingProgress[id] = ("Downloading \(name)'s home", 0)
                        _ = try await downloadWithProgress(
                            from: fetchedURL, vmId: id, to: cachedIpswPath)
                        ipswURL = cachedIpswPath
                        print("[ClawVM]   download complete")
                    }
                }
            }

            guard let img = restoreImage, let ipswURLToUse = ipswURL else {
                print("[ClawVM]   no restore image available")
                macOSCreatingProgress.removeValue(forKey: id)
                return
            }

            macOSCreatingProgress.removeValue(forKey: id)

            guard let configToUse = img.mostFeaturefulSupportedConfiguration else {
                print("[ClawVM]   no supported config for this host")
                return
            }

            let machineIdentifier = VZMacMachineIdentifier()
            let hardwareModel = configToUse.hardwareModel

            var diskGb: UInt64 = ClawVMConstants.macDiskSizeGb
            if let data = try? Data(contentsOf: configPath),
                let c = try? JSONDecoder().decode(VMConfig.self, from: data)
            {
                diskGb = UInt64(max(8, min(512, c.diskGb)))
            }
            let diskSizeBytes = diskGb * 1024 * 1024 * 1024
            FileManager.default.createFile(atPath: diskPath.path, contents: nil)
            let handle = try FileHandle(forWritingTo: diskPath)
            try handle.truncate(atOffset: diskSizeBytes)
            try handle.close()

            let auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxPath, hardwareModel: hardwareModel, options: .allowOverwrite)

            let config = VZVirtualMachineConfiguration()
            config.bootLoader = VZMacOSBootLoader()
            config.platform = {
                let p = VZMacPlatformConfiguration()
                p.hardwareModel = hardwareModel
                p.machineIdentifier = machineIdentifier
                p.auxiliaryStorage = auxiliaryStorage
                return p
            }()
            config.cpuCount = max(configToUse.minimumSupportedCPUCount, ProcessInfo.processInfo.processorCount)
            var memBytes = max(4 * 1024 * 1024 * 1024, configToUse.minimumSupportedMemorySize)
            if let data = try? Data(contentsOf: configPath),
                let c = try? JSONDecoder().decode(VMConfig.self, from: data)
            {
                let userRamBytes = UInt64(max(4096, min(65536, c.ramMb))) * 1024 * 1024
                memBytes = max(memBytes, userRamBytes)
            }
            config.memorySize = memBytes

            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: diskPath, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

            let networkAttachment = VZNATNetworkDeviceAttachment()
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            networkDevice.attachment = networkAttachment
            networkDevice.macAddress = try getOrCreateMacAddress(vmDir: vmDir)
            config.networkDevices = [networkDevice]

            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: Int(virtualDisplayWidth),
                    heightInPixels: Int(virtualDisplayHeight),
                    pixelsPerInch: virtualDisplayPixelsPerInch)
            ]
            config.graphicsDevices = [graphics]

            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

            // No directory sharing during installer — installer env may not support virtio-fs.
            // Sharing is added in createMacOSVM when starting an installed VM.

            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURLToUse)

            let view = VZVirtualMachineView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            if #available(macOS 14.0, *) {
                view.automaticallyReconfiguresDisplay = false  // Lock to 1920×1200 @ 92 PPI (normal DPI)
            }

            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: virtualDisplayWidth, height: virtualDisplayHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(name)'s home — Preparing"
            let installerDelegate = InstallerWindowDelegate(vmId: id)
            window.delegate = installerDelegate
            window.contentView?.addSubview(view)
            view.frame = window.contentView?.bounds ?? .zero
            view.autoresizingMask = [.width, .height]
            window.center()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            installingMacOS[id] = (installer.progress, window, installerDelegate)

            try hardwareModel.dataRepresentation.write(
                to: dataDir.appendingPathComponent("HardwareModel"))
            try machineIdentifier.dataRepresentation.write(
                to: dataDir.appendingPathComponent("MachineIdentifier"))

            var vmConfig = VMConfig(
                id: id, name: "\(id)", ramMb: 4096, diskGb: 128, guestType: "macos",
                isoPath: nil, ipswPath: ipswURLToUse.path, macAddress: nil)
            if let data = try? Data(contentsOf: configPath),
                let c = try? JSONDecoder().decode(VMConfig.self, from: data)
            {
                vmConfig = c
            }
            vmConfig.ipswPath = ipswURLToUse.path
            vmConfig.guestType = "macos"
            try? JSONEncoder().encode(vmConfig).write(to: configPath)

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                installer.install { result in
                    DispatchQueue.main.async {
                        self.installingMacOS.removeValue(forKey: id)
                        switch result {
                        case .success:
                            print("[ClawVM]   macOS installation complete")
                        case .failure(let err):
                            print("[ClawVM]   macOS installation failed: \(err)")
                        }
                        cont.resume()
                    }
                }
            }

            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } catch {
            let errMsg = error.localizedDescription
            print("[ClawVM] createMacOSVMAndInstall failed: \(errMsg)")
            macOSInstallError[id] = errMsg
            if let entry = installingMacOS[id] {
                entry.window.orderOut(nil)
            }
            installingMacOS.removeValue(forKey: id)
            macOSCreatingProgress.removeValue(forKey: id)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func downloadWithProgress(from url: URL, vmId: String, to destination: URL) async throws
        -> URL
    {
        final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
            var continuation: CheckedContinuation<URL, Error>?
            let destination: URL
            init(destination: URL) { self.destination = destination }
            func urlSession(
                _ session: URLSession, downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation?.resume(returning: destination)
                } catch {
                    continuation?.resume(throwing: error)
                }
                continuation = nil
            }
            func urlSession(
                _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
            ) {
                if let err = error, continuation != nil {
                    continuation?.resume(throwing: err)
                    continuation = nil
                }
            }
        }
        let delegate = DownloadDelegate(destination: destination)
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        let progress = task.progress
        let obs = progress.observe(\.fractionCompleted, options: [.initial, .new]) {
            [weak self] prog, _ in
            Task { @MainActor in
                let name = ClawVMManager.shared.displayName(for: vmId)
                self?.macOSCreatingProgress[vmId] = (
                    "Downloading \(name)'s home", prog.fractionCompleted
                )
            }
        }
        defer { obs.invalidate() }
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<URL, Error>) in
            delegate.continuation = cont
            task.resume()
        }
    }

    func createMacOSVM(at vmDir: URL) throws -> (VZVirtualMachine, FileHandle?) {
        let dataDir = vmDir.appendingPathComponent("Data")
        let diskPath = dataDir.appendingPathComponent("disk.img")
        let auxPath = dataDir.appendingPathComponent("auxiliary_storage")
        let hwPath = dataDir.appendingPathComponent("HardwareModel")
        let midPath = dataDir.appendingPathComponent("MachineIdentifier")

        guard FileManager.default.fileExists(atPath: diskPath.path),
            FileManager.default.fileExists(atPath: auxPath.path)
        else {
            throw NSError(
                domain: "ClawVM", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "macOS VM not installed - run installation first"
                ])
        }

        guard let hwData = try? Data(contentsOf: hwPath),
            let midData = try? Data(contentsOf: midPath),
            let hardwareModel = VZMacHardwareModel(dataRepresentation: hwData),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: midData)
        else {
            throw NSError(
                domain: "ClawVM", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "macOS VM config missing - reinstall required"
                ])
        }

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = VZMacOSBootLoader()
        config.platform = {
            let p = VZMacPlatformConfiguration()
            p.hardwareModel = hardwareModel
            p.machineIdentifier = machineIdentifier
            p.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxPath)
            return p
        }()
        var vmRamMb = ClawVMConstants.vmRamMb
        let configPath = vmDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configPath),
            let vmConfig = try? JSONDecoder().decode(VMConfig.self, from: data)
        {
            vmRamMb = UInt64(max(4096, min(65536, vmConfig.ramMb)))
        }
        config.cpuCount = ClawVMConstants.vmCpus
        config.memorySize = vmRamMb * 1024 * 1024

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let networkAttachment = VZNATNetworkDeviceAttachment()
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = networkAttachment
        networkDevice.macAddress = try getOrCreateMacAddress(vmDir: vmDir)
        config.networkDevices = [networkDevice]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: Int(virtualDisplayWidth), heightInPixels: Int(virtualDisplayHeight),
                pixelsPerInch: virtualDisplayPixelsPerInch)
        ]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Shared clipboard directory (host ↔ guest copy/paste)
        config.directorySharingDevices = [createClipboardShareConfig()]

        let serialLogPath = vmDir.appendingPathComponent("serial.log")
        FileManager.default.createFile(atPath: serialLogPath.path, contents: nil)
        var serialHandle: FileHandle?
        if let serialFile = try? FileHandle(forWritingTo: serialLogPath) {
            try? serialFile.truncate(atOffset: 0)
            serialHandle = serialFile
            let serialAttachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil, fileHandleForWriting: serialFile)
            let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
            serialConfig.attachment = serialAttachment
            config.serialPorts = [serialConfig]
            print("[ClawVM]   serial port -> \(serialLogPath.path)")
        }

        try config.validate()
        return (VZVirtualMachine(configuration: config), serialHandle)
    }

    public func startVM(id: String) async throws {
        print("[ClawVM] startVM(\(id))")
        if runningVM?.id == id {
            print("[ClawVM]   already running, skipping")
            return
        }

        let vmDir = ClawVMConstants.vmsDir.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: vmDir.path) else {
            throw NSError(
                domain: "ClawVM", code: 3, userInfo: [NSLocalizedDescriptionKey: "VM not found"])
        }

        let configPath = vmDir.appendingPathComponent("config.json")
        var vmConfig: VMConfig?
        if let data = try? Data(contentsOf: configPath),
            let c = try? JSONDecoder().decode(VMConfig.self, from: data)
        {
            vmConfig = c
        }
        let guestType = vmConfig?.guestType ?? "macos"
        guard guestType == "macos" else {
            throw NSError(
                domain: "ClawVM", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Only macOS VMs supported"])
        }

        print("[ClawVM]   creating macOS VM config...")
        let (vm, serialHandle) = try createMacOSVM(at: vmDir)
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        if #available(macOS 14.0, *) {
            view.automaticallyReconfiguresDisplay = false  // Lock to 1920×1200 @ 92 PPI (normal DPI)
        }

        let automator = VZAutomator(view: view)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: virtualDisplayWidth, height: virtualDisplayHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(displayName(for: id))'s home — Home Access"
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = createDockIcon(for: displayName(for: id))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let windowDelegate = VMWindowDelegate(vmId: id)
        window.delegate = windowDelegate

        let delegate = VMDelegate()
        vm.delegate = delegate

        print("[ClawVM]   starting VM...")
        try await vm.start()
        print("[ClawVM]   VM started, state=\(vm.state.rawValue)")

        reconfigureDisplayToFullHD(vm)

        let clipboardSync = ClipboardSync(sharedDirectory: ClawVMConstants.clipboardSharedDir)
        clipboardSync.start()
        print("[ClawVM]   Clipboard sync enabled (shared at /Volumes/My Shared Files in guest)")

        runningVM = (id, vm, view, automator, delegate, windowDelegate, serialHandle, clipboardSync)
        print(
            "[ClawVM] startVM done. Right-click dock icon → Paste to \(displayName(for: id))'s home. Serial log: \(vmDir.path)/serial.log"
        )
    }

    func showConsole(id: String) {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if let win = view.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: virtualDisplayWidth, height: virtualDisplayHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(displayName(for: id))'s home — Home Access"
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let windowDelegate = runningVM?.windowDelegate {
            window.delegate = windowDelegate
        }
    }

    /// Stop VM with 30s timeout. If guest is frozen, vm.stop() can hang indefinitely; this prevents blocking.
    /// VZVirtualMachine.stop() must be called on the main thread.
    private func stopVMWithTimeout(_ vm: VZVirtualMachine) async throws {
        let stopTimeoutNs: UInt64 = 30_000_000_000
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await vm.stop() }
            group.addTask {
                try await Task.sleep(nanoseconds: stopTimeoutNs)
                throw NSError(
                    domain: "ClawVM", code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "VM stop timed out after 30s (guest may be frozen)"
                    ]
                )
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    public func stopVM(id: String, force: Bool = false) async throws {
        guard runningVM?.id == id else { return }
        guard let vm = runningVM?.vm else { return }
        let window = runningVM?.view.window
        let automator = runningVM?.automator

        let guestType = guestType(forVMId: id)

        if !force && guestType == "macos" {
            // macOS guest does not respond to requestStop (PL061 GPIO); it ignores the signal.
            // Send Control+Option+Command+Power to trigger graceful shutdown from within the guest.
            if let automator = automator {
                print(
                    "[ClawVM] Sending shutdown shortcut (Control+Option+Command+Power) to macOS guest"
                )
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                do {
                    let shutdownKey = VZAutomator.Key.keyboardPower.control.alt.modify(.command)
                    try await automator.press(key: shutdownKey)
                    try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds for shutdown to start
                } catch {
                    print("[ClawVM] Shutdown shortcut failed: \(error), will try requestStop")
                }
            }
        }

        if !force && guestType == "linux", let automator = automator {
            // Linux: try ACPI power button before requestStop. Triggers graceful shutdown via acpid/systemd-logind.
            // Note: Ctrl+Alt+Del triggers reboot, not shutdown — do not use it here.
            print("[ClawVM] Sending ACPI power button to Linux guest for graceful shutdown")
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            do {
                try await automator.press(key: .keyboardPower)
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
            } catch {
                print("[ClawVM] Power button failed: \(error), will try requestStop")
            }
        }

        if !force && vm.canRequestStop {
            do {
                try vm.requestStop()
                let timeoutNs: UInt64 = guestType == "linux" ? 60_000_000_000 : 30_000_000_000
                let interval: UInt64 = 500_000_000  // 0.5 seconds
                var elapsed: UInt64 = 0
                while elapsed < timeoutNs, runningVM?.id == id {
                    try await Task.sleep(nanoseconds: interval)
                    elapsed += interval
                }
                if runningVM?.id == id {
                    print(
                        "[ClawVM] Graceful shutdown timeout (\(timeoutNs / 1_000_000_000)s), forcing stop"
                    )
                    do { try await stopVMWithTimeout(vm) } catch {
                        print("[ClawVM] \(error.localizedDescription)")
                    }
                    runningVM?.clipboardSync?.stop()
                    runningVM = nil
                }
            } catch {
                print("[ClawVM] requestStop failed: \(error), forcing stop")
                do { try await stopVMWithTimeout(vm) } catch {
                    print("[ClawVM] \(error.localizedDescription)")
                }
                runningVM?.clipboardSync?.stop()
                runningVM = nil
            }
        } else {
            do { try await stopVMWithTimeout(vm) } catch {
                print("[ClawVM] \(error.localizedDescription)")
            }
            runningVM?.clipboardSync?.stop()
            runningVM = nil
        }

        // Hide window (orderOut) instead of close - closing triggers segfault in Virtualization teardown
        window?.orderOut(nil as Any?)
    }

    public func deleteVM(id: String) async throws {
        if runningVM?.id == id {
            try await stopVM(id: id)
        }
        macOSInstallError.removeValue(forKey: id)

        let vmDir = ClawVMConstants.vmsDir.appendingPathComponent(id)
        try FileManager.default.removeItem(at: vmDir)
    }

    func screenshot(id: String) async throws -> Data? {
        guard runningVM?.id == id, let view = runningVM?.view else { return nil }
        if view.window == nil {
            showConsole(id: id)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        return captureFromIOSurface(view)
    }

    func typeText(id: String, text: String) async throws {
        guard runningVM?.id == id, let automator = runningVM?.automator else { return }
        try await automator.type(text)
    }

    func pressKey(id: String, key: String) async throws {
        guard runningVM?.id == id, let automator = runningVM?.automator else { return }
        let k = keyFromName(key)
        try await automator.press(key: k)
    }

    /// Reconfigure all graphics displays to virtual resolution. Fixes existing VMs created with other resolutions.
    private func reconfigureDisplayToFullHD(_ vm: VZVirtualMachine) {
        guard #available(macOS 14.0, *) else { return }
        let targetSize = CGSize(width: virtualDisplayWidth, height: virtualDisplayHeight)
        for device in vm.graphicsDevices {
            for display in device.displays {
                let current = display.sizeInPixels
                guard current.width != targetSize.width || current.height != targetSize.height
                else {
                    continue
                }
                do {
                    try display.reconfigure(sizeInPixels: targetSize)
                    print(
                        "[ClawVM]   display reconfigured \(Int(current.width))×\(Int(current.height)) → \(Int(virtualDisplayWidth))×\(Int(virtualDisplayHeight))"
                    )
                } catch {
                    print("[ClawVM]   display reconfigure failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Convert (x,y) from virtual display space (top-down, origin top-left) to view coordinates.
    /// Uses displaySubview's frame when available so letterboxing/pillarboxing is handled correctly.
    /// NSView is bottom-up. Display y=0 (top) maps to content rect top (maxY).
    private func displayToView(view: NSView, x: Double, y: Double) -> NSPoint {
        let dw = virtualDisplayWidth
        let dh = virtualDisplayHeight
        let contentRect: CGRect
        if let sub = view.subviews.first, sub.layer?.contents is IOSurface {
            contentRect = sub.frame
        } else {
            contentRect = view.bounds
        }
        guard contentRect.width > 0, contentRect.height > 0 else {
            return NSPoint(x: x, y: view.bounds.height - y)
        }
        let sx = contentRect.width / dw
        let sy = contentRect.height / dh
        let xView = contentRect.minX + x * sx
        let yView = contentRect.maxY - y * sy
        return NSPoint(x: xView, y: yView)
    }

    func moveMouse(id: String, x: Double, y: Double) async throws {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        let pt = displayToView(view: view, x: x, y: y)
        let locInWindow = view.convert(pt, to: nil)
        if let ev = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: locInWindow,
            modifierFlags: [],
            timestamp: NSDate.now.timeIntervalSince1970,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) {
            view.mouseMoved(with: ev)
        }
    }

    /// Move mouse while left button is held (for drag operations). Sends leftMouseDragged so the view receives mouseDragged(with:).
    func moveMouseDragging(id: String, x: Double, y: Double) async throws {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        let pt = displayToView(view: view, x: x, y: y)
        let locInWindow = view.convert(pt, to: nil)
        if let ev = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: locInWindow,
            modifierFlags: [],
            timestamp: NSDate.now.timeIntervalSince1970,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 1.0
        ) {
            view.mouseDragged(with: ev)
        }
    }

    func click(id: String, x: Double? = nil, y: Double? = nil, doubleClick: Bool = false)
        async throws
    {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        let pt: NSPoint
        if let x = x, let y = y {
            pt = displayToView(view: view, x: x, y: y)
        } else {
            pt = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        let locInWindow = view.convert(pt, to: nil)
        let winNum = win.windowNumber
        let clicks: [(Int, Int)] = doubleClick ? [(1, 1), (2, 2)] : [(1, 1)]
        for (downCount, upCount) in clicks {
            if doubleClick && downCount == 2 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let ts = NSDate.now.timeIntervalSince1970
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: locInWindow,
                modifierFlags: [],
                timestamp: ts,
                windowNumber: winNum,
                context: nil,
                eventNumber: 0,
                clickCount: downCount,
                pressure: 1.0
            ),
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: locInWindow,
                    modifierFlags: [],
                    timestamp: ts,
                    windowNumber: winNum,
                    context: nil,
                    eventNumber: 0,
                    clickCount: upCount,
                    pressure: 0
                )
            {
                view.mouseDown(with: down)
                view.mouseUp(with: up)
            }
        }
    }

    func mouseDown(id: String, x: Double, y: Double) async throws {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        try await moveMouse(id: id, x: x, y: y)
        let pt = displayToView(view: view, x: x, y: y)
        let locInWindow = view.convert(pt, to: nil)
        let ts = NSDate.now.timeIntervalSince1970
        if let ev = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locInWindow,
            modifierFlags: [],
            timestamp: ts,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) {
            view.mouseDown(with: ev)
        }
    }

    func mouseUp(id: String, x: Double, y: Double) async throws {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        let pt = displayToView(view: view, x: x, y: y)
        let locInWindow = view.convert(pt, to: nil)
        let ts = NSDate.now.timeIntervalSince1970
        if let ev = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locInWindow,
            modifierFlags: [],
            timestamp: ts,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) {
            view.mouseUp(with: ev)
        }
    }

    /// Scroll at coordinates. deltaY: positive = up, negative = down. deltaX: positive = left, negative = right.
    /// Uses line units (wheel clicks) for predictable behavior in VMs; pixel units are unreliable.
    func scroll(
        id: String, x: Double? = nil, y: Double? = nil, deltaX: Double = 0, deltaY: Double = 0
    ) async throws {
        guard runningVM?.id == id, let view = runningVM?.view else { return }
        if view.window == nil { showConsole(id: id) }
        guard let win = view.window else { return }
        if let x = x, let y = y {
            try await moveMouse(id: id, x: x, y: y)
        }
        let pt: NSPoint
        if let x = x, let y = y {
            pt = displayToView(view: view, x: x, y: y)
        } else {
            pt = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        let locInWindow = view.convert(pt, to: nil)
        let screenLoc = win.convertPoint(toScreen: locInWindow)
        let linesY = Int32(deltaY)
        let linesX = Int32(deltaX)
        let wheelCount: UInt32 = (linesX != 0 || linesY != 0) ? 2 : 1
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: wheelCount,
                wheel1: linesY,
                wheel2: linesX,
                wheel3: 0
            )
        else { return }
        cgEvent.location = CGPoint(x: screenLoc.x, y: screenLoc.y)
        if let nsEvent = NSEvent(cgEvent: cgEvent) {
            view.scrollWheel(with: nsEvent)
        }
    }

    /// Probe which capture methods succeed; returns method name -> size + center pixel from output
    func screenshotProbe(id: String) async -> [String: Any]? {
        guard runningVM?.id == id, let view = runningVM?.view else { return nil }
        var results: [String: Any] = [:]
        func addResult(_ name: String, _ data: Data?, _ cgImage: CGImage?) {
            guard let data = data else { return }
            var info: [String: Any] = ["size": data.count]
            if let img = cgImage {
                info["width"] = img.width
                info["height"] = img.height
                if let centerPixel = sampleCenterPixel(img) {
                    info["centerPixel"] = centerPixel
                }
            }
            results[name] = info
        }
        if let win = view.window, win.contentView != nil {
            let windowRect = view.convert(view.bounds, to: nil)
            let screenRect = win.convertToScreen(windowRect)
            if let cgImage = CGWindowListCreateImage(
                screenRect,
                .optionIncludingWindow,
                CGWindowID(win.windowNumber),
                .bestResolution
            ) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    addResult("cgwindow", png, cgImage)
                }
            }
            if let (data, cg) = captureViaCIImageWithCGImage(view) {
                addResult("ciimage", data, cg)
            }
            if let (data, cg) = captureFromIOSurfaceWithCGImage(view) {
                addResult("iosurface", data, cg)
            }
            if let (data, cg) = captureViewLayerWithCGImage(view) {
                addResult("layer", data, cg)
            }
        }
        if let automator = runningVM?.automator {
            if let image = try? await automator.screenshot(), let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(
                    using: .png as NSBitmapImageRep.FileType, properties: [:])
            {
                if let cg = bitmap.cgImage {
                    addResult("automator", png, cg)
                } else {
                    results["automator"] = ["size": png.count]
                }
            }
        }
        return ["methods": results]
    }

    private func sampleCenterPixel(_ cgImage: CGImage) -> [Int]? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let x = w / 2
        let y = h / 2
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let ctx = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else { return nil }
        ctx.draw(
            cgImage,
            in: CGRect(x: -CGFloat(x), y: -CGFloat(y), width: CGFloat(w), height: CGFloat(h)))
        return pixel.map { Int($0) }
    }

    /// Capture screenshot using a specific method only
    func screenshotWithMethod(id: String, method: String) async throws -> Data? {
        guard runningVM?.id == id, let view = runningVM?.view else { return nil }
        switch method {
        case "cgwindow":
            guard let win = view.window, win.contentView != nil else { return nil }
            let windowRect = view.convert(view.bounds, to: nil)
            let screenRect = win.convertToScreen(windowRect)
            guard
                let cgImage = CGWindowListCreateImage(
                    screenRect, .optionIncludingWindow, CGWindowID(win.windowNumber),
                    .bestResolution)
            else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        case "ciimage":
            return captureViaCIImage(view)
        case "iosurface":
            return captureFromIOSurface(view)
        case "layer":
            return captureViewLayer(view)
        case "automator":
            guard let automator = runningVM?.automator else { return nil }
            let image = try await automator.screenshot()
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff)
            else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        default:
            return nil
        }
    }

    func screenshotDebugInfo(id: String) -> [String: Any]? {
        guard runningVM?.id == id, let view = runningVM?.view else { return nil }
        guard let displaySubview = view.subviews.first,
            let surface = displaySubview.layer?.contents as? IOSurface
        else {
            return ["error": "No IOSurface in view.subviews.first"]
        }
        let pf = IOSurfaceGetPixelFormat(surface)
        let pfStr =
            String(
                bytes: [
                    UInt8((pf >> 0) & 0xFF),
                    UInt8((pf >> 8) & 0xFF),
                    UInt8((pf >> 16) & 0xFF),
                    UInt8((pf >> 24) & 0xFF),
                ], encoding: .ascii) ?? "?"
        var info: [String: Any] = [
            "width": IOSurfaceGetWidth(surface),
            "height": IOSurfaceGetHeight(surface),
            "bytesPerRow": IOSurfaceGetBytesPerRow(surface),
            "pixelFormat": pf,
            "pixelFormatStr": pfStr,
            "subviewCount": view.subviews.count,
        ]
        surface.lock(options: .readOnly, seed: nil)
        let base = IOSurfaceGetBaseAddress(surface)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface)
        var samples: [[Int]] = []
        for (y, x) in [(0, 0), (0, min(1, w - 1)), (min(1, h - 1), 0), (h / 2, w / 2)]
        where y < h && x < w {
            let offset = y * bpr + x * 4
            if offset + 4 <= bpr * h {
                samples.append([
                    Int(ptr[offset]), Int(ptr[offset + 1]),
                    Int(ptr[offset + 2]), Int(ptr[offset + 3]),
                ])
            }
        }
        info["pixelSamples"] = samples
        surface.unlock(options: .readOnly, seed: nil)
        return info
    }

    /// Uses CIImage(ioSurface:) + CIContext - same path as VZAutomator.screenshot, handles format correctly
    private func captureViaCIImage(_ view: NSView) -> Data? {
        captureViaCIImageWithCGImage(view)?.0
    }
    private func captureViaCIImageWithCGImage(_ view: NSView) -> (Data, CGImage)? {
        guard let displaySubview = view.subviews.first,
            let surface = displaySubview.layer?.contents as? IOSurface
        else { return nil }
        let display = CIImage(ioSurface: surface)
        let extent = display.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let context: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: [.useSoftwareRenderer: false])
        }
        guard
            let cgImage = context.createCGImage(
                display,
                from: extent,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, cgImage)
    }

    private func captureFromIOSurface(_ view: NSView) -> Data? {
        captureFromIOSurfaceWithCGImage(view)?.0
    }
    private func captureFromIOSurfaceWithCGImage(_ view: NSView) -> (
        Data, CGImage
    )? {
        guard let displaySubview = view.subviews.first,
            let surface = displaySubview.layer?.contents as? IOSurface
        else { return nil }
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface)
        guard w > 0, h > 0 else { return nil }
        // Lock syncs GPU framebuffer to CPU memory before reading pixels; required for coherent read.
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let dataSize = bpr * h
        let dataCopy = Data(bytes: base, count: dataSize)
        let pf = IOSurfaceGetPixelFormat(surface)
        let bitmapInfo: CGBitmapInfo
        switch pf {
        case 0x4247_5241:
            // kCVPixelFormatType_32BGRA: B,G,R,A in memory (byte 0 = B)
            bitmapInfo = CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.noneSkipFirst.rawValue)
        case 0x4142_4752:
            bitmapInfo = CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)
        default:
            bitmapInfo = CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.noneSkipFirst.rawValue)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: dataCopy as CFData) else { return nil }
        guard
            let cgImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bpr,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, cgImage)
    }

    private func captureViewLayer(_ view: NSView) -> Data? {
        captureViewLayerWithCGImage(view)?.0
    }
    private func captureViewLayerWithCGImage(_ view: NSView) -> (Data, CGImage)? {
        let layerToRender: CALayer?
        let boundsToUse: CGRect
        if let displaySubview = view.subviews.first,
            displaySubview.layer?.contents is IOSurface
        {
            layerToRender = displaySubview.layer
            boundsToUse = displaySubview.bounds
        } else {
            layerToRender = view.layer
            boundsToUse = view.bounds
        }
        guard let layer = layerToRender, boundsToUse.width > 0, boundsToUse.height > 0 else {
            return nil
        }
        let scale = view.window?.backingScaleFactor ?? 1
        let w = Int(boundsToUse.width * scale)
        let h = Int(boundsToUse.height * scale)
        guard w > 0, h > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let cgImage = ctx.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, cgImage)
    }

    private func keyFromName(_ name: String) -> VZAutomator.Key {
        let parts = name.split(separator: "+").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard !parts.isEmpty else { return .keyboardReturn }

        var modifiers: VZAutomator.Modifiers = []
        var mainKeyPart: String?
        let modifierNames: Set<String> = [
            "ctrl", "control", "alt", "option", "shift", "cmd", "command", "meta", "super", "win",
            "fn",
        ]

        for part in parts {
            let lower = part.lowercased()
            if modifierNames.contains(lower) {
                switch lower {
                case "ctrl", "control": modifiers.insert(.control)
                case "alt", "option": modifiers.insert(.alt)
                case "shift": modifiers.insert(.shift)
                case "cmd", "command", "meta", "super", "win": modifiers.insert(.command)
                case "fn": modifiers.insert(.fn)
                default: break
                }
            } else {
                mainKeyPart = part
                break
            }
        }

        let mainKey: VZAutomator.Key
        if let part = mainKeyPart ?? parts.last {
            mainKey = baseKeyFromName(String(part))
        } else {
            return .keyboardReturn
        }

        var result = mainKey
        if modifiers.contains(.control) { result = result.modify(.control) }
        if modifiers.contains(.alt) { result = result.modify(.alt) }
        if modifiers.contains(.shift) { result = result.modify(.shift) }
        if modifiers.contains(.command) { result = result.modify(.command) }
        if modifiers.contains(.fn) { result = result.modify(.fn) }
        return result
    }

    private func baseKeyFromName(_ name: String) -> VZAutomator.Key {
        // Handle actual escape chars (in case sent as single chars)
        if name == "\t" { return .keyboardTab }
        if name == "\n" || name == "\r" { return .keyboardReturn }
        if name == "\u{8}" { return .keyboardDelete }  // \b backspace
        switch name.lowercased() {
        case "enter", "return": return .keyboardReturn
        case "tab": return .keyboardTab
        case "escape", "esc": return .keyboardEsc
        case "space", "spacebar": return .keyboardSpacebar
        case "backspace", "backspace2": return .keyboardDelete
        case "delete", "del": return .keyboardDeleteForward
        case "up": return .keyboardUpArrow
        case "down": return .keyboardDownArrow
        case "left": return .keyboardLeftArrow
        case "right": return .keyboardRightArrow
        case "home": return .keyboardHome
        case "end": return .keyboardEnd
        case "page_up", "pageup": return .keyboardPageUp
        case "page_down", "pagedown": return .keyboardPageDown
        case "f1": return .keyboardF1
        case "f2": return .keyboardF2
        case "f3": return .keyboardF3
        case "f4": return .keyboardF4
        case "f5": return .keyboardF5
        case "f6": return .keyboardF6
        case "f7": return .keyboardF7
        case "f8": return .keyboardF8
        case "f9": return .keyboardF9
        case "f10": return .keyboardF10
        case "f11": return .keyboardF11
        case "f12": return .keyboardF12
        case "a": return .keyboardA
        case "b": return .keyboardB
        case "c": return .keyboardC
        case "d": return .keyboardD
        case "e": return .keyboardE
        case "f": return .keyboardF
        case "g": return .keyboardG
        case "h": return .keyboardH
        case "i": return .keyboardI
        case "j": return .keyboardJ
        case "k": return .keyboardK
        case "l": return .keyboardL
        case "m": return .keyboardM
        case "n": return .keyboardN
        case "o": return .keyboardO
        case "p": return .keyboardP
        case "q": return .keyboardQ
        case "r": return .keyboardR
        case "s": return .keyboardS
        case "t": return .keyboardT
        case "u": return .keyboardU
        case "v": return .keyboardV
        case "w": return .keyboardW
        case "x": return .keyboardX
        case "y": return .keyboardY
        case "z": return .keyboardZ
        case "0": return .keyboard0
        case "1": return .keyboard1
        case "2": return .keyboard2
        case "3": return .keyboard3
        case "4": return .keyboard4
        case "5": return .keyboard5
        case "6": return .keyboard6
        case "7": return .keyboard7
        case "8": return .keyboard8
        case "9": return .keyboard9
        case "power": return .keyboardPower
        case "minus", "-": return .keyboardHyphen
        case "equal", "=": return .keyboardEqualSign
        case "bracketleft", "[": return .keyboardOpenBracket
        case "bracketright", "]": return .keyboardCloseBracket
        case "backslash", "\\": return .keyboardBackslash
        case "semicolon", ";": return .keyboardSemicolon
        case "apostrophe", "'": return .keyboardQuote
        case "comma", ",": return .keyboardComma
        case "period", ".": return .keyboardPeriod
        case "slash", "/": return .keyboardSlash
        case "grave", "`": return .keyboardGrave
        default: return .keyboardReturn
        }
    }
}

class InstallerWindowDelegate: NSObject, NSWindowDelegate {
    let vmId: String

    init(vmId: String) {
        self.vmId = vmId
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ClawVMManager.shared.installingMacOS[vmId] != nil else {
            return true
        }
        let name = ClawVMManager.shared.displayName(for: vmId)
        let alert = NSAlert()
        alert.messageText = "Cancel preparing \(name)'s home?"
        alert.informativeText =
            "This will stop the installation. You can create the home again later."
        alert.addButton(withTitle: "Keep Preparing")
        alert.addButton(withTitle: "Cancel Installation")
        if alert.runModal() == .alertSecondButtonReturn {
            ClawVMManager.shared.cancelInstall(id: vmId)
        }
        return false
    }
}

class VMWindowDelegate: NSObject, NSWindowDelegate {
    let vmId: String

    init(vmId: String) {
        self.vmId = vmId
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let vmRunning = ClawVMManager.shared.runningVM?.id == vmId
        if !vmRunning {
            // VM already stopped — hide window and quit without confirmation
            sender.orderOut(nil)
            ClawVMManager.shared.isAboutToClose = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Are you sure to close this Home?"
        alert.informativeText =
            "Make sure you shut down macOS inside in order to prevent data loss."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close immediately")
        guard alert.runModal() == .alertSecondButtonReturn else {
            return false
        }
        ClawVMManager.shared.isAboutToClose = true
        Task { @MainActor in
            try? await ClawVMManager.shared.stopVM(id: vmId, force: true)
        }
        return false
    }
}

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("[ClawVM] VM didStopWithError: \(error.localizedDescription)")
        Task { @MainActor in
            ClawVMManager.shared.runningVM?.clipboardSync?.stop()
            ClawVMManager.shared.runningVM = nil
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[ClawVM] VM guestDidStop")
        Task { @MainActor in
            ClawVMManager.shared.runningVM?.clipboardSync?.stop()
            ClawVMManager.shared.runningVM = nil
        }
    }
}
