import Foundation

/// Project build artifacts that may be offered for removal inside ~/Developer,
/// and the files that prove a directory really is that kind of artifact.
public enum ProjectArtifacts {
    /// artifact directory name -> files that must sit NEXT TO it (any one of them).
    public static let siblingMarkers: [String: [String]] = [
        "node_modules": ["package.json"],
        ".next": ["package.json"],
        ".nuxt": ["package.json"],
        ".svelte-kit": ["package.json"],
        ".turbo": ["package.json"],
        ".parcel-cache": ["package.json"],
        ".build": ["Package.swift"],
        "target": ["Cargo.toml", "pom.xml"],
        "Pods": ["Podfile"],
    ]

    /// Python virtual environments are recognised by a file INSIDE them.
    public static let virtualEnvNames: Set<String> = [".venv", "venv"]

    public static let names: Set<String> = Set(siblingMarkers.keys).union(virtualEnvNames)
}

/// The single gatekeeper for every file deletion. Nothing is removed unless
/// one of the `validate...` methods approves the exact path, both when it is
/// listed and again right before it is deleted.
///
/// Two separate rule sets exist:
/// - `validateRemoval`: the curated allow-list used by the cleanup categories
///   (caches, DerivedData, project artifacts, ...).
/// - `validateUserTrash`: used by the folder scanner for files the user picks
///   by hand. Only ever moves to the Trash, and refuses sensitive areas.
///
/// Folders the user excluded are protected by BOTH: neither the excluded folder,
/// anything inside it, nor any item that would contain it can be removed.
public struct SafetyGuard: Sendable {
    public enum Violation: Error, Equatable, CustomStringConvertible, Sendable {
        case notFileURL
        case outsideAllowedLocations(String)
        case protectedLocation(String)
        case excludedByUser(String)
        case viewOnly(String)

        public var description: String {
            switch self {
            case .notFileURL: return L("Dosya yolu değil")
            case .outsideAllowedLocations(let path): return L("İzin verilen konumların dışında: \(path)")
            case .protectedLocation(let why): return L("Korunan konum (\(why))")
            case .excludedByUser: return L("Dışlanmış klasör — dokunulmaz")
            case .viewOnly(let why): return L("Yalnızca görüntülenir: \(why)")
            }
        }
    }

    private enum Rule: Sendable {
        /// The item must be a DIRECT child of this directory.
        case childOf(String)
        /// The item must be exactly this path.
        case exactly(String)
    }

    public let home: URL
    /// Canonical paths the user asked this app never to touch.
    public let excludedPaths: [String]
    private let rules: [Rule]
    private let developerPath: String
    private let cachesPath: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, excluded: [URL] = []) {
        let canonicalHome = home.standardizedFileURL.resolvingSymlinksInPath()
        func path(_ relative: String) -> String { canonicalHome.appendingPathComponent(relative).path }

        self.home = canonicalHome
        var seen = Set<String>()
        self.excludedPaths = excluded
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.developerPath = path("Developer")
        self.cachesPath = path("Library/Caches")
        self.rules = [
            // Xcode
            .childOf(path("Library/Developer/Xcode/DerivedData")),
            .childOf(path("Library/Developer/Xcode/iOS DeviceSupport")),
            .childOf(path("Library/Developer/Xcode/watchOS DeviceSupport")),
            .childOf(path("Library/Developer/Xcode/tvOS DeviceSupport")),
            .childOf(path("Library/Developer/Xcode/visionOS DeviceSupport")),
            .childOf(path("Library/Developer/Xcode/Archives")),
            .exactly(path("Library/Developer/Xcode/DocumentationCache")),
            .exactly(path("Library/Developer/CoreSimulator/Caches")),
            // Package manager caches
            .exactly(path(".npm/_cacache")),
            .exactly(path(".bun/install/cache")),
            .exactly(path(".cargo/registry/cache")),
            .exactly(path(".gradle/caches")),
            .childOf(path(".cache")),
            // System / app
            .childOf(path("Library/Caches")),
            .childOf(path("Library/Logs")),
            .childOf(path(".Trash")),
            .childOf(path("Library/Application Support/MobileSync/Backup")),
        ]
    }

    public func withExcluded(_ urls: [URL]) -> SafetyGuard {
        SafetyGuard(home: home, excluded: urls)
    }

    // MARK: - Exclusions

    /// True when `path` is an excluded folder, lies inside one, or would contain one.
    public func isExcluded(_ path: String) -> Bool {
        excludedPaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/") || excluded.hasPrefix(path + "/")
        }
    }

    // MARK: - Curated cleanup locations

    /// Returns the canonical path that may be removed, or throws.
    @discardableResult
    public func validateRemoval(of url: URL) throws -> URL {
        let candidate = try canonicalCandidate(url)
        let components = candidate.pathComponents
        let name = candidate.lastPathComponent

        if isExcluded(candidate.path) { throw Violation.excludedByUser(candidate.path) }
        try rejectAlwaysProtected(components: components, name: name)

        for rule in rules {
            switch rule {
            case .childOf(let root):
                guard candidate.deletingLastPathComponent().path == root else { continue }
                if root == cachesPath, name.hasPrefix("com.apple."), name != "com.apple.dt.Xcode" {
                    throw Violation.protectedLocation(L("Apple sistem önbelleği"))
                }
                return candidate
            case .exactly(let path):
                if candidate.path == path { return candidate }
            }
        }

        // Build artifacts inside ~/Developer.
        let insideDeveloper = candidate.path.hasPrefix(developerPath + "/")
        let ancestorIsArtifact = components.dropLast().contains { ProjectArtifacts.names.contains($0) }
        if insideDeveloper, ProjectArtifacts.names.contains(name), !ancestorIsArtifact {
            return candidate
        }

        throw Violation.outsideAllowedLocations(candidate.path)
    }

    // MARK: - Files the user picks by hand (Trash only)

    private static let cloudFolderNames: Set<String> = [
        "Dropbox", "Google Drive", "GoogleDrive", "Box", "iCloud Drive", "Creative Cloud Files", "pCloud Drive",
    ]
    private static let protectedBundleSuffixes = [".app", ".photoslibrary", ".musiclibrary", ".tvlibrary"]

    /// Approves moving a user-selected item to the Trash, or throws a reason
    /// that is shown to the user ("view only").
    @discardableResult
    public func validateUserTrash(of url: URL) throws -> URL {
        let candidate = try canonicalCandidate(url)
        let components = candidate.pathComponents
        let name = candidate.lastPathComponent

        if isExcluded(candidate.path) { throw Violation.excludedByUser(candidate.path) }
        try rejectAlwaysProtected(components: components, name: name)

        guard candidate.path.hasPrefix(home.path + "/") else {
            throw Violation.viewOnly(L("ana klasörünün dışı"))
        }
        let relative = Array(components.dropFirst(home.pathComponents.count))
        guard relative.count >= 2 else {
            throw Violation.viewOnly(L("ana klasördeki klasörler korunur, içine girip seçin"))
        }
        let top = relative[0]
        if top == "Library" || top.hasPrefix(".") {
            throw Violation.viewOnly(L("Library ve gizli klasörler"))
        }
        if top.hasPrefix("OneDrive") || Self.cloudFolderNames.contains(top) {
            throw Violation.viewOnly(L("bulutla senkronize klasör"))
        }
        if components.dropLast().contains(where: { part in
            Self.protectedBundleSuffixes.contains { part.hasSuffix($0) }
        }) {
            throw Violation.viewOnly(L("uygulama/kütüphane paketinin içi"))
        }
        return candidate
    }

    // MARK: - Uninstalling apps (Trash only)

    /// The paths of an uninstall that passed every check.
    public struct ApprovedUninstall: Sendable {
        public let app: URL
        public let leftovers: [URL]
    }

    /// Approves moving an installed app and its leftovers to the Trash. The app must be a
    /// top-level bundle in /Applications or ~/Applications whose real bundle ID matches the
    /// plan; every leftover must be tied to that bundle ID or name by `LeftoverRules`.
    /// Leftovers that fail are dropped; a bad app throws.
    public func validateUninstall(_ plan: AppUninstallPlan) throws -> ApprovedUninstall {
        let app = try canonicalCandidate(plan.appURL)
        if isExcluded(app.path) { throw Violation.excludedByUser(app.path) }

        let parent = app.deletingLastPathComponent().path
        let applicationRoots = ["/Applications", home.appendingPathComponent("Applications").path]
        guard app.pathExtension == "app", applicationRoots.contains(parent) else {
            throw Violation.outsideAllowedLocations(app.path)
        }
        guard let info = InstalledApps.info(at: app), info.bundleID == plan.bundleID else {
            throw Violation.outsideAllowedLocations(app.path)
        }
        guard InstalledApps.isUninstallable(bundleID: info.bundleID) else {
            throw Violation.protectedLocation(L("Korumalı uygulama"))
        }

        let library = home.appendingPathComponent("Library").path
        var leftovers: [URL] = []
        for url in plan.leftovers {
            guard let candidate = try? canonicalCandidate(url), !isExcluded(candidate.path) else { continue }
            let folderPath = candidate.deletingLastPathComponent().path
            guard folderPath.hasPrefix(library + "/") else { continue }
            let folder = String(folderPath.dropFirst(library.count + 1))
            guard LeftoverRules.folders.contains(folder),
                  LeftoverRules.matches(entry: candidate.lastPathComponent, folder: folder,
                                        bundleID: info.bundleID, appName: info.name) else { continue }
            leftovers.append(candidate)
        }
        return ApprovedUninstall(app: app, leftovers: leftovers)
    }

    public static func isInsideTrash(_ url: URL, home: URL) -> Bool {
        let trash = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(".Trash").path
        return url.standardizedFileURL.path.hasPrefix(trash + "/")
    }

    // MARK: - Shared

    /// Canonical path of the item: symlinks are resolved in the PARENT only, so a
    /// symlink item is removed as a link and its target is never touched.
    private func canonicalCandidate(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw Violation.notFileURL }
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else {
            throw Violation.outsideAllowedLocations(url.path)
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(name)
    }

    private func rejectAlwaysProtected(components: [String], name: String) throws {
        if components.contains(".git") { throw Violation.protectedLocation(L("git verisi")) }
        if components.contains("com.docker.docker") || name == "Docker.raw" {
            throw Violation.protectedLocation(L("Docker disk imajı"))
        }
    }
}
