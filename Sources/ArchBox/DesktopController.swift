import AVFoundation
import AppKit
import Virtualization

/// Runs the installed Arch Linux in a full-screen window.
/// Closing the window saves the machine's state; the next launch resumes it.
@MainActor
final class DesktopController: NSObject, NSWindowDelegate, VZVirtualMachineDelegate {
    private var window: NSWindow!
    private let machineView = VZVirtualMachineView()
    private var machine: VZVirtualMachine?
    private var canSaveState = false
    private var displayPixels = CGSize.zero
    /// The optional devices of the running machine, recorded with a saved state.
    private var devices = VMConfig.OptionalDevices(microphone: false, rosetta: false)
    private var isClosing = false
    private var closeCompletions: [() -> Void] = []

    /// True while the machine runs or is being saved; quitting must wait for close(completion:).
    var needsClosing: Bool {
        isClosing || machine?.state == .running || machine?.state == .paused
    }

    func start() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)

        window = NSWindow(contentRect: screen.visibleFrame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Arch Linux"
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = machineView
        window.delegate = self
        window.isReleasedWhenClosed = false
        machineView.capturesSystemKeys = false
        machineView.automaticallyReconfiguresDisplay = true
        window.makeKeyAndOrderFront(nil)
        // Entering full screen in the same run-loop turn as ordering the window front is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let window = self?.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
        installKeyMonitor()

        displayPixels = pixels

        // A saved state restores only into the same set of devices it was saved with.
        if FileManager.default.fileExists(atPath: Paths.savedState.path),
           let data = try? Data(contentsOf: Paths.savedStateDevices),
           let saved = try? JSONDecoder().decode(VMConfig.OptionalDevices.self, from: data) {
            startMachine(devices: saved)
            return
        }
        currentDevices { self.startMachine(devices: $0) }
    }

    /// What this Mac offers right now. The microphone is used by the Virtualization
    /// XPC service, where macOS denies it silently; the app itself has to ask first.
    private func currentDevices(_ completion: @escaping (VMConfig.OptionalDevices) -> Void) {
        let rosetta = VZLinuxRosettaDirectoryShare.availability == .installed
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(.init(microphone: true, rosetta: rosetta))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(.init(microphone: granted, rosetta: rosetta)) }
            }
        default:
            completion(.init(microphone: false, rosetta: rosetta))
        }
    }

    private func startMachine(devices: VMConfig.OptionalDevices) {
        do {
            let config = try makeConfiguration(devices: devices)
            let machine = makeMachine(config)
            if canSaveState, FileManager.default.fileExists(atPath: Paths.savedState.path) {
                resume(machine)
            } else {
                // A state that cannot be restored now must not be restored later
                // either: the disk changes from this boot on.
                Self.removeSavedState()
                boot(machine)
            }
        } catch {
            showFatal("Sanal makine yapılandırılamadı: \(error.localizedDescription)")
        }
    }

    private func makeConfiguration(devices: VMConfig.OptionalDevices) throws -> VZVirtualMachineConfiguration {
        let config = try VMConfig.desktop(displayPixels: displayPixels, devices: devices)
        self.devices = devices
        canSaveState = (try? config.validateSaveRestoreSupport()) != nil
        return config
    }

    /// The machine view forwards every key to Linux, ⌘ included (as the Meta key).
    /// Keep ⌘Q (save and quit) and ⌃⌘F (full screen) for the Mac.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
            case ([.command], "q"):
                NSApp.terminate(nil)
                return nil
            case ([.command, .control], "f"):
                event.window?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
        }
    }

    private func makeMachine(_ config: VZVirtualMachineConfiguration) -> VZVirtualMachine {
        let machine = VZVirtualMachine(configuration: config)
        machine.delegate = self
        machineView.virtualMachine = machine
        self.machine = machine
        return machine
    }

    private func boot(_ machine: VZVirtualMachine) {
        machine.start { [weak self] result in
            if case .failure(let error) = result {
                self?.showFatal("Arch Linux başlatılamadı: \(error.localizedDescription)")
            }
        }
    }

    private func resume(_ machine: VZVirtualMachine) {
        machine.restoreMachineStateFrom(url: Paths.savedState) { [weak self] error in
            // A saved state is only valid once; the disk changes after resuming.
            Self.removeSavedState()
            guard let self else { return }
            if let error {
                NSLog("ArchBox: restore failed, cold booting: \(error)")
                self.coldBoot(replacing: machine)
                return
            }
            machine.resume { [weak self] result in
                if case .failure(let error) = result {
                    NSLog("ArchBox: resume failed, cold booting: \(error)")
                    self?.coldBoot(replacing: machine)
                }
            }
        }
    }

    private static func removeSavedState() {
        try? FileManager.default.removeItem(at: Paths.savedState)
        try? FileManager.default.removeItem(at: Paths.savedStateDevices)
    }

    /// The restored machine may still hold disk.img; stop it before booting a fresh one,
    /// built with the devices this Mac offers now rather than the saved ones.
    private func coldBoot(replacing old: VZVirtualMachine) {
        let bootFresh = {
            // The user quit while the old machine was stopping: don't start a new one.
            if self.isClosing {
                self.finishClosing()
                return
            }
            self.currentDevices { devices in
                do {
                    self.boot(self.makeMachine(try self.makeConfiguration(devices: devices)))
                } catch {
                    self.showFatal("Sanal makine yapılandırılamadı: \(error.localizedDescription)")
                }
            }
        }
        guard old.canStop else {
            bootFresh()
            return
        }
        old.stop { _ in bootFresh() }
    }

    // MARK: - Closing

    /// Saves (or shuts down) the machine, then calls `completion`.
    /// Calls made while a close is already running wait for that close.
    /// The closures hold `self` strongly so the controller outlives the save.
    func close(completion: @escaping () -> Void) {
        if isClosing {
            closeCompletions.append(completion)
            return
        }
        guard let machine, machine.state == .running || machine.state == .paused else {
            completion()
            return
        }
        isClosing = true
        closeCompletions.append(completion)
        window.title = "Arch Linux — kaydediliyor…"

        guard canSaveState else {
            shutDown(machine)
            return
        }
        let save = {
            machine.saveMachineStateTo(url: Paths.savedState) { error in
                if let error {
                    NSLog("ArchBox: save failed, shutting down instead: \(error)")
                    Self.removeSavedState()
                    machine.resume { _ in self.shutDown(machine) }
                    return
                }
                if let data = try? JSONEncoder().encode(self.devices) {
                    try? data.write(to: Paths.savedStateDevices, options: .atomic)
                }
                machine.stop { _ in self.finishClosing() }
            }
        }
        if machine.state == .paused {
            save()
        } else {
            machine.pause { result in
                if case .failure = result { self.shutDown(machine) } else { save() }
            }
        }
    }

    /// Asks Linux to power off cleanly; forces it after 60 seconds.
    private func shutDown(_ machine: VZVirtualMachine) {
        window.title = "Arch Linux — kapatılıyor…"
        try? machine.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard self.machine === machine, machine.canStop else { return }
            machine.stop { _ in self.finishClosing() }
        }
    }

    private func finishClosing() {
        machine = nil
        isClosing = false
        let completions = closeCompletions
        closeCompletions = []
        completions.forEach { $0() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close { NSApp.terminate(nil) }
        return false
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            // Shut down from inside Arch, or the end of a shutDown(_:) request.
            if self.isClosing {
                self.finishClosing()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            self.showFatal("Arch Linux beklenmedik şekilde durdu: \(error.localizedDescription)")
        }
    }

    private func showFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ArchBox"
        alert.informativeText = message + "\n\nKonsol kaydı: \(Paths.console.path)"
        alert.runModal()
        NSApp.terminate(nil)
    }
}
