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
                    .fill(color.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * (shown ? fraction : 0)))
            }
        }
        .frame(height: 5)
        .onAppear { withAnimation(.smooth(duration: 0.4)) { shown = true } }
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
    var actionTitle: String?
    var action: (() -> Void)?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.13)).frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(tint)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.smooth) { appeared = true } }
    }
}

/// Whether the user can actually see the app's main window. Endless animations check this so a
/// hidden or covered window (menu bar mode) does not keep SwiftUI laying out every frame.
@MainActor
enum AppVisibility {
    static func isOnScreen() -> Bool {
        NSApp.isActive && NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }
}

extension View {
    /// Keeps `isOnScreen` in sync with window visibility and app activation.
    func trackOnScreen(_ isOnScreen: Binding<Bool>) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                isOnScreen.wrappedValue = AppVisibility.isOnScreen()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                // The closing window still reports isVisible during this callback.
                DispatchQueue.main.async { isOnScreen.wrappedValue = AppVisibility.isOnScreen() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                isOnScreen.wrappedValue = AppVisibility.isOnScreen()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                isOnScreen.wrappedValue = false
            }
    }
}

struct SkeletonList: View {
    @State private var pulse = false
    @State private var onScreen = AppVisibility.isOnScreen()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animating: Bool { onScreen && !reduceMotion }

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
            }
            Spacer(minLength: 0)
        }
        .animation(animating ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : nil, value: pulse)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .trackOnScreen($onScreen)
        .onAppear { pulse = animating }
        .onChange(of: animating) { _, active in pulse = active }
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
            .help(L("Yeniden tara"))
        }
    }

    private var statusText: String {
        if isScanning { return L("Taranıyor…") }
        guard let lastScanned else { return "" }
        return L("Güncellendi: \(Format.relative(lastScanned))")
    }
}

struct PageHeader<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    var reclaimable: Int64?
    var reclaimableLabel = L("temizlenebilir")
    var isScanning = false
    var lastScanned: Date?
    var note: String?
    var onRefresh: (() -> Void)?
    let accessory: Accessory

    init(symbol: String, tint: Color, title: String, summary: String,
         reclaimable: Int64? = nil, reclaimableLabel: String = L("temizlenebilir"),
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
                    Text(title).font(.system(size: 26, weight: .bold))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if let reclaimable {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Format.bytes(reclaimable))
                            .font(.system(size: 30, weight: .bold))
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
         reclaimable: Int64? = nil, reclaimableLabel: String = L("temizlenebilir"),
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
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(Motion.snappy, value: selected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard canToggle else { return }
            withAnimation(Motion.snappy) { store.setSelected(item, !selected) }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.smooth) { appeared = true } }
        .contextMenu {
            if let url = item.path {
                Button(L("Finder'da Göster")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L("Dışlananlara Ekle")) { store.addExcluded([url]) }
            }
        }
    }

    private var checkIcon: some View {
        Image(systemName: item.isSelectable ? (selected ? "checkmark.circle.fill" : "circle") : "lock.fill")
            .font(.system(size: 20))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
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
            if let verdict = store.verdicts[item.id] { AIVerdictBadge(verdict: verdict) }
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
                        .font(.system(.body).weight(.semibold).monospacedDigit())
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
                .help(L("Klasörün içine gir"))
            }
        }
    }
}

// MARK: - Floating action bar

struct FloatingActionBar: View {
    let store: ScanStore
    @State private var hoveringDelete = false

    var body: some View {
        let items = store.selectedItems
        let visible = store.isDeleting || !items.isEmpty

        ZStack {
            if visible {
                Group {
                    if store.isDeleting { progressContent } else { selectionContent(items) }
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                .fixedSize()
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.spring, value: visible)
        .animation(Motion.smooth, value: items.count)
        .allowsHitTesting(visible)
    }

    // MARK: Selection

    private func selectionContent(_ items: [CleanupItem]) -> some View {
        let cautionCount = items.filter { $0.safety == .caution }.count
        let permanentCount = items.filter { store.effectiveMode(of: $0) == .permanent }.count

        return HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 36, height: 36)
                Text("\(items.count)")
                    .font(.system(.callout).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(items.count)))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Format.bytes(store.selectedBytes))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(store.selectedBytes)))
                    .animation(Motion.smooth, value: store.selectedBytes)
                HStack(spacing: 6) {
                    Text(L("\(items.count) öğe seçili"))
                        .foregroundStyle(.secondary)
                    if cautionCount > 0 {
                        badge(L("\(cautionCount) dikkat"), symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if permanentCount > 0 {
                        badge(L("\(permanentCount) kalıcı"), symbol: "flame.fill", tint: .red)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }

            Button {
                withAnimation(Motion.spring) { store.clearAllSelection() }
            } label: {
                Text(L("Seçimi kaldır"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()

            Button { store.showConfirmation = true } label: {
                Label(L("Sil…"), systemImage: "trash")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(red: 0.82, green: 0.22, blue: 0.22).opacity(hoveringDelete ? 1 : 0.92)))
            }
            .buttonStyle(.plain)
            .onHover { hoveringDelete = $0 }
            .animation(.easeOut(duration: 0.14), value: hoveringDelete)
        }
    }

    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
    }

    // MARK: Deleting

    private var progressContent: some View {
        let fraction = Double(store.deletingProgress) / Double(max(store.deletingTotal, 1))

        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.smooth, value: fraction)
                Text("\(Int(fraction * 100))")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("Temizleniyor…")).font(.system(.body).weight(.semibold))
                Text(store.deletingTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            Text("\(store.deletingProgress)/\(store.deletingTotal)")
                .font(.system(.callout).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
        }
    }
}
