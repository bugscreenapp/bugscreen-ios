@testable import BugScreenSDK
import UIKit
import UserNotifications
import XCTest

@MainActor
final class ReportNotificationTests: XCTestCase {
    func testActionsReuseFloatingCopyAndForegroundCaptureActions() async {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        let actions = center.categories[0].actions
        XCTAssertEqual(actions.map(\.title), [SDKStrings.floatingReport, SDKStrings.floatingRecord])
        XCTAssertEqual(actions.map(\.identifier), [ReportNotificationController.reportAction,
                                                   ReportNotificationController.recordAction])
        XCTAssertTrue(actions[0].options.contains(.foreground))
        XCTAssertTrue(actions[1].options.contains(.foreground))
    }

    func testRecordingWaitsForOriginalWindowActivationAndSuppressesRepeatedActionsUntilFinished() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow()
        var active = false
        var foregroundWindow: UIWindow? = window
        var recordings = 0
        var finished: (() -> Void)?
        let controller = ReportNotificationController(center: center, windowProvider: { foregroundWindow }, eligible: { _ in true },
                                                      capture: { _ in XCTFail("Recording must not take a screenshot"); return nil },
                                                      isActive: { $0 === window && active },
                                                      startRecording: { origin, closed in
                                                          XCTAssertTrue(origin === window)
                                                          recordings += 1; finished = closed; return true
                                                      }, present: { _, _ in XCTFail("Unexpected screenshot report") })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        controller.handle(identifier: identifier, action: ReportNotificationController.recordAction)
        XCTAssertTrue(center.present.isEmpty)
        XCTAssertEqual(recordings, 0)
        foregroundWindow = nil
        active = true
        await controller.activate()
        XCTAssertEqual(recordings, 1)
        controller.handle(identifier: identifier, action: ReportNotificationController.recordAction)
        controller.handle(identifier: identifier, action: ReportNotificationController.reportAction)
        await controller.activate()
        XCTAssertEqual(recordings, 1)
        XCTAssertTrue(center.present.isEmpty)
        finished?()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
    }

    func testHideBackgroundAndShutdownCancelRecordingBeforeActivation() async throws {
        for cancellation in 0 ..< 3 {
            let center = FakeReportNotificationCenter()
            let window = UIWindow()
            var active = false
            var recordings = 0
            let controller = ReportNotificationController(center: center, windowProvider: { window }, eligible: { _ in true },
                                                          isActive: { _ in active },
                                                          startRecording: { _, _ in recordings += 1; return true },
                                                          present: { _, _ in XCTFail("Unexpected report") })
            await controller.start()
            controller.handle(identifier: try XCTUnwrap(controller.requestID), action: ReportNotificationController.recordAction)
            if cancellation == 0 { controller.hide() } else if cancellation == 1 { controller.background() } else { controller.stop() }
            active = true
            await controller.activate()
            XCTAssertEqual(recordings, 0)
            controller.stop()
        }
    }

    func testRecordingActionRecoversActivationBeforeResponseAndUnavailableHandoff() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow()
        var starts = 0
        let controller = ReportNotificationController(center: center, windowProvider: { window }, eligible: { _ in true },
                                                      isActive: { _ in true }, startRecording: { _, _ in starts += 1; return false },
                                                      present: { _, _ in XCTFail("Unexpected report") })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        center.present.removeAll()
        await controller.activate()
        XCTAssertTrue(controller.hidden)
        controller.handle(identifier: identifier, action: ReportNotificationController.recordAction)
        await controller.activate()
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(controller.hidden)
        XCTAssertEqual(center.present.count, 1)
    }

    func testSharedCaptureSuppressionSurvivesReporterFinishedAndExplicitShow() async {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        controller.captureBusy(true)
        controller.reporterFinished()
        controller.show()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
        controller.captureBusy(false)
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
    }

    func testManualReporterCancelsRecordingHandoffWithoutLosingReporterSuppression() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow()
        var active = false
        var starts = 0
        let controller = ReportNotificationController(center: center, windowProvider: { window }, eligible: { _ in true },
                                                      isActive: { _ in active }, startRecording: { _, _ in starts += 1; return true },
                                                      present: { _, _ in })
        defer { controller.stop() }
        await controller.start()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: ReportNotificationController.recordAction)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
        controller.reporterStarted()
        active = true
        await controller.activate()
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(center.present.isEmpty)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
    }

    func testRecordingHandoffNeverSubstitutesAnotherEligibleWindow() async throws {
        let center = FakeReportNotificationCenter()
        let original = UIWindow()
        let other = UIWindow()
        var foregroundWindow = original
        var activeWindow: UIWindow?
        var starts = 0
        let controller = ReportNotificationController(center: center, windowProvider: { foregroundWindow }, eligible: { _ in true },
                                                      isActive: { $0 === activeWindow }, startRecording: { window, _ in
                                                          XCTAssertTrue(window === original)
                                                          starts += 1
                                                          return true
                                                      }, present: { _, _ in })
        defer { controller.stop() }
        await controller.start()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: ReportNotificationController.recordAction)
        foregroundWindow = other
        activeWindow = other
        await controller.activate()
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(center.present.isEmpty)
        activeWindow = original
        await controller.activate()
        XCTAssertEqual(starts, 1)
    }

    func testQueuedActivationKeepsNotificationWhenOriginalWindowIsInactive() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        var activeWindow: UIWindow? = window
        var visible = true
        var captured: UIWindow?
        let controller = ReportNotificationController(center: center, windowProvider: { activeWindow },
                                                      eligible: { $0 === window && visible },
                                                      capture: { captured = $0; return nil }, present: { _, _ in })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        activeWindow = nil
        await controller.activate()
        XCTAssertEqual(controller.requestID, identifier)
        XCTAssertTrue(center.present.contains(identifier))
        controller.handle(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
        XCTAssertTrue(captured === window)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
        visible = false
        await controller.activate()
        for _ in 0 ..< 100 where !center.present.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(center.present.isEmpty)
    }

    func testShowWinsOverDeferredBackgroundDismissalReconciliation() async throws {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        let old = try XCTUnwrap(controller.requestID)
        center.present.removeAll()
        center.suspendIdentifiers = true
        controller.background()
        for _ in 0 ..< 100 where center.suspendedIdentifiers == nil {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedIdentifiers)
        controller.show()
        center.suspendIdentifiers = false
        center.suspendedIdentifiers?.resume()
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        XCTAssertEqual(center.present.count, 1)
        XCTAssertNotEqual(controller.requestID, old)
    }

    func testShowRestoresUnobservedRemovalAndRejectsOldAction() async throws {
        let center = FakeReportNotificationCenter()
        var reports = 0
        let controller = makeController(center, present: { _, _ in reports += 1 })
        defer { controller.stop() }
        await controller.start()
        let old = try XCTUnwrap(controller.requestID)
        center.present.removeAll()
        controller.show()
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        XCTAssertEqual(center.present.count, 1)
        XCTAssertNotEqual(controller.requestID, old)
        controller.handle(identifier: old, action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(reports, 0)
    }

    func testRepeatedShowWaitsForCategoryInstallation() async {
        let center = FakeReportNotificationCenter()
        center.suspendInstalling = true
        let controller = makeController(center)
        defer { controller.stop() }
        let start = Task { await controller.start() }
        for _ in 0 ..< 100 where center.suspendedInstall == nil {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedInstall)
        controller.show()
        controller.show()
        await controller.activate()
        XCTAssertTrue(center.requests.isEmpty)
        center.suspendInstalling = false
        center.suspendedInstall?.resume()
        await start.value
        XCTAssertEqual(center.present.count, 1)
        XCTAssertEqual(center.categories.count, 1)
    }

    func testExplicitVisibilityOverridesDismissalButNotPermissionOrReporterSuppression() async throws {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        controller.hide()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
        controller.show()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: UNNotificationDismissActionIdentifier)
        controller.show()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
        controller.reporterStarted()
        controller.hide()
        controller.show()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
        controller.hide()
        center.allowed = false
        controller.show()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
    }

    func testPermissionDenialDoesNotPostAndLaterGrantCanPost() async {
        let center = FakeReportNotificationCenter()
        center.allowed = false
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        XCTAssertTrue(center.requests.isEmpty)
        center.allowed = true
        await controller.activate()
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertNil(center.requests[0].content.sound)
        XCTAssertNil(center.requests[0].content.badge)
        XCTAssertEqual(center.requests[0].content.interruptionLevel, .passive)
        XCTAssertTrue(center.categories[0].options.contains(.customDismissAction))
        await controller.activate()
        XCTAssertEqual(center.requests.count, 1)
    }

    func testDismissalSurvivesBackgroundAndForeground() async throws {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: UNNotificationDismissActionIdentifier)
        controller.background()
        await controller.activate()
        XCTAssertTrue(controller.hidden)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.present.isEmpty)
    }

    func testUnexplainedAbsenceIsNotReposted() async {
        let center = FakeReportNotificationCenter()
        let controller = makeController(center)
        defer { controller.stop() }
        await controller.start()
        center.present.removeAll()
        await controller.activate()
        XCTAssertTrue(controller.hidden)
        XCTAssertEqual(center.requests.count, 1)
    }

    func testBackgroundRemovesEntryAndRestoresOnReturnButRejectsOldTap() async throws {
        let center = FakeReportNotificationCenter()
        var reports = 0
        let controller = makeController(center, present: { _, _ in reports += 1 })
        defer { controller.stop() }
        await controller.start()
        let firstID = try XCTUnwrap(controller.requestID)
        controller.background()
        controller.handle(identifier: firstID, action: UNNotificationDefaultActionIdentifier)
        await controller.activate()
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertFalse(center.present.contains(firstID))
    }

    func testCapturePrecedesReportAndDuplicateTapDoesNothing() async throws {
        let center = FakeReportNotificationCenter()
        var order: [String] = []
        let image = UIImage()
        let controller = makeController(center, capture: { _ in order.append("capture"); return image }, present: { _, received in
            XCTAssertTrue(received === image)
            order.append("report")
        })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        controller.handle(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
        controller.handle(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(order, ["capture", "report"])
        XCTAssertTrue(center.present.isEmpty)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertEqual(center.requests.count, 2)
    }

    func testCaptureFailureStillPresentsWithoutImage() async throws {
        let center = FakeReportNotificationCenter()
        var reports = 0
        let controller = makeController(center, present: { _, image in XCTAssertNil(image); reports += 1 })
        defer { controller.stop() }
        await controller.start()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(reports, 1)
    }

    func testInvalidatedWindowCannotBeCaptured() async throws {
        let center = FakeReportNotificationCenter()
        var visible = true
        var captures = 0
        let controller = makeController(center, eligible: { _ in visible }, capture: { _ in captures += 1; return nil })
        defer { controller.stop() }
        await controller.start()
        visible = false
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(captures, 0)
    }

    func testStopRestoresPreviousDelegateButDoesNotClobberReplacement() async {
        let center = FakeReportNotificationCenter()
        let previous = NotificationTestDelegate()
        center.delegate = previous
        let first = makeController(center)
        await first.start()
        XCTAssertFalse(center.delegate === previous)
        first.stop()
        XCTAssertTrue(center.delegate === previous)
        let second = makeController(center)
        await second.start()
        let replacement = NotificationTestDelegate()
        center.delegate = replacement
        await second.activate()
        XCTAssertTrue(second.hidden)
        second.stop()
        XCTAssertTrue(center.delegate === replacement)
        XCTAssertTrue(center.present.isEmpty)
    }

    func testExistingNotificationRemainsBoundToOriginalWindow() async throws {
        let center = FakeReportNotificationCenter()
        let original = UIWindow()
        let other = UIWindow()
        var current = original
        var captured: UIWindow?
        let controller = ReportNotificationController(center: center, windowProvider: { current }, eligible: { _ in true },
                                                      capture: { captured = $0; return nil }, present: { _, _ in })
        defer { controller.stop() }
        await controller.start()
        current = other
        await controller.activate()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: UNNotificationDefaultActionIdentifier)
        XCTAssertTrue(captured === original)
    }

    func testTapStillWorksWhenReactivationPrecedesResponse() async throws {
        let center = FakeReportNotificationCenter()
        var reports = 0
        let controller = makeController(center, present: { _, _ in reports += 1 })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        center.present.remove(identifier)
        await controller.activate()
        controller.handle(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(reports, 1)
        XCTAssertFalse(controller.hidden)
    }

    func testConcurrentActivationDoesNotMistakeInFlightDeliveryForDismissal() async {
        let center = FakeReportNotificationCenter()
        center.suspendAdding = true
        let controller = makeController(center)
        defer { controller.stop() }
        let starting = Task { await controller.start() }
        for _ in 0 ..< 100 where center.suspendedAdd == nil {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedAdd)
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        center.suspendedAdd?.resume()
        await starting.value
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertFalse(center.present.isEmpty)
    }

    func testStopDuringDeliveryRemovesLateNotification() async {
        let center = FakeReportNotificationCenter()
        center.suspendAdding = true
        let controller = makeController(center)
        let starting = Task { await controller.start() }
        for _ in 0 ..< 100 where center.suspendedAdd == nil {
            await Task.yield()
        }
        XCTAssertNotNil(center.suspendedAdd)
        controller.stop()
        center.suspendedAdd?.resume()
        await starting.value
        XCTAssertTrue(center.present.isEmpty)
    }

    func testManualReporterHidesEntryAndRejectsOldAction() async throws {
        let center = FakeReportNotificationCenter()
        var captures = 0
        let controller = makeController(center, capture: { _ in captures += 1; return nil })
        defer { controller.stop() }
        await controller.start()
        let identifier = try XCTUnwrap(controller.requestID)
        controller.reporterStarted()
        controller.handle(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
        await controller.activate()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(center.present.isEmpty)
        controller.reporterFinished()
        await controller.activate()
        XCTAssertEqual(center.requests.count, 2)
    }

    func testSdkPresentationPreservesDraftAndReleasesGuardOnDismissal() throws {
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey,
                                         baseURL: try XCTUnwrap(URL(string: "https://example.test")),
                                         session: StubURLProtocol.makeSession())
        defer { BugScreenSDK.shutdown() }
        let window = UIWindow()
        let presenter = NotificationTestPresenter()
        window.addSubview(presenter.view)
        BugScreenSDK.presentBugReport(from: presenter)
        BugScreenSDK.presentBugReport(from: presenter)
        XCTAssertEqual(presenter.reports.count, 1)
        presenter.reports.first?.dismissFromHost()
        BugScreenSDK.presentBugReport(from: presenter)
        XCTAssertEqual(presenter.reports.count, 2)
        presenter.reports.last?.dismissFromHost()
    }

    private func makeController(_ center: FakeReportNotificationCenter,
                                eligible: @escaping (UIWindow) -> Bool = { _ in true },
                                capture: @escaping (UIWindow) -> UIImage? = { _ in nil },
                                present: @escaping (UIWindow, UIImage?) -> Void = { _, _ in }) -> ReportNotificationController
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        return ReportNotificationController(
            center: center,
            windowProvider: { window },
            eligible: eligible,
            capture: capture,
            present: present
        )
    }
}

@MainActor
final class FakeReportNotificationCenter: ReportNotificationCenter {
    weak var delegate: UNUserNotificationCenterDelegate?
    var allowed = true
    var authorizationRequests = 0
    var authorizationResult = false
    var suspendAuthorizationPreflight = false
    var suspendedAuthorizationPreflight: CheckedContinuation<Void, Never>?
    var suspendAuthorization = false
    var suspendedAuthorization: CheckedContinuation<Void, Never>?
    var suspendAdding = false
    var suspendedAdd: CheckedContinuation<Void, Never>?
    var addError: Error?
    var addAttempts: [String] = []
    var suspendIdentifiers = false
    var suspendedIdentifiers: CheckedContinuation<Void, Never>?
    var suspendInstalling = false
    var suspendedInstall: CheckedContinuation<Void, Never>?
    var present: Set<String> = []
    var requests: [UNNotificationRequest] = []
    var categories: [UNNotificationCategory] = []
    func authorized() async -> Bool {
        allowed
    }

    func requestAuthorization(when allowed: () -> Bool) async -> ReportNotificationAuthorization {
        if suspendAuthorizationPreflight { await withCheckedContinuation { suspendedAuthorizationPreflight = $0 } }
        guard allowed() else { return .deferred }
        authorizationRequests += 1
        if suspendAuthorization { await withCheckedContinuation { suspendedAuthorization = $0 } }
        self.allowed = authorizationResult
        return self.allowed ? .authorized : .denied
    }

    func identifiers() async -> Set<String> {
        if suspendIdentifiers { await withCheckedContinuation { suspendedIdentifiers = $0 } }
        return present
    }

    func add(_ request: UNNotificationRequest) async throws {
        let failure = addError
        addAttempts.append(request.identifier)
        if suspendAdding { await withCheckedContinuation { suspendedAdd = $0 } }
        if let failure { throw failure }
        requests.append(request); present.insert(request.identifier)
    }

    func remove(_ identifier: String) {
        present.remove(identifier)
    }

    func installCategory(_ category: UNNotificationCategory) async {
        if suspendInstalling { await withCheckedContinuation { suspendedInstall = $0 } }
        categories.append(category)
    }
}

private final class NotificationTestDelegate: NSObject, UNUserNotificationCenterDelegate {}

@MainActor
private final class NotificationTestPresenter: UIViewController {
    var reports: [BugReportHostingController] = []
    override func present(_ viewControllerToPresent: UIViewController, animated _: Bool, completion: (() -> Void)? = nil) {
        if let reporter = viewControllerToPresent as? BugReportHostingController { reports.append(reporter) }
        completion?()
    }
}
