import Combine
import SwiftUI

struct UsageResetAlertsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var coordinator: UsageResetAlertCoordinator

    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if coordinator.alerts.isEmpty {
                Text("No upcoming reset alerts.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 26)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.alerts) { alert in
                            row(alert)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(clock) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.mode == .sticky ? "Reset Countdown" : "Reset Reminder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(coordinator.mode == .sticky ? "Live (final 10 minutes)" : "Scheduled popup")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            if coordinator.mode == .sticky {
                Text("LIVE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TerminalColors.amber.opacity(0.95))
                    )
            }

            Button {
                viewModel.notchClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(_ alert: UsageResetAlertCoordinator.Alert) -> some View {
        let remainingSeconds = max(0, Int(alert.resetAt.timeIntervalSince(now)))

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                UsageProviderIcon(provider: alert.provider, size: 14)

                if let tier = alert.tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
                    Text(tier)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                        )
                }

                Text(alert.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? alert.profileName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Text(alert.window.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .frame(width: 22, alignment: .leading)

                UsageDurationText.make(
                    seconds: remainingSeconds,
                    digitColor: .white.opacity(0.62)
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(remainingSeconds <= 10 * 60 ? 0.09 : 0.06))
        )
    }
}
