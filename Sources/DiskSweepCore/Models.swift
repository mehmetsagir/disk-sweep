import Foundation

/// How risky it is to remove an item.
public enum SafetyLevel: Int, Sendable, Comparable {
    /// Regenerates on its own; no data is lost.
    case safe = 0
    /// Costs something to get back (re-download, rebuild) or may hold user data.
    case caution = 1
    /// Shown for information only. Can never be removed from this app.
    case protected = 2

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RemovalMode: Sendable, Hashable {
    case permanent
    case trash
}

/// The only external commands this app is able to run. Being an enum makes it
/// impossible to build an arbitrary command line at runtime.
public enum SafeCommand: Hashable, Sendable {
    case dockerBuilderPrune
    case dockerContainerPrune
    case dockerImagePruneAll
    case simctlDeleteUnavailable
    case simctlDeleteDevice(UUID)
    case simctlDeleteRuntime(UUID)
    case pnpmStorePrune

    public var shellLine: String {
        switch self {
        case .dockerBuilderPrune: return "docker builder prune -af"
        case .dockerContainerPrune: return "docker container prune -f"
        case .dockerImagePruneAll: return "docker image prune -af"
        case .simctlDeleteUnavailable: return "xcrun simctl delete unavailable"
        case .simctlDeleteDevice(let id): return "xcrun simctl delete \(id.uuidString)"
        case .simctlDeleteRuntime(let id): return "xcrun simctl runtime delete \(id.uuidString)"
        case .pnpmStorePrune: return "pnpm store prune"
        }
    }

    /// pnpm is usually installed by a node version manager that only exists in
    /// the user's interactive shell PATH.
    public var needsUserShell: Bool { self == .pnpmStorePrune }

    public var timeout: TimeInterval { 900 }
}

public enum CleanupAction: Hashable, Sendable {
    case removePath(URL, RemovalMode)
    /// A file/folder picked by hand in the folder scanner. Always goes to the Trash.
    case trashUserSelected(URL)
    case run(SafeCommand)
    case informational
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let categoryID: String
    public var title: String
    public var detail: String
    /// Bytes expected to be freed. `nil` when it cannot be known up front.
    public var size: Int64?
    public var safety: SafetyLevel
    public var action: CleanupAction
    public var modified: Date?
    /// Location shown/opened in Finder even when the item itself cannot be removed.
    public var browseURL: URL?
    public var isFolder: Bool

    public init(id: String, categoryID: String, title: String, detail: String, size: Int64?,
                safety: SafetyLevel, action: CleanupAction, modified: Date? = nil,
                browseURL: URL? = nil, isFolder: Bool = false) {
        self.id = id
        self.categoryID = categoryID
        self.title = title
        self.detail = detail
        self.size = size
        self.safety = safety
        self.action = action
        self.modified = modified
        self.browseURL = browseURL
        self.isFolder = isFolder
    }

    public var isSelectable: Bool {
        if safety == .protected { return false }
        if case .informational = action { return false }
        return true
    }

    public var path: URL? {
        if let browseURL { return browseURL }
        switch action {
        case .removePath(let url, _), .trashUserSelected(let url): return url
        case .run, .informational: return nil
        }
    }

    public var removalMode: RemovalMode? {
        switch action {
        case .removePath(_, let mode): return mode
        case .trashUserSelected: return .trash
        case .run, .informational: return nil
        }
    }

    public var isCommand: Bool {
        if case .run = action { return true }
        return false
    }

    /// Case- and diacritic-insensitive search; every word must match somewhere
    /// in the title, description, path or `extra` (e.g. the category name).
    public func matches(_ query: String, extra: String = "") -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = [title, detail, path?.path ?? "", extra].joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) != nil
        }
    }
}

public struct DiskUsage: Sendable {
    public let total: Int64
    public let available: Int64
    public var used: Int64 { total - available }
    public var freeFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }

    public static func current() -> DiskUsage {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? url.resourceValues(forKeys: keys)
        return DiskUsage(total: Int64(values?.volumeTotalCapacity ?? 0),
                         available: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
