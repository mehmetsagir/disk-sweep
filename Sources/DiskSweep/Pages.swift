import SwiftUI
import DiskSweepCore

// MARK: - Category page

struct CategoryPage: View {
    let store: ScanStore
    let category: CleanupCategory

    var body: some View {
        let state = store.state(for: category)

        VStack(spacing: 0) {
            PageHeader(
                symbol: category.symbol, tint: category.group.tint, title: category.title,
                summary: category.summary, reclaimable: state.reclaimableBytes,
                isScanning: state.isScanning, lastScanned: store.lastScanned[category.id],
                note: [state.note, store.reviewNote].compactMap { $0 }.joined(separator: "\n").nilIfEmpty, onRefresh: { store.scan(category) }
            ) {
                AIReviewButton(store: store, items: state.items)
                PillButton(title: L("Güvenlileri seç"), symbol: "checkmark.shield") {
                    withAnimation(Motion.snappy) { store.selectSafe(in: state.items) }
                }
                .disabled(!state.items.contains { $0.safety == .safe && $0.isSelectable })
                PillButton(title: L("Seçimi temizle"), symbol: "xmark") {
                    withAnimation(Motion.snappy) { store.clearSelection(in: state.items) }
                }
                .disabled(!state.items.contains { store.isSelected($0) })
            }

            if state.items.isEmpty {
                if state.isScanning || !state.hasScanned {
                    SkeletonList()
                } else if state.note == FullDiskAccess.note {
                    // Not "all clean": the folder could not be read at all.
                    EmptyState(symbol: "lock.shield", title: L("Erişim izni gerekli"),
                               message: FullDiskAccess.note, tint: .orange,
                               actionTitle: L("Gizlilik Ayarlarını Aç")) {
                        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                    }
                } else {
                    EmptyState(symbol: "sparkles", title: L("Burası tertemiz"),
                               message: L("Bu kategoride temizlenebilecek bir şey bulunamadı."), tint: category.group.tint)
                }
            } else {
                ItemListView(store: store, items: state.items)
            }
        }
    }
}

// MARK: - Search page

struct SearchPage: View {
    let store: ScanStore

    var body: some View {
        let results = store.searchResults
        let items = results.map(\.item)
        let titles = Dictionary(results.map { ($0.item.id, $0.category.title) }, uniquingKeysWith: { first, _ in first })

        VStack(spacing: 0) {
            PageHeader(
                symbol: "magnifyingglass", tint: .indigo, title: L("Arama sonuçları"),
                summary: L("\"\(store.searchText)\" için tüm kategorilerde \(results.count) sonuç.")
                    + (store.isScanningAnything ? L(" Bazı kategoriler hâlâ taranıyor.") : ""),
                note: store.reviewNote
            ) {
                AIReviewButton(store: store, items: items)
                PillButton(title: L("Güvenlileri seç"), symbol: "checkmark.shield") {
                    withAnimation(Motion.snappy) { store.selectSafe(in: items) }
                }
                .disabled(!items.contains { $0.safety == .safe && $0.isSelectable })
                PillButton(title: L("Seçimi temizle"), symbol: "xmark") {
                    withAnimation(Motion.snappy) { store.clearSelection(in: items) }
                }
                .disabled(!items.contains { store.isSelected($0) })
            }

            if items.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: L("Sonuç yok"),
                           message: L("\"\(store.searchText)\" ile eşleşen bir öğe bulunamadı."), tint: .accentColor)
            } else {
                ItemListView(store: store, items: items, categoryTitles: titles)
            }
        }
    }
}

// MARK: - Folder scanner page

struct FolderPage: View {
    let store: ScanStore

    var body: some View {
        let state = store.state(forID: FolderScan.categoryID)
        let visible = store.filtered(state.items)
        let known = state.items.compactMap(\.size)
        let total = known.reduce(0, +)

        VStack(spacing: 0) {
            PageHeader(
                symbol: "magnifyingglass", tint: .indigo, title: L("Klasör Tara"),
                summary: L("Klasörlerin içine girip en büyük dosya ve klasörleri bulun. Çöp Kutusu'na taşınabilenler seçilebilir; Library, gizli, bulut klasörleri, git verisi ve dışladıklarınız yalnızca görüntülenir."),
                reclaimable: total, reclaimableLabel: L("bu klasörün boyutu"), isScanning: state.isScanning,
                lastScanned: store.lastScanned[FolderScan.categoryID], note: state.note,
                onRefresh: { store.openFolder(store.folderURL, quiet: true) }
            ) {
                PillButton(title: L("Üst klasör"), symbol: "arrow.up") { store.openParentFolder() }
                    .disabled(store.folderURL.path == "/")
                PillButton(title: L("Ana klasör"), symbol: "house") {
                    store.openFolder(FileManager.default.homeDirectoryForCurrentUser)
                }
                PillButton(title: L("Klasör seç…"), symbol: "folder.badge.plus") { store.chooseFolder() }
                PillButton(title: L("Seçimi temizle"), symbol: "xmark") {
                    withAnimation(Motion.snappy) { store.clearSelection(in: state.items) }
                }
                .disabled(!state.items.contains { store.isSelected($0) })
            }

            Breadcrumb(url: store.folderURL) { store.openFolder($0) }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            if state.isScanning && !state.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(known.count), total: Double(max(state.items.count, 1)))
                        .animation(Motion.smooth, value: known.count)
                    Text(L("\(known.count) / \(state.items.count) boyut hesaplandı"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .transition(.opacity)
            }

            if state.items.isEmpty && (state.isScanning || !state.hasScanned) {
                SkeletonList()
            } else if visible.isEmpty {
                if store.isSearching {
                    EmptyState(symbol: "magnifyingglass", title: L("Sonuç yok"),
                               message: L("Bu klasörde \"\(store.searchText)\" ile eşleşen bir şey yok."), tint: .accentColor)
                } else {
                    EmptyState(symbol: "folder", title: L("Klasör boş"),
                               message: L("Bu klasörde gösterilecek bir şey yok."), tint: .accentColor)
                }
            } else {
                ItemListView(store: store, items: visible) { item in
                    if let url = item.path { store.openFolder(url) }
                }
            }
        }
        .animation(Motion.smooth, value: state.isScanning)
        .task {
            if !state.hasScanned && !state.isScanning { store.openFolder(store.folderURL) }
        }
    }
}

struct Breadcrumb: View {
    let url: URL
    let onSelect: (URL) -> Void

    private var crumbs: [(name: String, url: URL)] {
        var current = URL(fileURLWithPath: "/")
        var result: [(String, URL)] = [("Macintosh HD", current)]
        for part in url.pathComponents.dropFirst() {
            current = current.appendingPathComponent(part)
            result.append((part, current))
        }
        return result
    }

    var body: some View {
        let items = crumbs
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        CrumbButton(name: crumb.name, isLast: index == items.count - 1) { onSelect(crumb.url) }
                            .id(index)
                    }
                }
            }
            .onAppear { proxy.scrollTo(items.count - 1, anchor: .trailing) }
            .onChange(of: url) { _, _ in
                withAnimation(Motion.smooth) { proxy.scrollTo(items.count - 1, anchor: .trailing) }
            }
        }
        .frame(height: 28)
    }
}

struct CrumbButton: View {
    let name: String
    let isLast: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.callout.weight(isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : (isLast ? 0.07 : 0))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
