import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var setupWindow: NSWindow?
    private var installer: Installer?
    private var desktop: DesktopController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // A killed install may have left the password behind.
        Installer.removeSecrets()
        try? Paths.ensureDirectories()
        if Paths.isInstalled {
            startDesktop()
        } else {
            showSetup()
        }
        NSApp.activate()
    }

    private func showSetup() {
        let installer = Installer()
        installer.onFinished = { [weak self] in
            self?.setupWindow?.close()
            self?.setupWindow = nil
            self?.startDesktop()
        }
        self.installer = installer

        let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(installer: installer)))
        window.title = "ArchBox"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        setupWindow = window

        // For testing: `ArchBox --unattended-install` with ARCHBOX_USER / ARCHBOX_PASSWORD set.
        let env = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--unattended-install"),
           let user = env["ARCHBOX_USER"], let password = env["ARCHBOX_PASSWORD"] {
            installer.start(account: .init(username: user, fullName: env["ARCHBOX_FULLNAME"] ?? user,
                                           password: password))
        }
    }

    private func startDesktop() {
        let desktop = DesktopController()
        self.desktop = desktop
        desktop.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let installer, installer.phase == .running {
            installer.cancel()
        }
        guard let desktop, desktop.needsClosing else { return .terminateNow }
        desktop.close { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        setupWindow != nil
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ArchBox Hakkında",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ArchBox'ı Gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Kaydet ve Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Pencere")
        let fullScreen = windowMenu.addItem(withTitle: "Tam Ekran",
                                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(withTitle: "Küçült", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
