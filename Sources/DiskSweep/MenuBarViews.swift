import SwiftUI
import DiskSweepCore

// MARK: - Menu bar items (iStat Menus style)
//
// Every reading is its own status item: a tiny label over a bold value, with a
// mini graph beside it. The artwork is drawn as a monochrome template image so
// macOS tints it for light/dark menu bars and wallpapers.

enum MenuBarMetric: String, CaseIterable {
    case cpu, memory, disk, network

    var storageKey: String { "menubar.\(rawValue)" }

    var menuTitle: String {
        switch self {
        case .cpu: return "İşlemci (CPU)"
        case .memory: return "Bellek (RAM)"
        case .disk: return "Disk"
        case .network: return "Ağ"
        }
    }
    var defaultOn: Bool { self != .disk }

    var isOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: storageKey) == nil ? defaultOn : defaults.bool(forKey: storageKey)
    }
}

@MainActor
private enum TemplateRenderer {
    static func image<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = true
        return image
    }
}

private struct StackedReading: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.6)
                .opacity(0.62)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(.black)
    }
}

private struct CPUMenuBarArt: View {
    let history: [Double]
    let value: Double
    let showGraph: Bool

    var body: some View {
        HStack(spacing: 5) {
            StackedReading(label: "CPU", value: "\(Int((value * 100).rounded()))%")
                .frame(width: 31, alignment: .leading)
            if showGraph {
                Sparkline(values: Array(history.suffix(20)), tint: .black, ceiling: 1, length: 20)
                    .frame(width: 28, height: 15)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 20)
    }
}

private struct MemoryMenuBarArt: View {
    let fraction: Double
    let showGraph: Bool

    var body: some View {
        HStack(spacing: 5) {
            StackedReading(label: "RAM", value: "\(Int((fraction * 100).rounded()))%")
                .frame(width: 31, alignment: .leading)
            if showGraph {
                ZStack {
                    Circle().stroke(Color.black.opacity(0.28), lineWidth: 3.2)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(fraction, 1)))
                        .stroke(Color.black, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 20)
    }
}

private struct DiskMenuBarArt: View {
    let disk: DiskUsage
    let showGraph: Bool

    private var free: String {
        let gigabytes = Double(disk.available) / 1_000_000_000
        return gigabytes >= 100 ? "\(Int(gigabytes.rounded()))G" : String(format: "%.0fG", gigabytes)
    }

    var body: some View {
        HStack(spacing: 5) {
            StackedReading(label: "DISK", value: free)
                .frame(width: 33, alignment: .leading)
            if showGraph {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.28))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black)
                        .frame(height: 15 * CGFloat(min(max(Double(disk.used) / Double(max(disk.total, 1)), 0.05), 1)))
                }
                .frame(width: 5, height: 15)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 20)
    }
}

private struct NetworkMenuBarArt: View {
    let download: Double
    let upload: Double

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            row(symbol: "arrow.down", value: Format.compactRate(download))
            row(symbol: "arrow.up", value: Format.compactRate(upload))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 3)
        .frame(width: 52, height: 20, alignment: .leading)
    }

    private func row(symbol: String, value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 7, weight: .heavy)).opacity(0.7)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }
}


// MARK: - Status item controller (AppKit)

/// One NSStatusItem per reading, like iStat Menus. Items can be dragged to reorder
/// (macOS remembers the position). Each opens its own detail popover; the fallback
/// icon (shown only when every reading is hidden) opens the overview.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let monitor: SystemMonitor
    private var items: [MenuBarMetric: NSStatusItem] = [:]
    private var popovers: [MenuBarMetric: NSPopover] = [:]
    private let fallbackItem: NSStatusItem
    private let overviewPopover = NSPopover()
    private weak var anchor: NSView?
    /// Content is built when a popover opens and dropped when it closes: hidden SwiftUI
    /// views would otherwise keep re-evaluating on every sample for nothing.
    private var builders: [ObjectIdentifier: () -> NSViewController] = [:]
    /// Our own settings last applied, and what each status item currently shows.
    private var appliedConfig: [Bool] = []
    private var shownSignatures: [MenuBarMetric: String] = [:]

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        fallbackItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let openMain: () -> Void = { [weak self] in self?.openMainWindow() }
        configure(overviewPopover, content: SystemPopover(monitor: monitor, openMainWindow: openMain))
        popovers[.cpu] = makePopover(CPUDetail(monitor: monitor, openMainWindow: openMain))
        popovers[.memory] = makePopover(MemoryDetail(monitor: monitor, openMainWindow: openMain))
        popovers[.disk] = makePopover(DiskDetail(monitor: monitor, openMainWindow: openMain))
        popovers[.network] = makePopover(NetworkDetail(monitor: monitor, openMainWindow: openMain))

        // The newest status item lands on the left, so create them right-to-left.
        for metric in MenuBarMetric.allCases.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            configure(item)
            items[metric] = item
        }
        configure(fallbackItem)
        let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "DiskSweep")
        symbol?.isTemplate = true
        fallbackItem.button?.image = symbol

        // UserDefaults posts this for EVERY change in the process, including the writes
        // NSStatusItem itself makes when an image is set. React only to our own settings,
        // otherwise updating an image would trigger another update, forever.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let config = self.currentConfig()
                guard config != self.appliedConfig else { return }
                self.syncVisibility()
            }
        }
        monitor.onUpdate = { [weak self] in self?.refreshImages() }
        syncVisibility()
        refreshImages()
    }

    private func makePopover<V: View>(_ content: V) -> NSPopover {
        let popover = NSPopover()
        configure(popover, content: content)
        return popover
    }

    private func configure<V: View>(_ popover: NSPopover, content: V) {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        builders[ObjectIdentifier(popover)] = { NSHostingController(rootView: content) }
    }

    private func configure(_ item: NSStatusItem) {
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private var allPopovers: [NSPopover] { Array(popovers.values) + [overviewPopover] }

    private func currentConfig() -> [Bool] {
        MenuBarMetric.allCases.map(\.isOn) + [MenuBarKey.graphsEnabled]
    }

    private func syncVisibility() {
        appliedConfig = currentConfig()
        shownSignatures.removeAll()
        var anyVisible = false
        for (metric, item) in items {
            let on = metric.isOn
            if item.isVisible != on { item.isVisible = on }
            anyVisible = anyVisible || on
        }
        // With every reading hidden the panel would be unreachable, so a plain icon takes over.
        if fallbackItem.isVisible == anyVisible { fallbackItem.isVisible = !anyVisible }
        // A popover must not stay open under an item that just disappeared.
        for (metric, popover) in popovers where !metric.isOn && popover.isShown { popover.performClose(nil) }
        refreshImages()
    }

    private func refreshImages() {
        let showGraph = MenuBarKey.graphsEnabled
        for (metric, item) in items where item.isVisible {
            // Skip identical artwork: assigning an image forces a layout pass.
            let signature = signature(for: metric, showGraph: showGraph)
            guard shownSignatures[metric] != signature else { continue }
            shownSignatures[metric] = signature
            item.button?.image = TemplateRenderer.image(art(for: metric, showGraph: showGraph))
        }
    }

    private func signature(for metric: MenuBarMetric, showGraph: Bool) -> String {
        switch metric {
        case .cpu:
            let graph = showGraph ? monitor.cpuHistory.suffix(20).map { Int($0 * 100) } : []
            return "\(Int(monitor.cpu * 100))|\(graph)"
        case .memory:
            return "\(Int(monitor.memory.fraction * 100))|\(showGraph)"
        case .disk:
            return "\(monitor.disk.available / 1_000_000_000)|\(Int(Double(monitor.disk.used) / Double(max(monitor.disk.total, 1)) * 100))|\(showGraph)"
        case .network:
            return "\(Format.compactRate(monitor.download))|\(Format.compactRate(monitor.upload))"
        }
    }

    @ViewBuilder private func art(for metric: MenuBarMetric, showGraph: Bool) -> some View {
        switch metric {
        case .cpu: CPUMenuBarArt(history: monitor.cpuHistory, value: monitor.cpu, showGraph: showGraph)
        case .memory: MemoryMenuBarArt(fraction: monitor.memory.fraction, showGraph: showGraph)
        case .disk: DiskMenuBarArt(disk: monitor.disk, showGraph: showGraph)
        case .network: NetworkMenuBarArt(download: monitor.download, upload: monitor.upload)
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick, let item = ([fallbackItem] + Array(items.values)).first(where: { $0.button === sender }) {
            showContextMenu(for: item)
            return
        }
        let metric = items.first { $0.value.button === sender }?.key
        let target = metric.flatMap { popovers[$0] } ?? overviewPopover

        let reopeningSame = target.isShown
        allPopovers.filter(\.isShown).forEach { $0.performClose(nil) }
        if reopeningSame { return }

        monitor.detailActive = true
        anchor = sender
        target.contentViewController = builders[ObjectIdentifier(target)]?()
        target.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        target.contentViewController?.view.window?.makeKey()
    }

    /// Screenshot testing only (`-DiskSweepShowPopover cpu`): opens a reading's popover.
    func showPopoverForTesting(_ metric: MenuBarMetric) {
        if let button = items[metric]?.button { togglePopover(button) }
    }

    /// Screenshot testing only (`-DiskSweepShowMenu cpu`): opens a reading's right-click menu.
    func showContextMenuForTesting(_ metric: MenuBarMetric) {
        if let item = items[metric] { showContextMenu(for: item) }
    }

    func popoverDidClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.contentViewController = nil
        monitor.detailActive = allPopovers.contains { $0.isShown }
    }

    // MARK: Right-click menu

    private func showContextMenu(for item: NSStatusItem) {
        allPopovers.filter(\.isShown).forEach { $0.performClose(nil) }
        let menu = NSMenu()
        for metric in MenuBarMetric.allCases {
            let entry = NSMenuItem(title: metric.menuTitle, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = metric.rawValue
            entry.state = metric.isOn ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let graphs = NSMenuItem(title: "Menü çubuğunda grafik", action: #selector(toggleGraphs), keyEquivalent: "")
        graphs.target = self
        graphs.state = MenuBarKey.graphsEnabled ? .on : .off
        menu.addItem(graphs)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "DiskSweep'i Aç", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Ayarlar…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "DiskSweep'ten Çık", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        // Showing a menu on a status item is done by attaching it for the duration of one click.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = MenuBarMetric(rawValue: raw) else { return }
        UserDefaults.standard.set(!metric.isOn, forKey: metric.storageKey)
    }

    @objc private func toggleGraphs() {
        UserDefaults.standard.set(!MenuBarKey.graphsEnabled, forKey: MenuBarKey.graphs)
    }

    @objc private func openFromMenu() { openMainWindow() }

    @objc private func openSettingsFromMenu() {
        AppNavigation.shared.request = AppNavigation.settingsPage
        openMainWindow()
    }
    @objc private func quitFromMenu() { AppLifecycle.quit() }

    func openMainWindow() {
        allPopovers.filter(\.isShown).forEach { $0.performClose(nil) }
        // The Dock icon is hidden while only the menu bar runs; bring it back with the window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "DiskSweep" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // No window yet: re-opening the app makes SwiftUI create it.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

// MARK: - Popover

struct SystemPopover: View {
    let monitor: SystemMonitor
    let openMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            CPUCard(monitor: monitor)
            MemoryCard(monitor: monitor)
            DiskCard(monitor: monitor, onClean: openMainWindow)
            NetworkCard(monitor: monitor)
            if let battery = monitor.battery { BatteryCard(battery: battery) }
            MenuBarToggles()

            HStack {
                Button(action: openMainWindow) { Label("DiskSweep'i aç", systemImage: "macwindow") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Çıkış") { AppLifecycle.quit() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 350)
    }

}

// MARK: - Cards

struct MetricCard<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var valueTint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, tint: tint, size: 22)
                Text(title).font(.headline)
                Spacer()
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(valueTint ?? .primary)
                    .contentTransition(.numericText())
            }
            content
        }
        .padding(12)
        .card(cornerRadius: 14)
    }
}

struct LevelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 7)
        .animation(Motion.smooth, value: fraction)
    }
}

private struct CPUCard: View {
    let monitor: SystemMonitor

    private var tint: Color { monitor.cpu > 0.85 ? .red : (monitor.cpu > 0.6 ? .orange : .blue) }

    var body: some View {
        MetricCard(symbol: "cpu", tint: .blue, title: "İşlemci",
                   value: "\(Int((monitor.cpu * 100).rounded()))%", valueTint: tint) {
            Sparkline(values: monitor.cpuHistory, tint: tint, ceiling: 1).frame(height: 34)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(monitor.cores.enumerated()), id: \.offset) { _, load in
                    Capsule()
                        .fill(tint.opacity(0.35 + 0.65 * load))
                        .frame(height: max(3, 22 * load))
                }
            }
            .frame(height: 22, alignment: .bottom)
            .animation(Motion.smooth, value: monitor.cores)
            Text("\(monitor.cores.count) çekirdek")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryCard: View {
    let monitor: SystemMonitor

    private var pressure: (label: String, tint: Color) {
        switch monitor.memory.pressure {
        case .normal: return ("Bellek baskısı normal", .green)
        case .warning: return ("Bellek baskısı yüksek", .orange)
        case .critical: return ("Bellek baskısı kritik", .red)
        }
    }

    var body: some View {
        let memory = monitor.memory
        MetricCard(symbol: "memorychip", tint: .purple, title: "Bellek",
                   value: "\(Int((memory.fraction * 100).rounded()))%", valueTint: pressure.tint) {
            LevelBar(fraction: memory.fraction, tint: pressure.tint == .green ? .purple : pressure.tint)
            HStack {
                Text("\(Format.bytes(Int64(memory.used))) / \(Format.bytes(Int64(memory.total)))")
                    .font(.callout.monospacedDigit())
                Spacer()
                Label(pressure.label, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(pressure.tint)
                    .labelStyle(DotLabelStyle())
            }
        }
    }
}

private struct DiskCard: View {
    let monitor: SystemMonitor
    let onClean: () -> Void

    var body: some View {
        let disk = monitor.disk
        let low = disk.freeFraction < 0.10
        let tint: Color = low ? .red : .teal
        MetricCard(symbol: "internaldrive", tint: .teal, title: "Disk",
                   value: Format.bytes(disk.available), valueTint: low ? .red : nil) {
            LevelBar(fraction: Double(disk.used) / Double(max(disk.total, 1)), tint: tint)
            HStack {
                Text("\(Format.bytes(disk.used)) kullanılıyor · \(Format.bytes(disk.total)) toplam")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Temizle…", action: onClean)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct NetworkCard: View {
    let monitor: SystemMonitor

    var body: some View {
        MetricCard(symbol: "arrow.up.arrow.down", tint: .green, title: "Ağ",
                   value: "↓ " + Format.compactRate(monitor.download)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(Format.rate(monitor.download), systemImage: "arrow.down")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.green)
                    Sparkline(values: monitor.downloadHistory, tint: .green).frame(height: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label(Format.rate(monitor.upload), systemImage: "arrow.up")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.orange)
                    Sparkline(values: monitor.uploadHistory, tint: .orange).frame(height: 26)
                }
            }
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryStatus

    private var tint: Color { battery.percent <= 20 && !battery.isCharging ? .red : .green }

    private var detail: String {
        var text = battery.isCharging ? "Şarj oluyor" : (battery.onACPower ? "Prize bağlı" : "Pil kullanılıyor")
        if let minutes = battery.minutesRemaining, minutes > 0 {
            text += " · \(minutes / 60) sa \(minutes % 60) dk"
        }
        return text
    }

    var body: some View {
        MetricCard(symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent", tint: .green,
                   title: "Pil", value: "\(battery.percent)%", valueTint: tint) {
            LevelBar(fraction: Double(battery.percent) / 100, tint: tint)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Menu bar toggles

struct MenuBarToggles: View {
    @AppStorage(MenuBarKey.cpu) private var cpu = true
    @AppStorage(MenuBarKey.memory) private var memory = true
    @AppStorage(MenuBarKey.disk) private var disk = false
    @AppStorage(MenuBarKey.network) private var network = true
    @AppStorage(MenuBarKey.graphs) private var graphs = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Menü çubuğunda göster")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            HStack(spacing: 4) {
                Chip(title: "CPU", isOn: $cpu)
                Chip(title: "RAM", isOn: $memory)
                Chip(title: "Disk", isOn: $disk)
                Chip(title: "Ağ", isOn: $network)
                Chip(title: "Grafik", isOn: $graphs)
            }
        }
    }
}

private struct Chip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isOn.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : .clear))
            .foregroundStyle(isOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let tint: Color
    /// Fixed top of the scale (e.g. 1 for percentages); `nil` scales to the largest value seen.
    var ceiling: Double?
    var length = SystemMonitor.historyLength

    var body: some View {
        GeometryReader { proxy in
            let top = max(ceiling ?? (values.max() ?? 1), 0.000_001)
            let points = pointList(in: proxy.size, top: top)
            if points.count >= 2 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            } else {
                Capsule().fill(tint.opacity(0.15)).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func pointList(in size: CGSize, top: Double) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let step = size.width / CGFloat(length - 1)
        let offset = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: offset + step * CGFloat(index),
                    y: size.height - size.height * CGFloat(min(value / top, 1)) * 0.92 - 1)
        }
    }
}
