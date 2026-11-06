@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class ReportNotificationPermissionTests: XCTestCase {
    func testInitialRequestWaitsForActiveHostThenPostsAfterGrant() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        center.authorizationResult = true
        var active = false
        let controller = makeController(center, requestPermission: true, active: { active })
        defer { controller.stop() }
        await controller.start()
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.present.isEmpty)
        active = true
        await controller.activate()
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.present.count, 1)
    }

    func testOptOutNeverRequestsAndExplicitShowUsesDefaultRequest() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        center.authorizationResult = true
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        controller.show(requestPermission: false)
        await controller.activate()
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.present.isEmpty)
        controller.show()
        await controller.activate()
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.present.count, 1)
    }

    func testDenialDoesNotRetryOnActivation() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        let controller = makeController(center, requestPermission: true)
        defer { controller.stop() }
        await controller.start()
        for _ in 0 ..< 3 {
            await controller.activate()
        }
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(center.present.isEmpty)
    }

    func testRepeatedShowWhileAuthorizationIsPendingDoesNotRequestAgainAfterDenial() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        center.suspendAuthorization = true
        let controller = makeController(center, requestPermission: true)
        defer { controller.stop() }
        let starting = Task { await controller.start() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedAuthorization)
        controller.show()
        controller.show()
        center.suspendedAuthorization?.resume()
        await starting.value
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(center.present.isEmpty)
    }

    func testHideAndStopPreventLateGrantFromPosting() async {
        for stop in [false, true] {
            let center = FakeReportNotificationCenter()
            center.allowed = false
            center.authorizationResult = true
            center.suspendAuthorization = true
            let controller = makeController(center, requestPermission: true)
            let starting = Task { await controller.start() }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            XCTAssertNotNil(center.suspendedAuthorization)
            if stop { controller.stop() } else { controller.hide() }
            center.suspendedAuthorization?.resume()
            await starting.value
            await controller.activate()
            XCTAssertTrue(center.present.isEmpty)
            controller.stop()
        }
    }

    func testExplicitOptOutBeforeAsyncStartupOverridesInitialRequest() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        let controller = makeController(center, requestPermission: true)
        defer { controller.stop() }
        controller.show(requestPermission: false)
        await controller.start()
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.present.isEmpty)
    }

    func testGrantedPermissionDoesNotRequireActiveHostOrRequestAgain() async {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center, requestPermission: true, active: { false })
        defer { controller.stop() }
        await controller.start()
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(center.present.count, 1)
    }

    func testHideStopAndOptOutPreventPromptAfterSettingsPreflight() async {
        for action in ["hide", "stop", "optOut"] {
            let center = FakeReportNotificationCenter()
            center.allowed = false
            center.suspendAuthorizationPreflight = true
            let controller = makeController(center, requestPermission: true)
            let starting = Task { await controller.start() }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            XCTAssertNotNil(center.suspendedAuthorizationPreflight)
            switch action {
            case "hide": controller.hide()
            case "stop": controller.stop()
            default: controller.show(requestPermission: false)
            }
            center.suspendedAuthorizationPreflight?.resume()
            await starting.value
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            XCTAssertEqual(center.authorizationRequests, 0)
            XCTAssertTrue(center.present.isEmpty)
            controller.stop()
        }
    }

    func testInactiveSettingsPreflightDefersUntilHostBecomesActiveAgain() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        center.authorizationResult = true
        center.suspendAuthorizationPreflight = true
        var active = true
        let controller = makeController(center, requestPermission: true, active: { active })
        defer { controller.stop() }
        let starting = Task { await controller.start() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedAuthorizationPreflight)
        active = false
        center.suspendedAuthorizationPreflight?.resume()
        await starting.value
        XCTAssertEqual(center.authorizationRequests, 0)
        center.suspendAuthorizationPreflight = false
        active = true
        await controller.activate()
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.present.count, 1)
    }

    func testConfigurationDefaultsAndOptOutArePreserved() {
        let originalCenter = BugScreenSDK.makeReportNotificationCenter
        BugScreenSDK.makeReportNotificationCenter = { FakeReportNotificationCenter() }
        defer {
            BugScreenSDK.shutdown()
            BugScreenSDK.makeReportNotificationCenter = originalCenter
        }
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, showReportNotification: false)
        XCTAssertEqual(BugScreenSDK.configuration?.showReportNotification, false)
        XCTAssertEqual(BugScreenSDK.configuration?.requestNotificationPermission, true)
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey, showReportNotification: true, requestNotificationPermission: false)
        XCTAssertEqual(BugScreenSDK.configuration?.showReportNotification, true)
        XCTAssertEqual(BugScreenSDK.configuration?.requestNotificationPermission, false)
    }

    private func makeController(_ center: FakeReportNotificationCenter, requestPermission: Bool = false,
                                active: @escaping () -> Bool = { true }) -> ReportNotificationController
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        return ReportNotificationController(center: center, requestPermission: requestPermission, windowProvider: { window },
                                            eligible: { _ in true }, isActive: { _ in active() }, present: { _, _ in })
    }
}
