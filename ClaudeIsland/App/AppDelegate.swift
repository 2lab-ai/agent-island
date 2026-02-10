import AppKit
import IOKit
#if !APPSTORE
import Sparkle
#endif
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?

    static var shared: AppDelegate?
    #if !APPSTORE
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver
    #endif

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        #if !APPSTORE
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        #endif
        super.init()
        AppDelegate.shared = self

        #if !APPSTORE
        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        migrateFromClaudeIslandIfNeeded()

        Analytics.initializeIfNeeded()

        let distinctId = getOrCreateDistinctId()
        Analytics.identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Analytics.registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Analytics.peopleSet(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Analytics.track(event: "App Launched")
        Analytics.flush()

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        let notchController = windowManager?.setupNotchWindow()

        UsageResetAlertCoordinator.shared.attachNotchViewModel(notchController?.viewModel)
        UsageResetAlertCoordinator.shared.startIfNeeded(model: UsageDashboardViewModel.shared)

        Task { @MainActor in
            UsageDashboardViewModel.shared.startBackgroundRefreshIfNeeded()
        }

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        #if !APPSTORE
        if updater.canCheckForUpdates {
            updater.checkForUpdatesInBackground()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
        #endif
    }

    private func handleScreenChange() {
        let notchController = windowManager?.setupNotchWindow()
        UsageResetAlertCoordinator.shared.attachNotchViewModel(notchController?.viewModel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Analytics.flush()
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Analytics.registerSuperProperties(["claude_code_version": version])
            Analytics.peopleSet(properties: ["claude_code_version": version])
            return
        }
    }

    private func migrateFromClaudeIslandIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldDir = home.appendingPathComponent(".claude-island")
        let newDir = home.appendingPathComponent(".agent-island")

        guard fm.fileExists(atPath: oldDir.path) else { return }

        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        } catch {
            print("Migration: failed to create .agent-island directory: \(error)")
            return
        }

        do {
            try mergeCopyMissingItems(from: oldDir, to: newDir, fileManager: fm)
        } catch {
            print("Migration from .claude-island failed: \(error)")
        }
    }

    private func mergeCopyMissingItems(from source: URL, to destination: URL, fileManager: FileManager) throws {
        let sourcePath = source.path
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for case let itemURL as URL in enumerator {
            let itemPath = itemURL.path
            guard itemPath.hasPrefix(sourcePath) else { continue }
            var relativePath = String(itemPath.dropFirst(sourcePath.count))
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            guard !relativePath.isEmpty else { continue }

            let targetURL = destination.appendingPathComponent(relativePath)
            guard !fileManager.fileExists(atPath: targetURL.path) else { continue }

            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            let parent = targetURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: itemURL, to: targetURL)
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.2lab.AgentIsalnd"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
