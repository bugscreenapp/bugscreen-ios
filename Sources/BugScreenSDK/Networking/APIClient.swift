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

    /// Optional `<wrapper>/<semver>` tag (e.g. `rn/0.5.0`) when a cross-platform wrapper drove
    /// init, emitted on the informational `X-BugScreen-SDK-Wrapper` header (OPS-011). `nil` for a
    /// direct native integration.
    private let wrapperSdk: String?

    /// Base URL for the API
    private let baseURL: URL

    /// URLSession for making network requests
    private let session: URLSession
    private let videoUploader: VideoUploadClient

    // MARK: - Initialization

    /// Creates a new API client.
    ///
    /// - Parameters:
    ///   - apiKey: The API key from BugScreen console (with "fb_" prefix)
    ///   - wrapperSdk: Cross-platform wrapper tag for the `X-BugScreen-SDK-Wrapper` header (default: none)
    ///   - baseURL: The base URL for the API (default: production API)
    ///   - session: URLSession to use for requests. Defaults to a session
    ///     configured with the SDK's standard request/upload timeouts.
    init(
        apiKey: String,
        wrapperSdk: String? = nil,
        baseURL: URL = URL(string: "https://qlqobn1oq5.execute-api.eu-west-2.amazonaws.com/prod/")!,
        session: URLSession? = nil,
        videoUploader: VideoUploadClient? = nil
    ) {
        self.apiKey = apiKey
        self.wrapperSdk = wrapperSdk
        self.baseURL = baseURL
        let resolvedSession = session ?? APIClient.makeDefaultSession()
        self.session = resolvedSession
        var headers = ["Authorization": "Bearer \(apiKey)", "X-BugScreen-SDK": "ios/\(BugScreenSDK.version)"]
        if let wrapperSdk { headers["X-BugScreen-SDK-Wrapper"] = wrapperSdk }
        self.videoUploader = videoUploader ?? VideoUploadClient(baseURL: baseURL, headers: headers, session: resolvedSession)
    }

    /// Applies the headers every SDK→API request carries: Bearer auth and the OPS-011 SDK version
    /// header(s). `X-BugScreen-SDK` is the transport header the server parses to gate
    /// non-backwards-compatible response features; `X-BugScreen-SDK-Wrapper` is sent only when a
    /// cross-platform wrapper drove init and is informational (never gates).
    private func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("ios/\(BugScreenSDK.version)", forHTTPHeaderField: "X-BugScreen-SDK")
        if let wrapperSdk {
            request.setValue(wrapperSdk, forHTTPHeaderField: "X-BugScreen-SDK-Wrapper")
        }
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
    ///   - screenshots: Up to 4 already-prepared screenshots. Downscaling and
    ///     re-encoding happen in the reporter (RFC-003 §2.2) — the transport only packs
    ///     what it is handed. Historically each was downscaled to a 2000 pt
    ///     long edge and re-encoded as JPEG q=0.85 before upload so a 4-shot report
    ///     comfortably fits API Gateway's 10 MB request cap. Extra screenshots beyond
    ///     the 4th are dropped silently.
    ///   - type: Reporter-selected Type display label. Forwarded as human-readable
    ///     classification and, where supported, a native label.
    ///   - severity: Reporter-selected severity ("low" | "medium" | "high"). Forwarded
    ///     to GitHub/Jira as a label / priority on the created issue.
    ///   - logFile: Optional log file URL (typically from Logger.exportToFile())
    ///
    /// - Returns: Response containing URLs of created issues
    /// - Throws: BugScreenSDKError for various failure cases
    func submitBugReport(
        description: String,
        metadata: BugReportMetadata,
        screenshots: [PreparedScreenshot] = [],
        type: String? = nil,
        severity: String? = nil,
        logFile: URL? = nil,
        videos: [PreparedVideo] = [],
        visualOrder: [ReportMediaOrder] = []
    ) async throws -> BugReportResponse {
        // Validate description length
        guard !description.isEmpty, description.count <= 10000 else {
            throw BugScreenSDKError.invalidArgument("Description must be between 1 and 10000 characters")
        }

        let visualAttachments = videos.isEmpty ? nil : try await videoUploader.references(videos: videos, order: visualOrder)

        // Construct url
        let url = baseURL.appendingPathComponent("reports")

        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Bearer auth + OPS-011 SDK version header(s)
        applyDefaultHeaders(to: &request)

        // Create multipart boundary
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Cap at 4: backend's busboy config rejects >4 `screenshot` parts.
        let capped = Array(screenshots.prefix(APIClient.maxScreenshots))

        // Concatenating 4 already-encoded screenshots is several MB of `Data`
        // appends. The caller is `@MainActor`, so build the body off it. The
        // expensive part — downscale + JPEG encode — happens in the reporter
        // before it ever reaches here (RFC-003 §2.2).
        let body = try await Task.detached(priority: .userInitiated) {
            try APIClient.createMultipartBody(
                boundary: boundary,
                description: description,
                metadata: metadata,
                screenshots: capped,
                type: type,
                severity: severity,
                logFile: logFile,
                visualAttachments: visualAttachments
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
            if !videos.isEmpty { await videoUploader.clearReadyUploads() }
            return try JSONDecoder().decode(BugReportResponse.self, from: data)
        }
        let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        throw BugScreenSDKError.httpError(
            status: httpResponse.statusCode,
            code: parsed?.code,
            message: parsed?.message
        )
    }

    /// Fetches the authoritative reporter configuration from `GET /config`.
    func fetchRuntimeConfig() async throws -> ResolvedSdkConfig {
        let url = baseURL.appendingPathComponent("config")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyDefaultHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BugScreenSDKError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw BugScreenSDKError.httpError(status: httpResponse.statusCode, code: nil, message: nil)
        }
        let config = try JSONDecoder().decode(SdkConfig.self, from: data)
        if config.videoAttachmentLimits?.isValid == false { throw BugScreenSDKError.invalidResponse }
        return ResolvedSdkConfig(
            showBranding: config.showBranding,
            reportTypes: config.reportTypes ?? defaultReportTypes,
            severityEnabled: config.severityEnabled ?? true,
            videoAttachmentLimits: config.videoAttachmentLimits,
            copy: config.reporterCopy ?? ReporterCopy()
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
        screenshots: [PreparedScreenshot],
        type: String?,
        severity: String?,
        logFile: URL?,
        visualAttachments: String? = nil
    ) throws -> Data {
        var body = Data()

        if let visualAttachments {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"visualAttachments\"\r\n")
            body.append("Content-Type: application/json\r\n\r\n")
            body.append("\(visualAttachments)\r\n")
        }

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
            let filename = "screenshot-\(index + 1).\(screenshot.fileExtension)"
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"screenshot\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(screenshot.contentType)\r\n\r\n")
            body.append(screenshot.data)
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
}
