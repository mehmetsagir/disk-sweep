import AppKit
import Combine
import DiskSweepCore
import UserNotifications

@MainActor
final class LowSpaceMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private var loop: Task<Void, Never>?
    private let armedKey = "lowSpaceAlertArmed"

    func start() {
        guard loop == nil else { return }
        center.delegate = self
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func check() async {
        guard defaults.bool(forKey: "lowSpaceAlertEnabled") else { return }
        let disk = DiskUsage.current()
        let thresholdGB = defaults.object(forKey: "lowSpaceThresholdGB") == nil
            ? 20 : defaults.integer(forKey: "lowSpaceThresholdGB")
        let threshold = Int64(max(thresholdGB, 1)) * 1_000_000_000
        let armed = defaults.object(forKey: armedKey) == nil ? true : defaults.bool(forKey: armedKey)

        if !armed && LowSpacePolicy.shouldRearm(available: disk.available, total: disk.total,
                                                thresholdBytes: threshold) {
            defaults.set(true, forKey: armedKey)
        }
        guard LowSpacePolicy.shouldNotify(available: disk.available, total: disk.total,
                                          thresholdBytes: threshold, armed: armed) else { return }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let updated = await center.notificationSettings()
        guard updated.authorizationStatus == .authorized || updated.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = L("Az disk alanı")
        content.body = L("Diskte \(Format.bytes(disk.available)) boş alan kaldı. DiskSweep'i açıp alanı inceleyin.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "disk-sweep.low-space", content: content, trigger: nil)
        do {
            try await center.add(request)
            defaults.set(false, forKey: armedKey)
        } catch {
            return
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.menuBar?.openMainWindow()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
