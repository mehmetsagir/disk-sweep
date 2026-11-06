import Foundation

// MARK: - Versions

public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Accepts "1.2.3", "v1.2", "1.2.3-beta" (the suffix is ignored). Returns nil for anything else.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<dash]) }
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

// MARK: - Release metadata

public struct UpdateInfo: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let assetName: String
    public let assetURL: URL
    public let size: Int64
    /// Hex SHA-256 published by GitHub for the asset, when available.
    public let sha256: String?
    public let pageURL: URL
}

public enum UpdateError: Error, CustomStringConvertible, Sendable {
    case network(String)
    case noDownload
    case untrustedSource
    case tooLarge
    case checksumMismatch
    case mountFailed(String)
    case appMissing
    case wrongApp
    case notNewer
    case signatureInvalid(String)
    case teamMismatch
    case cannotSelfUpdate
    case notWritable(String)

    public var description: String {
        switch self {
        case .network(let message): return message
        case .noDownload: return L("Yayında indirilebilir bir DMG bulunamadı.")
        case .untrustedSource: return L("İndirme adresi güvenilir değil.")
        case .tooLarge: return L("İndirme beklenenden büyük.")
        case .checksumMismatch: return L("İndirilen dosyanın sağlama toplamı eşleşmiyor.")
        case .mountFailed(let message): return L("DMG açılamadı: \(message)")
        case .appMissing: return L("DMG içinde DiskSweep.app bulunamadı.")
        case .wrongApp: return L("DMG içindeki uygulama DiskSweep değil.")
        case .notNewer: return L("İndirilen sürüm mevcut sürümden yeni değil.")
        case .signatureInvalid(let message): return L("İmza doğrulanamadı: \(message)")
        case .teamMismatch: return L("Yeni sürüm farklı bir geliştirici tarafından imzalanmış.")
        case .cannotSelfUpdate: return L("Bu sürüm imzasız; uygulama içinden güncellenemez. Sürümü GitHub'dan indirin.")
        case .notWritable(let path): return L("Uygulama bulunduğu klasöre yazılamıyor: \(path)")
        }
    }
}

public enum GitHubReleases {
    public static let owner = "mehmetsagir"
    public static let repo = "disk-sweep"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!

    /// 200 MB is far above any DiskSweep DMG.
    public static let maximumDownloadBytes: Int64 = 200 * 1024 * 1024

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
            let digest: String?
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// Downloads may only come from GitHub itself (assets redirect to its CDN).
    public static func isTrustedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// The update described by a `releases/latest` response, or nil when `currentVersion` is up to date.
    public static func parseLatest(_ data: Data, currentVersion: String) throws -> UpdateInfo? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateError.network(L("GitHub'dan beklenmeyen bir yanıt geldi."))
        }
        guard !release.draft, !release.prerelease,
              let latest = SemanticVersion(release.tag_name),
              let current = SemanticVersion(currentVersion), latest > current else { return nil }

        guard let asset = release.assets.first(where: { $0.name.hasPrefix("DiskSweep") && $0.name.hasSuffix(".dmg") }),
              let assetURL = URL(string: asset.browser_download_url),
              let pageURL = URL(string: release.html_url) else { throw UpdateError.noDownload }
        guard isTrustedDownloadHost(assetURL) else { throw UpdateError.untrustedSource }
        guard asset.size > 0, asset.size <= maximumDownloadBytes else { throw UpdateError.tooLarge }

        var sha: String?
        if let digest = asset.digest, digest.hasPrefix("sha256:") { sha = String(digest.dropFirst(7)).lowercased() }
        return UpdateInfo(version: latest.description, notes: release.body ?? "", assetName: asset.name,
                          assetURL: assetURL, size: asset.size, sha256: sha, pageURL: pageURL)
    }

    public static func fetchLatest(currentVersion: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiskSweep/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.network(L("Yanıt okunamadı.")) }
            // No release has been published yet.
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw UpdateError.network("GitHub: HTTP \(http.statusCode)") }
            return try parseLatest(data, currentVersion: currentVersion)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

// MARK: - Code signature

public enum CodeSignature {
    /// `TeamIdentifier=ABCDE12345` from `codesign -dv` output. "not set" (ad-hoc/unsigned) gives nil.
    public static func teamID(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    public static func teamID(of url: URL) async -> String? {
        let result = await Shell.run(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=2", url.path], timeout: 30)
        return teamID(from: result.stderr + "\n" + result.stdout)
    }
}

// MARK: - Installing

public enum UpdateInstaller {
    /// Streams the DMG to a temp file. Only HTTPS redirects within GitHub's hosts are followed.
    public static func download(_ info: UpdateInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(expected: info.size, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("DiskSweep.dmg")

        let location: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: info.assetURL, timeoutInterval: 60)
            request.setValue("DiskSweep", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            guard size > 0, size <= GitHubReleases.maximumDownloadBytes else { throw UpdateError.tooLarge }
            if let expected = info.sha256, try await sha256(of: destination) != expected { throw UpdateError.checksumMismatch }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return destination
    }

    static func sha256(of url: URL) async throws -> String {
        let result = await Shell.run(executable: "/usr/bin/shasum", arguments: ["-a", "256", url.path], timeout: 60)
        guard result.succeeded, let hash = result.stdout.split(separator: " ").first else {
            throw UpdateError.network(L("Sağlama toplamı hesaplanamadı."))
        }
        return hash.lowercased()
    }

    /// Mounts the DMG, verifies the app inside and copies it next to `destination`.
    /// Returns the staged copy. The app must be signed by the same team as the running one.
    public static func stage(dmg: URL, currentVersion: String, ownTeamID: String?, ownBundleID: String,
                             destination: URL) async throws -> URL {
        guard let ownTeamID else { throw UpdateError.cannotSelfUpdate }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }

        let attach = await Shell.run(executable: "/usr/bin/hdiutil",
                                     arguments: ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-plist", dmg.path],
                                     timeout: 120)
        guard attach.succeeded, let mountPoint = mountPoint(fromPlist: attach.stdout) else {
            throw UpdateError.mountFailed(attach.lastMessageLine)
        }
        defer { Task { _ = await Shell.run(executable: "/usr/bin/hdiutil", arguments: ["detach", "-force", mountPoint.path], timeout: 60) } }

        let app = mountPoint.appendingPathComponent("DiskSweep.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.appMissing }

        guard let info = InstalledApps.info(at: app), info.bundleID == ownBundleID else { throw UpdateError.wrongApp }
        let bundle = Bundle(url: app)
        let newVersion = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let new = SemanticVersion(newVersion), let current = SemanticVersion(currentVersion), new > current else {
            throw UpdateError.notNewer
        }

        let verify = await Shell.run(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard verify.succeeded else { throw UpdateError.signatureInvalid(verify.lastMessageLine) }
        guard await CodeSignature.teamID(of: app) == ownTeamID else { throw UpdateError.teamMismatch }
        // Gatekeeper: Developer ID signed and notarized.
        let assess = await Shell.run(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", app.path], timeout: 120)
        guard assess.succeeded else { throw UpdateError.signatureInvalid(assess.lastMessageLine) }

        let staged = parent.appendingPathComponent(".DiskSweep-update-\(UUID().uuidString).app")
        let copy = await Shell.run(executable: "/usr/bin/ditto", arguments: [app.path, staged.path], timeout: 300)
        guard copy.succeeded else { throw UpdateError.network(copy.lastMessageLine) }
        _ = await Shell.run(executable: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", staged.path], timeout: 30)
        return staged
    }

    static func mountPoint(fromPlist output: String) -> URL? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Swaps `staged` into `destination` after this process exits, then relaunches. The old app is
    /// kept until the new one is in place and restored if the swap fails. Paths and the PID reach the
    /// script as arguments, never as part of its text.
    public static func installAfterExit(staged: URL, destination: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; APP="$3"; BACKUP="$APP.update-backup"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
        rm -rf "$BACKUP"
        if mv "$APP" "$BACKUP"; then
          if mv "$NEW" "$APP"; then
            rm -rf "$BACKUP"
          else
            mv "$BACKUP" "$APP"
            rm -rf "$NEW"
          fi
        else
          rm -rf "$NEW"
        fi
        open "$APP"
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/sh", scriptURL.path, String(pid), staged.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<URL, Error>?
    private let expected: Int64
    private let progress: @Sendable (Double) -> Void
    private var finished = false
    private var movedLocation: URL?

    init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > GitHubReleases.maximumDownloadBytes {
            downloadTask.cancel()
            finish(.failure(UpdateError.tooLarge))
            return
        }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { progress(min(Double(totalBytesWritten) / Double(total), 1)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, GitHubReleases.isTrustedDownloadHost(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
            finish(.failure(UpdateError.untrustedSource))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so keep a copy.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("disksweep-dl-\(UUID().uuidString)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.network("GitHub: HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(UpdateError.network(error.localizedDescription))) }
    }
}
