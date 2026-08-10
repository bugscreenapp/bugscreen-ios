import PhotosUI
import SwiftUI
import UIKit

/// SwiftUI view for submitting bug reports.
///
/// Visual design mirrors the BugScreen brand tokens (cream/warm/ink + emerald
/// accent) shipped on Android in commit `ef54946`. The bottom-sheet behavior
/// (scrim, slide-in, drag-to-dismiss, detents, grabber) is owned by UIKit's
/// `UISheetPresentationController` configured on `BugReportHostingController`;
/// this view renders only the sheet's content.
struct BugReportView: View {
    @ObservedObject private var viewModel: BugReportViewModel

    /// Supplied by the host rather than read off a global: the companion app's branding
    /// answer comes from its own config call, not the SDK's (CAP-010).
    private let showBranding: Bool

    @State private var showPhotoPicker = false
    @State private var previewIndex: Int?
    @FocusState private var descriptionFocused: Bool

    init(viewModel: BugReportViewModel, showBranding: Bool = false) {
        self.showBranding = showBranding
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showBranding {
                        Image("BugScreenWordmark", bundle: BugScreenResources.bundle)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 26)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel("Reported with BugScreen")
                    }

                    Text("Report an issue")
                        .font(.system(size: 22, weight: .semibold))
                        .trackingCompat(-0.4)
                        .foregroundColor(Brand.ink)

                    DescriptionField(
                        text: $viewModel.description,
                        focused: $descriptionFocused,
                        enabled: viewModel.submissionState != .submitting
                    )
                    if let validation = viewModel.descriptionValidationMessage {
                        Text(validation)
                            .font(.system(size: 12))
                            .foregroundColor(Brand.dangerText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section(label: "Type") {
                        TypeChipRow(selection: $viewModel.bugType)
                    }

                    Section(label: "Severity") {
                        SeverityRow(selection: $viewModel.severity)
                    }

                    // The label carries the cap so the tester reads it before running into it,
                    // rather than discovering it when the Add tile disappears (CAP-004).
                    Section(label: "Attachments · \(viewModel.screenshots.count) of \(BugReportViewModel.maxScreenshots)") {
                        AttachmentRow(
                            screenshots: viewModel.screenshots,
                            canAddMore: viewModel.canAddMoreScreenshots,
                            enabled: viewModel.submissionState != .submitting,
                            onAdd: { showPhotoPicker = true },
                            onOpen: { previewIndex = $0 }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboardCompat()

            footer
        }
        .background(Brand.paper.ignoresSafeArea())
        .onChange(of: viewModel.description) { _ in
            if viewModel.descriptionValidationMessage != nil {
                viewModel.descriptionValidationMessage = nil
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerSheet(selectionLimit: max(1, viewModel.remainingScreenshotSlots)) { images in
                viewModel.addScreenshots(images)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { previewIndex != nil },
            set: { if !$0 { previewIndex = nil } }
        )) {
            AttachmentPreview(
                viewModel: viewModel,
                startIndex: previewIndex ?? 0,
                onClose: { previewIndex = nil }
            )
        }
        .onAppear {
            viewModel.onAppear(presenter: Self.topPresentedViewController())
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = viewModel.lastError,
               viewModel.submissionState == .error
            {
                ErrorSnackbar(error: error)
            }
            CreateTicketButton(
                isLoading: viewModel.submissionState == .submitting,
                enabled: viewModel.canSubmit,
                onTap: {
                    descriptionFocused = false
                    Task { await viewModel.submit() }
                }
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            Brand.paper
                .overlay(
                    Rectangle()
                        .fill(Brand.cream100)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    @MainActor
    private static func topPresentedViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let keyWindow = scene.windows.first(where: { $0.isKeyWindow }),
            var top = keyWindow.rootViewController
        else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - Form pieces

private struct Section<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .trackingCompat(0.6)
                .foregroundColor(Brand.warm500)
            content()
        }
    }
}

private struct DescriptionField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT HAPPENED?")
                .font(.system(size: 12, weight: .semibold))
                .trackingCompat(0.6)
                .foregroundColor(Brand.warm500)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Describe the bug")
                        .font(.system(size: 15))
                        .foregroundColor(Brand.warm400)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .focused(focused)
                    .disabled(!enabled)
                    .font(.system(size: 15))
                    .foregroundColor(Brand.warm700)
                    .tint(Brand.accent)
                    .scrollContentBackgroundCompat()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minHeight: 100)
            }
            .background(Brand.paper)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        focused.wrappedValue ? Brand.accent : Brand.cream200,
                        lineWidth: focused.wrappedValue ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct TypeChipRow: View {
    @Binding var selection: BugReportViewModel.BugType

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BugReportViewModel.BugType.allCases) { type in
                TypeChip(type: type, active: selection == type) {
                    selection = type
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct TypeChip: View {
    let type: BugReportViewModel.BugType
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(type.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? Brand.accentInk : Brand.warm600)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(active ? Brand.accentTint : Brand.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(active ? Brand.accentSoft : Brand.cream200, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SeverityRow: View {
    @Binding var selection: BugReportViewModel.Severity

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BugReportViewModel.Severity.allCases) { sev in
                SeverityPill(severity: sev, active: selection == sev) {
                    selection = sev
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SeverityPill: View {
    let severity: BugReportViewModel.Severity
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(severity.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(active ? Brand.paper : Brand.warm600)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(active ? Brand.ink : Brand.cream50)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Brand.ink : Brand.cream200, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch severity {
        case .low: Brand.sevLow
        case .medium: Brand.sevMed
        case .high: Brand.sevHigh
        }
    }
}

private struct AttachmentRow: View {
    let screenshots: [UIImage]
    let canAddMore: Bool
    let enabled: Bool
    let onAdd: () -> Void
    let onOpen: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(screenshots.enumerated()), id: \.offset) { index, image in
                AttachmentThumb(image: image, enabled: enabled) {
                    onOpen(index)
                }
            }
            if canAddMore {
                AddTile(enabled: enabled, onTap: onAdd)
            }
        }
    }
}

/// Tapping a thumbnail opens the full-screen preview; removal moved into the
/// preview's Delete button, so the thumbnail carries only an expand affordance.
private struct AttachmentThumb: View {
    let image: UIImage
    let enabled: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.cream100, lineWidth: 1)
                    )

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(4)
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(SDKStrings.previewOpen)
    }
}

// MARK: - Full-screen attachment preview (CAP-014)

/// Immersive lightbox over the reporter, opened by tapping a thumbnail. The
/// `xmark` here closes the *preview*, not the reporter sheet — the sheet still
/// has no close button (CAP-011). Delete lives here; the thumbnail no longer
/// carries a remove badge.
/// Index the preview should land on after the attachment at `deletedIndex` is
/// removed from a list that now holds `newCount` items. `nil` means nothing is
/// left, so the preview should close. Mirrors Android's
/// `nextPreviewIndexAfterDelete` so both platforms clamp identically.
func nextPreviewIndex(afterDeleting deletedIndex: Int, newCount: Int) -> Int? {
    newCount <= 0 ? nil : min(deletedIndex, newCount - 1)
}

private struct AttachmentPreview: View {
    @ObservedObject var viewModel: BugReportViewModel
    @State private var index: Int
    /// When set, the editor is swapped in over the preview for that attachment
    /// (a content swap inside this same presentation — no third stacked sheet).
    @State private var markupIndex: Int?
    let onClose: () -> Void

    init(viewModel: BugReportViewModel, startIndex: Int, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        _index = State(initialValue: startIndex)
        self.onClose = onClose
    }

    private var count: Int {
        viewModel.screenshots.count
    }

    private func deleteCurrent() {
        let deleted = index
        viewModel.removeScreenshot(at: deleted)
        if let next = nextPreviewIndex(afterDeleting: deleted, newCount: viewModel.screenshots.count) {
            index = next
        } else {
            onClose()
        }
    }

    var body: some View {
        ZStack {
            if let markupIndex, viewModel.screenshots.indices.contains(markupIndex) {
                MarkupEditorView(
                    image: viewModel.screenshots[markupIndex],
                    onCancel: { self.markupIndex = nil },
                    onSave: { edited in
                        viewModel.replaceScreenshot(at: markupIndex, with: edited)
                        self.markupIndex = nil
                    }
                )
            } else {
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
                    markupEntryButton
                    if count > 1 {
                        dots
                    }
                }
            }
        }
        .onChange(of: count) { newCount in
            if let next = nextPreviewIndex(afterDeleting: index, newCount: newCount) {
                index = next
            } else {
                onClose()
            }
        }
    }

    /// Accent-filled rather than the preview's usual translucent chip: markup is the
    /// one action on this screen worth advertising, and a glass chip beside a glass
    /// Close read as chrome rather than an invitation (CAP-016).
    private var markupEntryButton: some View {
        Button {
            markupIndex = index
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 15, weight: .medium))
                Text(SDKStrings.markupOpen)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Color(red: 0.204, green: 0.71, blue: 0.541))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var topChrome: some View {
        HStack {
            PreviewChip(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel(SDKStrings.previewClose)

            Spacer()

            VStack(spacing: 1) {
                Text(SDKStrings.previewTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(SDKStrings.previewCounter(index + 1, count))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            PreviewChip(
                action: deleteCurrent,
                tint: Color(red: 0.94, green: 0.52, blue: 0.6),
                background: Color(red: 0.94, green: 0.52, blue: 0.6).opacity(0.14)
            ) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
            }
            .accessibilityLabel(SDKStrings.previewDelete)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var stage: some View {
        TabView(selection: $index) {
            ForEach(Array(viewModel.screenshots.enumerated()), id: \.offset) { i, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.32))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .padding(.bottom, 24)
        .padding(.top, 8)
    }
}

private struct PreviewChip<Content: View>: View {
    let action: () -> Void
    var tint: Color = .white
    var background: Color = .white.opacity(0.12)
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct AddTile: View {
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Brand.warm500)
            .frame(width: 72, height: 72)
            .background(Brand.cream50)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Brand.cream300,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct CreateTicketButton: View {
    let isLoading: Bool
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Brand.onPrimary))
                } else {
                    Text("Create ticket")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Brand.onPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(enabled || isLoading ? Brand.primary : Brand.warm600)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color(red: 0.04, green: 0.06, blue: 0.08).opacity(0.22), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isLoading)
    }
}

private struct ErrorSnackbar: View {
    let error: BugScreenSDKError
    @State private var detailsVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SDKStrings.errorTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(error.userMessage)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = error.technicalDetail, !detail.isEmpty {
                Button {
                    detailsVisible.toggle()
                } label: {
                    Text(detailsVisible ? SDKStrings.errorDetailsHide : SDKStrings.errorDetailsShow)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if detailsVisible {
                    Text(detail)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundColor(Brand.dangerText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.dangerBg)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dangerBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Success confirmation rendered after submit. Used by the SwiftUI sheet
/// content during the success state and by `SuccessToastPresenter` for the
/// transient post-dismiss window.
struct SuccessToast: View {
    let partialFailures: [ReportPartialFailure]
    @State private var detailsVisible = false

    init(partialFailures: [ReportPartialFailure] = []) {
        self.partialFailures = partialFailures
    }

    private var hasPartials: Bool {
        !partialFailures.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hasPartials ? Brand.sevMed : Brand.accent)
                    .frame(width: 36, height: 36)
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Brand.onPrimary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(hasPartials ? SDKStrings.successPartialTitle : SDKStrings.successTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Brand.ink)
                Text(hasPartials ? SDKStrings.successPartialMessage : SDKStrings.successMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Brand.warm500)
                    .fixedSize(horizontal: false, vertical: true)
                if hasPartials {
                    Button {
                        detailsVisible.toggle()
                    } label: {
                        Text(detailsVisible ? SDKStrings.errorDetailsHide : SDKStrings.errorDetailsShow)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Brand.ink)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if detailsVisible {
                        ForEach(partialFailures.indices, id: \.self) { index in
                            let failure = partialFailures[index]
                            Text("\(failure.type): \(failure.message)")
                                .font(.system(size: 12))
                                .foregroundColor(Brand.warm600)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Brand.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Brand.cream100, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Brand palette

/// Each token resolves to a different concrete color depending on the current
/// `userInterfaceStyle` — UIKit's `UIColor(dynamicProvider:)` is consulted at
/// render time, so changing system appearance updates the sheet without any
/// explicit `@Environment(\.colorScheme)` wiring.
///
/// Light values mirror the brand spec from `bugscreen.app`. Dark values are
/// hand-tuned counterparts: surfaces invert (paper → near-black), cream
/// hairlines step up to mid-greys, ink and warms invert, and the emerald
/// accent shifts slightly brighter so it reads against a dark surface.
enum Brand {
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x1B1A18)
    static let cream50 = dynamic(light: 0xF7F7F6, dark: 0x232220)
    static let cream100 = dynamic(light: 0xEFEFEE, dark: 0x2D2B28)
    static let cream200 = dynamic(light: 0xE3E3E1, dark: 0x3A3835)
    static let cream300 = dynamic(light: 0xC7C7C5, dark: 0x4F4D49)
    static let warm400 = dynamic(light: 0x98989A, dark: 0x7F7C76)
    static let warm500 = dynamic(light: 0x757575, dark: 0xA6A39D)
    static let warm600 = dynamic(light: 0x474747, dark: 0xD2D0CA)
    static let warm700 = dynamic(light: 0x2D2D2D, dark: 0xE8E6E0)
    static let ink = dynamic(light: 0x0F0F0F, dark: 0xF7F6F1)
    static let accent = dynamic(light: 0x047857, dark: 0x34B58A)
    static let accentSoft = dynamic(light: 0x9FD4BE, dark: 0x1F5A48)
    static let accentTint = dynamic(light: 0xD5EBE0, dark: 0x142E26)
    static let accentInk = dynamic(light: 0x053D2C, dark: 0xA8E5CA)
    static let dangerBg = dynamic(light: 0xFBEAEE, dark: 0x3A1820)
    static let dangerBorder = dynamic(light: 0xF3C5CD, dark: 0x5C2333)
    static let dangerText = dynamic(light: 0x7A1D2E, dark: 0xF7B6C0)
    static let sevLow = accent
    static let sevMed = dynamic(light: 0xF0B96B, dark: 0xF0B96B)
    static let sevHigh = dynamic(light: 0x7A1D2E, dark: 0xF08599)
    /// Primary CTA — filled ink in light, filled emerald in dark.
    static let primary = dynamic(light: 0x0F0F0F, dark: 0x34B58A)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x08110D)
    /// The system sheet draws its own scrim — this token is retained only for
    /// any future overlay use; UISheetPresentationController ignores it.
    static let scrim = Color.black.opacity(0.32)

    /// Builds a SwiftUI `Color` whose concrete value depends on the current
    /// `userInterfaceStyle`. Hex inputs are 0xRRGGBB.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - iOS 15 / 16 compatibility shims

private extension View {
    @ViewBuilder
    func scrollContentBackgroundCompat() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollDismissesKeyboardCompat() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

private extension Text {
    /// `Text.tracking(_:)` is iOS 16+. On iOS 15 the SDK ships without letter
    /// spacing tweaks — visually subtle and not worth an AttributedString shim.
    @ViewBuilder
    func trackingCompat(_ value: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            tracking(value)
        } else {
            self
        }
    }
}

// MARK: - PHPickerViewController wrapper

/// How the reporter asks for images. Separated from the view because
/// `PHPickerViewController` cannot be driven from a unit test, and two of its settings carry
/// behaviour worth asserting rather than assuming.
enum PhotoPickerConfiguration {
    static func make(selectionLimit: Int) -> PHPickerConfiguration {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        // The caller passes the *remaining* slots, so the picker stops the tester at the cap
        // instead of accepting a selection the form would silently trim (CAP-004).
        config.selectionLimit = selectionLimit
        // `.ordered` returns results in the order the tester tapped them, and numbers the
        // badges to say so. The default is library order, which silently reorders a set of
        // screenshots taken in the sequence the bug unfolded.
        config.selection = .ordered
        return config
    }
}

/// Multi-image picker that works on iOS 15+ via `PHPickerViewController`.
/// SwiftUI's `PhotosPicker` would be simpler but is iOS 16+.
private struct PhotoPickerSheet: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPicked: ([UIImage]) -> Void

    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: PhotoPickerConfiguration.make(selectionLimit: selectionLimit))
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPickerSheet

        init(_ parent: PhotoPickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            var images: [(Int, UIImage)] = []
            let lock = NSLock()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    if let image = object as? UIImage {
                        lock.lock()
                        images.append((index, image))
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .main) { [parent] in
                let ordered = images.sorted { $0.0 < $1.0 }.map(\.1)
                parent.onPicked(ordered)
            }
        }
    }
}

// MARK: - Preview

struct BugReportView_Previews: PreviewProvider {
    /// The preview needs a transport it will never call.
    private struct PreviewSubmitter: BugReportSubmitting {
        @MainActor
        func submitBugReport(
            description _: String,
            screenshots _: [PreparedScreenshot],
            type _: String?,
            severity _: String?
        ) async throws -> ReportReceipt {
            ReportReceipt(partialFailures: [])
        }
    }

    static var previews: some View {
        BugReportView(
            viewModel: BugReportViewModel(onDismiss: {}, submitter: PreviewSubmitter())
        )
    }
}
