import SwiftUI
import ServiceManagement
import DiskSweepCore

// MARK: - Preferences

enum AppSettings {
    static let showWindowAtLaunch = "app.showWindowAtLaunch"
    static let autoRefresh = "app.autoRefresh"
    static let sampleInterval = "menubar.interval"

    static func bool(_ key: String, default value: Bool) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    static var showWindowAtLaunchEnabled: Bool { bool(showWindowAtLaunch, default: true) }
    static var autoRefreshEnabled: Bool { bool(autoRefresh, default: true) }

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
    static let settingsPage = "settings"
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

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "gearshape.fill", tint: .gray, title: "Ayarlar",
                       summary: "Başlangıç davranışı, menü çubuğu ve yenileme tercihleri. Değişiklikler hemen uygulanır.")

            ScrollView {
                VStack(spacing: 16) {
                    SettingsSection(title: "Genel") {
                        SettingRow(title: "Oturum açıldığında başlat", detail: launchDetail) {
                            Toggle("", isOn: Binding(get: { launch.isEnabled }, set: { launch.set($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        if launch.status == .requiresApproval {
                            SettingNotice(text: "macOS onayınızı bekliyor: Sistem Ayarları → Genel → Giriş Öğeleri'nde DiskSweep'i açın.",
                                          buttonTitle: "Giriş Öğeleri'ni Aç") { launch.openSystemSettings() }
                        }
                        if let error = launch.errorMessage {
                            SettingNotice(text: error, tint: .red)
                        }
                        if launch.isEnabled && !launch.isInApplicationsFolder {
                            SettingNotice(text: "Uygulama Uygulamalar klasöründe değil. Başlangıçta açılması için DiskSweep'i oraya taşıyıp ayarı yeniden açın.")
                        }
                        SettingRow(title: "Açılışta ana pencereyi göster",
                                   detail: "Kapalıyken DiskSweep yalnızca menü çubuğunda başlar.") {
                            Toggle("", isOn: $showWindowAtLaunch).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(title: "Sayfaları otomatik yenile",
                                   detail: "Açık sayfa yaklaşık 30 saniyede bir, eskiyen sayfalar uygulamaya dönünce taranır.") {
                            Toggle("", isOn: $autoRefresh).labelsHidden().toggleStyle(.switch)
                        }
                    }

                    SettingsSection(title: "Menü çubuğu") {
                        SettingRow(title: "İşlemci (CPU)") { Toggle("", isOn: $showCPU).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: "Bellek (RAM)") { Toggle("", isOn: $showMemory).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: "Disk") { Toggle("", isOn: $showDisk).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: "Ağ") { Toggle("", isOn: $showNetwork).labelsHidden().toggleStyle(.switch) }
                        SettingRow(title: "Mini grafikleri göster",
                                   detail: "Kapalıyken menü çubuğunda yalnızca yazılar görünür.") {
                            Toggle("", isOn: $showGraphs).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(title: "Güncelleme sıklığı",
                                   detail: "Daha sık güncelleme biraz daha fazla işlemci kullanır.") {
                            Picker("", selection: $interval) {
                                Text("1 sn").tag(1.0)
                                Text("2 sn").tag(2.0)
                                Text("5 sn").tag(5.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }
                    }

                    SettingsSection(title: "Temizlik") {
                        SettingRow(title: "Dışlanan klasörler",
                                   detail: store.excludedFolders.isEmpty
                                       ? "Hiç klasör dışlanmadı."
                                       : "\(store.excludedFolders.count) klasörde hiçbir işlem yapılmaz.") {
                            Button("Yönet…") { store.showExclusions = true }
                        }
                    }

                    SettingsSection(title: "Hakkında") {
                        HStack(spacing: 14) {
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DiskSweep").font(.headline)
                                Text("Sürüm \(Self.version)").font(.callout).foregroundStyle(.secondary)
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

    private var launchDetail: String {
        switch launch.status {
        case .enabled: return "Mac'e giriş yaptığında DiskSweep otomatik açılır."
        case .requiresApproval: return "İstendi; macOS'un onayı bekleniyor."
        // `notFound` is what macOS reports for an app that was never registered as a login item.
        case .notFound, .notRegistered: return "Kapalı. Açarsan menü çubuğu okumaları her açılışta hazır olur."
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
