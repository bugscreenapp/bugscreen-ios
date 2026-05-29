import Foundation
import UIKit

/// HTTP client for communicating with the BugScreen backend API.
///
/// Handles multipart form-data uploads, authentication, and error handling.
/// All methods are async and throw errors for proper error propagation.
final class APIClient {
    // MARK: - Properties

    /// API key for authentication (sent as Bearer token)
    private let apiKey: String

    /// Base URL for the API
    private let baseURL: URL

    /// URLSession for making network requests
    private let session: URLSession

    // MARK: - Initialization

    /// Creates a new API client.
    ///
    /// - Parameters:
    ///   - apiKey: The API key from BugScreen console (with "fb_" prefix)
    ///   - baseURL: The base URL for the API (default: production API)
    ///   - session: URLSession to use for requests. Defaults to a session
    ///     configured with the SDK's standard request/upload timeouts.
    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://qlqobn1oq5.execute-api.eu-west-2.amazonaws.com/prod/")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session ?? APIClient.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30 // 30 seconds for request
        config.timeoutIntervalForResource = 60 // 60 seconds for upload
        return URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Submits a bug report to the backend.
    ///
    /// This method uploads the bug report with optional screenshots and log file
    /// using multipart/form-data encoding. The backend will create issues in all
    /// configured integrations and return the URLs.
    ///
    /// - Parameters:
    ///   - description: User's description of the bug (required, 1-10000 characters)
    ///   - metadata: Device/app metadata to include in the report
    ///   - screenshots: Up to 4 screenshot images. Each is downscaled to a 2000 pt
    ///     long edge and re-encoded as JPEG q=0.85 before upload so a 4-shot report
    ///     comfortably fits API Gateway's 10 MB request cap. Extra screenshots beyond
    ///     the 4th are dropped silently.
    ///   - type: Reporter-selected bug type ("bug" | "ui" | "crash"). Forwarded to
    ///     GitHub/Jira as a label on the created issue.
    ///   - severity: Reporter-selected severity ("low" | "medium" | "high"). Forwarded
    ///     to GitHub/Jira as a label / priority on the created issue.
    ///   - logFile: Optional log file URL (typically from Logger.exportToFile())
    ///
    /// - Returns: Response containing URLs of created issues
    /// - Throws: BugScreenSDKError for various failure cases
    func submitBugReport(
        description: String,
        metadata: BugReportMetadata,
        screenshots: [UIImage] = [],
        type: String? = nil,
        severity: String? = nil,
        logFile: URL? = nil
    ) async throws -> BugReportResponse {
        // Validate description length
        guard !description.isEmpty, description.count <= 10000 else {
            throw BugScreenSDKError.invalidArgument("Description must be between 1 and 10000 characters")
        }

        // Construct url
        let url = baseURL.appendingPathComponent("reports")

        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add authorization header with Bearer token
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Create multipart boundary
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Cap at 4: backend's busboy config rejects >4 `screenshot` parts.
        let capped = Array(screenshots.prefix(APIClient.maxScreenshots))

        // Downscale + JPEG encoding for 4 retina screenshots can spend 1+ s of
        // CPU time. The caller is `@MainActor`, so building the body inline
        // would jank the UI mid-submit. Hop to a background task and await
        // the encoded bytes.
        let body = try await Task.detached(priority: .userInitiated) {
            try APIClient.createMultipartBody(
                boundary: boundary,
                description: description,
                metadata: metadata,
                screenshots: capped,
                type: type,
                severity: severity,
                logFile: logFile
            )
        }.value
        request.httpBody = body

        // Perform request. Map well-known URLError codes to typed SDK cases so
        // callers can switch on `.cancelled` / `.timeout` without inspecting
        // the underlying error.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                throw BugScreenSDKError.cancelled
            case .timedOut:
                throw BugScreenSDKError.timeout
            case .notConnectedToInternet, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff:
                throw BugScreenSDKError.offline
            default:
                throw BugScreenSDKError.networkError(urlError)
            }
        }

        // Validate HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BugScreenSDKError.invalidResponse
        }

        // 201 is the only success path. Every other status: try to surface the
        // backend's ErrorResponse.message verbatim (matches Android's Retrofit +
        // Gson flow) and fall back to a status-code message only if the body
        // can't be decoded.
        if httpResponse.statusCode == 201 {
            return try JSONDecoder().decode(BugReportResponse.self, from: data)
        }
        let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        throw BugScreenSDKError.httpError(
            status: httpResponse.statusCode,
            code: parsed?.code,
            message: parsed?.message
        )
    }

    // MARK: - Private Helpers

    /// Creates a multipart/form-data request body.
    ///
    /// Follows the OpenAPI specification for the /reports endpoint. Static so
    /// the synchronous body-building work can run on a detached task without
    /// dragging the `APIClient` instance (and its `URLSession`) across actors.
    private static func createMultipartBody(
        boundary: String,
        description: String,
        metadata: BugReportMetadata,
        screenshots: [UIImage],
        type: String?,
        severity: String?,
        logFile: URL?
    ) throws -> Data {
        var body = Data()

        // Add description (required field)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"description\"\r\n")
        body.append("Content-Type: text/plain\r\n\r\n")
        body.append("\(description)\r\n")

        // Add metadata (optional, encoded as JSON)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")

        guard
            JSONSerialization.isValidJSONObject(metadata),
            let metadataJSON = try? JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
        else {
            throw BugScreenSDKError.encodingError
        }
        body.append(metadataJSON)
        body.append("\r\n")

        if let type {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"type\"\r\n")
            body.append("Content-Type: text/plain\r\n\r\n")
            body.append("\(type)\r\n")
        }

        if let severity {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"severity\"\r\n")
            body.append("Content-Type: text/plain\r\n\r\n")
            body.append("\(severity)\r\n")
        }

        // Downscale + JPEG-encode each screenshot so a 4-shot report fits inside
        // API Gateway's 10 MB request cap. Raw retina iPhone PNGs are 2–5 MB
        // each — four of them blow past the limit. JPEG q=0.85 at a 2000 px
        // long edge is good enough to read text on a bug report and is roughly
        // an order of magnitude smaller than PNG (matches Android's
        // `prepareScreenshotFile` in ApiClient.kt, commit 6afce77). Every part
        // uses the same `screenshot` field name — busboy iterates them on the
        // server.
        for (index, screenshot) in screenshots.enumerated() {
            guard let encoded = APIClient.encodeScreenshotForUpload(screenshot) else { continue }
            let filename = "screenshot-\(index + 1).\(encoded.fileExt)"
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"screenshot\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(encoded.contentType)\r\n\r\n")
            body.append(encoded.data)
            body.append("\r\n")
        }

        // Add log file (optional)
        if let logFile,
           let logData = try? Data(contentsOf: logFile)
        {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"logFile\"; filename=\"logs.txt\"\r\n")
            body.append("Content-Type: text/plain\r\n\r\n")
            body.append(logData)
            body.append("\r\n")
        }

        // Add closing boundary
        body.append("--\(boundary)--\r\n")

        return body
    }

    /// Maximum number of screenshots accepted per report. Matches the backend's
    /// busboy file-count limit and the Android SDK's `MAX_SCREENSHOTS`.
    static let maxScreenshots = 4

    /// Long-edge cap (in pixels) for uploaded screenshots. 2000 matches
    /// Android's `MAX_SCREENSHOT_DIMENSION_PX` — small enough that four
    /// JPEGs fit comfortably under the 10 MB API Gateway request cap, large
    /// enough to read body text on a phone screen.
    static let maxScreenshotDimension: CGFloat = 2000

    /// JPEG quality used when re-encoding screenshots before upload.
    static let screenshotJpegQuality: CGFloat = 0.85

    /// Downscales `image` so its long edge fits within `maxScreenshotDimension`
    /// and re-encodes as JPEG. Falls back to a raw PNG if JPEG encoding
    /// genuinely fails — the server still enforces a per-screenshot size
    /// guard, so this is just a last-ditch attempt to produce *something*.
    static func encodeScreenshotForUpload(
        _ image: UIImage
    ) -> (data: Data, contentType: String, fileExt: String)? {
        let downscaled = downscale(image, longEdge: maxScreenshotDimension)
        if let jpeg = downscaled.jpegData(compressionQuality: screenshotJpegQuality) {
            return (jpeg, "image/jpeg", "jpg")
        }
        if let png = downscaled.pngData() {
            return (png, "image/png", "png")
        }
        return nil
    }

    /// Returns `image` unchanged if its pixel long edge is already within
    /// `longEdge`; otherwise renders a smaller bitmap whose pixel long edge
    /// equals `longEdge`. Compares pixel dimensions (`size × scale`), not
    /// points — a retina screenshot at 1179×2556 px / scale 3 reports a
    /// point size of 393×852 and would otherwise slip past the cap.
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
        // Render at 1× so the target size we computed in pixels lands 1:1 in
        // the output bitmap — otherwise the renderer would multiply by the
        // device scale and we'd overshoot the cap.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
