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

    public init(guardrail: SafetyGuard) {
        self.guardrail = guardrail
    }

    public func clean(_ item: CleanupItem) async -> CleanupOutcome {
        func failure(_ message: String) -> CleanupOutcome {
            CleanupOutcome(item: item, freedBytes: 0, errorMessage: message)
        }
        let freed = item.size ?? 0

        switch item.action {
        case .informational:
            return failure("Bu öğe yalnızca bilgi amaçlıdır, silinemez.")

        case .removePath(let url, let mode):
            // Second, independent check right before touching the disk.
            let validated: URL
            do {
                validated = try guardrail.validateRemoval(of: url)
            } catch {
                return failure("Güvenlik kontrolü reddetti: \(error)")
            }
            if let message = await Self.remove(validated, mode: mode) { return failure(message) }
            return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)

        case .trashUserSelected(let url):
            let validated: URL
            do {
                validated = try guardrail.validateUserTrash(of: url)
            } catch {
                return failure("Güvenlik kontrolü reddetti: \(error)")
            }
            if let message = await Self.remove(validated, mode: .trash) { return failure(message) }
            return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)

        case .run(let command):
            let result = await Shell.shell(command.shellLine, userShell: command.needsUserShell, timeout: command.timeout)
            if result.succeeded {
                return CleanupOutcome(item: item, freedBytes: freed, errorMessage: nil)
            }
            return failure(result.timedOut ? "Komut zaman aşımına uğradı" : result.lastMessageLine)
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
