import Foundation

public enum CategoryGroup: String, CaseIterable, Sendable {
    case xcode, docker, packageCaches, projects, system

    public var title: String {
        switch self {
        case .xcode: return "Xcode ve Simülatör"
        case .docker: return "Docker"
        case .packageCaches: return "Paket Önbellekleri"
        case .projects: return "Projeler (~/Developer)"
        case .system: return "Sistem ve Uygulamalar"
        }
    }
}

public struct ScanContext: Sendable {
    public let guardrail: SafetyGuard
    public let runningBundleIDs: Set<String>
    public var home: URL { guardrail.home }

    public init(guardrail: SafetyGuard, runningBundleIDs: Set<String> = []) {
        self.guardrail = guardrail
        self.runningBundleIDs = runningBundleIDs
    }
}

public struct ScanOutcome: Sendable {
    public var items: [CleanupItem]
    public var note: String?

    public init(items: [CleanupItem] = [], note: String? = nil) {
        self.items = items
        self.note = note
    }
}

public struct CleanupCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let group: CategoryGroup
    public let summary: String
    let scanner: @Sendable (ScanContext) async -> ScanOutcome

    public func scan(_ context: ScanContext) async -> ScanOutcome { await scanner(context) }
}

public enum Catalog {
    public static let all: [CleanupCategory] = [
        CleanupCategory(
            id: "xcode-derived", title: "DerivedData", symbol: "hammer", group: .xcode,
            summary: "Xcode'un derleme çıktıları. Silinince bir sonraki derlemede otomatik yeniden oluşur (ilk derleme yavaşlar). Kaynak kodunuza dokunmaz.",
            scanner: Scanners.derivedData),
        CleanupCategory(
            id: "xcode-device-support", title: "Cihaz Destek Dosyaları", symbol: "iphone", group: .xcode,
            summary: "Fiziksel cihaz bağlayınca Xcode'un indirdiği sembol dosyaları. Cihazı tekrar bağlayınca yeniden indirilir.",
            scanner: Scanners.deviceSupport),
        CleanupCategory(
            id: "xcode-archives", title: "Arşivler", symbol: "archivebox", group: .xcode,
            summary: "Dağıtım arşivleri ve dSYM dosyaları. Yayınladığınız sürümlerin crash raporlarını çözmek için gerekebilir; bu yüzden Çöp Kutusu'na taşınır.",
            scanner: Scanners.archives),
        CleanupCategory(
            id: "xcode-caches", title: "Xcode Önbellekleri", symbol: "internaldrive", group: .xcode,
            summary: "Dokümantasyon ve simülatör önbellekleri. Otomatik yeniden oluşur.",
            scanner: Scanners.xcodeCaches),
        CleanupCategory(
            id: "sim-devices", title: "Simülatörler", symbol: "ipad.and.iphone", group: .xcode,
            summary: "Simülatör cihazları ve içindeki uygulama verileri. Silinen cihaz Xcode'dan yeniden oluşturulabilir; içindeki test verileri kaybolur.",
            scanner: Scanners.simulatorDevices),
        CleanupCategory(
            id: "sim-runtimes", title: "Simülatör Runtime'ları", symbol: "square.stack.3d.up", group: .xcode,
            summary: "iOS/watchOS/tvOS simülatör sistemleri (genelde 5-9 GB). Xcode → Settings → Components'tan yeniden indirilebilir.",
            scanner: Scanners.simulatorRuntimes),

        CleanupCategory(
            id: "docker", title: "Docker", symbol: "shippingbox", group: .docker,
            summary: "Docker'ın kullanılmayan verileri. Volume'ler (veritabanı vb.) asla silinmez. Docker Desktop açık olmalı.",
            scanner: Scanners.docker),

        CleanupCategory(
            id: "pkg-caches", title: "Paket Yöneticileri", symbol: "cube", group: .packageCaches,
            summary: "npm, bun, cargo, gradle ve pnpm önbellekleri. Sonraki kurulumda gerekirse yeniden indirilir; projeleriniz bozulmaz.",
            scanner: Scanners.packageCaches),
        CleanupCategory(
            id: "dot-cache", title: "~/.cache", symbol: "folder", group: .packageCaches,
            summary: "Araçların önbellek klasörleri. Bazıları büyük modeller içerebilir (ör. huggingface) ve yeniden indirmek uzun sürebilir.",
            scanner: Scanners.dotCache),

        CleanupCategory(
            id: "projects", title: "Proje Artıkları", symbol: "folder.badge.gearshape", group: .projects,
            summary: "~/Developer altındaki node_modules, .next, .build, target, Pods gibi yeniden üretilebilir klasörler. Yalnızca git'te ignore edilenler \"Güvenli\" sayılır.",
            scanner: Scanners.projectArtifacts),

        CleanupCategory(
            id: "app-caches", title: "Uygulama Önbellekleri", symbol: "internaldrive", group: .system,
            summary: "~/Library/Caches altındaki uygulama önbellekleri. Uygulamalar gerekince yeniden üretir. Açık uygulamaların önbelleği \"Dikkat\" olarak işaretlenir.",
            scanner: Scanners.appCaches),
        CleanupCategory(
            id: "logs", title: "Kayıtlar (Logs)", symbol: "doc.plaintext", group: .system,
            summary: "~/Library/Logs altındaki günlük ve çökme raporları.",
            scanner: Scanners.logs),
        CleanupCategory(
            id: "trash", title: "Çöp Kutusu", symbol: "trash", group: .system,
            summary: "Zaten sildiğiniz ama yer kaplamaya devam eden dosyalar.",
            scanner: Scanners.trash),
        CleanupCategory(
            id: "ios-backups", title: "iPhone/iPad Yedekleri", symbol: "externaldrive", group: .system,
            summary: "Mac'e alınmış cihaz yedekleri. Geri getirilemez olabilir; bu yüzden Çöp Kutusu'na taşınır.",
            scanner: Scanners.iosBackups),
    ]
}

// MARK: - Scanner helpers

enum Scan {
    static let junkNames: Set<String> = [".DS_Store", ".localized", ".com.apple.timemachine.donotpresent"]

    static let fullDiskAccessNote =
        "Erişim reddedildi. Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi'ne DiskSweep'i ekleyip uygulamayı yeniden başlatın."

    struct Entry: Sendable {
        let url: URL
        let title: String
        let detail: String
        let safety: SafetyLevel
        let mode: RemovalMode
        var size: Int64?
    }

    static func children(of directory: URL) -> (urls: [URL], denied: Bool) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
            return (urls.filter { !junkNames.contains($0.lastPathComponent) }, false)
        } catch {
            let ns = error as NSError
            let denied = (ns.domain == NSCocoaErrorDomain && (ns.code == 257 || ns.code == 513))
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13))
            return ([], denied)
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Validates, measures and sorts entries into items. Entries rejected by the
    /// safety guard are silently dropped, so they can never appear in the UI.
    static func buildItems(categoryID: String, entries: [Entry], ctx: ScanContext, minimumSize: Int64 = 1) async -> [CleanupItem] {
        let valid = entries.filter { (try? ctx.guardrail.validateRemoval(of: $0.url)) != nil }
        let sizes = await SizeCalculator.concurrentMap(valid.map(\.url)) { SizeCalculator.allocatedSize(of: $0) }
        var items: [CleanupItem] = []
        for (entry, measured) in zip(valid, sizes) {
            let size = entry.size ?? measured
            guard size >= minimumSize else { continue }
            items.append(CleanupItem(
                id: "\(categoryID)|\(entry.url.path)", categoryID: categoryID,
                title: entry.title, detail: entry.detail, size: size, safety: entry.safety,
                action: .removePath(entry.url, entry.mode), modified: modificationDate(entry.url)))
        }
        return items.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    static func childrenOutcome(categoryID: String, directory: URL, ctx: ScanContext,
                                entry: (URL) -> Entry?) async -> ScanOutcome {
        let (urls, denied) = children(of: directory)
        let items = await buildItems(categoryID: categoryID, entries: urls.compactMap(entry), ctx: ctx)
        return ScanOutcome(items: items, note: denied ? fullDiskAccessNote : nil)
    }
}

// MARK: - Scanners

enum Scanners {
    // MARK: Xcode

    @Sendable static func derivedData(_ ctx: ScanContext) async -> ScanOutcome {
        let dir = ctx.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        var outcome = await Scan.childrenOutcome(categoryID: "xcode-derived", directory: dir, ctx: ctx) { url in
            Scan.Entry(url: url, title: stripDerivedDataHash(url.lastPathComponent),
                       detail: "Derleme çıktısı — yeniden derlemede otomatik oluşur",
                       safety: .safe, mode: .permanent)
        }
        if ctx.runningBundleIDs.contains("com.apple.dt.Xcode") {
            outcome.note = "Xcode şu an açık. Açık projelerin DerivedData'sını silmek bir sonraki derlemeyi uzatır; mümkünse Xcode'u kapatın."
        }
        return outcome
    }

    @Sendable static func deviceSupport(_ ctx: ScanContext) async -> ScanOutcome {
        var entries: [Scan.Entry] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let dir = ctx.home.appendingPathComponent("Library/Developer/Xcode/\(platform) DeviceSupport")
            for url in Scan.children(of: dir).urls {
                entries.append(Scan.Entry(
                    url: url, title: "\(platform) · \(url.lastPathComponent)",
                    detail: "Cihaz bağlanınca yeniden indirilir", safety: .safe, mode: .permanent))
            }
        }
        return ScanOutcome(items: await Scan.buildItems(categoryID: "xcode-device-support", entries: entries, ctx: ctx))
    }

    @Sendable static func archives(_ ctx: ScanContext) async -> ScanOutcome {
        let dir = ctx.home.appendingPathComponent("Library/Developer/Xcode/Archives")
        return await Scan.childrenOutcome(categoryID: "xcode-archives", directory: dir, ctx: ctx) { url in
            Scan.Entry(url: url, title: url.lastPathComponent,
                       detail: "Yayın arşivleri ve dSYM'ler — Çöp Kutusu'na taşınır",
                       safety: .caution, mode: .trash)
        }
    }

    @Sendable static func xcodeCaches(_ ctx: ScanContext) async -> ScanOutcome {
        let entries = [
            Scan.Entry(url: ctx.home.appendingPathComponent("Library/Developer/Xcode/DocumentationCache"),
                       title: "Dokümantasyon önbelleği", detail: "Xcode yeniden oluşturur",
                       safety: .safe, mode: .permanent),
            Scan.Entry(url: ctx.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
                       title: "Simülatör önbelleği", detail: "Simülatör yeniden oluşturur",
                       safety: .safe, mode: .permanent),
        ]
        return ScanOutcome(items: await Scan.buildItems(categoryID: "xcode-caches", entries: entries, ctx: ctx))
    }

    @Sendable static func simulatorDevices(_ ctx: ScanContext) async -> ScanOutcome {
        let result = await Shell.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "-j"], timeout: 30)
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else {
            return ScanOutcome(note: "simctl okunamadı (Xcode kurulu mu?)")
        }

        let devicesRoot = ctx.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        var items: [CleanupItem] = []
        var unavailableBytes: Int64 = 0
        var unavailableCount = 0
        let minimumSize: Int64 = 50_000_000

        for (runtimeKey, devices) in byRuntime {
            let runtimeName = readableRuntimeName(runtimeKey)
            for device in devices {
                guard let udidText = device["udid"] as? String, let udid = UUID(uuidString: udidText) else { continue }
                let name = device["name"] as? String ?? udidText
                let size: Int64
                if let reported = device["dataPathSize"] as? Int {
                    size = Int64(reported)
                } else {
                    size = SizeCalculator.allocatedSize(of: devicesRoot.appendingPathComponent(udidText))
                }
                let available = device["isAvailable"] as? Bool ?? true
                let booted = (device["state"] as? String) == "Booted"

                if !available {
                    unavailableBytes += size
                    unavailableCount += 1
                    continue
                }
                guard size >= minimumSize else { continue }
                items.append(CleanupItem(
                    id: "sim-devices|\(udidText)", categoryID: "sim-devices",
                    title: name, detail: booted ? "\(runtimeName) · Şu an çalışıyor" : "\(runtimeName) · uygulama verileri silinir",
                    size: size, safety: booted ? .protected : .caution,
                    action: booted ? .informational : .run(.simctlDeleteDevice(udid))))
            }
        }
        items.sort { ($0.size ?? 0) > ($1.size ?? 0) }

        if unavailableCount > 0 {
            items.insert(CleanupItem(
                id: "sim-devices|unavailable", categoryID: "sim-devices",
                title: "Kullanılamayan simülatörler (\(unavailableCount))",
                detail: "Silinmiş runtime'lara ait artık cihazlar", size: unavailableBytes,
                safety: .safe, action: .run(.simctlDeleteUnavailable)), at: 0)
        }
        return ScanOutcome(items: items, note: "50 MB'tan küçük simülatörler gizlendi.")
    }

    @Sendable static func simulatorRuntimes(_ ctx: ScanContext) async -> ScanOutcome {
        let result = await Shell.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: [String: Any]] else {
            return ScanOutcome(note: "Runtime listesi okunamadı.")
        }
        let isoParser = ISO8601DateFormatter()
        var items: [CleanupItem] = []
        for (idText, runtime) in json {
            guard let id = UUID(uuidString: idText), (runtime["deletable"] as? Bool) == true else { continue }
            let identifier = runtime["runtimeIdentifier"] as? String ?? idText
            let build = runtime["build"] as? String ?? ""
            let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let lastUsed = (runtime["lastUsedAt"] as? String).flatMap { isoParser.date(from: $0) }
            items.append(CleanupItem(
                id: "sim-runtimes|\(idText)", categoryID: "sim-runtimes",
                title: "\(readableRuntimeName(identifier)) (\(build))",
                detail: "Yeniden indirilebilir. Bu runtime'ı kullanan simülatörler kullanılamaz hale gelir.",
                size: size, safety: .caution, action: .run(.simctlDeleteRuntime(id)), modified: lastUsed))
        }
        items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        return ScanOutcome(items: items)
    }

    // MARK: Docker

    @Sendable static func docker(_ ctx: ScanContext) async -> ScanOutcome {
        var items: [CleanupItem] = []

        // Docker Desktop's VM disk: shown for information, never removable.
        let vms = ctx.home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms")
        let (vmDirs, denied) = Scan.children(of: vms)
        for dir in vmDirs {
            let raw = dir.appendingPathComponent("data/Docker.raw")
            guard FileManager.default.fileExists(atPath: raw.path) else { continue }
            items.append(CleanupItem(
                id: "docker|raw", categoryID: "docker", title: "Docker disk imajı (Docker.raw)",
                detail: "Docker'ın tüm verisi burada. Asla silinmez. Küçültmek için aşağıdaki temizliği çalıştırın; gerekirse Docker Desktop → Settings → Resources'tan disk boyutunu azaltın.",
                size: SizeCalculator.allocatedSize(of: raw), safety: .protected, action: .informational))
        }

        let probe = await Shell.shell("docker info --format '{{.ServerVersion}}'", timeout: 10)
        guard probe.succeeded else {
            return ScanOutcome(items: items, note: denied
                ? Scan.fullDiskAccessNote
                : "Docker çalışmıyor veya kurulu değil. Temizlik için Docker Desktop'ı açın.")
        }

        let df = await Shell.shell("docker system df --format '{{json .}}'", timeout: 60)
        for line in df.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("{") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["Type"] as? String else { continue }
            let reclaimable = (row["Reclaimable"] as? String).flatMap(SizeCalculator.parseDockerSize) ?? 0
            let total = (row["Size"] as? String).flatMap(SizeCalculator.parseDockerSize) ?? 0

            switch type {
            case "Build Cache" where reclaimable > 0:
                items.append(CleanupItem(
                    id: "docker|build-cache", categoryID: "docker", title: "Build cache",
                    detail: "Derleme önbelleği — sonraki build'ler biraz yavaşlar", size: reclaimable,
                    safety: .safe, action: .run(.dockerBuilderPrune)))
            case "Images" where reclaimable > 0:
                items.append(CleanupItem(
                    id: "docker|images", categoryID: "docker", title: "Kullanılmayan imajlar",
                    detail: "Hiçbir container'ın kullanmadığı imajlar — gerekince yeniden çekilir", size: reclaimable,
                    safety: .caution, action: .run(.dockerImagePruneAll)))
            case "Containers" where reclaimable > 0:
                items.append(CleanupItem(
                    id: "docker|containers", categoryID: "docker", title: "Durdurulmuş container'lar",
                    detail: "Container içindeki (volume dışı) veriler kaybolur", size: reclaimable,
                    safety: .caution, action: .run(.dockerContainerPrune)))
            case "Local Volumes" where total > 0:
                items.append(CleanupItem(
                    id: "docker|volumes", categoryID: "docker", title: "Volume'ler",
                    detail: "Veritabanı gibi kalıcı veri içerebilir. Güvenlik için bu uygulamadan silinemez.",
                    size: total, safety: .protected, action: .informational))
            default:
                break
            }
        }
        return ScanOutcome(items: items)
    }

    // MARK: Package manager caches

    @Sendable static func packageCaches(_ ctx: ScanContext) async -> ScanOutcome {
        let home = ctx.home
        let entries = [
            Scan.Entry(url: home.appendingPathComponent(".npm/_cacache"), title: "npm önbelleği",
                       detail: "Paketler gerekince yeniden indirilir", safety: .safe, mode: .permanent),
            Scan.Entry(url: home.appendingPathComponent(".bun/install/cache"), title: "bun önbelleği",
                       detail: "Paketler gerekince yeniden indirilir", safety: .safe, mode: .permanent),
            Scan.Entry(url: home.appendingPathComponent(".cargo/registry/cache"), title: "cargo önbelleği",
                       detail: "Crate'ler gerekince yeniden indirilir (ağ gerekir)", safety: .caution, mode: .permanent),
            Scan.Entry(url: home.appendingPathComponent(".gradle/caches"), title: "Gradle önbelleği",
                       detail: "Bağımlılıklar yeniden indirilir; ilk build uzun sürer", safety: .caution, mode: .permanent),
        ]
        var items = await Scan.buildItems(categoryID: "pkg-caches", entries: entries, ctx: ctx)

        // pnpm: only unreferenced packages are pruned, so the freed size is unknown.
        let pnpmStore = home.appendingPathComponent("Library/pnpm/store")
        if FileManager.default.fileExists(atPath: pnpmStore.path) {
            let total = SizeCalculator.allocatedSize(of: pnpmStore)
            items.append(CleanupItem(
                id: "pkg-caches|pnpm", categoryID: "pkg-caches", title: "pnpm store (kullanılmayan paketler)",
                detail: "`pnpm store prune`: yalnızca hiçbir projenin kullanmadığı paketleri siler. Store toplamı \(Format.bytes(total)); kazanç değişken.",
                size: nil, safety: .safe, action: .run(.pnpmStorePrune)))
        }
        return ScanOutcome(items: items)
    }

    @Sendable static func dotCache(_ ctx: ScanContext) async -> ScanOutcome {
        await Scan.childrenOutcome(
            categoryID: "dot-cache", directory: ctx.home.appendingPathComponent(".cache"), ctx: ctx
        ) { url in
            Scan.Entry(url: url, title: url.lastPathComponent,
                       detail: "Araç önbelleği — yeniden indirme/üretme gerekebilir",
                       safety: .caution, mode: .permanent)
        }
    }

    // MARK: Projects

    @Sendable static func projectArtifacts(_ ctx: ScanContext) async -> ScanOutcome {
        let root = ctx.home.appendingPathComponent("Developer")
        let excluded = ctx.guardrail.excludedPaths
        let found = await Task.detached(priority: .utility) { findArtifacts(in: root, excluded: excluded) }.value
        let classified = await SizeCalculator.concurrentMap(found) { url in
            await classifyArtifact(url)
        }

        let rootPath = root.path + "/"
        var entries: [Scan.Entry] = []
        for (url, verdict) in zip(found, classified) {
            let project = url.deletingLastPathComponent().path.replacingOccurrences(of: rootPath, with: "")
            entries.append(Scan.Entry(
                url: url, title: project, detail: "\(url.lastPathComponent) — \(verdict.reason)",
                safety: verdict.safety, mode: verdict.mode))
        }
        let items = await Scan.buildItems(categoryID: "projects", entries: entries, ctx: ctx, minimumSize: 1_000_000)
        return ScanOutcome(items: items, note: items.isEmpty ? nil : "1 MB'tan küçük klasörler gizlendi.")
    }

    /// Caches that hold tools which must be re-installed by hand after removal.
    static let browserBinaryCaches: Set<String> = ["ms-playwright", "puppeteer", "Cypress"]

    static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"]

    static func findArtifacts(in root: URL, excluded: [String] = []) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in true }) else { return [] }

        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 8 { enumerator.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent

            if name == ".git" || name == ".hg" { enumerator.skipDescendants(); continue }
            if excluded.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard ProjectArtifacts.names.contains(name) else { continue }

            enumerator.skipDescendants() // never walk into an artifact
            if ProjectArtifacts.virtualEnvNames.contains(name) {
                if fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) { found.append(url) }
            } else if let markers = ProjectArtifacts.siblingMarkers[name] {
                let parent = url.deletingLastPathComponent()
                if markers.contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                    found.append(url)
                }
            }
        }
        return found
    }

    struct ArtifactVerdict: Sendable {
        let safety: SafetyLevel
        let mode: RemovalMode
        let reason: String
    }

    static func classifyArtifact(_ url: URL) async -> ArtifactVerdict {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()

        if ProjectArtifacts.virtualEnvNames.contains(name) {
            return ArtifactVerdict(safety: .caution, mode: .trash,
                                   reason: "Python sanal ortamı — Çöp Kutusu'na taşınır")
        }

        let ignoreCheck = await Shell.run(
            executable: "/usr/bin/git", arguments: ["-C", parent.path, "check-ignore", "-q", "--", name], timeout: 10)
        let ignored: Bool? = ignoreCheck.timedOut ? nil : (ignoreCheck.status == 0 ? true : (ignoreCheck.status == 1 ? false : nil))

        if name == "node_modules" {
            let hasLock = lockfiles.contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
            if ignored == true && hasLock {
                return ArtifactVerdict(safety: .safe, mode: .permanent, reason: "lockfile var, git'te ignore — kurulumla geri gelir")
            }
            let why = !hasLock ? "lockfile yok" : (ignored == nil ? "git deposu değil" : "git'te ignore edilmemiş")
            return ArtifactVerdict(safety: .caution, mode: .trash, reason: "\(why) — Çöp Kutusu'na taşınır")
        }
        if ignored == true {
            return ArtifactVerdict(safety: .safe, mode: .permanent, reason: "git'te ignore — yeniden üretilir")
        }
        let why = ignored == nil ? "git deposu değil" : "git'te ignore edilmemiş (takipli dosya olabilir)"
        return ArtifactVerdict(safety: .caution, mode: .trash, reason: "\(why) — Çöp Kutusu'na taşınır")
    }

    // MARK: System

    @Sendable static func appCaches(_ ctx: ScanContext) async -> ScanOutcome {
        let dir = ctx.home.appendingPathComponent("Library/Caches")
        return await Scan.childrenOutcome(categoryID: "app-caches", directory: dir, ctx: ctx) { url in
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple."), name != "com.apple.dt.Xcode" { return nil }
            if ctx.runningBundleIDs.contains(name) {
                return Scan.Entry(url: url, title: name, detail: "Uygulama şu an açık — önce kapatın",
                                  safety: .caution, mode: .permanent)
            }
            if browserBinaryCaches.contains(name) {
                return Scan.Entry(url: url, title: name,
                                  detail: "Tarayıcı binary'leri — silinirse ilgili araç (ör. `playwright install`) yeniden kurulana kadar testler çalışmaz",
                                  safety: .caution, mode: .permanent)
            }
            return Scan.Entry(url: url, title: name, detail: "Uygulama gerekince yeniden üretir",
                              safety: .safe, mode: .permanent)
        }
    }

    @Sendable static func logs(_ ctx: ScanContext) async -> ScanOutcome {
        await Scan.childrenOutcome(
            categoryID: "logs", directory: ctx.home.appendingPathComponent("Library/Logs"), ctx: ctx
        ) { url in
            Scan.Entry(url: url, title: url.lastPathComponent, detail: "Günlük / çökme raporu",
                       safety: .safe, mode: .permanent)
        }
    }

    @Sendable static func trash(_ ctx: ScanContext) async -> ScanOutcome {
        await Scan.childrenOutcome(
            categoryID: "trash", directory: ctx.home.appendingPathComponent(".Trash"), ctx: ctx
        ) { url in
            Scan.Entry(url: url, title: url.lastPathComponent, detail: "Çöp Kutusu'nda — kalıcı olarak silinir",
                       safety: .safe, mode: .permanent)
        }
    }

    @Sendable static func iosBackups(_ ctx: ScanContext) async -> ScanOutcome {
        let dir = ctx.home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        return await Scan.childrenOutcome(categoryID: "ios-backups", directory: dir, ctx: ctx) { url in
            var title = url.lastPathComponent
            var detail = "Cihaz yedeği — Çöp Kutusu'na taşınır"
            let plist = url.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: plist),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let device = info["Device Name"] as? String { title = device }
                if let date = info["Last Backup Date"] as? Date {
                    detail = "Son yedek: \(date.formatted(date: .abbreviated, time: .omitted)) — Çöp Kutusu'na taşınır"
                }
            }
            return Scan.Entry(url: url, title: title, detail: detail, safety: .caution, mode: .trash)
        }
    }

    // MARK: Naming helpers

    /// "MyApp-bcdefghijklmnopqrstuvwxyzabc" -> "MyApp"
    static func stripDerivedDataHash(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let suffix = name[name.index(after: dash)...]
        return suffix.count == 28 && suffix.allSatisfy({ $0.isLetter && $0.isLowercase }) ? String(name[..<dash]) : name
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"
    static func readableRuntimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return last }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Turkish relative time ("3 dakika önce"); "az önce" for the last few seconds.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 5 { return "az önce" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
