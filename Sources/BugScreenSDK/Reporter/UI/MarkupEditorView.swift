import SwiftUI
import UIKit

/// Full-screen markup editor (CAP-016). Opened from the attachment preview; on
/// Done it flattens the drawn marks destructively into the attachment and hands
/// back a new `UIImage`. Cancel discards. Mirrors the Android SDK's
/// `MarkupEditor` — keep behaviour in sync.
///
/// Marks are stored in the image's PIXEL space (`size × scale`), which is also
/// the space `MarkupRenderer.flatten` renders in — so a mark lands exactly
/// where it was drawn with no rescale.
struct MarkupEditorView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    @State private var tool: MarkupTool = .pen
    @State private var inkArgb = markupInkColors[0]
    @State private var redactStyle: RedactStyle = .blur
    @State private var marks: [MarkupMark] = []
    @State private var pixelated: UIImage?
    @State private var isSaving = false

    // In-progress drag, in image-pixel space (converted on the fly).
    @State private var draftStart: CGPoint?
    @State private var draftCurrent: CGPoint?
    @State private var penPoints: [CGPoint] = []

    private var imageSize: CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.13, green: 0.118, blue: 0.094),
                    Color(red: 0.055, green: 0.051, blue: 0.039),
                ],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 900
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome
                stage
                dock
            }
        }
        .task {
            let source = image
            pixelated = await Task.detached { MarkupRenderer.pixelated(source) }.value
        }
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        ZStack {
            Text(SDKStrings.markupTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            HStack {
                Button(action: onCancel) {
                    Text(SDKStrings.markupCancel)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 8) {
                    undoButton
                    doneButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var undoButton: some View {
        Button(action: undo) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(marks.isEmpty ? 0.35 : 1))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(marks.isEmpty || isSaving)
        .accessibilityLabel(SDKStrings.markupUndo)
    }

    private var doneButton: some View {
        Button(action: save) {
            ZStack {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text(SDKStrings.markupDone)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 66, height: 38)
            .background(markupAccent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            let fitted = fittedImageRect(imageSize: imageSize, boundsSize: geo.size)
            let dispScale = fitted.width > 0 ? fitted.width / imageSize.width : 0
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()

                Canvas { context, _ in
                    for mark in marks {
                        drawMark(mark, into: &context, fitted: fitted, dispScale: dispScale)
                    }
                    if let draft = draftMark(dispScale: dispScale) {
                        drawMark(draft, into: &context, fitted: fitted, dispScale: dispScale)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(fitted: fitted, dispScale: dispScale))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func dragGesture(fitted: CGRect, dispScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard dispScale > 0 else { return }
                let current = imagePoint(fromDisplay: value.location, fittedRect: fitted, imageSize: imageSize)
                if draftStart == nil {
                    let start = imagePoint(fromDisplay: value.startLocation, fittedRect: fitted, imageSize: imageSize)
                    draftStart = start
                    penPoints = [start]
                }
                draftCurrent = current
                if tool == .pen {
                    penPoints.append(current)
                }
            }
            .onEnded { _ in
                if let start = draftStart, let end = draftCurrent, dispScale > 0,
                   let mark = markFromDrag(
                       tool: tool,
                       start: start,
                       end: end,
                       points: penPoints,
                       inkArgb: inkArgb,
                       redactStyle: redactStyle,
                       style: markStyle(dispScale: dispScale)
                   )
                {
                    marks.append(mark)
                }
                resetDraft()
            }
    }

    // MARK: - Dock

    private var dock: some View {
        VStack(spacing: 14) {
            palette
            toolRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var palette: some View {
        Group {
            if tool == .redact {
                HStack(spacing: 10) {
                    redactChip(SDKStrings.markupRedactBlur, active: redactStyle == .blur) { redactStyle = .blur }
                    redactChip(SDKStrings.markupRedactSolid, active: redactStyle == .solid) { redactStyle = .solid }
                }
            } else {
                HStack(spacing: 14) {
                    ForEach(markupInkColors, id: \.self) { color in
                        inkSwatch(color)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
        .clipShape(Capsule())
    }

    private func inkSwatch(_ color: UInt32) -> some View {
        let selected = color == inkArgb
        return Circle()
            .fill(Color(argb: color))
            .frame(width: 28, height: 28)
            .overlay(
                Circle().strokeBorder(
                    selected ? Color.white : Color.white.opacity(0.35),
                    lineWidth: selected ? 3 : 1
                )
            )
            .onTapGesture { inkArgb = color }
            .accessibilityLabel(SDKStrings.markupInk)
    }

    private func redactChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(active ? 1 : 0.7))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(active ? markupAccent : Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            toolButton(.pen, symbol: "scribble", label: SDKStrings.markupToolPen)
            toolButton(.arrow, symbol: "arrow.up.right", label: SDKStrings.markupToolArrow)
            toolButton(.box, symbol: "rectangle", label: SDKStrings.markupToolBox)
            toolButton(.redact, symbol: "eye.slash", label: SDKStrings.markupToolRedact)
        }
    }

    private func toolButton(_ target: MarkupTool, symbol: String, label: String) -> some View {
        let selected = tool == target
        return Button {
            tool = target
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(selected ? .white : .white.opacity(0.55))
                Capsule()
                    .fill(selected ? Color(argb: inkArgb) : Color.clear)
                    .frame(width: 20, height: 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Drawing

    private func drawMark(_ mark: MarkupMark, into context: inout GraphicsContext, fitted: CGRect, dispScale: CGFloat) {
        switch mark {
        case let .box(rect, colorArgb, strokeWidthPx, cornerRadiusPx):
            let displayRect = displayRect(rect, fitted: fitted)
            let path = Path(roundedRect: displayRect, cornerRadius: cornerRadiusPx * dispScale)
            context.stroke(path, with: .color(Color(argb: colorArgb)), style: strokeStyle(strokeWidthPx * dispScale))
        case let .arrow(start, end, colorArgb, strokeWidthPx, headLengthPx):
            let displayStart = displayPoint(fromImage: start, fittedRect: fitted, imageSize: imageSize)
            let displayEnd = displayPoint(fromImage: end, fittedRect: fitted, imageSize: imageSize)
            let color = Color(argb: colorArgb)
            let style = strokeStyle(strokeWidthPx * dispScale)
            var line = Path()
            line.move(to: displayStart)
            line.addLine(to: displayEnd)
            context.stroke(line, with: .color(color), style: style)

            let angle = atan2(displayEnd.y - displayStart.y, displayEnd.x - displayStart.x)
            let spread = CGFloat(markupArrowHeadSpreadDegrees * .pi / 180)
            let headLen = headLengthPx * dispScale
            for headAngle in [angle - spread, angle + spread] {
                var head = Path()
                head.move(to: displayEnd)
                head.addLine(to: CGPoint(
                    x: displayEnd.x - headLen * cos(headAngle),
                    y: displayEnd.y - headLen * sin(headAngle)
                ))
                context.stroke(head, with: .color(color), style: style)
            }
        case let .pen(points, colorArgb, strokeWidthPx):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: displayPoint(fromImage: points[0], fittedRect: fitted, imageSize: imageSize))
            for point in points.dropFirst() {
                path.addLine(to: displayPoint(fromImage: point, fittedRect: fitted, imageSize: imageSize))
            }
            context.stroke(path, with: .color(Color(argb: colorArgb)), style: strokeStyle(strokeWidthPx * dispScale))
        case let .redact(rect, style):
            let displayRect = displayRect(rect, fitted: fitted)
            switch style {
            case .solid:
                context.fill(Path(displayRect), with: .color(Color(argb: redactSolidColor)))
            case .blur:
                guard let pixelated else { return }
                var layer = context
                layer.clip(to: Path(displayRect))
                layer.draw(Image(uiImage: pixelated), in: fitted)
            }
        }
    }

    private func displayRect(_ rect: CGRect, fitted: CGRect) -> CGRect {
        let topLeft = displayPoint(fromImage: CGPoint(x: rect.minX, y: rect.minY), fittedRect: fitted, imageSize: imageSize)
        let bottomRight = displayPoint(
            fromImage: CGPoint(x: rect.maxX, y: rect.maxY),
            fittedRect: fitted,
            imageSize: imageSize
        )
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    private func strokeStyle(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    // MARK: - State helpers

    private func markStyle(dispScale: CGFloat, minDragOverride: CGFloat? = nil) -> MarkStyle {
        MarkStyle(
            strokeWidthPx: markStrokeWidthPt / dispScale,
            minDragPx: (minDragOverride ?? minDragPt) / dispScale,
            cornerRadiusPx: boxCornerRadiusPt / dispScale,
            arrowHeadLengthPx: arrowHeadLengthPt / dispScale
        )
    }

    private func draftMark(dispScale: CGFloat) -> MarkupMark? {
        guard let start = draftStart, let end = draftCurrent, dispScale > 0 else { return nil }
        return markFromDrag(
            tool: tool,
            start: start,
            end: end,
            points: penPoints,
            inkArgb: inkArgb,
            redactStyle: redactStyle,
            style: markStyle(dispScale: dispScale, minDragOverride: 0)
        )
    }

    private func resetDraft() {
        draftStart = nil
        draftCurrent = nil
        penPoints = []
    }

    private func undo() {
        guard !marks.isEmpty else { return }
        marks.removeLast()
    }

    private func save() {
        guard !marks.isEmpty else {
            onCancel()
            return
        }
        isSaving = true
        let source = image
        let snapshot = marks
        // Reuse the pixelated copy the `.task` already built for the live blur
        // preview — same full-pixel source, so recomputing it would be wasted
        // work. Fall back only if a save races the initial render.
        let readyPixelated = pixelated
        Task.detached {
            let pixelated = readyPixelated ?? MarkupRenderer.pixelated(source)
            let flattened = MarkupRenderer.flatten(image: source, marks: snapshot, pixelated: pixelated)
            await MainActor.run { onSave(flattened) }
        }
    }
}

private let markupAccent = Color(red: 0.204, green: 0.71, blue: 0.541)

private extension Color {
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}
