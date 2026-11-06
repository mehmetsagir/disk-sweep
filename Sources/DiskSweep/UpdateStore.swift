import SwiftUI
import AppKit
import DiskSweepCore

/// Checks GitHub for a newer release and, on request, installs it in place.
/// Nothing is downloaded or installed without the user pressing the update button.
@MainActor @Observable
final class UpdateStore {
    static let shared = UpdateStore()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    var state: State = .idle
    var lastChecked: Date?

    static let autoCheckKey = "update.autoCheck"
    private static let lastCheckKey = "update.lastCheck"
    private static let interval: TimeInterval = 24 * 3600

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        lastChecked = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var available: UpdateInfo? {
        if case .available(let info) = state { return info }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Called at launch: checks at most once a day, and only if the user did not turn it off.
    func checkIfDue() {
        guard AppSettings.bool(Self.autoCheckKey, default: true), !isBusy else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Task { await check() }
    }

    func check() async {
        guard !isBusy else { return }
        state = .checking
        do {
            let info = try await GitHubReleases.fetchLatest(currentVersion: currentVersion)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked?.timeIntervalSince1970, forKey: Self.lastCheckKey)
            withAnimation(Motion.smooth) { state = info.map(State.available) ?? .upToDate }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func install() async {
        guard let info = available else { return }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app", let bundleID = Bundle.main.bundleIdentifier else {
            state = .failed(String(describing: UpdateError.cannotSelfUpdate))
            return
        }
        state = .downloading(0)
        do {
            let dmg = try await UpdateInstaller.download(info) { fraction in
                Task { @MainActor in
                    if case .downloading = UpdateStore.shared.state { UpdateStore.shared.state = .downloading(fraction) }
                }
            }
            state = .installing
            let staged = try await UpdateInstaller.stage(
                dmg: dmg, currentVersion: currentVersion,
                ownTeamID: await CodeSignature.teamID(of: bundleURL),
                ownBundleID: bundleID, destination: bundleURL)
            try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
            try UpdateInstaller.installAfterExit(staged: staged, destination: bundleURL)
            AppLifecycle.quit()
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

struct UpdateSettingsSection: View {
    @State private var updates = UpdateStore.shared
    @AppStorage(UpdateStore.autoCheckKey) private var autoCheck = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Güncellemeler").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            VStack(spacing: 0) {
                row(title: L("Güncellemeleri otomatik denetle"),
                    detail: L("GitHub'daki son sürüm günde bir kez denetlenir. Hiçbir şey sormadan kurulmaz.")) {
                    Toggle("", isOn: $autoCheck).labelsHidden().toggleStyle(.switch)
                }
                row(title: L("Sürüm \(updates.currentVersion)"), detail: statusText) { action }
                if let info = updates.available, !info.notes.isEmpty {
                    DisclosureGroup(L("Sürüm notları")) {
                        Text(info.notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .card(cornerRadius: 14)
        }
    }

    private var statusText: String {
        switch updates.state {
        case .idle:
            return updates.lastChecked.map { L("Son denetim: \($0.formatted(date: .abbreviated, time: .shortened))") }
                ?? L("Henüz denetlenmedi.")
        case .checking: return L("Denetleniyor…")
        case .upToDate: return L("DiskSweep güncel.")
        case .available(let info): return L("Yeni sürüm hazır: \(info.version) (\(Format.bytes(info.size)))")
        case .downloading(let fraction): return L("İndiriliyor…") + " \(Int(fraction * 100))%"
        case .installing: return L("Doğrulanıyor ve kuruluyor…")
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var action: some View {
        switch updates.state {
        case .available(let info):
            HStack {
                Button(L("GitHub'da aç")) { NSWorkspace.shared.open(info.pageURL) }
                Button(L("Güncelle ve yeniden başlat")) { Task { await updates.install() } }
                    .buttonStyle(.borderedProminent)
            }
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        default:
            Button(L("Şimdi denetle")) { Task { await updates.check() } }
        }
    }

    private func row<Control: View>(title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(updates.state.isFailure ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
    }
}

private extension UpdateStore.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Shown above the disk gauge when a newer release exists.
struct UpdateBanner: View {
    let info: UpdateInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text(L("Sürüm \(info.version) hazır")).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .card(cornerRadius: 12, fill: Color.accentColor.opacity(0.12), stroke: Color.accentColor.opacity(0.35))
        }
        .buttonStyle(.plain)
    }
}
