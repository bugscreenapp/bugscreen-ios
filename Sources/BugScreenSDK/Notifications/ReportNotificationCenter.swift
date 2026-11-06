import Foundation
import UserNotifications

enum ReportNotificationAuthorization {
    case authorized, denied, deferred
}

@MainActor
protocol ReportNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func authorized() async -> Bool
    func requestAuthorization(when allowed: () -> Bool) async -> ReportNotificationAuthorization
    func identifiers() async -> Set<String>
    func add(_ request: UNNotificationRequest) async throws
    func remove(_ identifier: String)
    func installCategory(_ category: UNNotificationCategory) async
}

@MainActor
final class SystemReportNotificationCenter: ReportNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        return (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) &&
            settings.notificationCenterSetting == .enabled
    }

    func requestAuthorization(when allowed: () -> Bool) async -> ReportNotificationAuthorization {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard allowed() else { return .deferred }
            do { _ = try await center.requestAuthorization(options: [.alert]) } catch { return .denied }
        }
        return await authorized() ? .authorized : .denied
    }

    func identifiers() async -> Set<String> {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        return Set(delivered + pending)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func remove(_ identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func installCategory(_ category: UNNotificationCategory) async {
        let categories = await center.notificationCategories()
        center.setNotificationCategories(Self.adding(category, to: categories))
    }

    static func adding(_ category: UNNotificationCategory, to existing: Set<UNNotificationCategory>) -> Set<UNNotificationCategory> {
        var categories = existing.filter { $0.identifier != category.identifier }
        categories.insert(category)
        return categories
    }
}

final class ReportNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var previous: UNUserNotificationCenterDelegate?
    var presentation: (String, @escaping (UNNotificationPresentationOptions) -> Void) -> Void = { _, done in done([]) }
    var response: (String, String, @escaping () -> Void) -> Void = { _, _, done in done() }

    static func owns(_ identifier: String) -> Bool {
        identifier.hasPrefix("app.bugscreen.report.")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        if Self.owns(notification.request.identifier) {
            presentation(notification.request.identifier, completionHandler)
        } else if let previous, previous.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void)
    {
        if Self.owns(response.notification.request.identifier) {
            self.response(response.notification.request.identifier, response.actionIdentifier, completionHandler)
        } else if let previous, previous.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        previous?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
