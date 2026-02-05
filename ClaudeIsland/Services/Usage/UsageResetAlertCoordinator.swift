import Combine
import Foundation

@MainActor
final class UsageResetAlertCoordinator: ObservableObject {
    static let shared = UsageResetAlertCoordinator()

    enum Mode: Equatable {
        /// Short-lived popup (auto-closes).
        case pulse
        /// Keep the island open (until user closes it).
        case sticky
    }

    struct Alert: Identifiable, Equatable {
        let id: String
        let provider: UsageProvider
        let window: UsageWindow
        let profileName: String
        let email: String?
        let tier: String?
        let resetAt: Date
    }

    @Published private(set) var mode: Mode = .pulse
    @Published private(set) var alerts: [Alert] = []

    private weak var notchViewModel: NotchViewModel?
    private weak var usageModel: UsageDashboardViewModel?

    private var tickCancellable: AnyCancellable?
    private var notchCancellables = Set<AnyCancellable>()

    /// Prevent repeat popups while the rounded mark is stable (e.g., multiple ticks at "50m").
    private var firedKeys = Set<String>()

    /// If the user closes the sticky view, don't fight them and reopen for the same reset cycle.
    private var dismissedStickyCycles = Set<String>()
    private var activeStickyCycles = Set<String>()

    private var autoCloseTask: Task<Void, Never>?

    func startIfNeeded(model: UsageDashboardViewModel = .shared) {
        guard tickCancellable == nil else { return }
        usageModel = model

        // Evaluate immediately on boot so the first popup can be scheduled without waiting a full tick.
        evaluate(now: Date())

        tickCancellable = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                self?.evaluate(now: now)
            }
    }

    func attachNotchViewModel(_ viewModel: NotchViewModel?) {
        notchViewModel = viewModel
        notchCancellables.removeAll()

        guard let viewModel else { return }

        viewModel.$status
            .sink { [weak self] status in
                guard let self else { return }
                guard status == .closed else { return }
                guard self.mode == .sticky else { return }
                // User dismissed sticky countdown; don't reopen for the same reset(s).
                self.dismissedStickyCycles.formUnion(self.activeStickyCycles)
                self.activeStickyCycles.removeAll()
                self.mode = .pulse
            }
            .store(in: &notchCancellables)
    }

    private func evaluate(now: Date) {
        guard let usageModel else { return }

        let candidates = buildCandidateAlerts(from: usageModel, now: now)
        if candidates.isEmpty {
            activeStickyCycles.removeAll()
            mode = .pulse
            alerts = []
            return
        }

        pruneFiredKeys(candidates: candidates)

        let stickyCandidates = candidates.filter { alert in
            guard alert.window == .sevenDay else { return false }
            let remaining = max(0, Int(alert.resetAt.timeIntervalSince(now)))
            return remaining > 0 && remaining <= 10 * 60
        }

        let stickyCycles = Set(stickyCandidates.map { cycleId(for: $0) }).subtracting(dismissedStickyCycles)
        if !stickyCycles.isEmpty {
            mode = .sticky
            activeStickyCycles = stickyCycles
            alerts = candidates
                .filter { max(0, Int($0.resetAt.timeIntervalSince(now))) <= 10 * 60 }
                .sorted { $0.resetAt < $1.resetAt }

            openIslandIfNeeded(now: now, autoClose: false)
            return
        }

        // Sticky no longer applies (e.g., reset passed). Reset state so we don't keep showing stale data.
        if mode == .sticky {
            mode = .pulse
            alerts = []
            activeStickyCycles.removeAll()
        } else {
            activeStickyCycles.removeAll()
        }

        // Non-sticky: decide whether a popup is due on this tick.
        let due = dueAlerts(now: now, candidates: candidates)
        guard !due.isEmpty else { return }

        mode = .pulse
        alerts = due
        openIslandIfNeeded(now: now, autoClose: true)
    }

    private func buildCandidateAlerts(from model: UsageDashboardViewModel, now: Date) -> [Alert] {
        var result: [Alert] = []

        func addFromSnapshot(_ snapshot: UsageSnapshot?) {
            guard let snapshot, let output = snapshot.output else { return }

            func addProvider(
                provider: UsageProvider,
                info: CLIUsageInfo?,
                email: String?,
                tier: String?
            ) {
                guard let info, info.available, !info.error else { return }

                // 5h (primary) reset
                if let resetAt = info.fiveHourReset, resetAt > now {
                    result.append(
                        Alert(
                            id: "\(snapshot.profileName)|\(provider.displayName)|5h|\(Int(resetAt.timeIntervalSince1970))",
                            provider: provider,
                            window: .fiveHour,
                            profileName: snapshot.profileName,
                            email: email,
                            tier: tier,
                            resetAt: resetAt
                        )
                    )
                }

                // 7d (secondary) reset
                if let resetAt = info.sevenDayReset, resetAt > now {
                    result.append(
                        Alert(
                            id: "\(snapshot.profileName)|\(provider.displayName)|7d|\(Int(resetAt.timeIntervalSince1970))",
                            provider: provider,
                            window: .sevenDay,
                            profileName: snapshot.profileName,
                            email: email,
                            tier: tier,
                            resetAt: resetAt
                        )
                    )
                }
            }

            addProvider(
                provider: .claude,
                info: output.claude,
                email: snapshot.identities.claudeEmail,
                tier: snapshot.identities.claudeTier
            )
            addProvider(
                provider: .codex,
                info: output.codex,
                email: snapshot.identities.codexEmail,
                tier: nil
            )
        }

        addFromSnapshot(model.currentSnapshot)

        for profile in model.profiles {
            addFromSnapshot(model.snapshotsByProfileName[profile.name])
        }

        return result
    }

    private func dueAlerts(now: Date, candidates: [Alert]) -> [Alert] {
        // We show the union of "active" alerts when any mark is due:
        // - 5h: <= 1h remaining -> every 10 minutes
        // - 7d: <= 6h remaining -> hourly; <= 1h remaining -> every 10 minutes
        var shouldIncludeFiveHour = false
        var shouldIncludeSevenDay = false

        for alert in candidates {
            let remaining = max(0, Int(alert.resetAt.timeIntervalSince(now)))
            guard remaining > 0 else { continue }

            switch alert.window {
            case .fiveHour:
                guard remaining <= 60 * 60 else { continue }
                let minutesCeil = (remaining + 59) / 60
                guard minutesCeil >= 10, minutesCeil % 10 == 0 else { continue }
                let key = "\(cycleId(for: alert))|5h|m\(minutesCeil)"
                if firedKeys.insert(key).inserted {
                    shouldIncludeFiveHour = true
                }

            case .sevenDay:
                guard remaining <= 6 * 60 * 60 else { continue }

                if remaining > 60 * 60 {
                    let hoursCeil = (remaining + 3599) / 3600
                    guard hoursCeil >= 1, hoursCeil <= 6 else { continue }
                    let key = "\(cycleId(for: alert))|7d|h\(hoursCeil)"
                    if firedKeys.insert(key).inserted {
                        shouldIncludeSevenDay = true
                    }
                } else {
                    let minutesCeil = (remaining + 59) / 60
                    guard minutesCeil >= 10, minutesCeil % 10 == 0 else { continue }
                    let key = "\(cycleId(for: alert))|7d|m\(minutesCeil)"
                    if firedKeys.insert(key).inserted {
                        shouldIncludeSevenDay = true
                    }
                }

            case .twentyFourHour:
                continue
            }
        }

        guard shouldIncludeFiveHour || shouldIncludeSevenDay else { return [] }

        return candidates
            .filter { alert in
                let remaining = max(0, Int(alert.resetAt.timeIntervalSince(now)))
                guard remaining > 0 else { return false }

                switch alert.window {
                case .fiveHour:
                    return shouldIncludeFiveHour && remaining <= 60 * 60
                case .sevenDay:
                    return shouldIncludeSevenDay && remaining <= 6 * 60 * 60
                case .twentyFourHour:
                    return false
                }
            }
            .sorted { $0.resetAt < $1.resetAt }
    }

    private func openIslandIfNeeded(now: Date, autoClose: Bool) {
        guard let notchViewModel else { return }

        if notchViewModel.status == .closed {
            notchViewModel.notchOpen(reason: .usageAlert)
        }

        guard autoClose else {
            autoCloseTask?.cancel()
            autoCloseTask = nil
            return
        }

        autoCloseTask?.cancel()
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7 * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.mode == .pulse else { return }
                guard let notchViewModel = self.notchViewModel else { return }
                guard notchViewModel.status == .opened else { return }
                guard notchViewModel.openReason == .usageAlert else { return }
                notchViewModel.notchClose()
            }
        }
    }

    private func cycleId(for alert: Alert) -> String {
        alert.id
    }

    private func pruneFiredKeys(candidates: [Alert]) {
        // Keep memory bounded: drop keys that don't match any active cycle.
        let activeCycles = Set(candidates.map { cycleId(for: $0) })
        firedKeys = firedKeys.filter { key in
            guard let cycle = key.split(separator: "|").prefix(4).joined(separator: "|").nonEmptyOrNil else { return false }
            return activeCycles.contains(cycle)
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
