import XCTest
@testable import DiskSweepCore

final class SafetyGuardTests: XCTestCase {
    private var home: URL!
    private var outside: URL!
    private var guardrail: SafetyGuard!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        outside = base.appendingPathComponent("outside")
        for dir in ["Library/Caches", "Library/Developer/Xcode/DerivedData", "Developer/proj", "Documents"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        guardrail = SafetyGuard(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    // MARK: accepted

    func testAcceptsKnownCacheLocations() throws {
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Library/Developer/Xcode/DerivedData/App-abc")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Library/Caches/com.example.app")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path(".npm/_cacache")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Library/Caches/com.apple.dt.Xcode")))
    }

    func testAcceptsProjectArtifacts() throws {
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Developer/proj/node_modules")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Developer/proj/apps/web/.next")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Developer/proj/.build")))
    }

    // MARK: rejected

    func testRejectsUserDataAndRoots() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: home))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Documents")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Documents/file.txt")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/src")))
    }

    func testRejectsTheCacheRootsThemselves() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Caches")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Developer/Xcode/DerivedData")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library")))
    }

    func testRejectsDeeperThanDirectChildren() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Caches/com.example.app/data")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Developer/Xcode/DerivedData/App-abc/Build")))
    }

    func testRejectsAppleSystemCaches() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Caches/com.apple.Safari")))
    }

    func testRejectsGitDataAndDockerDisk() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/.git")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/.git/node_modules")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")))
    }

    func testRejectsArtifactNamedFolderOutsideDeveloper() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Documents/node_modules")))
    }

    func testRejectsNestedArtifacts() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/node_modules/pkg/node_modules")))
    }

    func testRejectsPathEscapingThroughDotDot() {
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Caches/../../Documents")))
    }

    // MARK: symlinks

    func testRejectsPathThroughSymlinkedDirectory() throws {
        // Caches/evil -> outside; anything below it resolves outside the allowed root.
        let link = path("Library/Caches/evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try guardrail.validateRemoval(of: link.appendingPathComponent("victim")))
    }

    func testSymlinkItemIsRemovedWithoutTouchingTarget() async throws {
        let target = outside.appendingPathComponent("keep.txt")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        let link = path("Library/Caches/com.example.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 1,
                               safety: .safe, action: .removePath(link, .permanent))
        let outcome = await Cleaner(guardrail: guardrail).clean(item)

        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "symlink target must survive")
    }

    // MARK: cleaner

    func testCleanerRefusesPathsTheGuardRejects() async throws {
        let doc = path("Documents/important.txt")
        try "data".write(to: doc, atomically: true, encoding: .utf8)
        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 1,
                               safety: .safe, action: .removePath(doc, .permanent))
        let outcome = await Cleaner(guardrail: guardrail).clean(item)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path))
    }

    func testCleanerRemovesCacheDirectory() async throws {
        let cache = path("Library/Caches/com.example.app")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "x".write(to: cache.appendingPathComponent("a.bin"), atomically: true, encoding: .utf8)
        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 10,
                               safety: .safe, action: .removePath(cache, .permanent))
        let outcome = await Cleaner(guardrail: guardrail).clean(item)

        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testCleanerRefusesInformationalItems() async {
        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 1,
                               safety: .protected, action: .informational)
        let outcome = await Cleaner(guardrail: guardrail).clean(item)
        XCTAssertFalse(outcome.succeeded)
    }
}

final class ParsingTests: XCTestCase {
    func testDockerSizeParsing() {
        XCTAssertEqual(SizeCalculator.parseDockerSize("0B"), 0)
        XCTAssertEqual(SizeCalculator.parseDockerSize("1.5kB"), 1_500)
        XCTAssertEqual(SizeCalculator.parseDockerSize("512.3MB"), 512_300_000)
        XCTAssertEqual(SizeCalculator.parseDockerSize("2.6GB (45%)"), 2_600_000_000)
        XCTAssertNil(SizeCalculator.parseDockerSize("abc"))
    }

    func testSafeCommandsAreFixedStrings() {
        let id = UUID()
        XCTAssertEqual(SafeCommand.simctlDeleteDevice(id).shellLine, "xcrun simctl delete \(id.uuidString)")
        XCTAssertEqual(SafeCommand.dockerBuilderPrune.shellLine, "docker builder prune -af")
    }

    func testConcurrentMapKeepsOrder() async {
        let result = await SizeCalculator.concurrentMap(Array(0..<50), limit: 4) { $0 * 2 }
        XCTAssertEqual(result, Array(0..<50).map { $0 * 2 })
    }
}

// MARK: - Exclusions, user trash, search, folder scan

final class ExclusionAndTrashTests: XCTestCase {
    private var home: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        outside = base.appendingPathComponent("outside")
        for dir in ["Library/Caches/com.example.app", "Developer/proj/node_modules", "Developer/other/node_modules",
                    "Documents/old", "Library/Application Support", ".ssh", "OneDrive - Corp/files",
                    "Documents/Thing.app/Contents", "Developer/proj/.git"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    // MARK: exclusions

    func testExcludedFolderAndItsContentsAreNotRemovable() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Developer/proj")])
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/node_modules")))
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Developer/other/node_modules")))
    }

    func testItemThatWouldContainAnExcludedFolderIsNotRemovable() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Library/Caches/com.example.app/keep")])
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Library/Caches/com.example.app"))) { error in
            guard case SafetyGuard.Violation.excludedByUser = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testExcludingTheDeveloperRootBlocksEveryProjectArtifact() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Developer")])
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/proj/node_modules")))
        XCTAssertThrowsError(try guardrail.validateRemoval(of: path("Developer/other/node_modules")))
    }

    func testExcludedFoldersAreBlockedForUserTrashToo() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Documents/old")])
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Documents/old")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Documents/old/file.txt")))
    }

    func testExclusionSimilarPrefixDoesNotOverMatch() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Developer/pro")])
        XCTAssertNoThrow(try guardrail.validateRemoval(of: path("Developer/proj/node_modules")))
    }

    func testCleanerRefusesExcludedPath() async throws {
        let target = path("Library/Caches/com.example.app")
        let guardrail = SafetyGuard(home: home, excluded: [target])
        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 1,
                               safety: .safe, action: .removePath(target, .permanent))
        let outcome = await Cleaner(guardrail: guardrail).clean(item)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: user trash rules

    func testUserTrashAcceptsNormalFilesDeepInsideHome() {
        let guardrail = SafetyGuard(home: home)
        XCTAssertNoThrow(try guardrail.validateUserTrash(of: path("Documents/old/video.mov")))
        XCTAssertNoThrow(try guardrail.validateUserTrash(of: path("Documents/old")))
        XCTAssertNoThrow(try guardrail.validateUserTrash(of: path("Developer/proj")))
    }

    func testUserTrashRefusesSensitiveAreas() {
        let guardrail = SafetyGuard(home: home)
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: home))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Documents")), "direct child of home")
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Library/Application Support/X")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path(".ssh/id_rsa")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("OneDrive - Corp/files/report.docx")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Documents/Thing.app/Contents/Info.plist")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: path("Developer/proj/.git")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: outside.appendingPathComponent("file")))
        XCTAssertThrowsError(try guardrail.validateUserTrash(of: URL(fileURLWithPath: "/System/Library")))
    }

    func testUserTrashCannotEscapeThroughSymlinkedParent() throws {
        let link = path("Documents/old/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try SafetyGuard(home: home).validateUserTrash(of: link.appendingPathComponent("victim")))
    }

    func testCleanerRefusesUserTrashOutsideHome() async throws {
        let victim = outside.appendingPathComponent("keep.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        let item = CleanupItem(id: "t", categoryID: "t", title: "t", detail: "", size: 1,
                               safety: .caution, action: .trashUserSelected(victim))
        let outcome = await Cleaner(guardrail: SafetyGuard(home: home)).clean(item)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    // MARK: folder scan items

    func testFolderScanMarksSensitiveEntriesViewOnly() {
        let guardrail = SafetyGuard(home: home)
        let library = FolderScan.makeItem(url: path("Library"), size: 10, guardrail: guardrail)
        XCTAssertEqual(library.safety, .protected)
        XCTAssertFalse(library.isSelectable)
        XCTAssertTrue(library.isFolder)

        let old = FolderScan.makeItem(url: path("Documents/old"), size: 10, guardrail: guardrail)
        XCTAssertTrue(old.isSelectable)
        XCTAssertEqual(old.removalMode, .trash)
    }

    func testFolderScanMarksExcludedViewOnly() {
        let guardrail = SafetyGuard(home: home, excluded: [path("Documents/old")])
        let item = FolderScan.makeItem(url: path("Documents/old"), size: 1, guardrail: guardrail)
        XCTAssertFalse(item.isSelectable)
        XCTAssertTrue(item.detail.contains("Dışlanmış"))
    }

    // MARK: search

    func testSearchMatchingIsCaseAndDiacriticInsensitive() {
        let item = CleanupItem(id: "1", categoryID: "c", title: "Önbellek Dosyası", detail: "Xcode cache",
                               size: 1, safety: .safe, action: .informational)
        XCTAssertTrue(item.matches("onbellek"))
        XCTAssertTrue(item.matches("XCODE"))
        XCTAssertTrue(item.matches("dosyası xcode"), "all words must match, any order")
        XCTAssertFalse(item.matches("docker"))
        XCTAssertTrue(item.matches("docker", extra: "Docker"), "category name counts")
        XCTAssertTrue(item.matches("   "), "blank query matches everything")
    }
}
