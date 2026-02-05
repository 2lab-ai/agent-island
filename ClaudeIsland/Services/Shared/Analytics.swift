import Foundation
import Mixpanel

enum Analytics {
    private static let mixpanelToken = "49814c1436104ed108f3fc4735228496"

    private static let lock = NSLock()
    private static var isInitialized: Bool = false

    static func initializeIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard !isInitialized else { return }
        Mixpanel.initialize(token: mixpanelToken)
        isInitialized = true
    }

    static func identify(distinctId: String) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().identify(distinctId: distinctId)
    }

    static func registerSuperProperties(_ properties: Properties) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().registerSuperProperties(properties)
    }

    static func peopleSet(properties: Properties) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().people.set(properties: properties)
    }

    static func track(event: String) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().track(event: event)
    }

    static func flush() {
        guard isInitialized else { return }
        Mixpanel.mainInstance().flush()
    }
}

