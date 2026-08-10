@testable import BugScreenSDK
import XCTest

/// Mirrors Android's `AttachmentPreviewIndexTest` so the full-screen preview
/// clamps its index identically on both platforms after a delete.
final class AttachmentPreviewIndexTests: XCTestCase {
    func testReturnsNilWhenLastAttachmentDeleted() {
        XCTAssertNil(nextPreviewIndex(afterDeleting: 0, newCount: 0))
    }

    func testClampsToNewLastWhenDeletingTheLastOfMany() {
        // Was viewing index 2 of 3; after delete only 2 remain → land on index 1.
        XCTAssertEqual(nextPreviewIndex(afterDeleting: 2, newCount: 2), 1)
    }

    func testStaysOnSameIndexWhenDeletingFromTheMiddle() {
        // Deleting index 1 of 3 leaves 2; the item that shifted in keeps index 1.
        XCTAssertEqual(nextPreviewIndex(afterDeleting: 1, newCount: 2), 1)
    }

    func testStaysAtZeroWhenDeletingFirstOfMany() {
        XCTAssertEqual(nextPreviewIndex(afterDeleting: 0, newCount: 3), 0)
    }
}
