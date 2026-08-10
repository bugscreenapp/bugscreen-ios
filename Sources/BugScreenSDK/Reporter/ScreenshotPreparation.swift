import UIKit

/// An image that has been downscaled and re-encoded, ready for whatever transport is
/// going to upload it.
struct PreparedScreenshot: Sendable {
    let data: Data
    let contentType: String
    let fileExtension: String
}

/// Turns a picked image into something safe to upload.
///
/// This lives with the reporter rather than with `APIClient` because the API client is
/// exactly the layer a host replaces: the companion app brings its own transport, and
/// preparation left behind is size handling it silently loses (COMP-004, RFC-003 §2.2).
/// COMP-004 requires every shared image to be downscaled and re-encoded
/// **unconditionally** — the same treatment SDK screenshots get — not only when it
/// exceeds a limit.
///
/// On iOS it matters a second time: COMP-004 needs images downscaled *before they cross
/// the process boundary* out of the share extension, because a full-resolution photo held
/// in a 120 MiB-capped extension is exactly what that cap punishes. That is only possible
/// if preparation is reachable outside the transport.
enum ScreenshotPreparation {
    /// Long-edge cap in pixels, named for what it means at the reporter layer: the largest
    /// image the reporter will upload. Matches Android's `MAX_UPLOAD_LONG_EDGE_PX`. The
    /// server-side reasoning for the number lives in `docs/kb/ios-sdk.md`.
    static let maxUploadLongEdge: CGFloat = 2000

    /// Readable enough for body text on a phone screenshot, far smaller than PNG.
    static let jpegQuality: CGFloat = 0.85

    /// Downscales `image` so its long edge fits within ``maxUploadLongEdge`` and
    /// re-encodes as JPEG.
    ///
    /// Falls back to PNG if JPEG encoding genuinely fails, and returns `nil` only if both
    /// do. That fallback stays here with preparation rather than on the transport: split
    /// them and the quiet branch is one every future host has to reimplement, which is
    /// precisely where the size handling goes missing.
    static func prepare(_ image: UIImage) -> PreparedScreenshot? {
        let downscaled = downscale(image, longEdge: maxUploadLongEdge)
        if let jpeg = downscaled.jpegData(compressionQuality: jpegQuality) {
            return PreparedScreenshot(data: jpeg, contentType: "image/jpeg", fileExtension: "jpg")
        }
        if let png = downscaled.pngData() {
            return PreparedScreenshot(data: png, contentType: "image/png", fileExtension: "png")
        }
        return nil
    }

    /// Returns `image` unchanged if its pixel long edge is already within `longEdge`;
    /// otherwise renders a smaller bitmap whose pixel long edge equals `longEdge`.
    /// Compares pixel dimensions (`size × scale`), not points — a retina screenshot at
    /// 1179×2556 px / scale 3 reports a point size of 393×852 and would otherwise slip
    /// past the cap.
    private static func downscale(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let pointSize = image.size
        let scale = image.scale
        let pixelWidth = pointSize.width * scale
        let pixelHeight = pointSize.height * scale
        let maxPixelSide = max(pixelWidth, pixelHeight)
        guard maxPixelSide > longEdge, maxPixelSide > 0 else { return image }
        let ratio = longEdge / maxPixelSide
        let target = CGSize(
            width: floor(pixelWidth * ratio),
            height: floor(pixelHeight * ratio)
        )
        // Render at 1× so the target size we computed in pixels lands 1:1 in the output
        // bitmap — otherwise the renderer would multiply by the device scale and we'd
        // overshoot the cap.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
