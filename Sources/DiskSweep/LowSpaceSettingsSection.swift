import SwiftUI
import DiskSweepCore

struct LowSpaceSettingsSection: View {
    @AppStorage("lowSpaceAlertEnabled") private var enabled = false
    @AppStorage("lowSpaceThresholdGB") private var thresholdGB = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Disk alanı uyarısı").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                row(title: L("Az alan kaldığında uyar"),
                    detail: L("Boş alan belirlediğiniz sınırın altına düşerse bildirim gönderir.")) {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
                row(title: L("Uyarı sınırı"), detail: nil) {
                    Stepper(L("\(thresholdGB) GB"), value: $thresholdGB, in: 1...1000, step: 1)
                        .fixedSize()
                        .disabled(!enabled)
                }
            }
            .card(cornerRadius: 14)
        }
    }

    private func row<Control: View>(title: String, detail: String?,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
    }
}
