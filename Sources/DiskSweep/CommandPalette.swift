import SwiftUI
import AppKit
import DiskSweepCore

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    var keywords = ""
    var tint: Color = .accentColor
    let run: @MainActor () -> Void
}

struct PaletteActions {
    let navigate: (String) -> Void
    let showFreeResource: (ResourceKind) -> Void
}

/// ⌘K: one search box for navigation, selection levels, AI review, quitting and uninstalling apps.
struct CommandPalette: View {
    let store: ScanStore
    let actions: PaletteActions
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var forceTarget: NSRunningApplication?
    @FocusState private var focused: Bool

    // MARK: Commands

    private var baseCommands: [PaletteCommand] {
        var list: [PaletteCommand] = []

        for category in Catalog.all {
            list.append(PaletteCommand(
                id: "go:\(category.id)", title: L("Git: \(category.title)"), subtitle: category.group.title,
                symbol: category.symbol, keywords: "open go goto aç git sayfa \(category.title)", tint: category.group.tint,
                run: { actions.navigate(category.id) }))
        }
        list.append(PaletteCommand(id: "go:smartscan", title: L("Git: Akıllı Tarama"), symbol: "sparkle.magnifyingglass",
                                   keywords: "smart scan auto akıllı tara otomatik temizle", tint: .blue,
                                   run: { actions.navigate(AppNavigation.smartScanPage) }))
        list.append(PaletteCommand(id: "go:folder", title: L("Git: Klasör Tara"), symbol: "magnifyingglass",
                                   keywords: "folder scan open aç klasör", tint: .indigo,
                                   run: { actions.navigate(FolderScan.categoryID) }))
        list.append(PaletteCommand(id: "go:settings", title: L("Git: Ayarlar"), symbol: "gearshape.fill",
                                   keywords: "settings preferences ayarlar tercihler", tint: .gray,
                                   run: { actions.navigate(AppNavigation.settingsPage) }))
        list.append(PaletteCommand(id: "rescan", title: L("Hepsini yeniden tara"), symbol: "arrow.clockwise",
                                   keywords: "rescan refresh scan tara yenile", run: { store.scanAll() }))

        for level in CleanupLevel.allCases {
            list.append(PaletteCommand(
                id: "level:\(level.rawValue)", title: L("Seç: \(level.title)"), subtitle: L("Tüm kategoriler") + " · " + level.detail,
                symbol: "slider.horizontal.3", keywords: "select level seç seviye tick",
                run: { withAnimation(Motion.snappy) { store.applyLevel(level) } }))
        }
        list.append(PaletteCommand(id: "clear", title: L("Seçimi temizle"), symbol: "xmark.circle",
                                   keywords: "clear deselect temizle", run: { store.clearAllSelection() }))
        if !store.selection.isEmpty {
            list.append(PaletteCommand(id: "delete", title: L("Seçilenleri sil…"),
                                       subtitle: L("\(store.selection.count) öğe seçili"), symbol: "trash",
                                       keywords: "delete remove sil kaldır", tint: .red,
                                       run: { store.showConfirmation = true }))
        }
        list.append(PaletteCommand(
            id: "ai", title: L("AI ile incele (tüm kategoriler)"), symbol: "sparkles",
            keywords: "ai review agent claude codex gemini incele ajan", tint: .blue,
            run: { store.reviewWithAgent(Catalog.all.flatMap { store.states[$0.id]?.items ?? [] }) }))

        for kind in ResourceKind.allCases {
            list.append(PaletteCommand(
                id: "free:\(kind.rawValue)", title: L("\(kind.title) boşalt"),
                subtitle: L("Açık uygulamaları listele, kapat veya zorla kapat"), symbol: kind.symbol,
                keywords: "free memory cpu gpu ram quit boşalt serbest bırak", tint: kind.tint,
                run: { actions.showFreeResource(kind) }))
        }
        list.append(PaletteCommand(id: "update", title: L("Güncellemeleri denetle"), symbol: "arrow.down.circle",
                                   keywords: "update upgrade version güncelle sürüm",
                                   run: { Task { await UpdateStore.shared.check() }; actions.navigate(AppNavigation.settingsPage) }))
        return list
    }

    /// Per-app commands only appear once the user types: there can be hundreds of them.
    private var appCommands: [PaletteCommand] {
        var list: [PaletteCommand] = []
        for app in AppControl.runningApps() {
            guard let name = app.localizedName else { continue }
            list.append(PaletteCommand(
                id: "quit:\(app.processIdentifier)", title: L("Kapat: \(name)"), subtitle: L("Uygulamadan çık"),
                symbol: "xmark.app", keywords: "quit close exit kapat çık \(name)", tint: .orange,
                run: { AppControl.quit(pid: app.processIdentifier) }))
            list.append(PaletteCommand(
                id: "force:\(app.processIdentifier)", title: L("Zorla kapat: \(name)"),
                subtitle: L("Kaydedilmemiş değişiklikler kaybolur"), symbol: "bolt.slash.fill",
                keywords: "force quit kill zorla kapat \(name)", tint: .red,
                run: { forceTarget = app }))
        }
        for item in store.states["apps"]?.items ?? [] {
            list.append(PaletteCommand(
                id: "uninstall:\(item.id)", title: L("Kaldır: \(item.title)"),
                subtitle: item.size.map { L("Uygulama ve artıkları · \(Format.bytes($0))") } ?? L("Uygulama ve artıkları"),
                symbol: "trash.square", keywords: "uninstall remove delete kaldır sil \(item.title)", tint: .brown,
                run: {
                    actions.navigate("apps")
                    store.clearAllSelection()
                    store.setSelected(item, true)
                    store.showConfirmation = true
                }))
        }
        return list
    }

    private var results: [PaletteCommand] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(baseCommands.prefix(12)) }
        let pool = baseCommands + appCommands
        let matches = pool.filter { command in
            let haystack = [command.title, command.subtitle ?? "", command.keywords].joined(separator: " ")
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
            }
        }
        // Titles that start with the first word rank above incidental keyword matches.
        let first = words[0]
        let ranked = matches.sorted { lhs, rhs in
            let left = lhs.title.range(of: first, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            let right = rhs.title.range(of: first, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            return left && !right
        }
        return Array(ranked.prefix(12))
    }

    // MARK: Body

    var body: some View {
        let list = results

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField(L("Bir komut yaz: kaldır, kapat, seç, boşalt…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(highlighted) { execute(list[highlighted]) } }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(list.count - 1, 0)); return .handled }
                    .onExitCommand(perform: dismiss)
            }
            .padding(14)

            Divider()

            if list.isEmpty {
                Text(L("Eşleşen komut yok")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 380)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, command in
                                row(command, isHighlighted: index == highlighted)
                                    .id(command.id)
                                    .onTapGesture { highlighted = index; execute(command) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 380)
                    .onChange(of: highlighted) { _, value in
                        if list.indices.contains(value) { proxy.scrollTo(list[value].id) }
                    }
                }
            }
        }
        .frame(width: 580)
        .background { Button("", action: dismiss).keyboardShortcut(.cancelAction).opacity(0) }
        .task {
            // The field only accepts focus once the sheet is on screen.
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .confirmationDialog(
            forceTarget?.localizedName.map { L("\($0) zorla kapatılsın mı?") } ?? "",
            isPresented: Binding(get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Zorla Kapat"), role: .destructive) {
                if let target = forceTarget { AppControl.forceQuit(pid: target.processIdentifier) }
                forceTarget = nil
                dismiss()
            }
            Button(L("Vazgeç"), role: .cancel) { forceTarget = nil }
        } message: {
            Text(L("Kaydedilmemiş değişiklikler kaybolur."))
        }
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: command.symbol, tint: command.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func execute(_ command: PaletteCommand) {
        // Force quit asks for confirmation inside the palette, so it stays open.
        if command.id.hasPrefix("force:") {
            command.run()
            return
        }
        dismiss()
        // Commands that open another sheet must wait until this one is gone.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            command.run()
        }
    }
}
