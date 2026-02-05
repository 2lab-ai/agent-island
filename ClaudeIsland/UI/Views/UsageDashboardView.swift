import Combine
import SwiftUI

@MainActor
final class UsageDashboardViewModel: ObservableObject {
    @Published var profiles: [UsageProfile] = []
    @Published var snapshotsByProfileName: [String: UsageSnapshot] = [:]
    @Published var isRefreshing = false
    @Published var isSavingProfile = false
    @Published var switchingProfileName: String?
    @Published var loadErrorMessage: String?
    @Published var lastActionMessage: String?

    private let accountStore: AccountStore
    private let profileStore: ProfileStore
    private let fetcher: UsageFetcher
    private let switcher: ProfileSwitcher

    private var refreshTask: Task<Void, Never>?

    init(accountStore: AccountStore = AccountStore()) {
        self.accountStore = accountStore
        self.profileStore = ProfileStore(accountStore: accountStore)
        self.fetcher = UsageFetcher(accountStore: accountStore, cache: UsageCache())
        self.switcher = ProfileSwitcher(accountStore: accountStore, exporter: CredentialExporter())
    }

    func load() {
        do {
            loadErrorMessage = nil
            profiles = try profileStore.loadProfiles()
        } catch {
            loadErrorMessage = error.localizedDescription
            profiles = []
        }

        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        isRefreshing = true

        let profilesToRefresh = profiles
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }

            for profile in profilesToRefresh {
                if Task.isCancelled { break }
                let snapshot = await fetcher.fetchSnapshot(for: profile)
                snapshotsByProfileName[profile.name] = snapshot
            }
        }
    }

    func saveProfile(named name: String) async -> Bool {
        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            let result = try switcher.saveCurrentProfile(named: name)
            lastActionMessage = result.warnings.isEmpty
                ? "Saved profile “\(result.profile.name)”."
                : "Saved “\(result.profile.name)” with warnings: \(result.warnings.joined(separator: " · "))"

            profiles = try profileStore.loadProfiles()
            refresh()
            return true
        } catch {
            lastActionMessage = error.localizedDescription
            return false
        }
    }

    func switchToProfile(_ profile: UsageProfile) async {
        switchingProfileName = profile.name
        defer { switchingProfileName = nil }

        do {
            let result = try switcher.switchToProfile(profile)
            var flags: [String] = []
            if result.claudeSwitched { flags.append("Claude") }
            if result.codexSwitched { flags.append("Codex") }
            if result.geminiSwitched { flags.append("Gemini") }

            let switchedSummary = flags.isEmpty ? "No files copied." : "Switched: \(flags.joined(separator: ", "))."
            let warningsSummary = result.warnings.isEmpty ? nil : "Warnings: \(result.warnings.joined(separator: " · "))"
            lastActionMessage = [switchedSummary, warningsSummary].compactMap { $0 }.joined(separator: " ")
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }
}

struct UsageDashboardView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var model = UsageDashboardViewModel()

    @State private var isSaveSheetPresented = false
    @State private var newProfileName = ""
    @State private var pendingSwitchProfile: UsageProfile?

    var body: some View {
        VStack(spacing: 10) {
            header

            if let message = model.lastActionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal, 6)
            }

            profilesSection

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.horizontal, 6)

            sessionsPreviewSection
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.load() }
        .confirmationDialog(
            "Switch Profile (Experimental)",
            isPresented: Binding(
                get: { pendingSwitchProfile != nil },
                set: { if !$0 { pendingSwitchProfile = nil } }
            )
        ) {
            Button("Switch", role: .destructive) {
                guard let profile = pendingSwitchProfile else { return }
                pendingSwitchProfile = nil
                Task { await model.switchToProfile(profile) }
            }
            Button("Cancel", role: .cancel) {
                pendingSwitchProfile = nil
            }
        } message: {
            if let profile = pendingSwitchProfile {
                Text("This will overwrite your active CLI credentials with “\(profile.name)”. Best-effort only.")
            } else {
                Text("This will overwrite your active CLI credentials. Best-effort only.")
            }
        }
        .sheet(isPresented: $isSaveSheetPresented) {
            SaveProfileSheet(
                isSaving: model.isSavingProfile,
                name: $newProfileName,
                onCancel: { isSaveSheetPresented = false },
                onSave: {
                    Task {
                        let ok = await model.saveProfile(named: newProfileName)
                        if ok {
                            newProfileName = ""
                            isSaveSheetPresented = false
                        }
                    }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("구독 사용량")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Profiles")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            Button {
                isSaveSheetPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Button {
                model.refresh()
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 6)
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.loadErrorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.red)
                    .padding(.horizontal, 6)
            }

            if model.profiles.isEmpty {
                emptyProfilesState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.profiles) { profile in
                            ProfileUsageRow(
                                profile: profile,
                                snapshot: model.snapshotsByProfileName[profile.name],
                                isSwitching: model.switchingProfileName == profile.name,
                                onSwitch: { pendingSwitchProfile = profile }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var emptyProfilesState: some View {
        VStack(spacing: 8) {
            Text("No profiles yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("Use “Save Profile” to snapshot your current CLI logins.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 10)
    }

    private var sessionsPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.showSessions()
            } label: {
                HStack(spacing: 8) {
                    Text("클로드 세션 리스트")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)

            if previewSessions.isEmpty {
                Text("No sessions")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(previewSessions) { session in
                        Button {
                            viewModel.showSessions()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(color(for: session.phase))
                                    .frame(width: 6, height: 6)
                                Text(session.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private var previewSessions: [SessionState] {
        sessionMonitor.instances
            .sorted { a, b in
                let dateA = a.lastUserMessageDate ?? a.lastActivity
                let dateB = b.lastUserMessageDate ?? b.lastActivity
                return dateA > dateB
            }
            .prefix(3)
            .map { $0 }
    }

    private func color(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval, .processing, .compacting:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return TerminalColors.dim
        }
    }
}

private struct ProfileUsageRow: View {
    let profile: UsageProfile
    let snapshot: UsageSnapshot?
    let isSwitching: Bool
    let onSwitch: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                if let snapshot, let fetchedAt = snapshot.fetchedAt {
                    Text(timeString(fetchedAt))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(snapshot.isStale ? 0.35 : 0.45))
                }

                Button {
                    onSwitch()
                } label: {
                    HStack(spacing: 6) {
                        if isSwitching {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("Switch")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSwitching)
            }

            HStack(spacing: 10) {
                UsageServicePill(label: "Claude", info: snapshot?.output?.claude)
                UsageServicePill(label: "Codex", info: snapshot?.output?.codex)
                UsageServicePill(label: "Gemini", info: snapshot?.output?.gemini)
            }

            if let message = snapshot?.errorMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.amber.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.09) : Color.white.opacity(0.06))
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func timeString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

private struct UsageServicePill: View {
    let label: String
    let info: CLIUsageInfo?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))

            Spacer(minLength: 6)

            Text(summaryText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(summaryColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var summaryText: String {
        guard let info else { return "--" }
        if !info.available { return "--" }
        if info.error { return "ERR" }

        let five = info.fiveHourPercent.map { "\(Int($0.rounded()))" } ?? "--"
        let seven = info.sevenDayPercent.map { "\(Int($0.rounded()))" } ?? "--"
        return "\(five)/\(seven)"
    }

    private var summaryColor: Color {
        guard let info else { return TerminalColors.dim }
        if !info.available { return TerminalColors.dim }
        if info.error { return TerminalColors.amber }
        return TerminalColors.green
    }
}

private struct SaveProfileSheet: View {
    let isSaving: Bool
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Profile")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("e.g. Work", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("This snapshots your current Claude/Codex/Gemini CLI credentials into `~/.claude-island/accounts/` and links them to the profile.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button(isSaving ? "Saving…" : "Save") { onSave() }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
