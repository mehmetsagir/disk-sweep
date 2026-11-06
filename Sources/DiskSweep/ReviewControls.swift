import SwiftUI
import DiskSweepCore

/// Asks the configured AI agent which of the given items are safe to remove.
struct AIReviewButton: View {
    let store: ScanStore
    let items: [CleanupItem]

    var body: some View {
        Button {
            store.reviewWithAgent(items)
        } label: {
            if store.isReviewing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("İnceleniyor…"))
                }
            } else {
                Label(L("AI ile incele"), systemImage: "sparkles")
            }
        }
        .buttonStyle(PillButtonStyle())
        .disabled(store.isReviewing || AgentReview.reviewable(items).isEmpty)
        .opacity(store.isReviewing || AgentReview.reviewable(items).isEmpty ? 0.5 : 1)
        .help(L("Ayarlardaki AI ajanı bu öğeleri inceler ve güvenli bulduklarını işaretler. Hiçbir şey silinmez."))
    }
}

/// Sparkle shown on a row the agent reviewed; hovering shows its reasoning.
struct AIVerdictBadge: View {
    let verdict: AIVerdict

    var body: some View {
        Image(systemName: verdict.safe ? "sparkles" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(verdict.safe ? Color.accentColor : Color.orange)
            .help(verdict.reason.isEmpty
                  ? (verdict.safe ? L("AI güvenli buldu") : L("AI güvenli bulmadı"))
                  : (verdict.safe ? L("AI güvenli buldu: ") : L("AI güvenli bulmadı: ")) + verdict.reason)
    }
}
