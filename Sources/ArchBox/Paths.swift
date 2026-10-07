import Foundation

/// Every file ArchBox owns lives under ~/Library/Application Support/ArchBox.
enum Paths {
    static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ArchBox", isDirectory: true)

    static let cache = root.appendingPathComponent("cache", isDirectory: true)
    static let tarball = cache.appendingPathComponent("ArchLinuxARM-aarch64-latest.tar.gz")
    
    // Temporary files used only while installing.
    static let install = root.appendingPathComponent("install", isDirectory: true)
    static let installerKernel = install.appendingPathComponent("Image")
    /// The rootfs repacked as an initramfs, without any secret.
    static let installerBaseInitrd = install.appendingPathComponent("initramfs-base.cpio.gz")
    /// A clone of the base with a small cpio segment holding config.env appended.
    static let installerInitrd = install.appendingPathComponent("initramfs.cpio.gz")
    static let installerSecretsOverlay = install.appendingPathComponent("secrets.mtree")
    static let installerOverlay = install.appendingPathComponent("overlay.mtree")
    static let installerConfig = install.appendingPathComponent("config.env")
    /// A clone of the tarball padded to whole sectors, attached as a read-only disk.
    static let installerTarballDisk = install.appendingPathComponent("rootfs.img")
    /// The installer's serial console; also carries the @@STEP / @@STATUS progress lines.
    static let installerConsole = install.appendingPathComponent("console.log")

    // The installed machine.
    static let disk = root.appendingPathComponent("disk.img")
    static let efiVariables = root.appendingPathComponent("efi-variables.fd")
    static let machineIdentifier = root.appendingPathComponent("machine-identifier.bin")
    static let macAddress = root.appendingPathComponent("mac-address.txt")
    static let savedState = root.appendingPathComponent("saved-state.vzvmsave")
    /// The optional devices the saved state was taken with; a restore needs the same set.
    static let savedStateDevices = root.appendingPathComponent("saved-state-devices.json")
    static let console = root.appendingPathComponent("console.log")
    static let installedMarker = root.appendingPathComponent("installed")

    /// Mounted inside Arch at ~/Mac.
    static let sharedFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ArchShared", isDirectory: true)

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedMarker.path)
            && FileManager.default.fileExists(atPath: disk.path)
    }

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, cache, install, sharedFolder] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Home folders are group-readable on macOS; what Linux puts here is private.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sharedFolder.path)
        // The download cache and the installer's temporary files have no place in backups.
        for var dir in [cache, install] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        }
    }
}
