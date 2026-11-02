import SwiftUI
import DiskSweepCore

// MARK: - Buttons

struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(PillButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Motion.snappy, value: isEnabled)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.17 : 0.08)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Size bar & badges

struct SizeBar: View {
    let fraction: Double
    let color: Color
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, proxy.size.width * (shown ? fraction : 0)))
            }
        }
        .frame(height: 5)
        .onAppear { withAnimation(.smooth(duration: 0.7)) { shown = true } }
        .animation(Motion.smooth, value: fraction)
    }
}

struct SafetyPill: View {
    let level: SafetyLevel

    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(level.color)
            .background(Capsule().fill(level.color.opacity(0.16)))
    }
}

// MARK: - Empty / loading states

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .green
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: appeared)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Motion.smooth) { appeared = true } }
    }
}

struct SkeletonList: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 140 + CGFloat(index % 3) * 40, height: 12)
                        RoundedRectangle(cornerRadius: 4).frame(height: 9)
                        Capsule().frame(height: 5)
                    }
                    RoundedRectangle(cornerRadius: 4).frame(width: 56, height: 14)
                }
                .foregroundStyle(Color.primary.opacity(pulse ? 0.10 : 0.05))
                .padding(12)
                .card()
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(index) * 0.08), value: pulse)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .onAppear { pulse = true }
    }
}

// MARK: - Page header

struct RefreshBadge: View {
    let isScanning: Bool
    let lastScanned: Date?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(isScanning ? 360 : 0))
                    .animation(isScanning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.25),
                               value: isScanning)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .help("Yeniden tara")
        }
    }

    private var statusText: String {
        if isScanning { return "Taranıyor…" }
        guard let lastScanned else { return "" }
        return "Güncellendi: \(Format.relative(lastScanned))"
    }
}

struct PageHeader<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    var reclaimable: Int64?
    var reclaimableLabel = "temizlenebilir"
    var isScanning = false
    var lastScanned: Date?
    var note: String?
    var onRefresh: (() -> Void)?
    let accessory: Accessory

    init(symbol: String, tint: Color, title: String, summary: String,
         reclaimable: Int64? = nil, reclaimableLabel: String = "temizlenebilir",
         isScanning: Bool = false, lastScanned: Date? = nil,
         note: String? = nil, onRefresh: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.summary = summary
        self.reclaimable = reclaimable
        self.reclaimableLabel = reclaimableLabel
        self.isScanning = isScanning
        self.lastScanned = lastScanned
        self.note = note
        self.onRefresh = onRefresh
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: symbol, tint: tint, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if let reclaimable {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Format.bytes(reclaimable))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                            .contentTransition(.numericText(value: Double(reclaimable)))
                            .animation(Motion.spring, value: reclaimable)
                        Text(reclaimableLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                accessory
                Spacer()
                if let onRefresh {
                    RefreshBadge(isScanning: isScanning, lastScanned: lastScanned, action: onRefresh)
                }
            }

            if let note {
                Label(note, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(cornerRadius: 10, fill: Color.orange.opacity(0.10), stroke: Color.orange.opacity(0.25))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .animation(Motion.smooth, value: note)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, summary: String,
         reclaimable: Int64? = nil, reclaimableLabel: String = "temizlenebilir",
         isScanning: Bool = false, lastScanned: Date? = nil,
         note: String? = nil, onRefresh: (() -> Void)? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, summary: summary,
                  reclaimable: reclaimable, reclaimableLabel: reclaimableLabel,
                  isScanning: isScanning, lastScanned: lastScanned,
                  note: note, onRefresh: onRefresh) { EmptyView() }
    }
}

// MARK: - Item list

struct ItemListView: View {
    let store: ScanStore
    let items: [CleanupItem]
    var categoryTitles: [String: String] = [:]
    var onOpen: ((CleanupItem) -> Void)?

    var body: some View {
        let scale = items.compactMap(\.size).max() ?? 0

        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ItemCard(store: store, item: item, index: index,
                             categoryTitle: categoryTitles[item.id], barScale: scale, onOpen: onOpen)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
                // Room for the floating action bar.
                Color.clear.frame(height: 96)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .animation(items.count > 300 ? nil : Motion.smooth, value: items.map(\.id))
        }
        .frame(minHeight: 200, idealHeight: 400, maxHeight: .infinity)
    }
}

struct ItemCard: View {
    let store: ScanStore
    let item: CleanupItem
    let index: Int
    var categoryTitle: String?
    var barScale: Int64
    var onOpen: ((CleanupItem) -> Void)?

    @State private var hovering = false
    @State private var appeared = false

    private var selected: Bool { store.isSelected(item) }

    private var pending: Bool {
        item.size == nil && item.categoryID == FolderScan.categoryID
            && store.state(forID: FolderScan.categoryID).isScanning
    }

    private var canToggle: Bool { item.isSelectable && !pending }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            checkIcon
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let size = item.size, barScale > 0 {
                    SizeBar(fraction: Double(size) / Double(barScale), color: item.safety.color)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .card(fill: selected ? Color.accentColor.opacity(0.14)
                             : Color.primary.opacity(hovering && canToggle ? 0.085 : 0.045),
              stroke: selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        .opacity(item.isSelectable ? 1 : 0.72)
        .scaleEffect(hovering && canToggle ? 1.003 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(Motion.snappy, value: selected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard canToggle else { return }
            withAnimation(Motion.snappy) { store.setSelected(item, !selected) }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(Motion.smooth.delay(index < 12 ? Double(index) * 0.03 : 0)) { appeared = true }
        }
        .contextMenu {
            if let url = item.path {
                Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Dışlananlara Ekle") { store.addExcluded([url]) }
            }
        }
    }

    private var checkIcon: some View {
        Image(systemName: item.isSelectable ? (selected ? "checkmark.circle.fill" : "circle") : "lock.fill")
            .font(.system(size: 20))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .symbolEffect(.bounce, value: selected)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 22, height: 22)
            .padding(.top, 1)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            if item.categoryID == FolderScan.categoryID {
                Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
            }
            Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
            SafetyPill(level: item.safety)
            if let categoryTitle {
                Text(categoryTitle)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }

    private var trailing: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                if pending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(item.size.map(Format.bytes) ?? "—")
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(item.size ?? 0)))
                        .animation(Motion.smooth, value: item.size)
                }
                if let modified = item.modified {
                    Text(Format.relative(modified))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let onOpen, item.isFolder {
                Button { onOpen(item) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .help("Klasörün içine gir")
            }
        }
    }
}

// MARK: - Floating action bar

struct FloatingActionBar: View {
    let store: ScanStore

    var body: some View {
        let count = store.selectedItems.count
        let visible = store.isDeleting || count > 0

        ZStack {
            if visible {
                HStack(spacing: 14) {
                    if store.isDeleting {
                        ProgressView(value: Double(store.deletingProgress), total: Double(max(store.deletingTotal, 1)))
                            .frame(width: 150)
                            .animation(Motion.smooth, value: store.deletingProgress)
                        Text("İşleniyor: \(store.deletingTitle)")
                            .lineLimit(1)
                            .frame(maxWidth: 240, alignment: .leading)
                        Text("\(store.deletingProgress)/\(store.deletingTotal)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(count)")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 26, minHeight: 26)
                            .background(Circle().fill(Color.accentColor))
                            .contentTransition(.numericText(value: Double(count)))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("öğe seçili").font(.caption).foregroundStyle(.secondary)
                            Text(Format.bytes(store.selectedBytes))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .contentTransition(.numericText(value: Double(store.selectedBytes)))
                        }
                        Button("Kaldır") { withAnimation(Motion.spring) { store.clearAllSelection() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Button { store.showConfirmation = true } label: {
                            Label("Sil…", systemImage: "trash")
                                .font(.body.weight(.semibold))
                                .fixedSize()
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                    }
                }
                .fixedSize()
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.spring, value: visible)
        .animation(Motion.smooth, value: count)
        .allowsHitTesting(visible)
    }
}
