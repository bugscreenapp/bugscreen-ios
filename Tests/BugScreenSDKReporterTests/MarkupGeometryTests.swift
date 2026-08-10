@testable import BugScreenSDK
import CoreGraphics
import XCTest

/// Mirrors Android's `MarkupGeometryTest` case-for-case so the markup editor's
/// coordinate math and mark construction behave identically on both platforms.
final class MarkupGeometryTests: XCTestCase {
    // MARK: - fittedImageRect

    func testTallImageInWideBoundsPillarboxesCentered() {
        let rect = fittedImageRect(imageSize: CGSize(width: 100, height: 200), boundsSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(rect, CGRect(x: 150, y: 0, width: 100, height: 200))
    }

    func testWideImageInTallBoundsLetterboxesCentered() {
        let rect = fittedImageRect(imageSize: CGSize(width: 200, height: 100), boundsSize: CGSize(width: 200, height: 400))
        XCTAssertEqual(rect, CGRect(x: 0, y: 150, width: 200, height: 100))
    }

    func testExactAspectMatchFillsBounds() {
        let rect = fittedImageRect(imageSize: CGSize(width: 100, height: 200), boundsSize: CGSize(width: 50, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 50, height: 100))
    }

    func testDegenerateSizesYieldZeroRect() {
        XCTAssertEqual(fittedImageRect(imageSize: CGSize(width: 0, height: 100), boundsSize: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(fittedImageRect(imageSize: CGSize(width: 100, height: 100), boundsSize: CGSize(width: 100, height: 0)), .zero)
    }

    // MARK: - coordinate mapping

    func testDisplayToImageRoundTripsThroughImageToDisplay() {
        let imageSize = CGSize(width: 1080, height: 2340)
        let fitted = fittedImageRect(imageSize: imageSize, boundsSize: CGSize(width: 400, height: 800))
        let display = CGPoint(x: fitted.minX + 37, y: fitted.minY + 111)
        let image = imagePoint(fromDisplay: display, fittedRect: fitted, imageSize: imageSize)
        let back = displayPoint(fromImage: image, fittedRect: fitted, imageSize: imageSize)
        XCTAssertEqual(back.x, display.x, accuracy: 0.01)
        XCTAssertEqual(back.y, display.y, accuracy: 0.01)
    }

    func testDisplayPointOutsideImageClampsToImageEdge() {
        let imageSize = CGSize(width: 100, height: 200)
        let fitted = CGRect(x: 50, y: 0, width: 100, height: 200)
        let clamped = imagePoint(fromDisplay: CGPoint(x: 500, y: -40), fittedRect: fitted, imageSize: imageSize)
        XCTAssertEqual(clamped, CGPoint(x: 100, y: 0))
    }

    func testFittedRectCornersMapToImageCorners() {
        let imageSize = CGSize(width: 1000, height: 500)
        let fitted = CGRect(x: 0, y: 75, width: 200, height: 100)
        XCTAssertEqual(imagePoint(fromDisplay: CGPoint(x: 0, y: 75), fittedRect: fitted, imageSize: imageSize), .zero)
        XCTAssertEqual(
            imagePoint(fromDisplay: CGPoint(x: 200, y: 175), fittedRect: fitted, imageSize: imageSize),
            CGPoint(x: 1000, y: 500)
        )
    }

    // MARK: - normalizedRect

    func testNormalizedRectIsIdenticalForAllFourDragDirections() {
        let expected = CGRect(x: 10, y: 20, width: 20, height: 20)
        XCTAssertEqual(normalizedRect(CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)), expected)
        XCTAssertEqual(normalizedRect(CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 20)), expected)
        XCTAssertEqual(normalizedRect(CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 20)), expected)
        XCTAssertEqual(normalizedRect(CGPoint(x: 30, y: 20), CGPoint(x: 10, y: 40)), expected)
    }

    // MARK: - markFromDrag

    private func mark(
        _ tool: MarkupTool,
        start: CGPoint = CGPoint(x: 10, y: 10),
        end: CGPoint = CGPoint(x: 100, y: 100),
        points: [CGPoint]? = nil,
        redactStyle: RedactStyle = .blur
    ) -> MarkupMark? {
        markFromDrag(
            tool: tool,
            start: start,
            end: end,
            points: points ?? [start, end],
            inkArgb: markupInkColors[0],
            redactStyle: redactStyle,
            style: MarkStyle(strokeWidthPx: 4, minDragPx: 8, cornerRadiusPx: 6, arrowHeadLengthPx: 14)
        )
    }

    func testTapCreatesNoMarkForAnyTool() {
        let point = CGPoint(x: 50, y: 50)
        for tool in MarkupTool.allCases {
            XCTAssertNil(mark(tool, start: point, end: point, points: [point]))
        }
    }

    func testSubThresholdDragCreatesNoMark() {
        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 54, y: 53)
        XCTAssertNil(mark(.box, start: start, end: end))
        XCTAssertNil(mark(.arrow, start: start, end: end))
        XCTAssertNil(mark(.redact, start: start, end: end))
    }

    func testBoxDragBuildsNormalizedBoxCapturingInk() {
        guard case let .box(rect, colorArgb, _, _)? = mark(.box, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 10, y: 10)) else {
            return XCTFail("expected a box mark")
        }
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 90, height: 90))
        XCTAssertEqual(colorArgb, markupInkColors[0])
    }

    func testArrowDragKeepsStartAndEndUnnormalized() {
        guard case let .arrow(start, end, _, _, _)? = mark(.arrow, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 10, y: 10)) else {
            return XCTFail("expected an arrow mark")
        }
        XCTAssertEqual(start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(end, CGPoint(x: 10, y: 10))
    }

    func testRedactDragCapturesStyle() {
        guard case let .redact(_, blurStyle)? = mark(.redact, redactStyle: .blur),
              case let .redact(_, solidStyle)? = mark(.redact, redactStyle: .solid)
        else {
            return XCTFail("expected redact marks")
        }
        XCTAssertEqual(blurStyle, .blur)
        XCTAssertEqual(solidStyle, .solid)
    }

    func testPenScribbleWithSmallDisplacementStillCreatesMark() throws {
        let points = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 70, y: 50),
            CGPoint(x: 50, y: 52),
            CGPoint(x: 70, y: 54),
            CGPoint(x: 52, y: 50),
        ]
        guard case let .pen(markPoints, _, _)? = mark(
            .pen,
            start: try XCTUnwrap(points.first),
            end: try XCTUnwrap(points.last),
            points: points
        ) else {
            return XCTFail("expected a pen mark")
        }
        XCTAssertEqual(markPoints.count, points.count)
    }

    func testPenShortStrokeCreatesNoMark() throws {
        let points = [CGPoint(x: 50, y: 50), CGPoint(x: 52, y: 51), CGPoint(x: 53, y: 52)]
        XCTAssertNil(mark(.pen, start: try XCTUnwrap(points.first), end: try XCTUnwrap(points.last), points: points))
    }

    // MARK: - scaledMark

    func testScaledMarkRescalesGeometryAndStrokeDimensions() {
        let box = MarkupMark.box(
            rect: CGRect(x: 10, y: 20, width: 20, height: 20),
            colorArgb: markupInkColors[0],
            strokeWidthPx: 4,
            cornerRadiusPx: 6
        )
        guard case let .box(rect, _, strokeWidthPx, cornerRadiusPx) = scaledMark(box, sx: 2, sy: 3) else {
            return XCTFail("expected a box mark")
        }
        XCTAssertEqual(rect, CGRect(x: 20, y: 60, width: 40, height: 60))
        XCTAssertEqual(strokeWidthPx, 8, accuracy: 0.001)
        XCTAssertEqual(cornerRadiusPx, 12, accuracy: 0.001)

        let pen = MarkupMark.pen(
            points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
            colorArgb: markupInkColors[1],
            strokeWidthPx: 4
        )
        guard case let .pen(points, _, _) = scaledMark(pen, sx: 2, sy: 2) else {
            return XCTFail("expected a pen mark")
        }
        XCTAssertEqual(points, [CGPoint(x: 2, y: 4), CGPoint(x: 6, y: 8)])

        let redact = MarkupMark.redact(rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: .solid)
        guard case let .redact(redactRect, style) = scaledMark(redact, sx: 4, sy: 4) else {
            return XCTFail("expected a redact mark")
        }
        XCTAssertEqual(redactRect, CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertEqual(style, .solid)
    }
}
