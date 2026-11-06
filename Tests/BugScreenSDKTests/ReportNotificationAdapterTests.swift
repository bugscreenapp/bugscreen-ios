@testable import BugScreenSDK
import ObjectiveC
import UIKit
import UserNotifications
import XCTest

@MainActor
final class ReportNotificationAdapterTests: XCTestCase {
    func testWindowRendererBoundsImageAndRejectsEmptyOrIncompleteDrawing() throws {
        let window = NotificationDrawingWindow(frame: CGRect(x: 0, y: 0, width: 2400, height: 1200))
        let image = try XCTUnwrap(ReportNotificationController.captureWindow(window))
        XCTAssertEqual(image.cgImage?.width, 2000)
        XCTAssertEqual(image.cgImage?.height, 1000)
        XCTAssertTrue(window.drew)
        window.complete = false
        XCTAssertNil(ReportNotificationController.captureWindow(window))
        window.frame = .zero
        window.drew = false
        XCTAssertNil(ReportNotificationController.captureWindow(window))
        XCTAssertFalse(window.drew)
    }

    func testDelegatePreservesHostCallbacksOptionsAndCompletionOwnership() throws {
        let center = try delegateSender()
        let host = ForwardingNotificationDelegate()
        let adapter = ReportNotificationDelegate()
        adapter.previous = host
        let notification = try notification(identifier: "host.message")
        var presentations = 0
        adapter.userNotificationCenter(center, willPresent: notification) { options in
            presentations += 1
            XCTAssertEqual(options, [.banner, .sound])
        }
        XCTAssertEqual(host.presentations, 1)
        XCTAssertEqual(presentations, 0)
        host.presentationCompletion?([.banner, .sound])
        XCTAssertEqual(presentations, 1)

        let response = try response(notification: notification)
        var responses = 0
        adapter.userNotificationCenter(center, didReceive: response) { responses += 1 }
        XCTAssertEqual(host.responses, 1)
        XCTAssertEqual(responses, 0)
        host.responseCompletion?()
        XCTAssertEqual(responses, 1)
        adapter.userNotificationCenter(center, openSettingsFor: notification)
        XCTAssertEqual(host.settings, 1)

        adapter.previous = nil
        adapter.userNotificationCenter(center, willPresent: notification) { options in
            presentations += 1
            XCTAssertTrue(options.isEmpty)
        }
        adapter.userNotificationCenter(center, didReceive: response) { responses += 1 }
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(responses, 2)
    }

    func testSdkCallbacksAreInterceptedWithoutInvokingHost() throws {
        let center = try delegateSender()
        let host = ForwardingNotificationDelegate()
        let adapter = ReportNotificationDelegate()
        adapter.previous = host
        let notification = try notification(identifier: "app.bugscreen.report.test")
        var presentations = 0
        var responses = 0
        adapter.presentation = { identifier, done in
            XCTAssertEqual(identifier, notification.request.identifier)
            done([.list])
        }
        adapter.response = { identifier, action, done in
            XCTAssertEqual(identifier, notification.request.identifier)
            XCTAssertEqual(action, UNNotificationDefaultActionIdentifier)
            done()
        }
        adapter.userNotificationCenter(center, willPresent: notification) { options in
            XCTAssertEqual(options, [.list])
            presentations += 1
        }
        adapter.userNotificationCenter(center, didReceive: try response(notification: notification)) { responses += 1 }
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(responses, 1)
        XCTAssertEqual(host.presentations, 0)
        XCTAssertEqual(host.responses, 0)
    }

    func testInstallingCategoryPreservesHostCategories() {
        let host = UNNotificationCategory(identifier: "host.message", actions: [], intentIdentifiers: [], options: [])
        let category = UNNotificationCategory(
            identifier: ReportNotificationController.category,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let installed = SystemReportNotificationCenter.adding(category, to: [host])
        XCTAssertEqual(Set(installed.map(\.identifier)), [host.identifier, category.identifier])
        XCTAssertTrue(installed.contains(host))
        XCTAssertEqual(SystemReportNotificationCenter.adding(category, to: installed).count, 2)
    }

    func testPublicConfigurationInstallsReplacesAndRemovesDelegate() async throws {
        let center = FakeReportNotificationCenter()
        let previous = ForwardingNotificationDelegate()
        center.delegate = previous
        let factory = BugScreenSDK.makeReportNotificationCenter
        BugScreenSDK.makeReportNotificationCenter = { center }
        defer {
            BugScreenSDK.shutdown()
            BugScreenSDK.makeReportNotificationCenter = factory
        }
        BugScreenSDK.shutdown()
        BugScreenSDK.showReportNotification()
        BugScreenSDK.hideReportNotification()
        XCTAssertTrue(center.delegate === previous)
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, enableScreenshotDetection: false)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration).showReportNotification)
        XCTAssertTrue(center.delegate === previous)
        BugScreenSDK.showReportNotification()
        BugScreenSDK.hideReportNotification()
        for _ in 0 ..< 100 where !(center.delegate is ReportNotificationDelegate) {
            await Task.yield()
        }
        XCTAssertTrue(center.delegate is ReportNotificationDelegate)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration).showReportNotification)
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, enableScreenshotDetection: false, showReportNotification: true,
                               screenRecordingOptions: .init(durationSeconds: 15, quality: .low), showFloatingButton: true)
        for _ in 0 ..< 100 where !(center.delegate is ReportNotificationDelegate) {
            await Task.yield()
        }
        let first = try XCTUnwrap(center.delegate as? ReportNotificationDelegate)
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration).showReportNotification)
        XCTAssertEqual(BugScreenSDK.configuration?.screenRecordingOptions.durationSeconds, 15)
        XCTAssertEqual(BugScreenSDK.configuration?.screenRecordingOptions.quality, .low)
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, enableScreenshotDetection: false, showReportNotification: true)
        for _ in 0 ..< 100 where center.delegate === previous {
            await Task.yield()
        }
        XCTAssertTrue(center.delegate is ReportNotificationDelegate)
        XCTAssertFalse(center.delegate === first)
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, enableScreenshotDetection: false, showReportNotification: false)
        XCTAssertTrue(center.delegate === previous)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration).showReportNotification)
        let done = expectation(description: "stale action completes without presenting")
        first.response("app.bugscreen.report.stale", UNNotificationDefaultActionIdentifier) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(center.delegate === previous)
    }

    func testShutdownCancelsDeferredNotificationCleanup() async {
        var created = 0
        let factory = BugScreenSDK.makeReportNotificationCenter
        BugScreenSDK.makeReportNotificationCenter = { created += 1; return FakeReportNotificationCenter() }
        defer { BugScreenSDK.makeReportNotificationCenter = factory }
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, enableScreenshotDetection: false)
        BugScreenSDK.shutdown()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(created, 0)
    }

    private func delegateSender() throws -> UNUserNotificationCenter {
        // The sender is only forwarded by identity. A package test runner has no app bundle
        // for current(), and this fixture never calls the notification service.
        try XCTUnwrap(class_createInstance(UNUserNotificationCenter.self, 0) as? UNUserNotificationCenter)
    }

    private func notification(identifier: String) throws -> UNNotification {
        let request = UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: nil)
        return try XCTUnwrap(UNNotification(coder: NotificationFixtureCoder(["request": request, "date": Date()])))
    }

    private func response(notification: UNNotification) throws -> UNNotificationResponse {
        try XCTUnwrap(UNNotificationResponse(coder: NotificationFixtureCoder([
            "notification": notification, "actionIdentifier": UNNotificationDefaultActionIdentifier,
        ])))
    }
}

private final class NotificationDrawingWindow: UIWindow {
    var complete = true
    var drew = false
    override func drawHierarchy(in rect: CGRect, afterScreenUpdates _: Bool) -> Bool {
        drew = true
        UIColor.red.setFill()
        UIRectFill(rect)
        return complete
    }
}

private final class NotificationFixtureCoder: NSCoder {
    let values: [String: Any]
    init(_ values: [String: Any]) {
        self.values = values
    }

    override var allowsKeyedCoding: Bool {
        true
    }

    override func decodeObject(forKey key: String) -> Any? {
        values[key]
    }
}

private final class ForwardingNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var presentations = 0
    var responses = 0
    var settings = 0
    var presentationCompletion: ((UNNotificationPresentationOptions) -> Void)?
    var responseCompletion: (() -> Void)?
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        presentations += 1
        presentationCompletion = completion
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive _: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void)
    {
        responses += 1
        responseCompletion = completion
    }

    func userNotificationCenter(_: UNUserNotificationCenter, openSettingsFor _: UNNotification?) {
        settings += 1
    }
}
