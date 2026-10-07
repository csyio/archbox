import AppKit
import Virtualization

/// Builds the two virtual machine configurations ArchBox uses:
/// the one-time installer (direct Linux boot into RAM) and the
/// everyday desktop (UEFI boot from the installed disk).
enum VMConfig {
    static let diskSize: UInt64 = 128 << 30

    static var cpuCount: Int {
        if let value = ProcessInfo.processInfo.environment["ARCHBOX_CPUS"].flatMap(Int.init) { return value }
        let host = ProcessInfo.processInfo.processorCount
        return max(2, min(host - 4, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
    }

    static var memorySize: UInt64 {
        if let gigabytes = ProcessInfo.processInfo.environment["ARCHBOX_MEMORY_GB"].flatMap(UInt64.init) {
            return gigabytes << 30
        }
        let host = ProcessInfo.processInfo.physicalMemory
        let wanted = min(host / 2, 8 << 30)
        return min(max(wanted, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                   VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    // MARK: - Installer

    static func installer() throws -> VZVirtualMachineConfiguration {
        let config = base()

        let bootLoader = VZLinuxBootLoader(kernelURL: Paths.installerKernel)
        bootLoader.initialRamdiskURL = Paths.installerInitrd
        bootLoader.commandLine = [
            "console=hvc0",
            "rdinit=/sbin/init",
            "systemd.firstboot=off",
            "systemd.unit=multi-user.target",
        ].joined(separator: " ")
        config.bootLoader = bootLoader

        // The tarball comes in as a raw read-only disk; no shared folder is needed.
        let tarball = try VZDiskImageStorageDeviceAttachment(url: Paths.installerTarballDisk, readOnly: true)
        config.storageDevices = [try disk(), storageDevice(tarball)]
        config.serialPorts = [try serialConsole(logTo: Paths.installerConsole)]

        try config.validate()
        return config
    }

    // MARK: - Desktop

    static func desktop(displayPixels: CGSize) throws -> VZVirtualMachineConfiguration {
        let config = base()

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try efiVariableStore()
        config.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: Int(displayPixels.width),
                heightInPixels: Int(displayPixels.height))
        ]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        config.storageDevices = [try disk()]
        config.directorySharingDevices = [share(tag: "archbox-shared", url: Paths.sharedFolder)]

        // Clipboard sharing through the SPICE agent (spice-vdagent in the guest).
        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        spicePort.attachment = spice
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        consoleDevice.ports[0] = spicePort
        config.consoleDevices = [consoleDevice]

        config.serialPorts = [try serialConsole(logTo: Paths.console)]

        try config.validate()
        return config
    }

    // MARK: - Shared pieces

    private static func base() -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = cpuCount
        config.memorySize = memorySize

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier()
        config.platform = platform

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = macAddress()
        config.networkDevices = [network]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // No memory balloon: Virtualization.framework never asks for memory back
        // unless the host drives it, so the device would only add surface area.
        return config
    }

    /// "nvme" (default) or "virtio"; ARCHBOX_DISK_BUS overrides it for testing.
    /// virtio-blk is not used by default: under sustained disk I/O the guest kernel
    /// memory got corrupted (zeroed seccomp filters, bad rss-counter, oopses) in
    /// about half of all runs on an M5 / macOS 27 host. The same load on the NVMe
    /// controller, or in RAM only, ran clean.
    static var diskBus: String {
        ProcessInfo.processInfo.environment["ARCHBOX_DISK_BUS"] ?? "nvme"
    }

    /// Guest device names for the first and second disk on the current bus.
    static var guestDiskNames: (String, String) {
        diskBus == "nvme" ? ("/dev/nvme0n1", "/dev/nvme1n1") : ("/dev/vda", "/dev/vdb")
    }

    private static func disk() throws -> VZStorageDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: Paths.disk, readOnly: false,
            cachingMode: .automatic, synchronizationMode: .fsync)
        return storageDevice(attachment)
    }

    private static func storageDevice(_ attachment: VZStorageDeviceAttachment) -> VZStorageDeviceConfiguration {
        diskBus == "nvme"
            ? VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
            : VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    private static func share(tag: String, url: URL) -> VZVirtioFileSystemDeviceConfiguration {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: false))
        return device
    }

    /// Writes the guest's hvc0 console to a log file (truncated on every boot).
    private static func serialConsole(logTo url: URL) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: handle)
        return port
    }

    private static func efiVariableStore() throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: Paths.efiVariables.path) {
            return VZEFIVariableStore(url: Paths.efiVariables)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: Paths.efiVariables)
    }

    /// Kept stable across launches; saved state can only be restored on the same machine.
    private static func machineIdentifier() -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: Paths.machineIdentifier),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try? identifier.dataRepresentation.write(to: Paths.machineIdentifier)
        return identifier
    }

    /// Kept stable so the guest keeps the same DHCP lease and NetworkManager profile.
    private static func macAddress() -> VZMACAddress {
        if let text = try? String(contentsOf: Paths.macAddress, encoding: .utf8),
           let address = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return address
        }
        let address = VZMACAddress.randomLocallyAdministered()
        try? address.string.write(to: Paths.macAddress, atomically: true, encoding: .utf8)
        return address
    }
}
