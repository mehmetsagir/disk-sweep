import SwiftUI
import DiskSweepCore

// MARK: - Confirm

struct ConfirmSheet: View {
    let store: ScanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = store.selectedItems
        let permanent = items.filter { $0.removalMode == .permanent }
        let trash = items.filter { $0.removalMode == .trash }
        let commands = items.filter(\.isCommand)
        let cautionCount = items.filter { $0.safety == .caution }.count

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "trash.fill", tint: .red, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Silmeyi onayla")).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(L("\(items.count) öğe seçildi")).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.bytes(store.selectedBytes))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(L("boşalacak (tahmini)")).font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    GroupCard(title: L("Kalıcı olarak silinecek"), symbol: "flame.fill", color: .red, items: permanent)
                    GroupCard(title: L("Çöp Kutusu'na taşınacak (geri alınabilir)"), symbol: "trash", color: .orange, items: trash)
                    GroupCard(title: L("Araçla temizlenecek (docker / simctl / pnpm)"), symbol: "terminal.fill", color: .blue, items: commands)
                }
            }
            .frame(maxHeight: 300)

            if cautionCount > 0 {
                Label(L("\(cautionCount) öğe \"Dikkat\" seviyesinde. Açıklamalarını okuduğundan emin ol."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(cornerRadius: 10, fill: Color.orange.opacity(0.10), stroke: Color.orange.opacity(0.25))
            }

            HStack {
                Spacer()
                Button(L("Vazgeç")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button {
                    dismiss()
                    Task { await store.performDeletion() }
                } label: {
                    Label(L("Sil"), systemImage: "trash").padding(.horizontal, 8)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

private struct GroupCard: View {
    let title: String
    let symbol: String
    let color: Color
    let items: [CleanupItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.18)))
                }
                ForEach(items) { item in
                    HStack {
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(item.size.map(Format.bytes) ?? "—")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .card(cornerRadius: 12, fill: color.opacity(0.07), stroke: color.opacity(0.22))
        }
    }
}

// MARK: - Result

struct ResultSheet: View {
    let store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var shownBytes: Int64 = 0
    @State private var sealed = false

    var body: some View {
        let ok = store.results.filter(\.succeeded)
        let failed = store.results.filter { !$0.succeeded }
        let freed = ok.reduce(Int64(0)) { $0 + $1.freedBytes }

        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(failed.isEmpty ? Color.green : .orange)
                    .symbolEffect(.bounce, value: sealed)
                Text(Format.bytes(shownBytes))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: Double(shownBytes)))
                Text(L("\(ok.count) öğe temizlendi") + (failed.isEmpty ? "" : L(" · \(failed.count) hata")) + L(" · tahmini"))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(store.results.enumerated()), id: \.element.id) { index, outcome in
                        ResultRow(outcome: outcome, index: index)
                    }
                }
            }
            .frame(height: 230)

            Text(L("Çöp Kutusu'na taşınanlar yer açmaz; \"Çöp Kutusu\" kategorisinden boşaltabilirsin. macOS boşalan alanı biraz gecikmeyle gösterir."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(L("Kapat")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 580)
        .onAppear {
            sealed = true
            withAnimation(.smooth(duration: 1.1)) { shownBytes = freed }
        }
    }
}

private struct ResultRow: View {
    let outcome: CleanupOutcome
    let index: Int
    @State private var appeared = false

    var body: some View {
        let color: Color = outcome.succeeded ? .green : .red
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.item.title).lineLimit(1)
                if let message = outcome.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if outcome.succeeded {
                Text(Format.bytes(outcome.freedBytes))
                    .font(.system(.callout, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .card(cornerRadius: 10, fill: color.opacity(0.07), stroke: color.opacity(0.2))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Motion.smooth.delay(min(Double(index), 10) * 0.04)) { appeared = true } }
    }
}

// MARK: - Exclusions

struct ExclusionsSheet: View {
    let store: ScanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "eye.slash.fill", tint: .gray, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Dışlanan klasörler")).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(L("Bu klasörlerde ve içlerinde hiçbir işlem yapılmaz.")).foregroundStyle(.secondary)
                }
            }
            Text(L("Bir dışlanan klasörü içeren üst öğeler de listelenmez ve silinemez. Değişiklik hemen uygulanır ve yeniden taranır."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.excludedFolders.isEmpty {
                EmptyHint()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.excludedFolders, id: \.path) { url in
                            ExcludedRow(url: url) {
                                withAnimation(Motion.smooth) { store.removeExcluded(url) }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .animation(Motion.smooth, value: store.excludedFolders.map(\.path))
                }
                .frame(minHeight: 80, maxHeight: 240)
            }

            HStack {
                Button { store.pickExcludedFolders() } label: {
                    Label(L("Klasör ekle…"), systemImage: "plus")
                }
                .controlSize(.large)
                Spacer()
                Button(L("Kapat")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.minus").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(L("Henüz dışlanan klasör yok")).font(.headline)
            Text(L("Bir öğeye sağ tıklayıp \"Dışlananlara Ekle\" de diyebilirsin."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .card(cornerRadius: 12)
    }
}

private struct ExcludedRow: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(url.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Dışlamayı kaldır"))
        }
        .padding(10)
        .card(cornerRadius: 10, fill: Color.primary.opacity(hovering ? 0.08 : 0.045))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
