import XCTest
@testable import DiskSweepCore

final class LeftoverRulesTests: XCTestCase {
    func testMatchesBundleIDVariants() {
        let id = "com.example.Tool"
        XCTAssertTrue(LeftoverRules.matches(entry: id, folder: "Caches", bundleID: id, appName: "Tool"))
        XCTAssertTrue(LeftoverRules.matches(entry: "\(id).plist", folder: "Preferences", bundleID: id, appName: "Tool"))
        XCTAssertTrue(LeftoverRules.matches(entry: "\(id).savedState", folder: "Saved Application State", bundleID: id, appName: "Tool"))
        XCTAssertTrue(LeftoverRules.matches(entry: "\(id).helper", folder: "Containers", bundleID: id, appName: "Tool"))
        XCTAssertTrue(LeftoverRules.matches(entry: "ABCDE12345.\(id)", folder: "Group Containers", bundleID: id, appName: "Tool"))
    }

    func testRejectsLookAlikes() {
        let id = "com.example.Tool"
        XCTAssertFalse(LeftoverRules.matches(entry: "com.example.Tooling", folder: "Caches", bundleID: id, appName: "Tool"))
        XCTAssertFalse(LeftoverRules.matches(entry: "com.example", folder: "Caches", bundleID: id, appName: "Tool"))
        XCTAssertFalse(LeftoverRules.matches(entry: "Tool", folder: "Caches", bundleID: id, appName: "Tool"))
        XCTAssertFalse(LeftoverRules.matches(entry: "x.\(id)", folder: "Caches", bundleID: id, appName: "Tool"))
        XCTAssertFalse(LeftoverRules.matches(entry: id, folder: "Caches", bundleID: "nodots", appName: "Tool"))
    }

    func testNameMatchOnlyInSupportAndLogsAndNotForShortNames() {
        let id = "com.example.Sketcher"
        XCTAssertTrue(LeftoverRules.matches(entry: "Sketcher", folder: "Application Support", bundleID: id, appName: "Sketcher"))
        XCTAssertTrue(LeftoverRules.matches(entry: "Sketcher", folder: "Logs", bundleID: id, appName: "Sketcher"))
        XCTAssertFalse(LeftoverRules.matches(entry: "Sketcher", folder: "Preferences", bundleID: id, appName: "Sketcher"))
        XCTAssertFalse(LeftoverRules.matches(entry: "Mail", folder: "Application Support", bundleID: "com.example.m", appName: "Mail"))
    }
}

final class UninstallGuardTests: XCTestCase {
    private var home: URL!
    private var guardrail: SafetyGuard!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        for dir in ["Applications", "Library/Caches", "Library/Preferences", "Library/Application Support", "Documents"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        guardrail = SafetyGuard(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func makeApp(_ name: String, bundleID: String, in folder: String = "Applications") throws -> URL {
        let app = home.appendingPathComponent("\(folder)/\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func plan(_ app: URL, bundleID: String, name: String, leftovers: [URL] = []) -> AppUninstallPlan {
        AppUninstallPlan(appURL: app, bundleID: bundleID, appName: name, leftovers: leftovers)
    }

    func testApprovesAppAndMatchingLeftovers() throws {
        let app = try makeApp("Sketcher", bundleID: "com.example.Sketcher")
        let cache = home.appendingPathComponent("Library/Caches/com.example.Sketcher")
        let prefs = home.appendingPathComponent("Library/Preferences/com.example.Sketcher.plist")
        let support = home.appendingPathComponent("Library/Application Support/Sketcher")
        let result = try guardrail.validateUninstall(plan(app, bundleID: "com.example.Sketcher", name: "Sketcher",
                                                          leftovers: [cache, prefs, support]))
        XCTAssertEqual(result.leftovers.count, 3)
    }

    func testDropsUnrelatedLeftoversButKeepsTheApp() throws {
        let app = try makeApp("Sketcher", bundleID: "com.example.Sketcher")
        let other = home.appendingPathComponent("Library/Caches/com.other.App")
        let documents = home.appendingPathComponent("Documents/Sketcher")
        let result = try guardrail.validateUninstall(plan(app, bundleID: "com.example.Sketcher", name: "Sketcher",
                                                          leftovers: [other, documents]))
        XCTAssertTrue(result.leftovers.isEmpty)
    }

    func testRefusesAppleAndWrongBundleID() throws {
        let apple = try makeApp("Safari", bundleID: "com.apple.Safari")
        XCTAssertThrowsError(try guardrail.validateUninstall(plan(apple, bundleID: "com.apple.Safari", name: "Safari")))
        let app = try makeApp("Sketcher", bundleID: "com.example.Sketcher")
        XCTAssertThrowsError(try guardrail.validateUninstall(plan(app, bundleID: "com.example.Forged", name: "Sketcher")))
    }

    func testRefusesAppsOutsideApplicationsAndOwnApp() throws {
        let stray = try makeApp("Stray", bundleID: "com.example.Stray", in: "Documents")
        XCTAssertThrowsError(try guardrail.validateUninstall(plan(stray, bundleID: "com.example.Stray", name: "Stray")))
        let own = try makeApp("DiskSweep", bundleID: "com.mehmetsagir.DiskSweep")
        XCTAssertThrowsError(try guardrail.validateUninstall(plan(own, bundleID: "com.mehmetsagir.DiskSweep", name: "DiskSweep")))
    }

    func testRespectsExcludedFolders() throws {
        let app = try makeApp("Sketcher", bundleID: "com.example.Sketcher")
        let excluding = guardrail.withExcluded([app])
        XCTAssertThrowsError(try excluding.validateUninstall(plan(app, bundleID: "com.example.Sketcher", name: "Sketcher")))
    }

    func testCleanerTrashesAppAndRefusesRunningApp() async throws {
        let app = try makeApp("Sketcher", bundleID: "com.example.Sketcher")
        let item = CleanupItem(id: "apps|x", categoryID: "apps", title: "Sketcher", detail: "", size: 10,
                               safety: .caution, action: .uninstall(plan(app, bundleID: "com.example.Sketcher", name: "Sketcher")))

        let running = Cleaner(guardrail: guardrail, isAppRunning: { _ in true })
        let refused = await running.clean(item)
        XCTAssertFalse(refused.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }
}

final class RemovalModeTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func item(_ url: URL, mode: RemovalMode) -> CleanupItem {
        CleanupItem(id: "x", categoryID: "c", title: "t", detail: "", size: 1, safety: .safe, action: .removePath(url, mode))
    }

    func testPermanentBecomesTrashUnlessEnabled() {
        let cache = item(home.appendingPathComponent("Library/Caches/x"), mode: .permanent)
        XCTAssertEqual(cache.effectiveRemovalMode(permanentDeletion: false, home: home), .trash)
        XCTAssertEqual(cache.effectiveRemovalMode(permanentDeletion: true, home: home), .permanent)
    }

    func testTrashItemsStayInTheTrashEvenWhenPermanentIsOn() {
        let backup = item(home.appendingPathComponent("Library/Application Support/MobileSync/Backup/x"), mode: .trash)
        XCTAssertEqual(backup.effectiveRemovalMode(permanentDeletion: true, home: home), .trash)
    }

    func testItemsAlreadyInTheTrashAreDeletedForGood() {
        let trashed = item(home.appendingPathComponent(".Trash/old.zip"), mode: .permanent)
        XCTAssertEqual(trashed.effectiveRemovalMode(permanentDeletion: false, home: home), .permanent)
    }
}

final class CleanupLevelTests: XCTestCase {
    private func item(_ id: String, safety: SafetyLevel, age days: Double? = nil,
                      action: CleanupAction? = nil, category: String = "c") -> CleanupItem {
        CleanupItem(id: id, categoryID: category, title: id, detail: "", size: 1, safety: safety,
                    action: action ?? .removePath(URL(fileURLWithPath: "/tmp/\(id)"), .trash),
                    modified: days.map { Date().addingTimeInterval(-$0 * 24 * 3600) })
    }

    func testSafeLevelOnlyTicksSafeItems() {
        XCTAssertTrue(CleanupLevel.safe.shouldSelect(item("a", safety: .safe), verdict: nil))
        XCTAssertFalse(CleanupLevel.safe.shouldSelect(item("b", safety: .caution), verdict: nil))
    }

    func testBalancedTicksOldOrApprovedCautionItems() {
        let old = item("old", safety: .caution, age: 90)
        let fresh = item("fresh", safety: .caution, age: 2)
        XCTAssertTrue(CleanupLevel.balanced.shouldSelect(old, verdict: nil))
        XCTAssertFalse(CleanupLevel.balanced.shouldSelect(fresh, verdict: nil))
        XCTAssertTrue(CleanupLevel.balanced.shouldSelect(fresh, verdict: AIVerdict(itemID: "fresh", safe: true, reason: "")))
    }

    func testAIRejectionBlocksEveryLevel() {
        let safe = item("a", safety: .safe)
        let no = AIVerdict(itemID: "a", safe: false, reason: "holds data")
        for level in CleanupLevel.allCases { XCTAssertFalse(level.shouldSelect(safe, verdict: no)) }
    }

    func testNoLevelTicksProtectedUninstallOrFolderScanItems() {
        let plan = AppUninstallPlan(appURL: URL(fileURLWithPath: "/Applications/X.app"), bundleID: "a.b", appName: "X", leftovers: [])
        XCTAssertFalse(CleanupLevel.thorough.shouldSelect(item("p", safety: .protected), verdict: nil))
        XCTAssertFalse(CleanupLevel.thorough.shouldSelect(item("u", safety: .caution, action: .uninstall(plan)), verdict: nil))
        XCTAssertFalse(CleanupLevel.thorough.shouldSelect(item("f", safety: .safe, category: FolderScan.categoryID), verdict: nil))
        XCTAssertTrue(CleanupLevel.thorough.shouldSelect(item("c", safety: .caution), verdict: nil))
    }
}

final class AgentReviewTests: XCTestCase {
    private func items() -> [CleanupItem] {
        (1...3).map { n in
            CleanupItem(id: "id\(n)", categoryID: "c", title: "t\(n)", detail: "d", size: Int64(n) * 100, safety: .safe,
                        action: .removePath(URL(fileURLWithPath: "/Users/x/Library/Caches/t\(n)"), .trash))
        }
    }

    func testParsesJSONWrappedInProseAndFences() {
        let reply = """
        Here you go:
        ```json
        [{"i":1,"safe":true,"reason":"cache"},{"i":3,"safe":false,"reason":"database"}]
        ```
        """
        let verdicts = AgentReview.parseVerdicts(reply, items: items())
        XCTAssertEqual(verdicts.map(\.itemID), ["id1", "id3"])
        XCTAssertEqual(verdicts.map(\.safe), [true, false])
    }

    func testIgnoresUnknownAndDuplicateNumbersAndGarbage() {
        let verdicts = AgentReview.parseVerdicts(#"[{"i":9,"safe":true},{"i":1,"safe":true},{"i":1,"safe":false}]"#, items: items())
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertTrue(verdicts[0].safe)
        XCTAssertTrue(AgentReview.parseVerdicts("no json here", items: items()).isEmpty)
        XCTAssertTrue(AgentReview.parseVerdicts("[not json]", items: items()).isEmpty)
    }

    func testReasonIsStrippedAndTruncated() {
        let long = String(repeating: "a", count: 500)
        let reply = #"[{"i":1,"safe":true,"reason":"x\u0007y\#(long)"}]"#
        let verdict = AgentReview.parseVerdicts(reply, items: items())[0]
        XCTAssertFalse(verdict.reason.contains("\u{07}"))
        XCTAssertLessThanOrEqual(verdict.reason.count, 300)
    }

    func testOnlyRemovablePathItemsAreReviewable() {
        var all = items()
        all.append(CleanupItem(id: "cmd", categoryID: "docker", title: "d", detail: "", size: 999, safety: .safe, action: .run(.dockerBuilderPrune)))
        all.append(CleanupItem(id: "prot", categoryID: "c", title: "p", detail: "", size: 999, safety: .protected, action: .informational))
        let reviewable = AgentReview.reviewable(all)
        XCTAssertEqual(Set(reviewable.map(\.id)), ["id1", "id2", "id3"])
        XCTAssertEqual(reviewable.first?.id, "id3") // largest first
    }

    func testPromptMarksDataAsUntrustedAndAbbreviatesHome() {
        let prompt = AgentReview.buildPrompt(items: items(), home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertTrue(prompt.contains("untrusted"))
        XCTAssertTrue(prompt.contains("~/Library/Caches/t1"))
        XCTAssertFalse(prompt.contains("/Users/x"))
    }

    func testCustomAgentNeedsACommand() async {
        let result = await AgentReview.run(items: items(), config: AgentConfig(kind: .custom, customCommand: "  "),
                                           home: URL(fileURLWithPath: "/Users/x"))
        guard case .failure(.notConfigured) = result else { return XCTFail("expected notConfigured") }
    }
}

final class QuitPolicyTests: XCTestCase {
    func testProtectsDesktopEssentials() {
        XCTAssertFalse(QuitPolicy.canQuit(bundleID: "com.apple.finder", ownBundleID: nil))
        XCTAssertFalse(QuitPolicy.canQuit(bundleID: "com.apple.dock", ownBundleID: nil))
        XCTAssertFalse(QuitPolicy.canQuit(bundleID: nil, ownBundleID: nil))
        XCTAssertFalse(QuitPolicy.canQuit(bundleID: "com.me.self", ownBundleID: "com.me.self"))
        XCTAssertTrue(QuitPolicy.canQuit(bundleID: "com.google.Chrome", ownBundleID: nil))
    }
}

final class ProcessTreeTests: XCTestCase {
    func testSumsAppAndDescendantsOnly() {
        let ps = """
          100     1   5.0  1000
          101   100  10.0  2000
          102   101   1.5   500
          200     1   7.0  4000
          300   200   2.0   100
        """
        let totals = ProcessTree.aggregate(psOutput: ps, appPIDs: [100, 200, 999])
        XCTAssertEqual(totals[100], ProcessTree.Totals(cpu: 16.5, memory: 3500 * 1024))
        XCTAssertEqual(totals[200], ProcessTree.Totals(cpu: 9.0, memory: 4100 * 1024))
        XCTAssertEqual(totals[999], ProcessTree.Totals(cpu: 0, memory: 0))
    }

    func testQuitAdviceMapsNumbersToPIDs() {
        let apps = [QuitCandidate(pid: 10, name: "A", bundleID: "a.b", cpu: 1, memory: 1),
                    QuitCandidate(pid: 20, name: "B", bundleID: "c.d", cpu: 1, memory: 1)]
        let advice = QuitAdvice.parse(#"ok [{"i":2,"safe":true,"reason":"idle"},{"i":5,"safe":true}]"#, apps: apps)
        XCTAssertEqual(advice.count, 1)
        XCTAssertEqual(advice[20]?.safe, true)
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() throws {
        XCTAssertTrue(try XCTUnwrap(SemanticVersion("1.2.0")) > XCTUnwrap(SemanticVersion("1.1.9")))
        XCTAssertTrue(try XCTUnwrap(SemanticVersion("v1.10")) > XCTUnwrap(SemanticVersion("1.9.9")))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertEqual(SemanticVersion("2.0.0-beta1")?.description, "2.0.0")
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion("1..2"))
    }

    private func releaseJSON(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
                             url: String = "https://github.com/mehmetsagir/disk-sweep/releases/download/v1.2.0/DiskSweep-1.2.0.dmg",
                             size: Int64 = 5_000_000, name: String = "DiskSweep-1.2.0.dmg",
                             digest: String? = "sha256:ABCDEF") -> Data {
        let digestField = digest.map { #","digest":"\#($0)""# } ?? ""
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/mehmetsagir/disk-sweep/releases/tag/\(tag)","body":"notes",
         "draft":\(draft),"prerelease":\(prerelease),
         "assets":[{"name":"\(name)","browser_download_url":"\(url)","size":\(size)\(digestField)}]}
        """.utf8)
    }

    func testNewerReleaseIsOffered() throws {
        let info = try XCTUnwrap(GitHubReleases.parseLatest(releaseJSON(), currentVersion: "1.1.0"))
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(info.sha256, "abcdef")
        XCTAssertEqual(info.notes, "notes")
    }

    func testSameOlderDraftAndPrereleaseAreIgnored() throws {
        XCTAssertNil(try GitHubReleases.parseLatest(releaseJSON(), currentVersion: "1.2.0"))
        XCTAssertNil(try GitHubReleases.parseLatest(releaseJSON(), currentVersion: "2.0.0"))
        XCTAssertNil(try GitHubReleases.parseLatest(releaseJSON(draft: true), currentVersion: "1.1.0"))
        XCTAssertNil(try GitHubReleases.parseLatest(releaseJSON(prerelease: true), currentVersion: "1.1.0"))
    }

    func testRejectsUntrustedHostsOversizeAndMissingDMG() {
        XCTAssertThrowsError(try GitHubReleases.parseLatest(releaseJSON(url: "https://evil.example.com/DiskSweep.dmg"), currentVersion: "1.1.0"))
        XCTAssertThrowsError(try GitHubReleases.parseLatest(releaseJSON(url: "http://github.com/x/DiskSweep.dmg"), currentVersion: "1.1.0"))
        XCTAssertThrowsError(try GitHubReleases.parseLatest(releaseJSON(size: 900_000_000), currentVersion: "1.1.0"))
        XCTAssertThrowsError(try GitHubReleases.parseLatest(releaseJSON(name: "notes.txt"), currentVersion: "1.1.0"))
    }

    func testTrustedHosts() {
        XCTAssertTrue(GitHubReleases.isTrustedDownloadHost(URL(string: "https://github.com/a/b")!))
        XCTAssertTrue(GitHubReleases.isTrustedDownloadHost(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertFalse(GitHubReleases.isTrustedDownloadHost(URL(string: "https://githubusercontent.com.evil.com/x")!))
        XCTAssertFalse(GitHubReleases.isTrustedDownloadHost(URL(string: "https://evilgithub.com/x")!))
    }

    func testTeamIDParsing() {
        XCTAssertEqual(CodeSignature.teamID(from: "Identifier=x\nTeamIdentifier=ABCDE12345\nSealed"), "ABCDE12345")
        XCTAssertNil(CodeSignature.teamID(from: "TeamIdentifier=not set"))
        XCTAssertNil(CodeSignature.teamID(from: "no team here"))
    }

    func testMountPointParsing() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk4</string></dict>
        <dict><key>mount-point</key><string>/Volumes/DiskSweep</string></dict></array></dict></plist>
        """
        XCTAssertEqual(UpdateInstaller.mountPoint(fromPlist: plist)?.path, "/Volumes/DiskSweep")
        XCTAssertNil(UpdateInstaller.mountPoint(fromPlist: "garbage"))
    }
}

final class DeviceScanTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-\(UUID().uuidString)")
        home = base.appendingPathComponent("home").resolvingSymlinksInPath()
        for dir in ["Library/Caches", "Downloads", "Developer/app", "Projects/web", "Movies", ".cache", "Dropbox/stuff"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func write(_ relative: String, megabytes: Int, ageDays: Double = 0) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: megabytes * 1024 * 1024).write(to: url)
        if ageDays > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * 86400)], ofItemAtPath: url.path)
        }
    }

    private func config() -> DeviceScan.Config {
        var config = DeviceScan.Config()
        config.largeFileThreshold = 3 * 1024 * 1024
        config.installerThreshold = 1024 * 1024
        return config
    }

    private func scanHome(excluded: [URL] = []) -> [CleanupItem] {
        DeviceScan.scan(guardrail: SafetyGuard(home: home, excluded: excluded), config: config(), progress: { _ in })
    }

    func testFindsLargeFilesInstallersAndOldDownloads() throws {
        try write("Movies/film.mov", megabytes: 4)
        try write("Movies/small.mov", megabytes: 1)
        try write("Downloads/App.dmg", megabytes: 2)
        try write("Downloads/old.zip", megabytes: 1, ageDays: 120)
        try write("Downloads/fresh.zip", megabytes: 1, ageDays: 1)
        let items = scanHome()
        let byGroup = Dictionary(grouping: items, by: \.categoryID)
        XCTAssertEqual(byGroup[DeviceScan.largeID]?.map(\.title), ["film.mov"])
        XCTAssertEqual(byGroup[DeviceScan.installersID]?.map(\.title), ["App.dmg"])
        XCTAssertEqual(byGroup[DeviceScan.downloadsID]?.map(\.title), ["old.zip"])
        XCTAssertTrue(items.allSatisfy { if case .trashUserSelected = $0.action { return true } else { return false } })
    }

    func testFindsDependencyFoldersOutsideDeveloperOnly() throws {
        try write("Projects/web/package.json", megabytes: 1)
        try write("Projects/web/node_modules/lib/index.js", megabytes: 1)
        try write("Developer/app/package.json", megabytes: 1)
        try write("Developer/app/node_modules/lib/index.js", megabytes: 1)
        try write("Projects/web/target/x.bin", megabytes: 1) // no Cargo.toml: not an artifact
        let deps = scanHome().filter { $0.categoryID == DeviceScan.dependenciesID }
        XCTAssertEqual(deps.map(\.title), ["node_modules"])
        XCTAssertTrue(deps[0].path?.path.contains("Projects/web") == true)
    }

    func testSkipsLibraryHiddenCloudAndExcludedFolders() throws {
        try write("Library/Caches/huge.bin", megabytes: 4)
        try write(".cache/huge.bin", megabytes: 4)
        try write("Dropbox/stuff/huge.bin", megabytes: 4)
        try write("Movies/keep/huge.bin", megabytes: 4)
        try write("Movies/film.mov", megabytes: 4)
        let items = scanHome(excluded: [home.appendingPathComponent("Movies/keep")])
        XCTAssertEqual(items.map(\.title), ["film.mov"])
    }

    func testCancellationReturnsNothing() async throws {
        try write("Movies/film.mov", megabytes: 4)
        let guardrail = SafetyGuard(home: home)
        let config = config()
        let task = Task.detached { () -> [CleanupItem] in
            withUnsafeCurrentTask { $0?.cancel() }
            return DeviceScan.scan(guardrail: guardrail, config: config, progress: { _ in })
        }
        let items = await task.value
        XCTAssertTrue(items.isEmpty)
    }

    func testLargeFilesAreNeverTickedOnTheAIsWord() {
        let item = CleanupItem(id: "x", categoryID: DeviceScan.largeID, title: "f", detail: "", size: 1, safety: .caution,
                               action: .trashUserSelected(URL(fileURLWithPath: "/tmp/f")),
                               modified: Date().addingTimeInterval(-400 * 86400))
        XCTAssertFalse(CleanupLevel.balanced.shouldSelect(item, verdict: nil))
        // Even an AI "safe" never ticks a personal-file candidate; only the Thorough level does.
        XCTAssertFalse(CleanupLevel.balanced.shouldSelect(item, verdict: AIVerdict(itemID: "x", safe: true, reason: "")))
        XCTAssertTrue(CleanupLevel.thorough.shouldSelect(item, verdict: nil))
        XCTAssertTrue(AgentReview.reviewable([item]).count == 1)
    }
}


final class LeftoverSafetyTests: XCTestCase {
    private func app(_ id: String, _ name: String) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: id, name: name)
    }

    func testSiblingAppDataIsNotClaimed() {
        let others = [app("com.vendor.App", "App"), app("com.vendor.App.Canary", "App Canary")]
        XCTAssertTrue(LeftoverRules.matches(entry: "com.vendor.App", folder: "Caches", bundleID: "com.vendor.App",
                                            appName: "App", others: others))
        XCTAssertFalse(LeftoverRules.matches(entry: "com.vendor.App.Canary", folder: "Caches", bundleID: "com.vendor.App",
                                             appName: "App", others: others))
        XCTAssertFalse(LeftoverRules.matches(entry: "com.vendor.App.Canary.plist", folder: "Preferences",
                                             bundleID: "com.vendor.App", appName: "App", others: others))
        XCTAssertFalse(LeftoverRules.matches(entry: "TEAM123456.com.vendor.App.Canary", folder: "Group Containers",
                                             bundleID: "com.vendor.App", appName: "App", others: others))
    }

    func testNameMatchRefusesSharedVendorFoldersAndOtherAppsNames() {
        XCTAssertFalse(LeftoverRules.matches(entry: "Google", folder: "Application Support", bundleID: "com.example.Google",
                                             appName: "Google"))
        let others = [app("com.other.Notes", "Notes Pro")]
        XCTAssertFalse(LeftoverRules.matches(entry: "Notes Pro", folder: "Application Support",
                                             bundleID: "com.example.NotesPro", appName: "Notes Pro", others: others))
    }

    func testShortOrAppleBundleIDsAreNotUninstallable() {
        XCTAssertFalse(InstalledApps.isUninstallable(bundleID: "com.foo", ownBundleID: nil))
        XCTAssertFalse(InstalledApps.isUninstallable(bundleID: "COM.APPLE.Safari", ownBundleID: nil))
        XCTAssertFalse(InstalledApps.isUninstallable(bundleID: "com..App", ownBundleID: nil))
        XCTAssertTrue(InstalledApps.isUninstallable(bundleID: "com.vendor.App", ownBundleID: nil))
    }
}
