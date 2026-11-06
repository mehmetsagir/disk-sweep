import SwiftUI
import DiskSweepCore

// MARK: - Stages & helpers

private struct SmartStage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
}

private extension CleanupLevel {
    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .balanced: return "slider.horizontal.3"
        case .thorough: return "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safe: return .green
        case .balanced: return .orange
        case .thorough: return .red
        }
    }
}

/// Smart Scan: scans the curated categories AND walks the whole home folder, ticks what the chosen
/// level allows, shows the result per category, and hands the deletion to the normal confirm sheet.
struct SmartScanPage: View {
    let store: ScanStore

    private enum Phase { case idle, scanning, review }

    @AppStorage("smartscan.level") private var levelRaw = CleanupLevel.safe.rawValue
    @AppStorage("smartscan.useAI") private var useAI = false
    @State private var phase: Phase = .idle

    private var level: CleanupLevel { CleanupLevel(rawValue: levelRaw) ?? .safe }

    /// Apps are never part of a smart scan: uninstalling is always a deliberate, manual choice.
    private var stages: [SmartStage] {
        Catalog.all.filter { $0.id != "apps" }.map { SmartStage(id: $0.id, title: $0.title, symbol: $0.symbol, tint: $0.group.tint) }
            + DeviceScan.groups.map { SmartStage(id: $0.id, title: $0.title, symbol: $0.symbol, tint: DiskSweep.tint(forCategory: $0.id)) }
    }

    private var allScanned: Bool { stages.allSatisfy { store.state(forID: $0.id).hasScanned } }

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                SmartIdleView(stages: stages, useAI: $useAI, onStart: startScan)
                    .transition(.opacity)
            case .scanning:
                SmartScanningView(store: store, stages: stages, onCancel: cancelScan)
                    .transition(.opacity)
            case .review:
                SmartReviewView(store: store, stages: stages, level: level, useAI: $useAI,
                                onLevel: setLevel, onRescan: startScan)
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: phase)
        .onAppear { if phase == .idle && allScanned && store.isScanningAnything == false { phase = .review } }
        .onChange(of: store.isScanningAnything) { _, scanning in
            guard !scanning, phase == .scanning else { return }
            finishScan()
        }
        .onChange(of: store.isReviewing) { _, reviewing in
            // The agent's verdicts feed the level, so apply it again once they are in.
            if !reviewing, phase == .review { store.applyLevel(level) }
        }
    }

    private func startScan() {
        store.reviewNote = nil
        phase = .scanning
        store.scanAll()
        store.scanDevice()
    }

    private func cancelScan() {
        store.cancelDeviceScan()
    }

    private func finishScan() {
        phase = .review
        store.applyLevel(level)
        if useAI { store.reviewWithAgent(store.allCategoryItems) }
    }

    private func setLevel(_ new: CleanupLevel) {
        levelRaw = new.rawValue
        withAnimation(Motion.snappy) { store.applyLevel(new) }
    }
}

// MARK: - Idle

private struct SmartIdleView: View {
    let stages: [SmartStage]
    @Binding var useAI: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            OrbitHero(stages: stages)
            VStack(spacing: 8) {
                Text(L("Cihazını tara")).font(.title.weight(.semibold))
                Text(L("Önbellekler, geliştirici dosyaları ve kullanıcı klasörlerin dahil, tüm cihaz baştan sona taranır. İşaretlenenleri silmeden önce sen onaylarsın."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }


            AIOptionCard(isOn: $useAI)
                .frame(maxWidth: 420)

            Button(action: onStart) {
                Label(L("Taramayı başlat"), systemImage: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Also review with AI" option: a tappable card instead of a system checkbox.
private struct AIOptionCard: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", tint: isOn ? .accentColor : .gray, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Bittiğinde AI ile de incele")).font(.callout.weight(.semibold))
                    Text(L("Ayarlardaki ajan öğeleri kontrol eder; hiçbir şey silinmez."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.08) : Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Motion.snappy, value: isOn)
    }
}

// MARK: - Orbit hero

/// The areas being scanned as small icons slowly circling a disk. Idle: everything lit and calm.
/// Scanning: faster, finished areas stay lit, pending ones dim. Honors "Reduce Motion".
private struct OrbitHero: View {
    let stages: [SmartStage]
    var scanning = false
    var scale: CGFloat = 1
    var isLit: (SmartStage) -> Bool = { _ in true }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let canvas: CGFloat = 300
    private var inner: [SmartStage] { Array(stages.prefix(5)) }
    private var outer: [SmartStage] { Array(stages.dropFirst(5)) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let speed = scanning ? 2.6 : 1.0
            ZStack {
                orbitLine(radius: 70)
                orbitLine(radius: 124)

                ForEach(Array(inner.enumerated()), id: \.element.id) { index, stage in
                    node(stage, radius: 70, angle: angle(index, of: inner.count, rate: 7 * speed, t: t))
                }
                ForEach(Array(outer.enumerated()), id: \.element.id) { index, stage in
                    node(stage, radius: 124, angle: angle(index, of: outer.count, rate: -4.5 * speed, t: t))
                }
                core(t: t)
            }
            .frame(width: canvas, height: canvas)
        }
        .frame(width: canvas, height: canvas)
        .scaleEffect(scale)
        .frame(width: canvas * scale, height: canvas * scale)
    }

    private func angle(_ index: Int, of count: Int, rate: Double, t: Double) -> Double {
        (Double(index) / Double(max(count, 1))) * 360 + t * rate
    }

    private func orbitLine(radius: CGFloat) -> some View {
        Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1).frame(width: radius * 2, height: radius * 2)
    }

    private func node(_ stage: SmartStage, radius: CGFloat, angle: Double) -> some View {
        let lit = isLit(stage)
        let radians = angle * .pi / 180
        return IconTile(symbol: stage.symbol, tint: stage.tint, size: 30)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 38, height: 38))
            .opacity(lit ? 1 : 0.35)
            .offset(x: CGFloat(cos(radians)) * radius, y: CGFloat(sin(radians)) * radius)
            .animation(Motion.smooth, value: lit)
    }

    private func core(t: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.06 + 0.03 * sin(t * 1.3)))
                .frame(width: 92, height: 92)
            if scanning {
                Circle()
                    .trim(from: 0, to: 0.24)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 84, height: 84)
                    .rotationEffect(.degrees(t * 220))
            }
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Scanning

private struct SmartScanningView: View {
    let store: ScanStore
    let stages: [SmartStage]
    let onCancel: () -> Void

    private var foundBytes: Int64 {
        store.allCategoryItems.reduce(0) { $0 + ($1.size ?? 0) } + store.deviceProgress.foundBytes
    }

    private var doneCount: Int { stages.filter { store.state(forID: $0.id).hasScanned }.count }

    var body: some View {
        let progress = store.deviceProgress

        GeometryReader { proxy in
          ScrollView {
            VStack(spacing: 18) {
            Spacer(minLength: 10)
            OrbitHero(stages: stages, scanning: true, scale: 0.72) { stage in
                let state = store.state(forID: stage.id)
                return state.hasScanned || state.isScanning
            }

            VStack(spacing: 4) {
                Text(Format.bytes(foundBytes))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(foundBytes)))
                    .animation(Motion.smooth, value: foundBytes)
                Text(L("temizlenebilir bulundu")).foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                stat(value: progress.filesVisited.formatted(), label: L("dosya tarandı"))
                stat(value: "\(doneCount) / \(stages.count)", label: L("alan tamamlandı"))
            }

            VStack(spacing: 3) {
                Text(progress.stage.isEmpty ? L("Başlatılıyor…") : progress.stage)
                    .font(.callout.weight(.medium))
                Text(progress.currentPath.isEmpty ? " " : progress.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            // Updates ~10 times a second; animating each one only makes the text flicker.
            .transaction { $0.animation = nil }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 8)], spacing: 8) {
                ForEach(stages) { stage in StageChip(store: store, stage: stage) }
            }
            .frame(maxWidth: 740)
            .padding(.horizontal, 24)

            Button(L("Durdur"), action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(store.isDeviceScanning ? 1 : 0)
            Spacer(minLength: 10)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
          }
          .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.title3).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StageChip: View {
    let store: ScanStore
    let stage: SmartStage

    var body: some View {
        let state = store.state(forID: stage.id)
        let done = state.hasScanned && !state.isScanning

        HStack(spacing: 8) {
            Image(systemName: stage.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done || state.isScanning ? stage.tint : .secondary)
                .frame(width: 18)
            Text(stage.title).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            if done {
                if state.reclaimableBytes > 0 {
                    Text(Format.bytes(state.reclaimableBytes))
                        .font(.system(.caption).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.85)).font(.caption)
                    .transition(.opacity)
            } else if state.isScanning {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(Color.primary.opacity(0.15)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(done ? stage.tint.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(state.isScanning ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06)))
        .animation(Motion.snappy, value: done)
        .animation(Motion.snappy, value: state.isScanning)
    }
}

// MARK: - Review

private struct SmartReviewView: View {
    let store: ScanStore
    let stages: [SmartStage]
    let level: CleanupLevel
    @Binding var useAI: Bool
    let onLevel: (CleanupLevel) -> Void
    let onRescan: () -> Void

    @State private var expanded: Set<String> = []

    private var rows: [(stage: SmartStage, items: [CleanupItem])] {
        stages.compactMap { stage in
            let items = store.state(forID: stage.id).items.filter(\.isSelectable)
            return items.isEmpty ? nil : (stage, items.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
        }
        .sorted { lhs, rhs in lhs.items.reduce(0) { $0 + ($1.size ?? 0) } > rhs.items.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    private func bytes(for level: CleanupLevel) -> Int64 {
        let now = Date()
        return rows.flatMap(\.items)
            .filter { level.shouldSelect($0, verdict: store.verdicts[$0.id], now: now) }
            .reduce(0) { $0 + ($1.size ?? 0) }
    }

    var body: some View {
        let rows = self.rows

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Akıllı Tarama")).font(.title2.weight(.semibold))
                Spacer()
                AIReviewButton(store: store, items: rows.flatMap(\.items))
                PillButton(title: L("Yeniden tara"), symbol: "arrow.clockwise", action: onRescan)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            if rows.isEmpty {
                EmptyState(symbol: "sparkles", title: L("Burası tertemiz"),
                           message: L("Hiçbir alanda temizlenebilecek bir şey bulunamadı."), tint: .green)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let note = store.reviewNote {
                            Label(note, systemImage: "info.circle.fill")
                                .font(.callout).foregroundStyle(.orange)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .card(cornerRadius: 10, fill: Color.orange.opacity(0.10), stroke: Color.orange.opacity(0.25))
                        }
                        SummaryCard(store: store, level: level, rows: rows, bytesFor: bytes, onLevel: onLevel)

                        ForEach(Array(rows.enumerated()), id: \.element.stage.id) { index, row in
                            StageCard(store: store, stage: row.stage, items: row.items, index: index,
                                      maxBytes: rows.first.map { $0.items.reduce(0) { $0 + ($1.size ?? 0) } } ?? 1,
                                      isExpanded: expanded.contains(row.stage.id)) {
                                withAnimation(Motion.smooth) {
                                    if expanded.contains(row.stage.id) { expanded.remove(row.stage.id) } else { expanded.insert(row.stage.id) }
                                }
                            }
                        }
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

private struct SummaryCard: View {
    let store: ScanStore
    let level: CleanupLevel
    let rows: [(stage: SmartStage, items: [CleanupItem])]
    let bytesFor: (CleanupLevel) -> Int64
    let onLevel: (CleanupLevel) -> Void

    private var selectedBytes: Int64 { store.selectedBytes }
    private var totalBytes: Int64 { rows.flatMap(\.items).reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.bytes(selectedBytes))
                        .font(.system(size: 40, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(selectedBytes)))
                        .animation(Motion.spring, value: selectedBytes)
                    Text(L("\(store.selection.count) öğe işaretli · \(Format.bytes(totalBytes)) bulundu"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            BreakdownBar(store: store, rows: rows)

            HStack(spacing: 10) {
                ForEach(CleanupLevel.allCases) { option in
                    LevelTile(level: option, bytes: bytesFor(option), isSelected: option == level) { onLevel(option) }
                }
            }
        }
        .padding(18)
        .card(cornerRadius: 14, fill: Color.primary.opacity(0.04))
    }
}

/// Stacked bar of what is ticked, one muted segment per category.
private struct BreakdownBar: View {
    let store: ScanStore
    let rows: [(stage: SmartStage, items: [CleanupItem])]

    private func color(_ stage: SmartStage) -> Color { stage.tint.opacity(0.85) }

    var body: some View {
        let parts = rows.enumerated().map { index, row in
            (stage: row.stage, rank: index, bytes: row.items.filter(store.isSelected).reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        }
        let total = max(parts.reduce(0) { $0 + $1.bytes }, 1)

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.bytes > 0 }, id: \.stage.id) { part in
                        Rectangle()
                            .fill(color(part.stage))
                            .frame(width: max(proxy.size.width * CGFloat(part.bytes) / CGFloat(total), 3))
                            .help("\(part.stage.title) · \(Format.bytes(part.bytes))")
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 8)
            .animation(Motion.smooth, value: parts.map(\.bytes))

            let top = parts.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(4)
            HStack(spacing: 14) {
                ForEach(Array(top), id: \.stage.id) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color(part.stage)).frame(width: 8, height: 8)
                        Text(part.stage.title).lineLimit(1)
                        Text(Format.bytes(part.bytes)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct LevelTile: View {
    let level: CleanupLevel
    let bytes: Int64
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: level.symbol).foregroundStyle(level.tint)
                    Text(level.title).font(.callout.weight(.medium))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            .transition(.opacity)
                    }
                }
                Text(Format.bytes(bytes))
                    .font(.system(.title3).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(bytes)))
                Text(level.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(hovering ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct StageCard: View {
    let store: ScanStore
    let stage: SmartStage
    let items: [CleanupItem]
    let index: Int
    let maxBytes: Int64
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    @State private var appeared = false

    private var selectedCount: Int { items.filter(store.isSelected).count }
    private var selectedBytes: Int64 { items.filter(store.isSelected).reduce(0) { $0 + ($1.size ?? 0) } }
    private var totalBytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    private var allSelected: Bool { selectedCount == items.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(Motion.snappy) {
                        if allSelected { store.clearSelection(in: items) } else { items.forEach { store.setSelected($0, true) } }
                    }
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : (selectedCount > 0 ? "minus.circle.fill" : "circle"))
                        .font(.system(size: 20))
                        .foregroundStyle(selectedCount > 0 ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(allSelected ? L("Seçimi kaldır") : L("Hepsini seç"))

                Button(action: toggleExpanded) {
                    HStack(spacing: 12) {
                        IconTile(symbol: stage.symbol, tint: stage.tint, size: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(stage.title).font(.body.weight(.semibold))
                                Spacer()
                                Text(Format.bytes(selectedBytes))
                                    .font(.system(.body).weight(.semibold).monospacedDigit())
                                    .contentTransition(.numericText(value: Double(selectedBytes)))
                                Text(L("/ \(Format.bytes(totalBytes))"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            // Share of the biggest category, with the ticked part filled in.
                            GeometryReader { proxy in
                                let width = proxy.size.width * CGFloat(totalBytes) / CGFloat(max(maxBytes, 1))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(stage.tint.opacity(0.16)).frame(width: max(width, 6))
                                    Capsule().fill(stage.tint.opacity(0.85))
                                        .frame(width: max(width * CGFloat(selectedBytes) / CGFloat(max(totalBytes, 1)), selectedBytes > 0 ? 6 : 0))
                                }
                            }
                            .frame(height: 5)
                            Text(L("\(selectedCount) / \(items.count) öğe işaretli"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(items.prefix(150)) { item in SmartItemRow(store: store, item: item) }
                    if items.count > 150 {
                        Text(L("…ve \(items.count - 150) öğe daha. Tamamı için kategori sayfasına bak."))
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .card(cornerRadius: 14)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.smooth.delay(min(Double(index) * 0.02, 0.2))) { appeared = true } }
    }
}

private struct SmartItemRow: View {
    let store: ScanStore
    let item: CleanupItem
    @State private var hovering = false

    var body: some View {
        let selected = store.isSelected(item)
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    SafetyPill(level: item.safety)
                    if let verdict = store.verdicts[item.id] { AIVerdictBadge(verdict: verdict) }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.size.map(Format.bytes) ?? "—")
                .font(.system(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(Motion.snappy) { store.setSelected(item, !selected) } }
        .contextMenu {
            if let url = item.path {
                Button(L("Finder'da Göster")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L("Dışlananlara Ekle")) { store.addExcluded([url]) }
            }
        }
    }
}
