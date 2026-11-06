import SwiftUI
import AppKit
import DiskSweepCore

@MainActor @Observable
final class ScanStore {
    struct CategoryState {
        var items: [CleanupItem] = []
        var note: String?
        var isScanning = false
        var hasScanned = false

        /// Bytes the user could actually reclaim here (protected/info items excluded).
        var reclaimableBytes: Int64 {
            items.filter(\.isSelectable).reduce(0) { $0 + ($1.size ?? 0) }
        }
    }

    var states: [String: CategoryState] = [:]
    var lastScanned: [String: Date] = [:]
    var selection: Set<String> = []
    var disk = DiskUsage.current()

    var searchText = ""

    var excludedFolders: [URL]
    private(set) var guardrail: SafetyGuard
    /// Bumped whenever the exclusion list changes so stale scan results are discarded.
    private var generation = 0

    var folderURL: URL

    var showConfirmation = false
    var showExclusions = false
    var isDeleting = false
    var deletingTitle = ""
    var deletingProgress = 0
    var deletingTotal = 0
    var results: [CleanupOutcome] = []
    var showResults = false

    // AI review
    var verdicts: [String: AIVerdict] = [:]
    var isReviewing = false
    /// Outcome of the last review (problem or summary), shown as a note until the next review.
    var reviewNote: String?

    // Whole-device scan (Smart Scan)
    var deviceProgress = DeviceScanProgress()
    @ObservationIgnored private var deviceTask: Task<Void, Never>?

    @ObservationIgnored private var folderTask: Task<Void, Never>?
    private static let excludedKey = "excludedFolderPaths"

    init() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.excludedKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        excludedFolders = saved
        guardrail = SafetyGuard(excluded: saved)
        folderURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func state(for category: CleanupCategory) -> CategoryState { states[category.id] ?? CategoryState() }
    func state(forID id: String) -> CategoryState { states[id] ?? CategoryState() }

    var isScanningAnything: Bool { states.values.contains { $0.isScanning } }

    /// Only the cleanup categories count here; the folder scanner is exploration, not cleanup.
    var totalReclaimable: Int64 {
        Catalog.all.reduce(0) { $0 + (states[$1.id]?.reclaimableBytes ?? 0) }
    }

    var selectedItems: [CleanupItem] {
        let order = Catalog.all.map(\.id) + DeviceScan.groups.map(\.id) + [FolderScan.categoryID]
        return order.flatMap { states[$0]?.items ?? [] }.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: Search

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Matches across every cleanup category (the folder scanner filters its own listing).
    var searchResults: [(item: CleanupItem, category: CleanupCategory)] {
        guard isSearching else { return [] }
        var found: [(item: CleanupItem, category: CleanupCategory)] = []
        for category in Catalog.all {
            for item in states[category.id]?.items ?? [] where item.matches(searchText, extra: category.title) {
                found.append((item, category))
            }
        }
        return found.sorted { ($0.item.size ?? 0) > ($1.item.size ?? 0) }
    }

    func filtered(_ items: [CleanupItem]) -> [CleanupItem] {
        isSearching ? items.filter { $0.matches(searchText) } : items
    }

    // MARK: Scanning

    func scanAll() {
        for category in Catalog.all { scan(category) }
        refreshDisk()
    }

    func scan(_ category: CleanupCategory) {
        guard states[category.id]?.isScanning != true else { return }
        states[category.id, default: CategoryState()].isScanning = true

        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let context = ScanContext(guardrail: guardrail, runningBundleIDs: runningIDs)
        let startedGeneration = generation

        Task {
            let outcome = await category.scan(context)
            if startedGeneration != generation {
                // Exclusions changed mid-scan: this result may show now-protected items.
                states[category.id]?.isScanning = false
                scan(category)
                return
            }
            var state = states[category.id] ?? CategoryState()
            state.items = outcome.items
            state.note = outcome.note
            state.isScanning = false
            state.hasScanned = true
            withAnimation(Motion.smooth) {
                states[category.id] = state
                lastScanned[category.id] = Date()
            }
            pruneSelection()
        }
    }

    private func pruneSelection() {
        let valid = Set(states.values.flatMap { $0.items.filter(\.isSelectable).map(\.id) })
        selection.formIntersection(valid)
    }

    // MARK: Auto refresh

    func refreshDisk() {
        let current = DiskUsage.current()
        guard current.available != disk.available || current.total != disk.total else { return }
        withAnimation(Motion.spring) { disk = current }
    }

    private func age(of id: String) -> TimeInterval {
        Date().timeIntervalSince(lastScanned[id] ?? .distantPast)
    }

    /// The project walk is expensive, so it refreshes less often.
    private func maxAge(of id: String) -> TimeInterval { id == "projects" ? 180 : 30 }

    /// Re-scans whatever the user is looking at once it is stale (quietly, no flicker).
    func refreshVisible(_ id: String?) {
        guard AppSettings.autoRefreshEnabled, !isDeleting, !isSearching, let id else { return }
        if id == FolderScan.categoryID {
            if states[id]?.isScanning != true, age(of: id) > 30 { openFolder(folderURL, quiet: true) }
        } else if let category = Catalog.all.first(where: { $0.id == id }),
                  states[id]?.isScanning != true, age(of: id) > min(maxAge(of: id), 60) {
            scan(category)
        }
    }

    /// Called when the app comes back to the foreground.
    func refreshStale() {
        guard !isDeleting else { return }
        refreshDisk()
        guard AppSettings.autoRefreshEnabled else { return }
        for category in Catalog.all where states[category.id]?.isScanning != true && age(of: category.id) > maxAge(of: category.id) {
            scan(category)
        }
        if states[FolderScan.categoryID] != nil, states[FolderScan.categoryID]?.isScanning != true,
           age(of: FolderScan.categoryID) > 30 {
            openFolder(folderURL, quiet: true)
        }
    }

    // MARK: Folder scanner

    /// `quiet` keeps the current listing on screen while it refreshes in place.
    func openFolder(_ url: URL, quiet: Bool = false) {
        folderTask?.cancel()
        let target = url.standardizedFileURL
        let sameFolder = target.path == folderURL.path
        folderURL = target
        let id = FolderScan.categoryID
        let keep = quiet && sameFolder ? states[id]?.items ?? [] : []
        let knownSizes = Dictionary(keep.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        if keep.isEmpty {
            withAnimation(Motion.smooth) {
                states[id] = CategoryState(items: [], note: nil, isScanning: true, hasScanned: false)
            }
        } else {
            states[id]?.isScanning = true
        }
        let guardrail = self.guardrail

        folderTask = Task {
            let (urls, denied) = await Task.detached { FolderScan.listChildren(of: target) }.value
            guard !Task.isCancelled else { return }

            var items = urls.map { url -> CleanupItem in
                var item = FolderScan.makeItem(url: url, size: nil, guardrail: guardrail)
                if let known = knownSizes[item.id] { item.size = known }
                return item
            }
            let note = denied ? FolderScan.accessDeniedNote : nil
            withAnimation(Motion.smooth) {
                states[id] = CategoryState(items: items, note: note, isScanning: true, hasScanned: false)
            }

            // Sizes arrive one by one; publish at most ~8 times a second.
            var lastPublish = Date()
            await withTaskGroup(of: (Int, Int64).self) { group in
                var next = 0
                while next < min(8, urls.count) {
                    let index = next
                    let child = urls[index]
                    group.addTask { (index, SizeCalculator.allocatedSize(of: child)) }
                    next += 1
                }
                while let (index, size) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    items[index].size = size
                    if Date().timeIntervalSince(lastPublish) > 0.12 {
                        states[id]?.items = items
                        lastPublish = Date()
                    }
                    if next < urls.count {
                        let nextIndex = next
                        let child = urls[nextIndex]
                        group.addTask { (nextIndex, SizeCalculator.allocatedSize(of: child)) }
                        next += 1
                    }
                }
            }
            guard !Task.isCancelled else { return }

            items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
            withAnimation(Motion.smooth) {
                states[id] = CategoryState(items: items, note: note, isScanning: false, hasScanned: true)
                lastScanned[id] = Date()
            }
            pruneSelection()
        }
    }

    func openParentFolder() {
        let parent = folderURL.deletingLastPathComponent()
        guard parent.path != folderURL.path else { return }
        openFolder(parent)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = L("Tara")
        panel.message = L("Taranacak klasörü seçin")
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    // MARK: Exclusions

    func pickExcludedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Dışla")
        panel.message = L("Hiçbir işlem yapılmayacak klasörleri seçin")
        if panel.runModal() == .OK { addExcluded(panel.urls) }
    }

    func addExcluded(_ urls: [URL]) {
        var list = excludedFolders
        for url in urls.map(\.standardizedFileURL) where !list.contains(where: { $0.path == url.path }) {
            list.append(url)
        }
        applyExclusions(list)
    }

    func removeExcluded(_ url: URL) {
        applyExclusions(excludedFolders.filter { $0.path != url.path })
    }

    private func applyExclusions(_ list: [URL]) {
        excludedFolders = list
        UserDefaults.standard.set(list.map(\.path), forKey: Self.excludedKey)
        guardrail = SafetyGuard(excluded: list)
        generation += 1
        selection.removeAll()
        scanAll()
        if states[FolderScan.categoryID] != nil { openFolder(folderURL, quiet: true) }
    }

    // MARK: Selection

    func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

    func setSelected(_ item: CleanupItem, _ on: Bool) {
        guard item.isSelectable else { return }
        if on { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func selectSafe(in items: [CleanupItem]) {
        selection.formUnion(items.filter { $0.isSelectable && $0.safety == .safe }.map(\.id))
    }

    func clearSelection(in items: [CleanupItem]) {
        selection.subtract(items.map(\.id))
    }

    func clearAllSelection() { selection.removeAll() }

    // MARK: Cleanup levels

    var allCategoryItems: [CleanupItem] {
        (Catalog.all.map(\.id) + DeviceScan.groups.map(\.id)).flatMap { states[$0]?.items ?? [] }
    }

    // MARK: Whole-device scan

    var isDeviceScanning: Bool { DeviceScan.groups.contains { states[$0.id]?.isScanning == true } }

    /// Walks the home folder for big files, old downloads, installers and stray dependency folders.
    func scanDevice() {
        deviceTask?.cancel()
        deviceProgress = DeviceScanProgress()
        for group in DeviceScan.groups {
            states[group.id] = CategoryState(items: [], note: nil, isScanning: true, hasScanned: false)
        }
        let guardrail = self.guardrail

        deviceTask = Task {
            let work = Task.detached(priority: .utility) {
                DeviceScan.scan(guardrail: guardrail) { progress in
                    Task { @MainActor [weak self] in self?.deviceProgress = progress }
                }
            }
            let items = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

            if Task.isCancelled {
                for group in DeviceScan.groups { states[group.id]?.isScanning = false }
                return
            }
            let grouped = Dictionary(grouping: items, by: \.categoryID)
            withAnimation(Motion.smooth) {
                for group in DeviceScan.groups {
                    let found = (grouped[group.id] ?? []).sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                    states[group.id] = CategoryState(items: found, note: nil, isScanning: false, hasScanned: true)
                    lastScanned[group.id] = Date()
                }
            }
            pruneSelection()
        }
    }

    func cancelDeviceScan() {
        deviceTask?.cancel()
        for group in DeviceScan.groups { states[group.id]?.isScanning = false }
    }

    /// Ticks what the level allows. With `items` only those are re-evaluated (the open page);
    /// without, every category is, and the selection is replaced.
    func applyLevel(_ level: CleanupLevel, to items: [CleanupItem]? = nil) {
        let now = Date()
        let scope = items ?? allCategoryItems
        let chosen = Set(scope.filter { level.shouldSelect($0, verdict: verdicts[$0.id], now: now) }.map(\.id))
        if items == nil {
            selection = chosen
        } else {
            selection.subtract(scope.map(\.id))
            selection.formUnion(chosen)
        }
    }

    // MARK: AI review

    var agentConfig: AgentConfig {
        let defaults = UserDefaults.standard
        let kind = AgentKind(rawValue: defaults.string(forKey: AppSettings.agentKind) ?? "") ?? .claude
        return AgentConfig(kind: kind, customCommand: defaults.string(forKey: AppSettings.agentCustomCommand) ?? "")
    }

    /// Asks the configured agent which of `items` are safe and ticks those. Only the check boxes
    /// change: nothing is deleted, and the safety guard and the confirm sheet still apply.
    func reviewWithAgent(_ items: [CleanupItem]) {
        guard !isReviewing else { return }
        let candidates = AgentReview.reviewable(items)
        guard !candidates.isEmpty else {
            reviewNote = L("İncelenecek öğe yok.")
            return
        }
        isReviewing = true
        reviewNote = nil
        let config = agentConfig
        let home = guardrail.home

        Task {
            let result = await AgentReview.run(items: candidates, config: config, home: home)
            isReviewing = false
            switch result {
            case .failure(let error):
                reviewNote = String(describing: error)
            case .success(let found):
                withAnimation(Motion.smooth) {
                    for verdict in found { verdicts[verdict.itemID] = verdict }
                    let approved = found.filter(\.safe).map(\.itemID)
                    let valid = Set(candidates.map(\.id))
                    selection.formUnion(approved.filter(valid.contains))
                    // An item the agent now rejects must not stay ticked from an earlier pass.
                    for verdict in found where !verdict.safe { selection.remove(verdict.itemID) }
                    reviewNote = L("AI \(found.count) öğeyi inceledi: \(approved.count) tanesini güvenli buldu ve işaretledi.")
                }
            }
        }
    }

    /// Mode shown in the confirm sheet and used by the cleaner.
    func effectiveMode(of item: CleanupItem) -> RemovalMode? {
        item.effectiveRemovalMode(permanentDeletion: AppSettings.permanentDeletionEnabled, home: guardrail.home)
    }

    // MARK: Deleting

    func performDeletion() async {
        let items = selectedItems
        guard !items.isEmpty, !isDeleting else { return }

        isDeleting = true
        results = []
        deletingTotal = items.count
        deletingProgress = 0

        // Uses the CURRENT guard, so exclusions are enforced even for stale items.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let cleaner = Cleaner(guardrail: guardrail,
                              permanentDeletion: AppSettings.permanentDeletionEnabled,
                              isAppRunning: { running.contains($0) })
        // Sequential on purpose: docker/simctl commands must not run concurrently.
        for item in items {
            deletingTitle = item.title
            let outcome = await cleaner.clean(item)
            results.append(outcome)
            deletingProgress += 1
        }

        let succeeded = Set(results.filter(\.succeeded).map(\.item.id))
        selection.subtract(succeeded)
        let touched = Set(results.map(\.item.categoryID))
        // Whole-device findings are not rescanned (that is a long walk): the deleted ones just disappear.
        for id in touched where DeviceScan.isDeviceCategory(id) {
            states[id]?.items.removeAll { succeeded.contains($0.id) }
        }

        isDeleting = false
        showResults = true
        for category in Catalog.all where touched.contains(category.id) { scan(category) }
        if touched.contains(FolderScan.categoryID) { openFolder(folderURL, quiet: true) }
        refreshDisk()
    }
}
