import SwiftUI
import DiskSweepCore

// MARK: - Shared building blocks

private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Frame shared by every detail popover: header, content, graph toggle and footer.
struct DetailShell<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let value: String
    var valueTint: Color?
    let openMainWindow: () -> Void
    @ViewBuilder let content: Content
    @State private var bodyHeight: CGFloat = 0

    /// Room left for the scrolling body: the smallest connected screen minus menu bar,
    /// header, toggle, footer and margins.
    static var maxBodyHeight: CGFloat {
        let smallest = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        return max(240, min(smallest - 230, 720))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(valueTint ?? .primary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 4)

            // The body scrolls when the panel would not fit on the screen (e.g. a laptop display).
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) { content }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: BodyHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: bodyHeight > 0 ? min(bodyHeight, DetailShell.maxBodyHeight) : DetailShell.maxBodyHeight)
            .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }

            MenuBarToggles()

            HStack {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: { Label("Etkinlik Monitörü", systemImage: "waveform.path.ecg") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: openMainWindow) { Label("DiskSweep'i aç", systemImage: "macwindow") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("Çıkış") { AppLifecycle.quit() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            .font(.callout)
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 12)
    }
}

struct Segment: Identifiable {
    let id = UUID()
    let value: Double
    let color: Color
}

struct SegmentedBar: View {
    let segments: [Segment]

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + max($1.value, 0) }, 0.000_001)
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, (proxy.size.width - 6) * segment.value / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .animation(Motion.smooth, value: segments.map(\.value))
    }
}

struct LegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.callout, design: .rounded).weight(.medium).monospacedDigit())
        }
    }
}

enum ProcessMetric { case cpu, memory }

struct ProcessList: View {
    let processes: [ProcessUsage]
    let metric: ProcessMetric
    let tint: Color
    var totalMemory: UInt64 = 1

    var body: some View {
        if processes.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("İşlemler okunuyor…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            let peak = max(processes.map(\.cpu).max() ?? 1, 100)
            VStack(spacing: 9) {
                ForEach(processes) { process in
                    VStack(spacing: 4) {
                        HStack {
                            Text(process.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text(metric == .cpu ? "\(Int(process.cpu.rounded()))%" : Format.bytes(Int64(process.memory)))
                                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        LevelBar(fraction: metric == .cpu ? process.cpu / peak
                                                          : Double(process.memory) / Double(max(totalMemory, 1)),
                                 tint: tint)
                    }
                }
            }
            // Rows re-sort every sample; animating that cross-fades names on top of each other.
            .transaction { $0.animation = nil }
        }
    }
}

// MARK: - CPU

struct CPUDetail: View {
    let monitor: SystemMonitor
    let openMainWindow: () -> Void

    private var tint: Color { monitor.cpu > 0.85 ? .red : (monitor.cpu > 0.6 ? .orange : .blue) }

    private var coreSummary: String {
        let info = monitor.info
        if let performance = info.performanceCores, let efficiency = info.efficiencyCores {
            return "\(performance) performans + \(efficiency) verimlilik"
        }
        return "\(info.logicalCores) mantıksal çekirdek"
    }

    var body: some View {
        DetailShell(symbol: "cpu", tint: .blue, title: "İşlemci", subtitle: monitor.info.cpuModel,
                    value: percent(monitor.cpu), valueTint: tint, openMainWindow: openMainWindow) {
            DetailCard(title: "Kullanım geçmişi") {
                Sparkline(values: monitor.cpuHistory, tint: tint, ceiling: 1).frame(height: 62)
            }

            DetailCard(title: "Dağılım") {
                SegmentedBar(segments: [
                    Segment(value: monitor.cpuUser, color: .blue),
                    Segment(value: monitor.cpuSystem, color: .red),
                    Segment(value: monitor.cpuIdle, color: Color.primary.opacity(0.15)),
                ])
                HStack {
                    LegendRow(color: .blue, label: "Kullanıcı", value: percent(monitor.cpuUser))
                    LegendRow(color: .red, label: "Sistem", value: percent(monitor.cpuSystem))
                }
                LegendRow(color: Color.primary.opacity(0.3), label: "Boşta", value: percent(monitor.cpuIdle))
            }

            DetailCard(title: "Çekirdekler · \(coreSummary)") {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(monitor.cores.enumerated()), id: \.offset) { index, load in
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottom) {
                                Capsule().fill(tint.opacity(0.12))
                                Capsule().fill(tint.opacity(0.45 + 0.55 * load))
                                    .frame(height: max(4, 44 * load))
                            }
                            .frame(height: 44)
                            Text("\(index + 1)").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .animation(Motion.smooth, value: monitor.cores)
            }

            DetailCard(title: "Sistem") {
                InfoRow(label: "Yük ortalaması (1 · 5 · 15 dk)",
                        value: String(format: "%.2f · %.2f · %.2f", monitor.load.one, monitor.load.five, monitor.load.fifteen))
                InfoRow(label: "Çalışma süresi", value: Format.duration(monitor.uptime))
            }

            DetailCard(title: "En çok işlemci kullananlar") {
                ProcessList(processes: monitor.topCPU, metric: .cpu, tint: tint)
            }
        }
    }
}

// MARK: - Memory

struct MemoryDetail: View {
    let monitor: SystemMonitor
    let openMainWindow: () -> Void

    private var pressure: (label: String, tint: Color) {
        switch monitor.memory.pressure {
        case .normal: return ("Normal", .green)
        case .warning: return ("Yüksek", .orange)
        case .critical: return ("Kritik", .red)
        }
    }

    private func size(_ bytes: UInt64) -> String { Format.bytes(Int64(bytes)) }

    var body: some View {
        let memory = monitor.memory
        DetailShell(symbol: "memorychip", tint: .purple, title: "Bellek",
                    subtitle: "\(size(memory.used)) / \(size(memory.total))",
                    value: percent(memory.fraction), valueTint: pressure.tint == .green ? nil : pressure.tint,
                    openMainWindow: openMainWindow) {
            DetailCard(title: "Kullanım geçmişi") {
                Sparkline(values: monitor.memoryHistory, tint: pressure.tint == .green ? .purple : pressure.tint, ceiling: 1)
                    .frame(height: 62)
            }

            DetailCard(title: "Dağılım") {
                SegmentedBar(segments: [
                    Segment(value: Double(memory.app), color: .purple),
                    Segment(value: Double(memory.wired), color: .orange),
                    Segment(value: Double(memory.compressed), color: .pink),
                    Segment(value: Double(memory.cached), color: .blue.opacity(0.6)),
                    Segment(value: Double(memory.free), color: Color.primary.opacity(0.15)),
                ])
                LegendRow(color: .purple, label: "Uygulama belleği", value: size(memory.app))
                LegendRow(color: .orange, label: "Sabit (wired)", value: size(memory.wired))
                LegendRow(color: .pink, label: "Sıkıştırılmış", value: size(memory.compressed))
                LegendRow(color: .blue.opacity(0.6), label: "Önbellek (boşaltılabilir)", value: size(memory.cached))
                LegendRow(color: Color.primary.opacity(0.3), label: "Boş", value: size(memory.free))
            }

            DetailCard(title: "Bellek baskısı ve takas") {
                HStack {
                    Text("Bellek baskısı").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(pressure.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(pressure.tint)
                        .background(Capsule().fill(pressure.tint.opacity(0.18)))
                }
                if memory.swapTotal > 0 {
                    LevelBar(fraction: Double(memory.swapUsed) / Double(memory.swapTotal), tint: .orange)
                    InfoRow(label: "Takas kullanımı", value: "\(size(memory.swapUsed)) / \(size(memory.swapTotal))")
                } else {
                    InfoRow(label: "Takas kullanımı", value: "Yok")
                }
            }

            DetailCard(title: "En çok bellek kullananlar") {
                ProcessList(processes: monitor.topMemory, metric: .memory, tint: .purple, totalMemory: memory.total)
            }
        }
    }
}

// MARK: - Disk

struct DiskDetail: View {
    let monitor: SystemMonitor
    let openMainWindow: () -> Void

    var body: some View {
        let disk = monitor.disk
        let low = disk.freeFraction < 0.10
        let bootName = monitor.volumes.first { $0.path == "/" }?.name ?? "Disk"
        DetailShell(symbol: "internaldrive", tint: .teal, title: "Disk", subtitle: bootName,
                    value: Format.bytes(disk.available), valueTint: low ? .red : nil,
                    openMainWindow: openMainWindow) {
            DetailCard(title: "Birimler") {
                ForEach(monitor.volumes) { volume in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                .foregroundStyle(.secondary)
                            Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(volume.isReadOnly ? "Salt okunur" : "\(Format.bytes(volume.available)) boş")
                                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                                .foregroundStyle(volume.isReadOnly ? .secondary : .primary)
                        }
                        if volume.isReadOnly {
                            Text("\(Format.bytes(volume.total)) · bağlı disk görüntüsü")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            LevelBar(fraction: volume.usedFraction, tint: volume.usedFraction > 0.9 ? .red : .teal)
                            Text("\(Format.bytes(volume.used)) kullanılıyor · \(Format.bytes(volume.total)) toplam")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            DetailCard(title: "Okuma / Yazma hızı") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(Format.rate(monitor.diskRead), systemImage: "arrow.down.doc")
                            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(.blue)
                        Sparkline(values: monitor.diskReadHistory, tint: .blue).frame(height: 40)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(Format.rate(monitor.diskWrite), systemImage: "arrow.up.doc")
                            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Sparkline(values: monitor.diskWriteHistory, tint: .orange).frame(height: 40)
                    }
                }
            }

            Button(action: openMainWindow) {
                Label("DiskSweep ile temizle…", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Network

struct NetworkDetail: View {
    let monitor: SystemMonitor
    let openMainWindow: () -> Void

    private var primary: NetworkInterface? {
        monitor.interfaces.first { $0.ipv4 != nil }
    }

    var body: some View {
        DetailShell(symbol: "arrow.up.arrow.down", tint: .green, title: "Ağ",
                    subtitle: primary.map { "\($0.name) · \($0.ipv4 ?? "")" } ?? "Bağlantı yok",
                    value: "↓ " + Format.compactRate(monitor.download), openMainWindow: openMainWindow) {
            HStack(spacing: 10) {
                DetailCard(title: "İndirme") {
                    Text(Format.rate(monitor.download))
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(.green)
                    Sparkline(values: monitor.downloadHistory, tint: .green).frame(height: 46)
                }
                DetailCard(title: "Yükleme") {
                    Text(Format.rate(monitor.upload))
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                    Sparkline(values: monitor.uploadHistory, tint: .orange).frame(height: 46)
                }
            }

            DetailCard(title: "DiskSweep açıldığından beri") {
                InfoRow(label: "İndirilen", value: Format.bytes(Int64(monitor.sessionDownloaded)))
                InfoRow(label: "Yüklenen", value: Format.bytes(Int64(monitor.sessionUploaded)))
            }

            DetailCard(title: "Arayüzler") {
                if monitor.interfaces.isEmpty {
                    Text("Etkin ağ arayüzü yok").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.interfaces) { interface in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(interface.name).font(.callout.weight(.semibold))
                                Spacer()
                                Text(interface.ipv4 ?? "IP yok")
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text("↓ \(Format.rate(interface.down))   ↑ \(Format.rate(interface.up))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
