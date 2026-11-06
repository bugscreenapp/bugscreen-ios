@testable import BugScreenSDK
import UIKit
import XCTest

/// Pixel-level tests for the destructive markup flatten. Mirrors the intent of
/// Android's `MarkupFlattenerTest` (Robolectric): real pixel ops, deterministic
/// redaction, correct output dimensions.
final class MarkupRendererTests: XCTestCase {
    func testFlattenPreservesPixelSizeForScaledInput() {
        // 10×20 points at scale 3 → 30×60 device pixels; the flattened output
        // is those pixels at scale 1.
        let image = solidImage(widthPt: 10, heightPt: 20, scale: 3, color: .red)
        let flattened = MarkupRenderer.flatten(image: image, marks: [], pixelated: MarkupRenderer.pixelated(image))
        XCTAssertEqual(flattened.size, CGSize(width: 30, height: 60))
        XCTAssertEqual(flattened.scale, 1)
    }

    func testSolidRedactOverwritesInsideRectOnly() {
        let image = solidImage(widthPt: 40, heightPt: 40, scale: 1, color: .red)
        let marks: [MarkupMark] = [.solidRedact(rect: CGRect(x: 0, y: 0, width: 20, height: 40))]
        let flattened = MarkupRenderer.flatten(image: image, marks: marks, pixelated: MarkupRenderer.pixelated(image))

        let inside = pixel(flattened, x: 10, y: 20)
        let outside = pixel(flattened, x: 30, y: 20)
        // redactSolidColor is 0xFF0F0F0F.
        XCTAssertEqual(Int(inside.r), 15, accuracy: 2)
        XCTAssertEqual(Int(inside.g), 15, accuracy: 2)
        XCTAssertEqual(Int(inside.b), 15, accuracy: 2)
        XCTAssertEqual(Int(outside.r), 255, accuracy: 2)
        XCTAssertEqual(Int(outside.g), 0, accuracy: 2)
        XCTAssertEqual(Int(outside.b), 0, accuracy: 2)
    }

    func testPixelationIsDeterministic() {
        let image = splitImage(sizePx: 200, boundaryX: 101)
        let first = rawBytes(MarkupRenderer.pixelated(image))
        let second = rawBytes(MarkupRenderer.pixelated(image))
        XCTAssertEqual(first, second)
    }

    func testBlurReplacesCoveredPixelsWithTheExistingPixelationStrength() {
        let image = splitImage(sizePx: 200, boundaryX: 101)
        let pixelated = MarkupRenderer.pixelated(image)
        let mark = MarkupMark.blur(points: [CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 180)], strokeWidthPx: 32)
        let flattened = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: pixelated)
        assertCopiedPixel(flattened, from: pixelated, replacing: image, x: 100, y: 100)
    }

    func testBlurFollowsBentPathWithRoundCapsAndJoinsWithoutFillingBoundingRectangle() {
        let image = stripedImage()
        // One mosaic cell makes every stripe differ, isolating coverage from resampling.
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let mark = MarkupMark.blur(
            points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 40), CGPoint(x: 140, y: 140)],
            strokeWidthPx: 32
        )
        let flattened = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: pixelated)

        for point in [(90, 40), (140, 90), (148, 32), (29, 40), (140, 151)] {
            assertCopiedPixel(flattened, from: pixelated, replacing: image, x: point.0, y: point.1)
        }
        for point in [(90, 90), (23, 40), (27, 27), (153, 153)] {
            XCTAssertEqual(pixelBytes(flattened, x: point.0, y: point.1), pixelBytes(image, x: point.0, y: point.1))
        }
    }

    func testBlurConnectsSparseFingerSamplesContinuously() {
        let image = stripedImage()
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let mark = MarkupMark.blur(points: [CGPoint(x: 30, y: 30), CGPoint(x: 170, y: 170)], strokeWidthPx: 32)
        let flattened = MarkupRenderer.flatten(image: image, marks: [mark], pixelated: pixelated)
        for coordinate in stride(from: 30, through: 170, by: 10) {
            assertCopiedPixel(flattened, from: pixelated, replacing: image, x: coordinate, y: coordinate)
        }
        XCTAssertEqual(pixelBytes(flattened, x: 40, y: 150), pixelBytes(image, x: 40, y: 150))
    }

    func testBlurLoopAndDoubleBackDoNotLeaveHolesOrFillTheLoopInterior() {
        let image = stripedImage()
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let points = [
            CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 160, y: 160),
            CGPoint(x: 40, y: 160), CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 40, y: 40),
        ]
        let flattened = MarkupRenderer.flatten(image: image, marks: [.blur(points: points, strokeWidthPx: 32)], pixelated: pixelated)
        for point in [(40, 100), (100, 40), (160, 100), (100, 160), (40, 40)] {
            assertCopiedPixel(flattened, from: pixelated, replacing: image, x: point.0, y: point.1)
        }
        XCTAssertEqual(pixelBytes(flattened, x: 100, y: 100), pixelBytes(image, x: 100, y: 100))
    }

    func testBlurAtImageEdgesClipsCoverageToNativeImageBounds() {
        let image = stripedImage()
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let points = [CGPoint.zero, CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200), .zero]
        let flattened = MarkupRenderer.flatten(image: image, marks: [.blur(points: points, strokeWidthPx: 32)], pixelated: pixelated)

        XCTAssertEqual(flattened.size, image.size)
        for point in [(0, 100), (199, 100), (100, 0), (100, 199)] {
            assertCopiedPixel(flattened, from: pixelated, replacing: image, x: point.0, y: point.1)
        }
        XCTAssertEqual(pixelBytes(flattened, x: 100, y: 100), pixelBytes(image, x: 100, y: 100))
    }

    func testRepeatedBlurIsPixelIdenticalIncludingTranslucentImageAndStrokeEdges() {
        for alpha in [CGFloat(1), CGFloat(0.5)] {
            let image = stripedImage(alpha: alpha)
            let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
            let stroke = MarkupMark.blur(
                points: [CGPoint(x: 30, y: 30), CGPoint(x: 170, y: 170), CGPoint(x: 30, y: 30)],
                strokeWidthPx: 32
            )
            let once = MarkupRenderer.flatten(image: image, marks: [stroke], pixelated: pixelated)
            let twice = MarkupRenderer.flatten(image: image, marks: [stroke, stroke], pixelated: pixelated)

            XCTAssertEqual(rawBytes(once), rawBytes(twice), "Repeated coverage must replace pixels, never accumulate blending")
            assertCopiedPixel(once, from: pixelated, replacing: image, x: 100, y: 100)
            assertPixelsAreEitherSourceOrMosaic(once, source: image, pixelated: pixelated)
        }
    }

    func testCrossingBlurStrokesReuseOriginalPixelation() {
        let image = stripedImage()
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let strokes: [MarkupMark] = [
            .blur(points: [CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 100)], strokeWidthPx: 32),
            .blur(points: [CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 180)], strokeWidthPx: 32),
        ]
        let flattened = MarkupRenderer.flatten(image: image, marks: strokes, pixelated: pixelated)
        assertCopiedPixel(flattened, from: pixelated, replacing: image, x: 100, y: 100)
        XCTAssertEqual(pixelBytes(flattened, x: 40, y: 40), pixelBytes(image, x: 40, y: 40))
    }

    func testBlurUsesNativePixelsForScaledUIImage() throws {
        let source = stripedImage()
        let image = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 2, orientation: .up)
        let pixelated = MarkupRenderer.pixelated(image, cellsLongEdge: 1)
        let stroke = MarkupMark.blur(points: [CGPoint(x: 40, y: 100), CGPoint(x: 160, y: 100)], strokeWidthPx: 32)
        let flattened = MarkupRenderer.flatten(image: image, marks: [stroke], pixelated: pixelated)

        XCTAssertEqual(flattened.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(flattened.scale, 1)
        assertCopiedPixel(flattened, from: pixelated, replacing: image, x: 100, y: 85)
        XCTAssertEqual(pixelBytes(flattened, x: 100, y: 82), pixelBytes(image, x: 100, y: 82))
    }

    // MARK: - Helpers

    private func stripedImage(alpha: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { context in
            for x in 0 ..< 200 {
                (x.isMultiple(of: 2) ? UIColor.black : UIColor.white).withAlphaComponent(alpha).setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: 200))
            }
        }
    }

    private func assertCopiedPixel(_ image: UIImage, from pixelated: UIImage, replacing source: UIImage,
                                   x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line)
    {
        XCTAssertEqual(pixelBytes(image, x: x, y: y), pixelBytes(pixelated, x: x, y: y), file: file, line: line)
        XCTAssertNotEqual(pixelBytes(image, x: x, y: y), pixelBytes(source, x: x, y: y), file: file, line: line)
    }

    private func assertPixelsAreEitherSourceOrMosaic(_ image: UIImage, source: UIImage, pixelated: UIImage,
                                                     file: StaticString = #filePath, line: UInt = #line)
    {
        let actual = rawBytes(image)
        let original = rawBytes(source)
        let mosaic = rawBytes(pixelated)
        for index in stride(from: 0, to: actual.count, by: 4) {
            let pixel = actual[index ..< index + 4]
            if pixel != original[index ..< index + 4], pixel != mosaic[index ..< index + 4] {
                return XCTFail("Blur mixed original pixels into its coverage at byte \(index)", file: file, line: line)
            }
        }
    }

    private func pixelBytes(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        let bytes = rawBytes(image)
        let width = Int(image.size.width * image.scale)
        let index = (y * width + x) * 4
        return Array(bytes[index ..< index + 4])
    }

    private func solidImage(widthPt: Int, heightPt: Int, scale: CGFloat, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: widthPt, height: heightPt), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: widthPt, height: heightPt))
        }
    }

    private func splitImage(sizePx: Int, boundaryX: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: sizePx, height: sizePx), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: boundaryX, height: sizePx))
            UIColor.white.setFill()
            context.fill(CGRect(x: boundaryX, y: 0, width: sizePx - boundaryX, height: sizePx))
        }
    }

    private func rawBytes(_ image: UIImage) -> [UInt8] {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard let cgImage = image.cgImage else { return [] }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let cgContext = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let bytes = rawBytes(image)
        let width = Int(image.size.width * image.scale)
        let index = (y * width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }
}

private func XCTAssertEqual(_ value: Int, _ expected: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(value - expected) <= accuracy, "\(value) not within \(accuracy) of \(expected)", file: file, line: line)
}
