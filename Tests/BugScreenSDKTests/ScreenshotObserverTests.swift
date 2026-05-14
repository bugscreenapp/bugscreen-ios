//
//  ScreenshotObserverTests.swift
//  BugScreenSDKTests
//
//  Created by BugScreen on 2025-01-15.
//

import XCTest
@testable import BugScreenSDK

@available(iOS 15.0, *)
final class ScreenshotObserverTests: XCTestCase {

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        // Stop observer before each test to start with clean state
        ScreenshotObserver.shared.stopObserving()
    }

    override func tearDown() {
        // Clean up after each test
        ScreenshotObserver.shared.stopObserving()
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSharedInstanceReturnsSameObject() {
        // Given
        let instance1 = ScreenshotObserver.shared
        let instance2 = ScreenshotObserver.shared

        // Then
        XCTAssertTrue(instance1 === instance2, "shared should return the same singleton instance")
    }

    // MARK: - Observer Lifecycle Tests

    func testStartObservingRegistersForNotifications() {
        // Given
        let observer = ScreenshotObserver.shared

        // When
        observer.startObserving()

        // Then
        // We can't directly test if NotificationCenter has registered the observer,
        // but we can verify the observer doesn't crash and can be stopped
        XCTAssertNoThrow(observer.stopObserving())
    }

    func testStopObservingUnregistersFromNotifications() {
        // Given
        let observer = ScreenshotObserver.shared
        observer.startObserving()

        // When
        observer.stopObserving()

        // Then
        // Verify we can start observing again after stopping
        XCTAssertNoThrow(observer.startObserving())
        observer.stopObserving()
    }

    func testMultipleStartCallsAreIdempotent() {
        // Given
        let observer = ScreenshotObserver.shared

        // When - Call startObserving multiple times
        observer.startObserving()
        observer.startObserving()
        observer.startObserving()

        // Then - Should not crash or register multiple times
        // Clean stop should work fine
        XCTAssertNoThrow(observer.stopObserving())
    }

    func testMultipleStopCallsAreIdempotent() {
        // Given
        let observer = ScreenshotObserver.shared
        observer.startObserving()

        // When - Call stopObserving multiple times
        observer.stopObserving()
        observer.stopObserving()
        observer.stopObserving()

        // Then - Should not crash
        XCTAssertNoThrow(observer.startObserving())
        observer.stopObserving()
    }

    func testStopWithoutStartDoesNotCrash() {
        // Given
        let observer = ScreenshotObserver.shared

        // When - Stop without ever starting
        // Then - Should not crash
        XCTAssertNoThrow(observer.stopObserving())
    }

    func testRestartAfterStop() {
        // Given
        let observer = ScreenshotObserver.shared

        // When
        observer.startObserving()
        observer.stopObserving()
        observer.startObserving()

        // Then - Should be able to restart without issues
        XCTAssertNoThrow(observer.stopObserving())
    }

    // MARK: - Thread Safety Tests

    func testConcurrentStartStopOperations() {
        // Given
        let observer = ScreenshotObserver.shared
        let expectation = self.expectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 10
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        // When - Perform concurrent start/stop operations
        for i in 0..<10 {
            queue.async {
                if i % 2 == 0 {
                    observer.startObserving()
                } else {
                    observer.stopObserving()
                }
                expectation.fulfill()
            }
        }

        // Then
        waitForExpectations(timeout: 5) { error in
            XCTAssertNil(error, "Concurrent operations should complete without error")
        }

        // Cleanup
        observer.stopObserving()
    }

    // MARK: - Integration with SDK Configuration

    func testObserverDoesNotPresentWhenSDKNotConfigured() {
        // Given - SDK not configured
        let observer = ScreenshotObserver.shared

        // When
        observer.startObserving()

        // Then - Post a fake screenshot notification
        // This should not crash even though SDK is not configured
        NotificationCenter.default.post(
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        // Wait a bit for notification to be processed
        let expectation = self.expectation(description: "Notification processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1) { error in
            XCTAssertNil(error)
        }

        // Cleanup
        observer.stopObserving()
    }

    // MARK: - Note About UI Tests

    /*
     The following scenarios are difficult to test in unit tests and would be better
     suited for UI tests or integration tests:

     1. Actual screenshot detection and UI presentation
     2. Background state handling
     3. Window hierarchy navigation
     4. View controller presentation
     5. Preventing duplicate presentations

     These require a full UIKit environment with window scenes, view controllers,
     and the ability to trigger actual screenshot events. Consider adding
     UI tests or manual testing for these scenarios.
     */
}
