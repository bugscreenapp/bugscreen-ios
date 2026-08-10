import CoreGraphics
import Foundation

// Markup model + pure geometry for the screenshot markup editor (CAP-016).
//
// Mirrors the Android SDK's `MarkupGeometry.kt` — keep behaviour and names in
// sync (same house pattern as `nextPreviewIndex`).
//
// All mark coordinates are stored in IMAGE-PIXEL space, not display space:
// drags are converted display→image as they happen, and rendering converts
// image→display each frame. That makes flattening a pure function of
// `(image, marks)` and keeps marks glued to image features across relayout
// and rotation.

/// Declaration order is the tool dock's left-to-right order; the first case is the
/// default tool. Nothing persists or serialises the order, so this is safe to reorder.
enum MarkupTool: CaseIterable {
    case pen, arrow, box, redact
}

enum RedactStyle {
    case blur, solid
}

enum MarkupMark: Equatable {
    case box(rect: CGRect, colorArgb: UInt32, strokeWidthPx: CGFloat, cornerRadiusPx: CGFloat)
    case arrow(start: CGPoint, end: CGPoint, colorArgb: UInt32, strokeWidthPx: CGFloat, headLengthPx: CGFloat)
    case pen(points: [CGPoint], colorArgb: UInt32, strokeWidthPx: CGFloat)
    case redact(rect: CGRect, style: RedactStyle)
}

/// Creation-time geometry for a new mark, all in image pixels. Bundled so the
/// drag → mark builder stays within a sane parameter count. Mirrors the
/// Android SDK's `MarkStyle`.
struct MarkStyle {
    let strokeWidthPx: CGFloat
    let minDragPx: CGFloat
    let cornerRadiusPx: CGFloat
    let arrowHeadLengthPx: CGFloat
}

// MARK: - Constants (mirrored with Android)

/// Spec-fixed ink palette (CAP-016); first entry is the default.
let markupInkColors: [UInt32] = [0xFFF0_412E, 0xFF17_B67F, 0xFFF0_B96B, 0xFF3D_7BFF, 0xFFFF_FFFF]

let redactSolidColor: UInt32 = 0xFF0F_0F0F

/// Pixelation cell count along the image's long edge. Relative-to-long-edge
/// sizing keeps the display-resolution live preview and the native-resolution
/// flatten visually identical.
let redactCellsLongEdge = 40

let markStrokeWidthPt: CGFloat = 4
let arrowHeadLengthPt: CGFloat = 14
let boxCornerRadiusPt: CGFloat = 6
let minDragPt: CGFloat = 8

/// Half-angle each arrowhead barb opens from the shaft. Shared by the live
/// preview and the flatten pass so the drawn arrow and the saved arrow match.
let markupArrowHeadSpreadDegrees = 28.0

// MARK: - Pure geometry

/// Aspect-fit rect of an image inside `boundsSize`, centered with letterbox /
/// pillarbox bars as needed. Zero for degenerate inputs so callers can skip
/// drawing rather than divide by zero.
func fittedImageRect(imageSize: CGSize, boundsSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          boundsSize.width > 0, boundsSize.height > 0
    else {
        return .zero
    }
    let scale = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
    let fittedWidth = imageSize.width * scale
    let fittedHeight = imageSize.height * scale
    let left = (boundsSize.width - fittedWidth) / 2
    let top = (boundsSize.height - fittedHeight) / 2
    return CGRect(x: left, y: top, width: fittedWidth, height: fittedHeight)
}

/// Display-space point → image-pixel point, clamped to the image bounds so a
/// drag that leaves the image edge pins to the edge instead of spilling out.
func imagePoint(fromDisplay point: CGPoint, fittedRect: CGRect, imageSize: CGSize) -> CGPoint {
    guard fittedRect.width > 0, fittedRect.height > 0 else { return .zero }
    let x = (point.x - fittedRect.minX) / fittedRect.width * imageSize.width
    let y = (point.y - fittedRect.minY) / fittedRect.height * imageSize.height
    return CGPoint(
        x: min(max(x, 0), imageSize.width),
        y: min(max(y, 0), imageSize.height)
    )
}

func displayPoint(fromImage point: CGPoint, fittedRect: CGRect, imageSize: CGSize) -> CGPoint {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    return CGPoint(
        x: fittedRect.minX + point.x / imageSize.width * fittedRect.width,
        y: fittedRect.minY + point.y / imageSize.height * fittedRect.height
    )
}

/// Order-independent rect from two drag corners, valid for all four drag
/// directions.
func normalizedRect(_ start: CGPoint, _ end: CGPoint) -> CGRect {
    CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
    )
}

/// Builds the mark a completed drag produces, or nil when the gesture was a
/// tap / near-zero drag (the "tap creates no mark" acceptance criterion).
/// Box/Arrow/Redact gate on start→end displacement; Pen gates on total path
/// length so a tight scribble with small displacement still counts.
func markFromDrag(
    tool: MarkupTool,
    start: CGPoint,
    end: CGPoint,
    points: [CGPoint],
    inkArgb: UInt32,
    redactStyle: RedactStyle,
    style: MarkStyle
) -> MarkupMark? {
    switch tool {
    case .pen:
        guard points.count >= 2, pathLength(points) >= style.minDragPx else { return nil }
        return .pen(points: points, colorArgb: inkArgb, strokeWidthPx: style.strokeWidthPx)
    case .arrow:
        guard distance(start, end) >= style.minDragPx else { return nil }
        return .arrow(
            start: start,
            end: end,
            colorArgb: inkArgb,
            strokeWidthPx: style.strokeWidthPx,
            headLengthPx: style.arrowHeadLengthPx
        )
    case .box:
        guard distance(start, end) >= style.minDragPx else { return nil }
        return .box(
            rect: normalizedRect(start, end),
            colorArgb: inkArgb,
            strokeWidthPx: style.strokeWidthPx,
            cornerRadiusPx: style.cornerRadiusPx
        )
    case .redact:
        guard distance(start, end) >= style.minDragPx else { return nil }
        return .redact(rect: normalizedRect(start, end), style: redactStyle)
    }
}

/// Rescales a mark between two pixel spaces (the editor draws on a sampled
/// display image; flattening replays onto the full-resolution image).
/// Stroke-derived dimensions scale by `sx` — sampling preserves aspect ratio,
/// so `sx` and `sy` only differ by sub-pixel rounding.
func scaledMark(_ mark: MarkupMark, sx: CGFloat, sy: CGFloat) -> MarkupMark {
    switch mark {
    case let .box(rect, colorArgb, strokeWidthPx, cornerRadiusPx):
        .box(
            rect: scaledRect(rect, sx: sx, sy: sy),
            colorArgb: colorArgb,
            strokeWidthPx: strokeWidthPx * sx,
            cornerRadiusPx: cornerRadiusPx * sx
        )
    case let .arrow(start, end, colorArgb, strokeWidthPx, headLengthPx):
        .arrow(
            start: CGPoint(x: start.x * sx, y: start.y * sy),
            end: CGPoint(x: end.x * sx, y: end.y * sy),
            colorArgb: colorArgb,
            strokeWidthPx: strokeWidthPx * sx,
            headLengthPx: headLengthPx * sx
        )
    case let .pen(points, colorArgb, strokeWidthPx):
        .pen(
            points: points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) },
            colorArgb: colorArgb,
            strokeWidthPx: strokeWidthPx * sx
        )
    case let .redact(rect, style):
        .redact(rect: scaledRect(rect, sx: sx, sy: sy), style: style)
    }
}

private func scaledRect(_ rect: CGRect, sx: CGFloat, sy: CGFloat) -> CGRect {
    CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    (a - b).length
}

private func pathLength(_ points: [CGPoint]) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    var length: CGFloat = 0
    for i in 1 ..< points.count {
        length += (points[i] - points[i - 1]).length
    }
    return length
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    var length: CGFloat {
        (x * x + y * y).squareRoot()
    }
}
