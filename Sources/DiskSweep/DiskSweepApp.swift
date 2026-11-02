import SwiftUI
import DiskSweepCore

/// The only sanctioned way to really quit. ⌘Q and Dock > Quit just close the window and
/// leave the menu bar readouts running.
@MainActor
enum AppLifecycle {
    static var allowTermination = false

    static func quit() {
        allowTermination = true
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBar: MenuBarController?
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(monitor: .shared)
        // macOS only lays out new status items once the app has been active at least once.
        NSApp.activate(ignoringOtherApps: true)

        // "Show main window at launch" off: start as a menu bar app only.
        if !AppSettings.showWindowAtLaunchEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NSApp.windows.filter { $0.title == "DiskSweep" }.forEach { $0.close() }
            }
        }

        // Closing the main window removes the Dock icon; the menu bar keeps running.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard (note.object as? NSWindow)?.title == "DiskSweep" else { return }
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
        }

        // Screenshot testing only (`-DiskSweepRenderDir <dir>`): draws every detail panel to a PNG, then quits.
        if let directory = UserDefaults.standard.string(forKey: "DiskSweepRenderDir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                DetailRenderer.renderAll(into: URL(fileURLWithPath: directory), monitor: .shared)
                AppLifecycle.quit()
            }
        }
        if let name = UserDefaults.standard.string(forKey: "DiskSweepShowMenu"),
           let metric = MenuBarMetric(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.menuBar?.showContextMenuForTesting(metric)
            }
        }
        if let name = UserDefaults.standard.string(forKey: "DiskSweepShowPopover"),
           let metric = MenuBarMetric(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.menuBar?.showPopoverForTesting(metric)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppLifecycle.allowTermination || Self.isSystemShutdown { return .terminateNow }
        // ⌘Q / Dock > Quit: close the window, keep running in the menu bar.
        NSApp.windows.filter { $0.title == "DiskSweep" }.forEach { $0.close() }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuBar?.openMainWindow() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Shutdown, restart and log-out must never be blocked, so they are recognised by the
    /// reason code that macOS attaches to the quit Apple event.
    private static var isSystemShutdown: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(0x7768793F)) // 'why?'
        else { return false }
        let codes: [OSType] = [0x73687574, 0x72657374, 0x726C676F, 0x6C6F676F] // shut, rest, rlgo, logo
        return codes.contains(reason.enumCodeValue)
    }
}

@main
struct DiskSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DiskSweep", id: "main") {
            ContentView()
                .frame(minWidth: 960, idealWidth: 1100, maxWidth: .infinity,
                       minHeight: 620, idealHeight: 760, maxHeight: .infinity)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Ayarlar…")) {
                    AppNavigation.shared.request = AppNavigation.settingsPage
                    appDelegate.menuBar?.openMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
