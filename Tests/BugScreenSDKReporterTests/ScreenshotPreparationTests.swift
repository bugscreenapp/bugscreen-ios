@testable import BugScreenSDK
import UIKit
import XCTest

/// Preparation moved out of APIClient with these assertions (RFC-003 §2.2). They live
/// here now because this is the layer every host shares — the transport is the part a
/// host replaces, and COMP-004's unconditional-downscale promise has to survive that.
final class ScreenshotPreparationTests: XCTestCase {
    func testOversizeImageIsDownscaledUnderTheUploadLongEdgeCap() throws {
        // A 6000×4000 raw image — way over the 2000 px long-edge cap.
        let oversized = TestHelpers.solidImage(width: 6000, height: 4000, color: .blue)
        let prepared = try XCTUnwrap(ScreenshotPreparation.prepare(oversized))

        // `UIImage(data:)` loads JPEGs at scale 1, so `size` reflects pixels here.
        let decoded = try XCTUnwrap(UIImage(data: prepared.data))
        XCTAssertLessThanOrEqual(
            max(decoded.size.width, decoded.size.height),
            ScreenshotPreparation.maxUploadLongEdge
        )
        XCTAssertLessThan(prepared.data.count, 1_000_000)
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
    }

    func testDownscaleMeasuresPixelsNotPoints() throws {
        // Retina screenshot shape: 1179×2556 px at scale 3 ⇒ point size 393×852. The
        // point-based check would let this through untouched; the pixel check must catch it.
        let image = TestHelpers.retinaImage(pixelWidth: 1179, pixelHeight: 2556, scale: 3)
        XCTAssertLessThan(max(image.size.width, image.size.height), ScreenshotPreparation.maxUploadLongEdge)
        XCTAssertGreaterThan(
            max(image.size.width, image.size.height) * image.scale,
            ScreenshotPreparation.maxUploadLongEdge
        )

        let prepared = try XCTUnwrap(ScreenshotPreparation.prepare(image))
        let decoded = try XCTUnwrap(UIImage(data: prepared.data))
        XCTAssertLessThanOrEqual(
            max(decoded.size.width, decoded.size.height),
            ScreenshotPreparation.maxUploadLongEdge
        )
    }

    func testEveryImageIsReEncodedEvenWhenAlreadyUnderTheCap() throws {
        // COMP-004: unconditionally, not only when it exceeds the limit. A small image
        // still comes back as JPEG rather than passing through untouched.
        let small = TestHelpers.solidImage(width: 10, height: 10)
        let prepared = try XCTUnwrap(ScreenshotPreparation.prepare(small))

        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertFalse(prepared.data.isEmpty)
    }
}
