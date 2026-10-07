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

        do {
            let config = try VMConfig.desktop(displayPixels: pixels)
            canSaveState = (try? config.validateSaveRestoreSupport()) != nil
            let machine = makeMachine(config)
            if canSaveState, FileManager.default.fileExists(atPath: Paths.savedState.path) {
                resume(machine, config: config)
            } else {
                boot(machine)
            }
        } catch {
            showFatal("Sanal makine yapılandırılamadı: \(error.localizedDescription)")
        }
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

    private func resume(_ machine: VZVirtualMachine, config: VZVirtualMachineConfiguration) {
        machine.restoreMachineStateFrom(url: Paths.savedState) { [weak self] error in
            // A saved state is only valid once; the disk changes after resuming.
            try? FileManager.default.removeItem(at: Paths.savedState)
            guard let self else { return }
            if let error {
                NSLog("ArchBox: restore failed, cold booting: \(error)")
                self.coldBoot(replacing: machine, config: config)
                return
            }
            machine.resume { [weak self] result in
                if case .failure(let error) = result {
                    NSLog("ArchBox: resume failed, cold booting: \(error)")
                    self?.coldBoot(replacing: machine, config: config)
                }
            }
        }
    }

    /// The restored machine may still hold disk.img; stop it before booting a fresh one.
    private func coldBoot(replacing old: VZVirtualMachine, config: VZVirtualMachineConfiguration) {
        guard old.canStop else {
            boot(makeMachine(config))
            return
        }
        old.stop { [weak self] _ in
            guard let self else { return }
            // The user quit while the old machine was stopping: don't start a new one.
            if self.isClosing {
                self.finishClosing()
            } else {
                self.boot(self.makeMachine(config))
            }
        }
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
                    try? FileManager.default.removeItem(at: Paths.savedState)
                    machine.resume { _ in self.shutDown(machine) }
                    return
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
