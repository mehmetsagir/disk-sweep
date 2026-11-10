import SwiftUI
import DiskSweepCore

// NOTE: the layout is a plain HStack with a hand-made sidebar on purpose.
// NavigationSplitView laid its content out taller than the window and clipped
// the sidebar rows, headers and the bottom bar.
struct ContentView: View {
    @State private var store = ScanStore()
    @State private var selectedID: String?
    @State private var navigation = AppNavigation.shared
    @FocusState private var searchFocused: Bool
    @State private var showPalette = false
    @State private var freeResourceKind: ResourceKind?

    init() {
        // `-DiskSweepSelect <id>` launch argument: open a given page (screenshot testing).
        _selectedID = State(initialValue: UserDefaults.standard.string(forKey: "DiskSweepSelect") ?? Catalog.all.first?.id)
    }

    private var detailKey: String {
        if [FolderScan.categoryID, AppNavigation.settingsPage, AppNavigation.smartScanPage].contains(selectedID) { return selectedID ?? "" }
        return (selectedID ?? "") + (store.isSearching ? "|search" : "")
    }

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 0) {
            SidebarView(store: store, selection: $selectedID, showExclusions: $store.showExclusions)
                .frame(width: 304)
                .background(.regularMaterial)
            Divider()
            ZStack(alignment: .bottom) {
                detail
                    .id(detailKey)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FloatingActionBar(store: store)
            }
            .animation(Motion.smooth, value: detailKey)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(navigation.languageRevision)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SearchField(text: $store.searchText, focused: $searchFocused)
            }
        }
        .background {
            // Cmd+F focuses the search field, Cmd+K opens the command palette.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        }
        .sheet(isPresented: $showPalette) {
            CommandPalette(
                store: store,
                actions: PaletteActions(
                    navigate: { id in withAnimation(Motion.snappy) { selectedID = id } },
                    showFreeResource: { kind in freeResourceKind = kind }),
                dismiss: { showPalette = false })
        }
        .sheet(item: $freeResourceKind) { kind in
            FreeResourceSheet(kind: kind, config: store.agentConfig)
        }
        .sheet(isPresented: $store.showConfirmation) { ConfirmSheet(store: store) }
        .sheet(isPresented: $store.showResults) { ResultSheet(store: store) }
        .sheet(isPresented: $store.showExclusions) { ExclusionsSheet(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshStale()
        }
        .onChange(of: navigation.freeResourceRequest) { _, kind in
            guard let kind else { return }
            freeResourceKind = kind
            navigation.freeResourceRequest = nil
        }
        .onChange(of: navigation.request) { _, request in
            guard let request else { return }
            withAnimation(Motion.snappy) { selectedID = request }
            navigation.request = nil
        }
        .task {
            let defaults = UserDefaults.standard
            if let query = defaults.string(forKey: "DiskSweepSearch") { store.searchText = query }
            if defaults.bool(forKey: "DiskSweepExclusions") { store.showExclusions = true }
            // Menu bar mode closes the window right after launch: do not walk the whole disk for nobody.
            // When the window is opened later, `refreshStale()` scans whatever is out of date.
            try? await Task.sleep(for: .seconds(1.2))
            if NSApp.windows.contains(where: { $0.title == "DiskSweep" && $0.isVisible }) {
                store.scanAll()
            }
            if defaults.bool(forKey: "DiskSweepPreselect") {
                // Screenshot testing only: selects (never deletes) the safe items.
                try? await Task.sleep(for: .seconds(14))
                store.selectSafe(in: store.states.values.flatMap(\.items))
            }

            // Auto refresh: disk gauge every 5 s, the visible page every ~30 s.
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                tick += 1
                guard NSApp.isActive else { continue }
                store.refreshDisk()
                if tick % 6 == 0 { store.refreshVisible(selectedID) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if selectedID == AppNavigation.settingsPage {
            SettingsPage(store: store)
        } else if selectedID == AppNavigation.smartScanPage {
            SmartScanPage(store: store)
        } else if selectedID == FolderScan.categoryID {
            FolderPage(store: store)
        } else if store.isSearching {
            SearchPage(store: store)
        } else if let category = Catalog.all.first(where: { $0.id == selectedID }) {
            CategoryPage(store: store, category: category)
        } else {
            EmptyState(symbol: "sidebar.left", title: L("Bir kategori seçin"),
                       message: L("Soldaki listeden temizlemek istediğiniz alanı seçin."), tint: .accentColor)
        }
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Ara…  ⌘F"), text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { withAnimation(Motion.snappy) { text = "" } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 250)
        .background(Capsule().fill(Color.primary.opacity(focused.wrappedValue ? 0.12 : 0.07)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(focused.wrappedValue ? 0.7 : 0), lineWidth: 1.5))
        .animation(Motion.snappy, value: focused.wrappedValue)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let store: ScanStore
    @Binding var selection: String?
    @Binding var showExclusions: Bool
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SidebarSection(title: L("Araçlar")) {
                        SidebarRow(id: AppNavigation.smartScanPage, title: L("Akıllı Tarama"), symbol: "sparkle.magnifyingglass",
                                   tint: .blue, selection: $selection, namespace: highlight) { EmptyView() }
                        SidebarRow(id: FolderScan.categoryID, title: L("Klasör Tara"), symbol: "magnifyingglass",
                                   tint: .indigo, selection: $selection, namespace: highlight) { EmptyView() }
                        SidebarRow(id: AppNavigation.settingsPage, title: L("Ayarlar"), symbol: "gearshape.fill",
                                   tint: .gray, selection: $selection, namespace: highlight) { EmptyView() }
                    }
                    ForEach(CategoryGroup.allCases, id: \.self) { group in
                        SidebarSection(title: group.title) {
                            ForEach(Catalog.all.filter { $0.group == group }) { category in
                                SidebarRow(id: category.id, title: category.title, symbol: category.symbol,
                                           tint: group.tint, selection: $selection, namespace: highlight) {
                                    SidebarTrailing(state: store.state(for: category))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .frame(minHeight: 200, idealHeight: 400, maxHeight: .infinity)

            if let update = UpdateStore.shared.available {
                UpdateBanner(info: update) { withAnimation(Motion.snappy) { selection = AppNavigation.settingsPage } }
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            DiskGauge(disk: store.disk, reclaimable: store.totalReclaimable,
                      excludedCount: store.excludedFolders.count) { showExclusions = true }
                .padding(12)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            content
        }
    }
}

struct SidebarRow<Trailing: View>: View {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    @Binding var selection: String?
    let namespace: Namespace.ID
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    private var selected: Bool { selection == id }

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { selection = id }
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 26)
                Text(title)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.20))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35)))
                        .matchedGeometryEffect(id: "sidebar-highlight", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SidebarTrailing: View {
    let state: ScanStore.CategoryState

    var body: some View {
        if state.isScanning && state.items.isEmpty {
            ProgressView().controlSize(.small)
        } else if state.reclaimableBytes > 0 {
            Text(Format.bytes(state.reclaimableBytes))
                .font(.system(.callout).weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(state.reclaimableBytes)))
                .animation(Motion.smooth, value: state.reclaimableBytes)
        }
    }
}

// MARK: - Disk gauge

struct DiskGauge: View {
    let disk: DiskUsage
    let reclaimable: Int64
    let excludedCount: Int
    let onShowExclusions: () -> Void

    private var isLow: Bool { disk.freeFraction < 0.10 }
    private var usedFraction: Double { disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0 }
    private var reclaimFraction: Double {
        disk.total > 0 ? min(Double(reclaimable) / Double(disk.total), usedFraction) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(disk.available))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isLow ? Color.red : .primary)
                    .contentTransition(.numericText(value: Double(disk.available)))
                Text(L("boş")).foregroundStyle(.secondary)
                Spacer()
                if isLow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(isLow ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.85))
                        .frame(width: proxy.size.width * usedFraction)
                    Capsule()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: proxy.size.width * reclaimFraction)
                        .offset(x: proxy.size.width * (usedFraction - reclaimFraction))
                }
            }
            .frame(height: 9)

            HStack(spacing: 10) {
                Label(L("\(Format.bytes(reclaimable)) temizlenebilir"), systemImage: "circle.fill")
                    .foregroundStyle(.green)
                Spacer(minLength: 4)
                Text(Format.bytes(disk.total)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .labelStyle(DotLabelStyle())

            Button(action: onShowExclusions) {
                Label(L("Dışlanan klasörler (\(excludedCount))"), systemImage: "eye.slash")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(14)
        .card(cornerRadius: 16)
        .animation(Motion.spring, value: disk.available)
        .animation(Motion.spring, value: reclaimable)
    }
}

struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}
