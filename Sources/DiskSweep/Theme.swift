import SwiftUI
import DiskSweepCore

enum Motion {
    // Short, damped transitions: no bounce, nothing that draws attention to itself.
    static let spring = Animation.smooth(duration: 0.28)
    static let smooth = Animation.smooth(duration: 0.24)
    static let snappy = Animation.snappy(duration: 0.16)
}

extension CategoryGroup {
    /// Muted, flat hues: enough to tell areas apart, never loud.
    var tint: Color {
        switch self {
        case .xcode: return .blue
        case .docker: return .teal
        case .packageCaches: return .orange
        case .projects: return .indigo
        case .system: return .green
        case .apps: return .brown
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
        case .safe: return L("Güvenli")
        case .caution: return L("Dikkat")
        case .protected: return L("Korumalı")
        }
    }
}

func tint(forCategory id: String) -> Color {
    if id == FolderScan.categoryID { return .indigo }
    switch id {
    case DeviceScan.largeID: return .brown
    case DeviceScan.downloadsID: return .blue
    case DeviceScan.installersID: return .teal
    case DeviceScan.dependenciesID: return .indigo
    default: return Catalog.all.first { $0.id == id }?.group.tint ?? .accentColor
    }
}

/// Small rounded tile with an SF Symbol: a soft tint of the color behind a full-color glyph. Flat on purpose.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26
    var emphasized = true

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.opacity(0.17))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
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
