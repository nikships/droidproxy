import SwiftUI

/// Same visual language as the Codex fast-mode rows: a caption label with a
/// checkbox, plus a time picker once the provider's toggle is on.
struct WindowPrimerRow: View {
    let provider: WindowPrimerProvider
    @AppStorage private var enabled: Bool
    @AppStorage private var minutes: Int

    init(provider: WindowPrimerProvider) {
        self.provider = provider
        _enabled = AppStorage(wrappedValue: false, provider.enabledKey)
        _minutes = AppStorage(wrappedValue: WindowPrimerProvider.defaultMinutes, provider.minutesKey)
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                return calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: Date())) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    var body: some View {
        HStack {
            Text("5-hour window")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if enabled {
                DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Toggle("Auto-start daily", isOn: $enabled)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Sends one tiny request (a few tokens) per account at this time every day while DroidProxy is running, so your 5-hour \(provider.serviceType.displayName) window is already underway when you start work and resets sooner during your day.")
        }
        .padding(.vertical, 2)
        .padding(.leading, 28)
    }
}
