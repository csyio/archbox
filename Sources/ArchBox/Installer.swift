import AppKit
import Virtualization

/// Drives the one-time installation:
/// download the Arch Linux ARM rootfs, turn it into an in-memory installer,
/// boot it, and let `archbox-provision` install the real system onto disk.img.
@MainActor
final class Installer: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum Phase: Equatable {
        case form
        case running
        case failed(String)
        case finished
    }

    struct Account {
        var username: String
        var fullName: String
        var password: String
    }

    static let stepTitles = [
        "Arch Linux ARM indiriliyor",
        "Kurulum sistemi hazırlanıyor",
        "Kurulum sistemi açılıyor",
        "Disk bölümleniyor",
        "Temel sistem kopyalanıyor",
        "Paket anahtarları hazırlanıyor",
        "Sistem güncelleniyor",
        "KDE Plasma kuruluyor (en uzun adım)",
        "Sistem ayarlanıyor",
        "Önyükleyici kuruluyor",
        "Bitiriliyor",
    ]
    /// `@@STEP n` from the guest script maps to stepTitles[n + guestStepOffset].
    private static let guestStepOffset = 1

    @Published var phase: Phase = .form
    @Published var step = 0
    @Published var downloadProgress: Double?
    @Published var logTail = ""

    var onFinished: (() -> Void)?

    private static let tarballURL = URL(string: "https://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz")!
    private static let signatureURL = URL(string: "https://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.sig")!

    private var machine: VZVirtualMachine?
    private var logTimer: Timer?
    /// Incremental console parsing: bytes already read, the unfinished last line,
    /// the last status seen and the recent output lines shown in the UI.
    private var consoleOffset: UInt64 = 0
    private var consolePartialLine = ""
    private var consoleStatus: String?
    private var consoleLines: [String] = []
    private var task: Task<Void, Never>?

    func start(account: Account) {
        guard phase != .running else { return }
        phase = .running
        step = 0
        logTail = ""
        downloadProgress = nil
        task = Task {
            do {
                try Paths.ensureDirectories()
                Self.removeSecrets()
                try await downloadTarballIfNeeded()
                try Task.checkCancellation()
                step = 1
                try await prepareInstallerSystem(account: account)
                try Task.checkCancellation()
                step = 2
                try bootInstaller()
            } catch {
                // After a cancel, errors from the dying run (URLError.cancelled, a late
                // hash failure) must not touch a newer run; cancel() already reported it.
                if Task.isCancelled {
                    Self.removeSecrets()
                } else {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    /// Deletes every file that carries the account password. Also called at launch,
    /// in case an earlier install was killed before it could clean up.
    static func removeSecrets() {
        for url in [Paths.installerConfig, Paths.installerInitrd] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Host side

    /// Downloads the rootfs unless the cached copy matches the mirror's current signature.
    /// The signature is checked against the pinned Arch Linux ARM key, not the mirror.
    private func downloadTarballIfNeeded() async throws {
        let (signature, _) = try await URLSession.shared.data(from: Self.signatureURL)
        if FileManager.default.fileExists(atPath: Paths.tarball.path),
           (try? await verify(Paths.tarball, signature: signature)) != nil {
            return
        }

        downloadProgress = 0
        let downloaded = try await Downloader.download(Self.tarballURL) { [weak self] fraction in
            Task { @MainActor in self?.downloadProgress = fraction }
        }
        downloadProgress = nil
        do {
            try await verify(downloaded, signature: signature)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        try? FileManager.default.removeItem(at: Paths.tarball)
        try FileManager.default.moveItem(at: downloaded, to: Paths.tarball)
    }

    /// Hashing 800 MB takes a moment; keep it off the main thread.
    private nonisolated func verify(_ file: URL, signature: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try SignatureVerifier.verify(file: file, signature: signature)
        }.value
    }

    private func prepareInstallerSystem(account: Account) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.installerConsole)

        // The tarball reaches the installer as a raw disk. A disk image must be a
        // whole number of 512-byte sectors, so pad an APFS clone (no extra space used).
        let tarballSize = try fm.attributesOfItem(atPath: Paths.tarball.path)[.size] as! UInt64
        try? fm.removeItem(at: Paths.installerTarballDisk)
        try fm.copyItem(at: Paths.tarball, to: Paths.installerTarballDisk)
        let tarballDisk = try FileHandle(forWritingTo: Paths.installerTarballDisk)
        try tarballDisk.truncate(atOffset: (tarballSize + 511) / 512 * 512)
        try tarballDisk.close()


        // A fresh, sparse disk: 128 GB on paper, only what is used on the Mac.
        try? fm.removeItem(at: Paths.disk)
        try? fm.removeItem(at: Paths.efiVariables)
        try? fm.removeItem(at: Paths.savedState)
        try? fm.removeItem(at: Paths.installedMarker)
        fm.createFile(atPath: Paths.disk.path, contents: nil)
        let disk = try FileHandle(forWritingTo: Paths.disk)
        try disk.truncate(atOffset: VMConfig.diskSize)
        try disk.close()

        // Also checks that the archive really is a rootfs, before anything else uses it.
        let links = try await hardLinks(in: Paths.tarball)

        // The kernel for the installer comes straight from the rootfs.
        fm.createFile(atPath: Paths.installerKernel.path, contents: nil)
        try await run("/usr/bin/tar", ["-xOzf", Paths.tarball.path, "./boot/Image"],
                      stdout: try FileHandle(forWritingTo: Paths.installerKernel))

        // The installer's root filesystem is the whole Arch Linux ARM rootfs
        // (minus firmware and docs) plus our provisioning service, repacked as
        // a cpio initramfs. bsdtar keeps root ownership and device nodes intact.
        guard let guestDir = Bundle.main.resourceURL?.appendingPathComponent("guest") else {
            throw InstallError("Uygulama paketinde kurulum dosyaları bulunamadı.")
        }
        var overlay = """
            #mtree
            ./usr/local/bin/archbox-provision type=file uid=0 gid=0 mode=0755 contents=archbox-provision
            ./etc/systemd/system/archbox-provision.service type=file uid=0 gid=0 mode=0644 contents=archbox-provision.service
            ./etc/systemd/system/multi-user.target.wants/archbox-provision.service type=link uid=0 gid=0 mode=0777 link=/etc/systemd/system/archbox-provision.service
            ./etc/systemd/system/serial-getty@hvc0.service type=link uid=0 gid=0 mode=0777 link=/dev/null

            """
        // bsdtar's cpio writer drops hard links when repacking another archive
        // (e.g. mkfs.ext4 -> mke2fs), so re-add each one as a symlink. The later
        // entry wins when the kernel unpacks the initramfs.
        for (path, target) in links {
            overlay += "\(mtreeEscape(path)) type=link uid=0 gid=0 mode=0777 link=\(mtreeEscape("/" + target.dropFirst(2)))\n"
        }
        try overlay.write(to: Paths.installerOverlay, atomically: true, encoding: .utf8)

        var arguments = ["-c", "-z", "--options", "gzip:compression-level=1", "--format", "newc",
                         "-f", Paths.installerBaseInitrd.path]
        for excluded in ["usr/lib/firmware", "usr/share/man", "usr/share/doc",
                         "usr/share/info", "usr/share/locale", "boot"] {
            arguments += ["--exclude", "./\(excluded)/*"]
        }
        arguments += ["@" + Paths.tarball.path, "@" + Paths.installerOverlay.path]
        try await run("/usr/bin/tar", arguments, currentDirectory: guestDir)

        // The account goes into a separate, tiny cpio segment appended to a clone of
        // the base; Linux unpacks concatenated initramfs segments in order. This keeps
        // the password on disk for milliseconds instead of the whole repack.
        try? fm.removeItem(at: Paths.installerInitrd)
        try fm.copyItem(at: Paths.installerBaseInitrd, to: Paths.installerInitrd)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.installerInitrd.path)
        try """
            #mtree
            ./etc/archbox type=dir uid=0 gid=0 mode=0700
            ./etc/archbox/config.env type=file uid=0 gid=0 mode=0600 contents=\(mtreeEscape(Paths.installerConfig.path))

            """.write(to: Paths.installerSecretsOverlay, atomically: true, encoding: .utf8)
        // Set up the removal first, so a failed or partial write is cleaned up too.
        defer { try? fm.removeItem(at: Paths.installerConfig) }
        try writeConfig(account: account, tarballSize: tarballSize)
        let initrd = try FileHandle(forWritingTo: Paths.installerInitrd)
        try initrd.seekToEnd()
        try await run("/usr/bin/tar", ["-c", "-z", "--format", "newc", "-f", "-",
                                       "@" + Paths.installerSecretsOverlay.path],
                      stdout: initrd)
    }

    /// Returns (path, target) for every hard link in the tarball, both as "./relative" paths.
    private func hardLinks(in tarball: URL) async throws -> [(String, String)] {
        let listing = Paths.install.appendingPathComponent("rootfs.list")
        FileManager.default.createFile(atPath: listing.path, contents: nil)
        try await run("/usr/bin/tar", ["-tvzf", tarball.path], stdout: try FileHandle(forWritingTo: listing))
        defer { try? FileManager.default.removeItem(at: listing) }

        // Lines look like: "hrwxr-xr-x  0 root root 0 Mar 12  2026 ./usr/bin/mkfs.ext4 link to ./usr/bin/mke2fs"
        let text = try String(contentsOf: listing, encoding: .utf8)
        // The signing key also signs packages; make sure this really is a rootfs.
        guard text.contains(" ./etc/arch-release\n"), text.contains(" ./usr/lib/systemd/systemd\n") else {
            try? FileManager.default.removeItem(at: tarball)
            throw InstallError("İndirilen dosya bir Arch Linux ARM kök dosya sistemi değil. Tekrar deneyin.")
        }
        var links: [(String, String)] = []
        for line in text.split(separator: "\n") where line.hasPrefix("h") {
            guard let start = line.range(of: " ./"),
                  let separator = line.range(of: " link to ./", range: start.upperBound..<line.endIndex) else { continue }
            let path = "./" + line[start.upperBound..<separator.lowerBound]
            let target = "./" + line[separator.upperBound...]
            links.append((String(path), String(target)))
        }
        return links
    }

    /// mtree paths use octal escapes for anything outside a safe ASCII set.
    private func mtreeEscape(_ path: String) -> String {
        var result = ""
        for byte in path.utf8 {
            let scalar = Unicode.Scalar(byte)
            if byte > 0x20 && byte < 0x7f && scalar != "\\" && scalar != "#" && scalar != "=" {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(format: "\\%03o", byte)
            }
        }
        return result
    }

    private func writeConfig(account: Account, tarballSize: UInt64) throws {
        let values: [(String, String)] = [
            ("ARCHBOX_USER", account.username),
            ("ARCHBOX_FULLNAME", account.fullName),
            ("ARCHBOX_PASSWORD", account.password),
            ("ARCHBOX_HOSTNAME", "archbox"),
            ("ARCHBOX_TIMEZONE", TimeZone.current.identifier),
            ("ARCHBOX_CONSOLE_KEYMAP", "trq"),
            ("ARCHBOX_XKB_LAYOUT", "tr"),
            ("ARCHBOX_DISPLAY_SCALE", String(Int(NSScreen.main?.backingScaleFactor ?? 2))),
            ("ARCHBOX_NOW", String(Int(Date().timeIntervalSince1970))),
            ("ARCHBOX_TARBALL_SIZE", String(tarballSize)),
            ("ARCHBOX_DISK", VMConfig.guestDiskNames.0),
            ("ARCHBOX_TARBALL_DISK", VMConfig.guestDiskNames.1),
            ("ARCHBOX_TEST", ProcessInfo.processInfo.environment["ARCHBOX_TEST"] ?? ""),
        ]
        let text = values.map { "\($0.0)=\(shellQuote($0.1))" }.joined(separator: "\n") + "\n"
        // Owner-only from the first byte (FileManager.createFile writes a 0644 temp
        // file and applies the mode afterwards). O_EXCL: never reuse an existing file.
        try? FileManager.default.removeItem(at: Paths.installerConfig)
        let fd = open(Paths.installerConfig.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallError("Kurulum ayarları yazılamadı (errno \(errno)).") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Guest side

    private func bootInstaller() throws {
        consoleOffset = 0
        consolePartialLine = ""
        consoleStatus = nil
        consoleLines = []
        let machine = VZVirtualMachine(configuration: try VMConfig.installer())
        machine.delegate = self
        self.machine = machine
        machine.start { [weak self] result in
            guard let self, self.machine === machine else {
                // Cancelled while starting: nobody tracks this machine any more.
                if machine.canStop { machine.stop { _ in } }
                return
            }
            switch result {
            case .success:
                // The kernel and initramfs are in guest memory now; the password
                // no longer needs to exist on the Mac's disk.
                Self.removeSecrets()
            case .failure(let error):
                self.fail("Kurulum sistemi başlatılamadı: \(error.localizedDescription)")
            }
        }
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in _ = self?.readProgress() }
        }
    }

    /// Progress comes from the installer's serial console, mixed with kernel and systemd output.
    /// Reads only what was appended since the last call.
    private func readProgress() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: Paths.installerConsole) else { return consoleStatus }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: consoleOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return consoleStatus }
        consoleOffset += UInt64(data.count)

        var lines = (consolePartialLine + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        consolePartialLine = lines.removeLast()
        for raw in lines {
            // Progress bars redraw with \r; only the text after the last one is visible.
            let line = (raw.components(separatedBy: "\r").last { !$0.isEmpty } ?? "")
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            if let range = line.range(of: "@@STEP ") {
                if let n = Int(line[range.upperBound...].prefix { $0.isNumber }) {
                    step = min(n + Self.guestStepOffset, Self.stepTitles.count - 1)
                }
            } else if let range = line.range(of: "@@STATUS ") {
                consoleStatus = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty, !line.hasPrefix("[") {
                consoleLines.append(line)
            }
        }
        consoleLines = Array(consoleLines.suffix(14))
        logTail = consoleLines.joined(separator: "\n")
        return consoleStatus
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }   // from a cancelled run
            self.installerStopped()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            self.fail("Kurulum sistemi beklenmedik şekilde durdu: \(error.localizedDescription)")
        }
    }

    private func installerStopped() {
        logTimer?.invalidate()
        let status = readProgress()
        machine = nil
        guard status == "ok" else {
            fail("Kurulum tamamlanamadı. Ayrıntılar: \(Paths.installerConsole.path)")
            return
        }
        // Remove the large temporary installer files.
        Self.removeSecrets()
        let fm = FileManager.default
        for url in [Paths.installerKernel, Paths.installerOverlay, Paths.installerTarballDisk,
                    Paths.installerBaseInitrd, Paths.installerSecretsOverlay] {
            try? fm.removeItem(at: url)
        }
        // A stress test (ARCHBOX_TEST) ends with "ok" too, but installs nothing.
        if ProcessInfo.processInfo.environment["ARCHBOX_TEST", default: ""].isEmpty {
            fm.createFile(atPath: Paths.installedMarker.path,
                          contents: Data(ISO8601DateFormatter().string(from: Date()).utf8))
        }
        phase = .finished
        onFinished?()
    }

    private func fail(_ message: String) {
        guard phase == .running else { return }
        Self.removeSecrets()
        task?.cancel()
        task = nil
        logTimer?.invalidate()
        if let machine, machine.canStop {
            machine.stop { _ in }
        }
        machine = nil
        phase = .failed(message)
    }

    func cancel() {
        fail("Kurulum iptal edildi.")
    }

    // MARK: - Helpers

    private nonisolated func run(_ tool: String, _ arguments: [String],
                                 currentDirectory: URL? = nil, stdout: FileHandle? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let stdout { process.standardOutput = stdout }
        // stderr goes to a file: a Pipe that is only read after exit can fill up and block the tool.
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archbox-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stderr.close()
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardError = stderr
        // terminate() on a process that never launched raises an exception, and a
        // cancel can arrive before, during or after launch; a lock orders the two.
        let state = ProcessCancelState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                state.launch {
                    do {
                        try process.run()
                        return true
                    } catch {
                        continuation.resume(throwing: error)
                        return false
                    }
                } ifCancelled: {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            state.cancel { process.terminate() }
        }
        try? stdout?.close()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw InstallError("\(tool) başarısız oldu: \(message.suffix(400))")
        }
    }
}

/// Coordinates launching a Process with a cancel that may arrive on another thread.
private final class ProcessCancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var launched = false

    /// `run` returns whether the process actually launched.
    func launch(_ run: () -> Bool, ifCancelled: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            ifCancelled()
        } else {
            launched = run()
        }
    }

    func cancel(_ terminate: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if launched { terminate() }
    }
}

struct InstallError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// URLSession download with a progress callback.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func download(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let downloader = Downloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it now.
        let destination = Paths.tarball.appendingPathExtension("part")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
