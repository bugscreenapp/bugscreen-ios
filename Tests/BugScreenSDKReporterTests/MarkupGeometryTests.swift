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
            style: MarkStyle(displayScale: 1)
        )
    }

    func testTapCreatesNoMarkForAnyTool() {
        let point = CGPoint(x: 50, y: 50)
        for tool in MarkupTool.allCases {
            XCTAssertNil(mark(tool, start: point, end: point, points: [point]))
        }
        XCTAssertNil(mark(.redact, start: point, end: point, points: [point], redactStyle: .solid))
    }

    func testSubThresholdDragCreatesNoMark() {
        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 54, y: 53)
        XCTAssertNil(mark(.box, start: start, end: end))
        XCTAssertNil(mark(.arrow, start: start, end: end))
        XCTAssertNil(mark(.redact, start: start, end: end))
        XCTAssertNil(mark(.redact, start: start, end: end, redactStyle: .solid))
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

    func testRedactBlurCapturesPathAndBrushWidthWhileSolidKeepsRectangle() {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 10), CGPoint(x: 10, y: 10)]
        guard case let .blur(blurPoints, width)? = mark(.redact, points: points),
              case let .solidRedact(rect)? = mark(.redact, start: points[0], end: points[2], redactStyle: .solid)
        else {
            return XCTFail("expected redact marks")
        }
        XCTAssertEqual(blurPoints, points)
        XCTAssertEqual(width, 32)
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 90, height: 90))
    }

    func testBlurLoopAndDoubleBackUseTravelledDistanceInsteadOfDisplacement() {
        let start = CGPoint(x: 50, y: 50)
        for points in [
            [start, CGPoint(x: 70, y: 50), CGPoint(x: 70, y: 70), CGPoint(x: 50, y: 70), start],
            [start, CGPoint(x: 70, y: 50), start],
        ] {
            guard case let .blur(markPoints, _)? = mark(.redact, start: start, end: start, points: points) else {
                return XCTFail("expected a blur stroke despite zero displacement")
            }
            XCTAssertEqual(markPoints, points)
        }
    }

    func testBlurRepeatedIdenticalPointsAndShortLoopCreateNoMark() {
        let start = CGPoint(x: 50, y: 50)
        XCTAssertNil(mark(.redact, start: start, end: start, points: Array(repeating: start, count: 20)))
        XCTAssertNil(mark(.redact, start: start, end: start, points: [start, CGPoint(x: 53, y: 50), start]))
    }

    func testBlurAcceptsEightLogicalPointsOfTravelAtSampledDisplayScale() throws {
        var draft = blurDraft(start: .zero, displayScale: 0.25)
        draft.update(to: CGPoint(x: 31, y: 0))
        XCTAssertNil(draft.mark())
        draft.update(to: CGPoint(x: 32, y: 0))
        let mark = try XCTUnwrap(draft.mark())
        guard case let .blur(_, width) = mark else { return XCTFail("expected a blur stroke") }
        XCTAssertEqual(width, 128)
    }

    // MARK: - active gesture

    func testArrowBoxAndSolidDraftsKeepOriginalStartAndLatestEndpointAfterReversing() {
        let start = CGPoint(x: 100, y: 80)
        let end = CGPoint(x: 10, y: 20)
        let ink = markupInkColors[3]
        let rect = CGRect(x: 10, y: 20, width: 90, height: 60)
        let cases: [(MarkupTool, RedactStyle, MarkupMark)] = [
            (.arrow, .blur, .arrow(start: start, end: end, colorArgb: ink, strokeWidthPx: 8, headLengthPx: 28)),
            (.box, .blur, .box(rect: rect, colorArgb: ink, strokeWidthPx: 8, cornerRadiusPx: 12)),
            (.redact, .solid, .solidRedact(rect: rect)),
        ]
        for (tool, redactStyle, expected) in cases {
            var draft = MarkupDraft(tool: tool, start: start, inkArgb: ink, redactStyle: redactStyle,
                                    style: MarkStyle(displayScale: 0.5))
            draft.update(to: CGPoint(x: 200, y: 160))
            draft.update(to: end)
            XCTAssertEqual(draft.mark(), expected)
            XCTAssertEqual(draft.mark(preview: true), expected)
        }
    }

    func testPenDraftRetainsIntermediatePointsWhenReturningToItsStart() {
        let start = CGPoint(x: 100, y: 80)
        let middle = CGPoint(x: 200, y: 160)
        let reversed = CGPoint(x: 10, y: 20)
        var draft = MarkupDraft(tool: .pen, start: start, inkArgb: markupInkColors[1], redactStyle: .blur,
                                style: MarkStyle(displayScale: 0.5))
        draft.update(to: middle)
        draft.update(to: reversed)
        draft.update(to: start)
        let expected = MarkupMark.pen(points: [start, middle, reversed, start], colorArgb: markupInkColors[1], strokeWidthPx: 8)
        XCTAssertEqual(draft.mark(), expected)
        XCTAssertEqual(draft.mark(preview: true), expected)
    }

    func testBlurDraftPreviewsBeforeThresholdAndIncludesFinalGesturePosition() throws {
        var draft = blurDraft(start: CGPoint(x: 10, y: 10))
        XCTAssertNil(draft.mark(preview: true), "A tap has no stroke preview")
        draft.update(to: CGPoint(x: 12, y: 10))
        XCTAssertNotNil(draft.mark(preview: true), "Drawing must provide live feedback before committing")
        XCTAssertNil(draft.mark())

        draft.update(to: CGPoint(x: 30, y: 10))
        let mark = try XCTUnwrap(draft.mark())
        guard case let .blur(points, _) = mark else { return XCTFail("expected a blur stroke") }
        XCTAssertEqual(points, [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 10), CGPoint(x: 30, y: 10)])
    }

    func testBlurDraftKeepsCreationWidthAsImageDisplaySizeChanges() throws {
        let imageSize = CGSize(width: 200, height: 200)
        let initialFitted = fittedImageRect(imageSize: imageSize, boundsSize: CGSize(width: 100, height: 100))
        var draft = blurDraft(start: CGPoint(x: 20, y: 20), displayScale: initialFitted.width / imageSize.width)
        draft.update(to: CGPoint(x: 80, y: 20))
        let relaidFitted = fittedImageRect(imageSize: imageSize, boundsSize: CGSize(width: 200, height: 200))
        draft.update(to: imagePoint(fromDisplay: CGPoint(x: 100, y: 20), fittedRect: relaidFitted, imageSize: imageSize))

        guard case let .blur(points, width)? = draft.mark() else { return XCTFail("expected a blur stroke") }
        XCTAssertEqual(width, 64)
        XCTAssertEqual(try XCTUnwrap(points.last), CGPoint(x: 100, y: 20))
        XCTAssertEqual(draft.mark(preview: true), draft.mark())
    }

    func testBlurDraftIgnoresDuplicateSamplesAndNewGestureStartsFresh() {
        var first = blurDraft(start: CGPoint(x: 10, y: 10))
        first.update(to: CGPoint(x: 40, y: 10))
        first.update(to: CGPoint(x: 40, y: 10))
        XCTAssertEqual(first.points.count, 2)

        var second = blurDraft(start: CGPoint(x: 100, y: 100))
        second.update(to: CGPoint(x: 140, y: 100))
        guard case let .blur(points, _)? = second.mark() else { return XCTFail("expected a second stroke") }
        XCTAssertEqual(points, [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 100)])
    }

    private func blurDraft(start: CGPoint, displayScale: CGFloat = 1) -> MarkupDraft {
        MarkupDraft(tool: .redact, start: start, inkArgb: markupInkColors[0], redactStyle: .blur,
                    style: MarkStyle(displayScale: displayScale))
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

        let redact = MarkupMark.solidRedact(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        guard case let .solidRedact(redactRect) = scaledMark(redact, sx: 4, sy: 4) else {
            return XCTFail("expected a redact mark")
        }
        XCTAssertEqual(redactRect, CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    func testScaledBlurKeepsPathAndWidthAlignedWithTheImage() {
        let blur = MarkupMark.blur(points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)], strokeWidthPx: 32)
        guard case let .blur(points, width) = scaledMark(blur, sx: 2, sy: 3) else {
            return XCTFail("expected a blur stroke")
        }
        XCTAssertEqual(points, [CGPoint(x: 20, y: 60), CGPoint(x: 60, y: 120)])
        XCTAssertEqual(width, 64)
    }
}
