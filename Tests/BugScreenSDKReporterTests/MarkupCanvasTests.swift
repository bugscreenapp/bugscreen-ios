@testable import BugScreenSDK
import SwiftUI
import XCTest

@MainActor
final class MarkupCanvasTests: XCTestCase {
    func testBentBlurDraftAndCommittedCanvasMatchSavedPixelsIncludingTransparency() throws {
        let image = translucentStripes()
        let mosaic = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        var draft = MarkupDraft(tool: .redact, start: CGPoint(x: 40, y: 40), inkArgb: markupInkColors[0],
                                redactStyle: .blur, style: MarkStyle(displayScale: 1))
        draft.update(to: CGPoint(x: 140, y: 40))
        draft.update(to: CGPoint(x: 140, y: 140))
        let mark = try XCTUnwrap(draft.mark())
        let live = try preview(image: image, mosaic: mosaic, draft: draft.mark(preview: true))
        let committed = try preview(image: image, mosaic: mosaic, marks: [mark])
        let repeated = try preview(image: image, mosaic: mosaic, marks: [mark, mark])
        let saved = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: mosaic)

        XCTAssertEqual(bytes(live), bytes(committed), "Lifting the finger must retain the previewed coverage")
        XCTAssertEqual(bytes(committed), bytes(repeated), "Repeating Blur must not accumulate source blending")
        for point in [(90, 40), (140, 90), (148, 32), (29, 40), (140, 151)] {
            assertPixel(live, matches: saved, x: point.0, y: point.1)
            assertPixel(live, matches: mosaic, x: point.0, y: point.1)
            XCTAssertLessThanOrEqual(pixel(live, x: point.0, y: point.1)[3], 130,
                                     "Source-over blending would make the half-transparent image more opaque")
        }
        for point in [(90, 90), (23, 40), (27, 27), (153, 153)] {
            assertPixel(live, matches: image, x: point.0, y: point.1)
        }
    }

    func testLoopCanvasMatchesExportWithoutFillingItsCenterOrCancellingDoubleBacks() throws {
        let image = translucentStripes()
        let mosaic = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let mark = MarkupMark.blur(points: [
            CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 160, y: 160),
            CGPoint(x: 40, y: 160), CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 40, y: 40),
        ], strokeWidthPx: 32)
        let rendered = try preview(image: image, mosaic: mosaic, marks: [mark])
        let saved = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: mosaic)

        for point in [(40, 100), (100, 40), (160, 100), (100, 160), (30, 30)] {
            assertPixel(rendered, matches: saved, x: point.0, y: point.1)
            assertPixel(rendered, matches: mosaic, x: point.0, y: point.1)
        }
        assertPixel(rendered, matches: image, x: 100, y: 100)
    }

    func testCanvasClipsEdgeStrokeToFittedImageAfterDisplaySizeChanges() throws {
        let image = translucentStripes()
        let mosaic = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        var draft = MarkupDraft(tool: .redact, start: .zero, inkArgb: markupInkColors[0], redactStyle: .blur,
                                style: MarkStyle(displayScale: 0.5))
        draft.update(to: CGPoint(x: 0, y: 200))
        draft.update(to: CGPoint(x: 200, y: 200))
        let mark = try XCTUnwrap(draft.mark())
        let size = CGSize(width: 160, height: 120)
        let fitted = fittedImageRect(imageSize: image.size, boundsSize: size)
        let rendered = try preview(image: image, mosaic: mosaic, marks: [mark], size: size)
        let unmarked = try preview(image: image, mosaic: mosaic, size: size)
        let saved = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: mosaic)
        let expected = UIGraphicsImageRenderer(size: size, format: imageFormat()).image { _ in
            saved.draw(in: fitted)
        }

        for point in [(21, 60), (36, 60), (80, 118)] {
            assertPixel(rendered, matches: expected, x: point.0, y: point.1)
        }
        assertPixel(rendered, matches: unmarked, x: 44, y: 60)
        for point in [(0, 60), (19, 60), (140, 60), (159, 60)] {
            XCTAssertEqual(pixel(rendered, x: point.0, y: point.1)[3], 0, "Brush coverage must not enter the letterbox")
        }
    }

    private func preview(image: UIImage, mosaic: UIImage, marks: [MarkupMark] = [], draft: MarkupMark? = nil,
                         size: CGSize = CGSize(width: 200, height: 200)) throws -> UIImage
    {
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer requires iOS 16 or later") }
        let view = MarkupCanvas(image: image, pixelated: mosaic, marks: marks, draftMark: draft,
                                fitted: fittedImageRect(imageSize: image.size, boundsSize: size))
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = false
        renderer.colorMode = .nonLinear
        return try XCTUnwrap(renderer.uiImage, "Render the same Canvas used by the markup editor")
    }

    private func translucentStripes() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: imageFormat()).image { context in
            for x in 0 ..< 200 {
                (x.isMultiple(of: 2) ? UIColor.black : UIColor.white).withAlphaComponent(0.5).setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: 200))
            }
        }
    }

    private func imageFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return format
    }

    private func assertPixel(_ actual: UIImage, matches expected: UIImage, x: Int, y: Int,
                             file: StaticString = #filePath, line: UInt = #line)
    {
        let actualPixel = pixel(actual, x: x, y: y)
        let expectedPixel = pixel(expected, x: x, y: y)
        for channel in 0 ..< 4 {
            XCTAssertEqual(Double(actualPixel[channel]), Double(expectedPixel[channel]), accuracy: 2,
                           "Pixel (\(x), \(y)), channel \(channel)", file: file, line: line)
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        let data = bytes(image)
        let index = (y * Int(image.size.width * image.scale) + x) * 4
        return Array(data[index ..< index + 4])
    }

    private func bytes(_ image: UIImage) -> [UInt8] {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard let cgImage = image.cgImage else { return [] }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
}
