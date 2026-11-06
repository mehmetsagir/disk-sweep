import Foundation

/// An installed app and the leftovers it keeps in ~/Library, removed together.
public struct AppUninstallPlan: Hashable, Sendable {
    public let appURL: URL
    public let bundleID: String
    public let appName: String
    public let leftovers: [URL]

    public init(appURL: URL, bundleID: String, appName: String, leftovers: [URL]) {
        self.appURL = appURL
        self.bundleID = bundleID
        self.appName = appName
        self.leftovers = leftovers
    }
}

/// Which ~/Library folders hold app leftovers, and how a child is tied to its app.
/// The same rules discover the leftovers and re-validate them right before deletion.
public enum LeftoverRules {
    /// Folders (relative to ~/Library) searched for leftovers.
    public static let folders = [
        "Caches", "Preferences", "Application Support", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Application Scripts", "Cookies",
    ]

    /// Folders where an entry may also be named after the app instead of its bundle ID.
    private static let nameMatchedFolders: Set<String> = ["Application Support", "Logs"]

    /// Shorter names are too generic to claim ("Code", "Mail").
    private static let minimumNameLength = 5

    public static func matches(entry: String, folder: String, bundleID: String, appName: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.contains(".") else { return false }

        // Preferences, saved state, cookies carry a suffix; strip it before comparing.
        var base = entry
        for suffix in [".plist", ".savedState", ".binarycookies"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if base == bundleID { return true }
        // Per-host preferences ("<id>.<UUID>.plist") and sub-identifiers ("<id>.helper").
        if base.hasPrefix(bundleID + ".") { return true }
        // Group containers are named "<team>.<bundle id>".
        if folder == "Group Containers", base.hasSuffix("." + bundleID) { return true }
        if nameMatchedFolders.contains(folder), appName.count >= minimumNameLength, entry == appName { return true }
        return false
    }

    /// Existing leftovers of an app under `library` (~/Library).
    public static func discover(library: URL, bundleID: String, appName: String) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for folder in folders {
            let directory = library.appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where matches(entry: name, folder: folder, bundleID: bundleID, appName: appName) {
                found.append(directory.appendingPathComponent(name))
            }
        }
        return found
    }
}

public enum InstalledApps {
    /// Bundle IDs that can never be uninstalled from this app.
    public static func isUninstallable(bundleID: String, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if bundleID.hasPrefix("com.apple.") { return false }
        if bundleID == ownBundleID || bundleID == "com.mehmetsagir.DiskSweep" { return false }
        return bundleID.contains(".")
    }

    public static func info(at url: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (id, name)
    }

    /// Top-level .app bundles in /Applications and ~/Applications.
    public static func applicationURLs(home: URL) -> [URL] {
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var apps: [URL] = []
        for root in roots {
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            apps += urls.filter { $0.pathExtension == "app" }
        }
        return apps
    }
}

extension Scanners {
    @Sendable static func installedApps(_ ctx: ScanContext) async -> ScanOutcome {
        let library = ctx.home.appendingPathComponent("Library")
        var plans: [AppUninstallPlan] = []
        for url in InstalledApps.applicationURLs(home: ctx.home) {
            guard let info = InstalledApps.info(at: url),
                  InstalledApps.isUninstallable(bundleID: info.bundleID) else { continue }
            let leftovers = LeftoverRules.discover(library: library, bundleID: info.bundleID, appName: info.name)
            let plan = AppUninstallPlan(appURL: url, bundleID: info.bundleID, appName: info.name, leftovers: leftovers)
            // Anything the guard would refuse never reaches the UI.
            guard (try? ctx.guardrail.validateUninstall(plan)) != nil else { continue }
            plans.append(plan)
        }

        let sizes = await SizeCalculator.concurrentMap(plans) { plan in
            ([plan.appURL] + plan.leftovers).reduce(Int64(0)) { $0 + SizeCalculator.allocatedSize(of: $1) }
        }

        var items: [CleanupItem] = []
        for (plan, size) in zip(plans, sizes) {
            let running = ctx.runningBundleIDs.contains(plan.bundleID)
            let detail: String
            if running {
                detail = L("Uygulama şu an açık — önce kapatın")
            } else if plan.leftovers.isEmpty {
                detail = L("Uygulama Çöp Kutusu'na taşınır")
            } else {
                detail = L("Uygulama ve \(plan.leftovers.count) artık dosya Çöp Kutusu'na taşınır")
            }
            items.append(CleanupItem(
                id: "apps|\(plan.appURL.path)", categoryID: "apps", title: plan.appName, detail: detail,
                size: size, safety: .caution, action: .uninstall(plan),
                modified: Scan.modificationDate(plan.appURL), browseURL: plan.appURL))
        }
        return ScanOutcome(items: items.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }
}
