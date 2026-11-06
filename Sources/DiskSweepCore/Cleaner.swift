import Foundation

public struct CleanupOutcome: Identifiable, Sendable {
    public let id = UUID()
    public let item: CleanupItem
    public let freedBytes: Int64
    public let errorMessage: String?
    public var succeeded: Bool { errorMessage == nil }
}

public struct Cleaner: Sendable {
    public let guardrail: SafetyGuard
    /// When false (the default), items that would be deleted for good go to the Trash instead.
    public let permanentDeletion: Bool
    /// Tells whether an app is running right now (by bundle ID). Uninstalling a running app is refused.
    private let isAppRunning: @Sendable (String) -> Bool

    public init(guardrail: SafetyGuard, permanentDeletion: Bool = false,
                isAppRunning: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.guardrail = guardrail
        self.permanentDeletion = permanentDeletion
        self.isAppRunning = isAppRunning
    }

    public func clean(_ item: CleanupItem) async -> CleanupOutcome {
        func failure(_ message: String) -> CleanupOutcome {
            CleanupOutcome(item: item, freedBytes: 0, errorMessage: message)
        }
        let freed = item.size ?? 0

        switch item.action {
        case .informational:
            return failure(L("Bu öğe yalnızca bilgi amaçlıdır, silinemez."))

        case .removePath(let url, let mode):
            // Second, independent check right before touching the disk.
            let validated: URL
            do {
                validated = try guardrail.validateRemoval(of: url)
            } catch {
                return failure(L("Güvenlik kontrolü reddetti: \(String(describing: error))"))
            }
            let effective = item.effectiveRemovalMode(permanentDeletion: permanentDeletion, home: guardrail.home) ?? mode
            if let message = await Self.remove(validated, mode: effective) { return failure(message) }
            return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)

        case .uninstall(let plan):
            let approved: SafetyGuard.ApprovedUninstall
            do {
                approved = try guardrail.validateUninstall(plan)
            } catch {
                return failure(L("Güvenlik kontrolü reddetti: \(String(describing: error))"))
            }
            if isAppRunning(plan.bundleID) { return failure(L("Uygulama şu an açık — önce kapatın")) }
            // The app first: if it cannot be removed, its data stays where it is.
            if let message = await Self.remove(approved.app, mode: .trash) { return failure(message) }
            var firstError: String?
            for leftover in approved.leftovers {
                if let message = await Self.remove(leftover, mode: .trash), firstError == nil { firstError = message }
            }
            return CleanupOutcome(item: item, freedBytes: freed, errorMessage: firstError)

        case .trashUserSelected(let url):
            let validated: URL
            do {
                validated = try guardrail.validateUserTrash(of: url)
            } catch {
                return failure(L("Güvenlik kontrolü reddetti: \(String(describing: error))"))
            }
            if let message = await Self.remove(validated, mode: .trash) { return failure(message) }
            return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)

        case .run(let command):
            let result = await Shell.shell(command.shellLine, userShell: command.needsUserShell, timeout: command.timeout)
            if result.succeeded {
                return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)
            }
            return failure(result.timedOut ? L("Komut zaman aşımına uğradı") : result.lastMessageLine)
        }
    }

    /// Returns an error message, or nil on success. An item that is already gone counts as success.
    private static func remove(_ url: URL, mode: RemovalMode) async -> String? {
        let result: Result<Void, Error> = await Task.detached(priority: .utility) {
            Result {
                let fm = FileManager.default
                guard fm.fileExists(atPath: url.path)
                        || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
                switch mode {
                case .permanent: try fm.removeItem(at: url)
                case .trash: try fm.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }.value
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }
}
