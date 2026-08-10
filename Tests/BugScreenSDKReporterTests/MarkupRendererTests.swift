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
        let marks: [MarkupMark] = [.redact(rect: CGRect(x: 0, y: 0, width: 20, height: 40), style: .solid)]
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

    func testBlurRedactChangesCoveredPixels() {
        // A black/white split with the boundary inside a mosaic cell guarantees
        // the pixelation averages across the edge, so covered pixels change.
        let image = splitImage(sizePx: 200, boundaryX: 101)
        let original = rawBytes(image)
        let marks: [MarkupMark] = [.redact(rect: CGRect(x: 0, y: 0, width: 200, height: 200), style: .blur)]
        let flattened = MarkupRenderer.flatten(image: image, marks: marks, pixelated: MarkupRenderer.pixelated(image))
        XCTAssertNotEqual(rawBytes(flattened), original)
    }

    // MARK: - Helpers

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
