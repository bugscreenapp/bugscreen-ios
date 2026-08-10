import CoreGraphics
import UIKit

/// Bitmap side of the markup editor (CAP-016): building the pixelated copy used
/// for blur redaction and replaying marks destructively onto a full-resolution
/// copy of the attachment. Mirrors the Android SDK's `MarkupFlattener` — keep
/// behaviour in sync.
///
/// Everything renders at the image's PIXEL size (`size × scale`) with a
/// format scale of 1, so mark coordinates (image pixels) map 1:1 and the
/// output is deterministic and unit-testable.
enum MarkupRenderer {
    /// Deterministic mosaic: bilinear downscale to `cellsLongEdge` cells along
    /// the long edge, then nearest-neighbour upscale back. Pure resampling —
    /// no GPU blur — so the live preview, the flatten, and unit tests agree.
    static func pixelated(_ image: UIImage, cellsLongEdge: Int = redactCellsLongEdge) -> UIImage {
        let pixelSize = pixelSize(of: image)
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > 0 else { return image }

        let scale = CGFloat(cellsLongEdge) / longEdge
        let smallSize = CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded())
        )

        let small = renderer(size: smallSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: smallSize))
        }
        return renderer(size: pixelSize).image { context in
            context.cgContext.interpolationQuality = .none
            small.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Replays `marks` (image-pixel coordinates) onto a copy of `image`.
    /// Redaction is destructive by construction: blur rects copy in pixelated
    /// pixels, solid rects overwrite with an opaque fill.
    static func flatten(image: UIImage, marks: [MarkupMark], pixelated: UIImage) -> UIImage {
        let pixelSize = pixelSize(of: image)
        return renderer(size: pixelSize).image { context in
            let cg = context.cgContext
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
            for mark in marks {
                draw(mark, in: cg, pixelated: pixelated, pixelSize: pixelSize)
            }
        }
    }

    // MARK: - Private

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private static func renderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func draw(_ mark: MarkupMark, in cg: CGContext, pixelated: UIImage, pixelSize: CGSize) {
        switch mark {
        case let .box(rect, colorArgb, strokeWidthPx, cornerRadiusPx):
            strokePath(in: cg, color: colorArgb, width: strokeWidthPx) {
                cg.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: cornerRadiusPx,
                    cornerHeight: cornerRadiusPx,
                    transform: nil
                ))
            }
        case let .arrow(start, end, colorArgb, strokeWidthPx, headLengthPx):
            strokePath(in: cg, color: colorArgb, width: strokeWidthPx) {
                cg.move(to: start)
                cg.addLine(to: end)
            }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let spread = CGFloat(markupArrowHeadSpreadDegrees * .pi / 180)
            for headAngle in [angle - spread, angle + spread] {
                strokePath(in: cg, color: colorArgb, width: strokeWidthPx) {
                    cg.move(to: end)
                    cg.addLine(to: CGPoint(
                        x: end.x - headLengthPx * cos(headAngle),
                        y: end.y - headLengthPx * sin(headAngle)
                    ))
                }
            }
        case let .pen(points, colorArgb, strokeWidthPx):
            guard points.count >= 2 else { return }
            strokePath(in: cg, color: colorArgb, width: strokeWidthPx) {
                cg.move(to: points[0])
                for point in points.dropFirst() {
                    cg.addLine(to: point)
                }
            }
        case let .redact(rect, style):
            switch style {
            case .solid:
                cg.setFillColor(uiColor(redactSolidColor).cgColor)
                cg.fill(rect)
            case .blur:
                cg.saveGState()
                cg.clip(to: rect)
                pixelated.draw(in: CGRect(origin: .zero, size: pixelSize))
                cg.restoreGState()
            }
        }
    }

    private static func strokePath(in cg: CGContext, color: UInt32, width: CGFloat, build: () -> Void) {
        cg.setStrokeColor(uiColor(color).cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        build()
        cg.strokePath()
    }

    private static func uiColor(_ argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}
