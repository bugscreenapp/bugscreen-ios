import SwiftUI
import PhotosUI

/// SwiftUI view for submitting bug reports.
///
/// Displays a form with description editor, screenshot attachment, device info,
/// and submit button. Handles loading states and success/error alerts.
/// Uses minimal black/white design matching Android SDK.
@available(iOS 15.0, *)
internal struct BugReportView: View {

    // MARK: - Properties

    @StateObject private var viewModel: BugReportViewModel

    @State private var showImagePicker = false
    @State private var showMetadata = false

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Initialization

    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: BugReportViewModel(
            screenshot: screenshot,
            autoAttach: autoAttach,
            onDismiss: onDismiss
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    descriptionSection
                    screenshotSection
                    deviceInfoSection
                    actionButtons
                    if let error = viewModel.errorMessage {
                        errorSection(error)
                    }
                }
                .padding(16)
            }
            .background(backgroundColor)
            .navigationTitle("Report Bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        viewModel.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(primaryColor)
                    }
                    .disabled(viewModel.submissionState == .submitting)
                }
            }
            .alert("Submission Failed", isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) {}
                Button("Try Again") {
                    Task {
                        await viewModel.submit()
                    }
                }
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred")
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $viewModel.screenshot)
            }
            .onAppear {
                viewModel.onAppear(presenter: Self.topPresentedViewController())
            }
        }
    }

    /// Finds the topmost presented view controller in the active scene, used as the host for
    /// the auto-attach permission rationale alert.
    @MainActor
    private static func topPresentedViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let keyWindow = scene.windows.first(where: { $0.isKeyWindow }),
              var top = keyWindow.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Theme Colors

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(hex: "000000") : Color(hex: "FAFAFA")
    }

    private var surfaceColor: Color {
        colorScheme == .dark ? Color(hex: "1E1E1E") : Color.white
    }

    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var secondaryColor: Color {
        colorScheme == .dark ? Color(hex: "E0E0E0") : Color(hex: "757575")
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color(hex: "2C2C2C") : Color(hex: "E0E0E0")
    }

    private var errorBackgroundColor: Color {
        colorScheme == .dark ? Color(hex: "CF6679").opacity(0.2) : Color(hex: "B00020").opacity(0.1)
    }

    private var errorTextColor: Color {
        colorScheme == .dark ? Color(hex: "CF6679") : Color(hex: "B00020")
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Description *")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(primaryColor)

            TextEditor(text: $viewModel.description)
                .frame(minHeight: 150)
                .padding(8)
                .background(surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColor, lineWidth: 1)
                )
                .disabled(viewModel.submissionState == .submitting)
        }
        .padding(12)
        .background(surfaceColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Screenshot Section

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Screenshot (Optional)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(primaryColor)

                Spacer()

                if viewModel.screenshot != nil {
                    Button("Change") {
                        showImagePicker = true
                    }
                    .font(.system(size: 14))
                    .foregroundColor(primaryColor)
                    .disabled(viewModel.submissionState == .submitting)
                }
            }

            if let screenshot = viewModel.screenshot {
                Image(uiImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .cornerRadius(4)
            } else {
                Button {
                    showImagePicker = true
                } label: {
                    Text("Select Screenshot")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(primaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.submissionState == .submitting)
            }
        }
        .padding(12)
        .background(surfaceColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Device Info Section

    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Device Information")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(primaryColor)

                Spacer()

                Button(showMetadata ? "Hide" : "Show") {
                    withAnimation {
                        showMetadata.toggle()
                    }
                }
                .font(.system(size: 14))
                .foregroundColor(primaryColor)
            }

            if showMetadata {
                VStack(alignment: .leading, spacing: 4) {
                    deviceInfoRow(label: "Device", key: MetadataKeys.device)
                    deviceInfoRow(label: "OS Version", key: MetadataKeys.osVersion)
                    deviceInfoRow(label: "App Version", key: MetadataKeys.appVersion)
                    deviceInfoRow(label: "Build Number", key: MetadataKeys.appBuildNumber)
                    deviceInfoRow(label: "Screen Resolution", key: MetadataKeys.screenResolution)
                    deviceInfoRow(label: "Locale", key: MetadataKeys.locale)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(12)
        .background(surfaceColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func deviceInfoRow(label: String, key: String) -> some View {
        let value = (viewModel.metadata[key] as? String) ?? ""
        return HStack(alignment: .top) {
            Text(label + ":")
                .foregroundColor(secondaryColor)
            Spacer()
            Text(value)
                .foregroundColor(primaryColor)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(primaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.submissionState == .submitting)

            Button {
                Task {
                    await viewModel.submit()
                }
            } label: {
                if viewModel.submissionState == .submitting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .black : .white))
                        .frame(maxWidth: .infinity)
                        .padding(14)
                } else {
                    Text("Submit")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                }
            }
            .background(viewModel.canSubmit ? primaryColor : secondaryColor.opacity(0.5))
            .cornerRadius(8)
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Submission Failed")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(errorTextColor)

            Text(error)
                .font(.system(size: 13))
                .foregroundColor(errorTextColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(errorBackgroundColor)
        .cornerRadius(8)
    }

}

// MARK: - Image Picker

/// UIImagePickerController wrapper for iOS 15 compatibility.
///
/// Note: For iOS 16+, we could use PhotosPicker instead, but this provides
/// backwards compatibility with iOS 15.
@available(iOS 15.0, *)
internal struct ImagePicker: UIViewControllerRepresentable {

    @Binding var image: UIImage?
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Preview

@available(iOS 15.0, *)
struct BugReportView_Previews: PreviewProvider {
    static var previews: some View {
        BugReportView(onDismiss: {})
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
