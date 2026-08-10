import UIKit

/// The reporter tests' own image fixtures.
///
/// A deliberate small duplicate of the ones in `BugScreenSDKTests/Mocks`: SPM test targets
/// cannot share source without inventing a third target, and this is a handful of lines of
/// UIGraphicsImageRenderer. The SDK's copy also carries API-key and custom-data fixtures,
/// none of which the reporter has any use for.
enum TestHelpers {
    static func solidImage(
        width: Int = 4,
        height: Int = 4,
        color: UIColor = .red
    ) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Renders an image with a specific pixel size and scale, mimicking a real device
    /// screenshot (e.g. 1179×2556 px at scale 3) so the pixel-vs-point distinction bites.
    static func retinaImage(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> UIImage {
        let pointSize = CGSize(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        return renderer.image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(origin: .zero, size: pointSize))
        }
    }
}
