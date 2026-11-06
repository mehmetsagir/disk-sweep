import SwiftUI
import ServiceManagement
import DiskSweepCore

// MARK: - Preferences

enum AppSettings {
    static let showWindowAtLaunch = "app.showWindowAtLaunch"
    static let autoRefresh = "app.autoRefresh"
    static let sampleInterval = "menubar.interval"
    static let permanentDeletion = "cleanup.permanentDeletion"
    static let agentKind = "ai.agentKind"
    static let agentCustomCommand = "ai.customCommand"

    static func bool(_ key: String, default value: Bool) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    static var showWindowAtLaunchEnabled: Bool { bool(showWindowAtLaunch, default: true) }
    static var autoRefreshEnabled: Bool { bool(autoRefresh, default: true) }
    /// Off by default: items that would be deleted for good go to the Trash instead.
    static var permanentDeletionEnabled: Bool { bool(permanentDeletion, default: false) }

    /// Seconds between menu bar samples.
    static var sampleSeconds: Double {
        let value = UserDefaults.standard.double(forKey: sampleInterval)
        return value > 0 ? value : 2
    }
}

/// Lets other parts of the app (menu bar menu, ⌘,) ask the main window to show a page.
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()
    var request: String?
    /// Set by the menu bar (gauge names) or the command palette to open the "free up" sheet.
    var freeResourceRequest: ResourceKind?
    /// Bumped when the app language changes; the main window re-renders on it.
    var languageRevision = 0
    static let settingsPage = "settings"
    static let smartScanPage = "smartscan"
}

// MARK: - Launch at login

@MainActor @Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    var status = SMAppService.mainApp.status
    var errorMessage: String?

    /// "Requires approval" still means the user asked for it; macOS wants a confirmation.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    var isInApplicationsFolder: Bool { Bundle.main.bundlePath.hasPrefix("/Applications") }
}

// MARK: - Settings page

struct SettingsPage: View {
    let store: ScanStore
    @State private var launch = LaunchAtLogin.shared

    @AppStorage(AppSettings.showWindowAtLaunch) private var showWindowAtLaunch = true
    @AppStorage(AppSettings.autoRefresh) private var autoRefresh = true
    @AppStorage(MenuBarKey.cpu) private var showCPU = true
    @AppStorage(MenuBarKey.memory) private var showMemory = true
    @AppStorage(MenuBarKey.disk) private var showDisk = false
    @AppStorage(MenuBarKey.network) private var showNetwork = true
    @AppStorage(MenuBarKey.graphs) private var showGraphs = true
    @AppStorage(AppSettings.sampleInterval) private var interval = 2.0
    @AppStorage(AppSettings.permanentDeletion) private var permanentDeletion = false
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @AppStorage(AppSettings.agentKind) private var agentKind = AgentKind.claude.rawValue
    @AppStorage(AppSettings.agentCustomCommand) private var agentCustomCommand = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "gearshape.fill", tint: .gray, title: L("Ayarlar"),
                       summary: L("Başlangıç davranışı, menü çubuğu ve yenileme tercihleri. Değişiklikler hemen uygulanır."))

            ScrollView {
                VStack(spacing: 16) {
                    SettingsSection(title: L("Genel")) {
                        SettingRow(title: L("Oturum açıldığında başlat"), detail: launchDetail) {
                            Toggle("", isOn: Binding(get: { launch.isEnabled }, set: { launch.set($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        if launch.status == .requiresApproval {
                            SettingNotice(text: L("macOS onayınızı bekliyor: Sistem Ayarları → Genel → Giriş Öğeleri'nde DiskSweep'i açın."),
                                          buttonTitle: L("Giriş Öğeleri'ni Aç")) { launch.openSystemSettings() }
                        }
                        if let error = launch.errorMessage {
                            SettingNotice(text: error, tint: .red)
                        }
                        if launch.isEnabled && !launch.isInApplicationsFolder {
                            SettingNotice(text: L("Uygulama Uygulamalar klasöründe değil. Başlangıçta açılması için DiskSweep'i oraya taşıyıp ayarı yeniden açın."))
                        }
                        SettingRow(title: L("Dil"), detail: L("Uygulamanın dili. \"Sistem\" cihazın dilini izler.")) {
                            Picker("", selection: Binding(get: { language }, set: { changeLanguage($0) })) {
                                Text(L("Sistem")).tag(AppLanguage.system)
                                Text("Türkçe").tag(AppLanguage.tr)
                                Text("English").tag(AppLanguage.en)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        if languageChanged {
                            SettingNotice(text: L("Menü çubuğu paneli, uygulama yeniden başlayınca yeni dile geçer."),
                                          tint: .accentColor, buttonTitle: L("Yeniden başlat")) { Self.relaunch() }
                        }
                        SettingRow(title: L("Açılışta ana pencereyi göster"),
                                   detail: L("Kapalıyken DiskSweep yalnızca menü çubuğunda başlar.")) {
                            Toggle("", isOn: $showWindowAtLaunch).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(title: L("Sayfaları otomatik yenile"),
                                   detail: L("Açık sayfa yaklaşık 30 saniyede bir, eskiyen sayfalar uygulamaya dönünce taranır.")) {
                            Toggle("", isOn: $autoRefresh).labelsHidden().toggleStyle(.switch)
                        }
                    }

                    SettingsSection(title: L("Menü çubuğu")) {
                        SettingRow(title: L("İşlemci (CPU)")) { Toggle("", isOn: $showCPU).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: L("Bellek (RAM)")) { Toggle("", isOn: $showMemory).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: "Disk") { Toggle("", isOn: $showDisk).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: L("Ağ")) { Toggle("", isOn: $showNetwork).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: L("Mini grafikleri göster"),
                                   detail: L("Kapalıyken menü çubuğunda yalnızca yazılar görünür.")) {
                            Toggle("", isOn: $showGraphs).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(title: L("Güncelleme sıklığı"),
                                   detail: L("Daha sık güncelleme biraz daha fazla işlemci kullanır.")) {
                            Picker("", selection: $interval) {
                                Text(L("1 sn")).tag(1.0)
                                Text(L("2 sn")).tag(2.0)
                                Text(L("5 sn")).tag(5.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }
                    }

                    SettingsSection(title: L("Temizlik")) {
                        SettingRow(title: L("Dışlanan klasörler"),
                                   detail: store.excludedFolders.isEmpty
                                       ? L("Hiç klasör dışlanmadı.")
                                       : L("\(store.excludedFolders.count) klasörde hiçbir işlem yapılmaz.")) {
                            Button(L("Yönet…")) { store.showExclusions = true }
                        }
                        SettingRow(title: L("Kalıcı olarak sil"),
                                   detail: permanentDeletion
                                       ? L("Önbellek ve benzeri öğeler geri alınamaz şekilde silinir; alan hemen boşalır. Yedekler ve arşivler yine Çöp Kutusu'na gider.")
                                       : L("Öğeler Çöp Kutusu'na taşınır ve geri alınabilir. Alan, Çöp Kutusu boşaltılınca açılır.")) {
                            Toggle("", isOn: $permanentDeletion).labelsHidden().toggleStyle(.switch)
                        }
                    }

                    SettingsSection(title: L("AI ajanı")) {
                        SettingRow(title: L("Ajan"),
                                   detail: L("\"AI ile incele\" seçilen ajanı salt okunur çalıştırır. Ajan yalnızca hangi öğelerin işaretleneceğini söyler; silme yine onayınla ve güvenlik kontrolüyle yapılır.")) {
                            Picker("", selection: $agentKind) {
                                ForEach(AgentKind.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        if agentKind == AgentKind.custom.rawValue {
                            SettingRow(title: L("Özel komut"),
                                       detail: L("Komut istemi $DISKSWEEP_PROMPT ortam değişkeninden okur ve cevabı çıktıya yazar. Örnek: mycli --prompt \"$DISKSWEEP_PROMPT\"")) {
                                TextField("mycli \"$DISKSWEEP_PROMPT\"", text: $agentCustomCommand)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                            }
                        }
                    }

                    LowSpaceSettingsSection()

                    UpdateSettingsSection()

                    SettingsSection(title: L("Hakkında")) {
                        HStack(spacing: 14) {
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DiskSweep").font(.headline)
                                Text(L("Sürüm \(Self.version)")).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .frame(minHeight: 200, idealHeight: 400, maxHeight: .infinity)
        }
        .onAppear { launch.refresh() }
    }

    private func changeLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        AppLanguage.current = new
        languageChanged = true
        // Rebuilds the main window so every L() string is read again.
        AppNavigation.shared.languageRevision += 1
    }

    /// Starts a fresh copy of the app once this one has quit.
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        AppLifecycle.quit()
    }

    private var launchDetail: String {
        switch launch.status {
        case .enabled: return L("Mac'e giriş yaptığında DiskSweep otomatik açılır.")
        case .requiresApproval: return L("İstendi; macOS'un onayı bekleniyor.")
        // `notFound` is what macOS reports for an app that was never registered as a login item.
        case .notFound, .notRegistered: return L("Kapalı. Açarsan menü çubuğu okumaları her açılışta hazır olur.")
        @unknown default: return ""
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack(spacing: 0) { content }
                .card(cornerRadius: 14)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
    }
}

private struct SettingNotice: View {
    let text: String
    var tint: Color = .orange
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
