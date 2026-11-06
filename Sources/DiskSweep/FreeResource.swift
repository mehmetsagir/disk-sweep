import SwiftUI
import AppKit
import DiskSweepCore

enum ResourceKind: String, CaseIterable, Identifiable {
    case memory, cpu, gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: return L("Bellek")
        case .cpu: return L("İşlemci")
        case .gpu: return "GPU"
        }
    }

    var symbol: String {
        switch self {
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .gpu: return "display"
        }
    }

    var tint: Color {
        switch self {
        case .memory: return .indigo
        case .cpu: return .blue
        case .gpu: return .teal
        }
    }
}

struct RunningAppRow: Identifiable {
    let pid: Int32
    let name: String
    let bundleID: String
    let icon: NSImage?
    let cpu: Double
    let memory: UInt64
    var id: Int32 { pid }
}

/// The user's regular (Dock) apps. Desktop essentials and this app are excluded by `QuitPolicy`.
@MainActor
enum AppControl {
    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && QuitPolicy.canQuit(bundleID: $0.bundleIdentifier)
        }
    }

    static func snapshot() async -> [RunningAppRow] {
        let apps = runningApps()
        let totals = await ProcessTree.snapshot(appPIDs: apps.map(\.processIdentifier))
        return apps.map { app in
            let usage = totals[app.processIdentifier]
            return RunningAppRow(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "?",
                                 bundleID: app.bundleIdentifier ?? "", icon: app.icon,
                                 cpu: usage?.cpu ?? 0, memory: usage?.memory ?? 0)
        }
    }

    /// Politely asks the app to quit; it can still ask to save.
    static func quit(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              QuitPolicy.canQuit(bundleID: app.bundleIdentifier) else { return }
        app.terminate()
    }

    /// Ends the app immediately. Unsaved work in it is lost.
    static func forceQuit(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              QuitPolicy.canQuit(bundleID: app.bundleIdentifier) else { return }
        app.forceTerminate()
    }
}

@MainActor @Observable
final class FreeResourceModel {
    var kind: ResourceKind
    var rows: [RunningAppRow] = []
    var isLoading = true
    var advice: [Int32: (safe: Bool, reason: String)] = [:]
    var isAsking = false
    var errorMessage: String?

    init(kind: ResourceKind) { self.kind = kind }

    /// GPU load cannot be read per app, so the heaviest apps by CPU stand in for it.
    var sorted: [RunningAppRow] {
        switch kind {
        case .memory: return rows.sorted { $0.memory > $1.memory }
        case .cpu, .gpu: return rows.sorted { $0.cpu > $1.cpu }
        }
    }

    func load() async {
        rows = await AppControl.snapshot()
        isLoading = false
    }

    func quit(_ row: RunningAppRow, force: Bool) {
        if force { AppControl.forceQuit(pid: row.pid) } else { AppControl.quit(pid: row.pid) }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await load()
        }
    }

    func askAgent(config: AgentConfig) {
        guard !isAsking else { return }
        guard let line = config.kind.commandLine(custom: config.customCommand) else {
            errorMessage = String(describing: AgentReviewError.notConfigured)
            return
        }
        let candidates = Array(sorted.prefix(25)).map {
            QuitCandidate(pid: $0.pid, name: $0.name, bundleID: $0.bundleID, cpu: $0.cpu, memory: $0.memory)
        }
        guard !candidates.isEmpty else { return }
        isAsking = true
        errorMessage = nil
        let prompt = QuitAdvice.buildPrompt(candidates)

        Task {
            let result = await AgentReview.runAgent(line: line, prompt: prompt)
            isAsking = false
            switch result {
            case .failure(let error):
                errorMessage = String(describing: error)
            case .success(let output):
                let parsed = QuitAdvice.parse(output, apps: candidates)
                if parsed.isEmpty { errorMessage = String(describing: AgentReviewError.unreadableReply) }
                withAnimation(Motion.smooth) { advice = parsed }
            }
        }
    }
}

struct FreeResourceSheet: View {
    @State private var model: FreeResourceModel
    @State private var forceTarget: RunningAppRow?
    @Environment(\.dismiss) private var dismiss
    let config: AgentConfig

    init(kind: ResourceKind, config: AgentConfig) {
        _model = State(initialValue: FreeResourceModel(kind: kind))
        self.config = config
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: model.kind.symbol, tint: model.kind.tint, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(model.kind.title) boşalt")).font(.system(size: 22, weight: .bold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $model.kind) {
                    ForEach(ResourceKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if model.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 160)
            } else if model.rows.isEmpty {
                Text(L("Kapatılabilecek açık uygulama yok.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.sorted.prefix(25)) { row in
                            AppRowView(row: row, kind: model.kind, advice: model.advice[row.pid],
                                       onQuit: { model.quit(row, force: false) },
                                       onForceQuit: { forceTarget = row })
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            HStack {
                Button {
                    model.askAgent(config: config)
                } label: {
                    if model.isAsking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("İnceleniyor…")) }
                    } else {
                        Label(L("AI'a sor: neler kapatılabilir?"), systemImage: "sparkles")
                    }
                }
                .disabled(model.isAsking || model.rows.isEmpty)
                Spacer()
                Button(L("Kapat")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .task { await model.load() }
        .confirmationDialog(
            forceTarget.map { L("\($0.name) zorla kapatılsın mı?") } ?? "",
            isPresented: Binding(get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Zorla Kapat"), role: .destructive) {
                if let target = forceTarget { model.quit(target, force: true) }
                forceTarget = nil
            }
            Button(L("Vazgeç"), role: .cancel) { forceTarget = nil }
        } message: {
            Text(L("Kaydedilmemiş değişiklikler kaybolur."))
        }
    }

    private var subtitle: String {
        switch model.kind {
        case .memory: return L("En çok bellek kullanan uygulamalar. Yardımcı süreçleri dahildir.")
        case .cpu: return L("En çok işlemci kullanan uygulamalar. Yardımcı süreçleri dahildir.")
        case .gpu: return L("GPU kullanımı uygulama bazında okunamaz; en yoğun uygulamalar işlemciye göre sıralanır.")
        }
    }
}

private struct AppRowView: View {
    let row: RunningAppRow
    let kind: ResourceKind
    let advice: (safe: Bool, reason: String)?
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    private var value: String {
        kind == .memory ? Format.bytes(Int64(row.memory)) : "\(Int(row.cpu.rounded()))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = row.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if let advice {
                        Image(systemName: advice.safe ? "sparkles" : "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(advice.safe ? Color.accentColor : Color.secondary)
                            .help(advice.reason.isEmpty
                                  ? (advice.safe ? L("AI: kapatılabilir") : L("AI: açık kalsın"))
                                  : advice.reason)
                    }
                }
                if let advice, !advice.reason.isEmpty {
                    Text(advice.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(value)
                .font(.system(.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(L("Kapat"), action: onQuit).controlSize(.small)
            Button(L("Zorla"), action: onForceQuit).controlSize(.small).tint(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .card(cornerRadius: 10, fill: advice?.safe == true ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
    }
}
