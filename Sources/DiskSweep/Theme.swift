import SwiftUI
import DiskSweepCore

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let smooth = Animation.smooth(duration: 0.32)
    static let snappy = Animation.snappy(duration: 0.24)
}

extension CategoryGroup {
    var tint: Color {
        switch self {
        case .xcode: return .blue
        case .docker: return .cyan
        case .packageCaches: return .orange
        case .projects: return .purple
        case .system: return .teal
        }
    }
}

extension SafetyLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .caution: return .orange
        case .protected: return .gray
        }
    }

    var label: String {
        switch self {
        case .safe: return "Güvenli"
        case .caution: return "Dikkat"
        case .protected: return "Korumalı"
        }
    }
}

func tint(forCategory id: String) -> Color {
    if id == FolderScan.categoryID { return .indigo }
    return Catalog.all.first { $0.id == id }?.group.tint ?? .accentColor
}

/// Rounded gradient tile with a white SF Symbol, like System Settings icons.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: size * 0.15, y: size * 0.07)
    }
}

extension View {
    func card(cornerRadius: CGFloat = 14,
              fill: Color = Color.primary.opacity(0.045),
              stroke: Color = Color.primary.opacity(0.08)) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(stroke))
    }
}
