import Foundation

public struct DeviceGroup: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
}

public struct DeviceScanProgress: Sendable, Equatable {
    public var filesVisited = 0
    /// Bytes of everything found so far.
    public var foundBytes: Int64 = 0
    public var currentPath = ""
    public var stage = ""

    public init() {}
}

/// Walks the whole home folder for things the curated categories do not cover: huge files, old
/// downloads, installers and dependency folders anywhere. Everything it finds can only be moved to
/// the Trash, and each item has to pass `SafetyGuard.validateUserTrash`.
public enum DeviceScan {
    public static let largeID = "device-large"
    public static let downloadsID = "device-downloads"
    public static let installersID = "device-installers"
    public static let dependenciesID = "device-deps"

    public static let groups: [DeviceGroup] = [
        DeviceGroup(id: largeID, title: L("Büyük Dosyalar"), symbol: "doc.zipper",
                    summary: L("Kullanıcı klasörlerindeki çok büyük dosyalar (film, disk imajı, arşiv…). Kişisel veri olabilir; her biri Çöp Kutusu'na taşınır ve AI incelemesi önerilir.")),
        DeviceGroup(id: downloadsID, title: L("Eski İndirilenler"), symbol: "arrow.down.circle",
                    summary: L("İndirilenler klasöründe aylardır dokunulmamış dosyalar. Çöp Kutusu'na taşınır.")),
        DeviceGroup(id: installersID, title: L("Yükleyiciler ve Disk İmajları"), symbol: "opticaldisc",
                    summary: L(".dmg, .pkg, .iso gibi kurulum dosyaları. Kurulduktan sonra gerekmez, gerekirse yeniden indirilir.")),
        DeviceGroup(id: dependenciesID, title: L("Diğer Proje Artıkları"), symbol: "shippingbox.and.arrow.backward",
                    summary: L("~/Developer dışında kalan node_modules, Pods, .venv gibi yeniden kurulabilir bağımlılık klasörleri.")),
    ]

    public static func isDeviceCategory(_ id: String) -> Bool { id.hasPrefix("device-") }

    public struct Config: Sendable {
        public var largeFileThreshold: Int64 = 200 * 1024 * 1024
        public var installerThreshold: Int64 = 20 * 1024 * 1024
        public var oldDownloadAge: TimeInterval = 60 * 24 * 3600
        public var maximumItemsPerGroup = 200
        public init() {}
    }

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "xip", "msi"]
    private static let cloudFolderNames: Set<String> = [
        "Dropbox", "Google Drive", "GoogleDrive", "Box", "iCloud Drive", "Creative Cloud Files", "pCloud Drive",
    ]
    private static let skippedTopLevel: Set<String> = ["Library", "Downloads", "Applications"]

    /// The enumerator reports "/private/var/..." where `SafetyGuard.home` (symlinks resolved the
    /// Foundation way) says "/var/...". Compare both in the short form.
    private static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Artifact folders that count even though their name starts with a dot.
    private static func isArtifact(_ url: URL, name: String) -> Bool {
        let fm = FileManager.default
        if ProjectArtifacts.virtualEnvNames.contains(name) {
            return fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
        }
        guard let markers = ProjectArtifacts.siblingMarkers[name] else { return false }
        let parent = url.deletingLastPathComponent()
        return markers.contains { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
    }

    /// Blocking: run it off the main thread. Honors task cancellation (returns nothing when cancelled).
    public static func scan(guardrail: SafetyGuard, config: Config = Config(),
                            progress: @escaping @Sendable (DeviceScanProgress) -> Void) -> [CleanupItem] {
        let home = guardrail.home
        let fm = FileManager.default
        let developerPath = home.appendingPathComponent("Developer").path
        let downloadsURL = home.appendingPathComponent("Downloads")

        var state = DeviceScanProgress()
        state.stage = L("Dosyalar geziliyor…")
        var lastReport = Date.distantPast
        func report(_ path: String, force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = now
            state.currentPath = path.replacingOccurrences(of: home.path, with: "~")
            progress(state)
        }

        func isExcluded(_ path: String) -> Bool {
            guardrail.excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        struct Candidate { let url: URL; let group: String; var size: Int64; let modified: Date?; let isFolder: Bool; let reason: String }
        var candidates: [Candidate] = []
        var dependencyFolders: [URL] = []

        // 1. Walk the home folder.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        if let walker = fm.enumerator(at: home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                      errorHandler: { _, _ in true }) {
            for case let url as URL in walker {
                if Task.isCancelled { return [] }
                let name = url.lastPathComponent
                let path = normalized(url.path)
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { continue }
                state.filesVisited += 1
                report(path)

                if values.isDirectory == true {
                    if isExcluded(path) { walker.skipDescendants(); continue }
                    if walker.level == 1, skippedTopLevel.contains(name) { walker.skipDescendants(); continue }
                    if walker.level == 1, cloudFolderNames.contains(name) || name.hasPrefix("OneDrive") {
                        walker.skipDescendants(); continue
                    }
                    if isArtifact(url, name: name) {
                        // Inside ~/Developer the "Project Artifacts" category already owns these.
                        if !path.hasPrefix(developerPath + "/") { dependencyFolders.append(url) }
                        walker.skipDescendants(); continue
                    }
                    if name.hasPrefix(".") { walker.skipDescendants(); continue }
                    continue
                }

                let size = Int64(values.totalFileAllocatedSize ?? 0)
                if installerExtensions.contains(url.pathExtension.lowercased()), size >= config.installerThreshold {
                    candidates.append(Candidate(url: url, group: installersID, size: size, modified: values.contentModificationDate,
                                                isFolder: false, reason: L("Yükleyici — gerekirse yeniden indirilir")))
                    state.foundBytes += size
                } else if size >= config.largeFileThreshold {
                    candidates.append(Candidate(url: url, group: largeID, size: size, modified: values.contentModificationDate,
                                                isFolder: false, reason: L("Büyük dosya")))
                    state.foundBytes += size
                }
            }
        }

        // 2. Downloads: only its direct children are offered, as whole items.
        state.stage = L("İndirilenler inceleniyor…")
        report(downloadsURL.path, force: true)
        let downloads = (try? fm.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for url in downloads where !Scan.junkNames.contains(url.lastPathComponent) {
            if Task.isCancelled { return [] }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true || isExcluded(url.path) || url.lastPathComponent.hasPrefix(".") { continue }
            let isFolder = values?.isDirectory == true
            let size = SizeCalculator.allocatedSize(of: url)
            let modified = values?.contentModificationDate
            let isInstaller = installerExtensions.contains(url.pathExtension.lowercased()) && size >= config.installerThreshold
            let age = modified.map { Date().timeIntervalSince($0) } ?? 0
            if isInstaller {
                candidates.append(Candidate(url: url, group: installersID, size: size, modified: modified, isFolder: isFolder,
                                            reason: L("Yükleyici — gerekirse yeniden indirilir")))
            } else if age > config.oldDownloadAge {
                let days = Int(age / 86400)
                candidates.append(Candidate(url: url, group: downloadsID, size: size, modified: modified, isFolder: isFolder,
                                            reason: L("\(days) gündür dokunulmamış")))
            } else if size >= config.largeFileThreshold {
                candidates.append(Candidate(url: url, group: largeID, size: size, modified: modified, isFolder: isFolder,
                                            reason: L("Büyük dosya")))
            } else { continue }
            state.foundBytes += size
        }

        // 3. Size the dependency folders (they were not walked).
        state.stage = L("Boyutlar hesaplanıyor…")
        for url in dependencyFolders {
            if Task.isCancelled { return [] }
            report(url.path, force: true)
            let size = SizeCalculator.allocatedSize(of: url)
            guard size > 0 else { continue }
            candidates.append(Candidate(url: url, group: dependenciesID, size: size,
                                        modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                                        isFolder: true, reason: L("Bağımlılık klasörü — kurulumla geri gelir")))
            state.foundBytes += size
        }
        report("", force: true)

        // 4. Only what the safety guard accepts becomes an item.
        var perGroup: [String: [CleanupItem]] = [:]
        for candidate in candidates {
            guard (try? guardrail.validateUserTrash(of: candidate.url)) != nil else { continue }
            let parent = candidate.url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
            perGroup[candidate.group, default: []].append(CleanupItem(
                id: "\(candidate.group)|\(candidate.url.path)", categoryID: candidate.group,
                title: candidate.url.lastPathComponent, detail: "\(parent) — \(candidate.reason)",
                size: candidate.size, safety: .caution, action: .trashUserSelected(candidate.url),
                modified: candidate.modified, browseURL: candidate.url, isFolder: candidate.isFolder))
        }
        return perGroup.values.flatMap { items in
            Array(items.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(config.maximumItemsPerGroup))
        }
    }
}
