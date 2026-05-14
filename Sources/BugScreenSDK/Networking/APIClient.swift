import Foundation
import UIKit

/// HTTP client for communicating with the BugScreen backend API.
///
/// Handles multipart form-data uploads, authentication, and error handling.
/// All methods are async and throw errors for proper error propagation.
internal class APIClient {

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
        config.timeoutIntervalForRequest = 30  // 30 seconds for request
        config.timeoutIntervalForResource = 60 // 60 seconds for upload
        return URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Submits a bug report to the backend.
    ///
    /// This method uploads the bug report with optional screenshot and log file
    /// using multipart/form-data encoding. The backend will create issues in all
    /// configured integrations and return the URLs.
    ///
    /// - Parameters:
    ///   - description: User's description of the bug (required, 1-10000 characters)
    ///   - metadata: Device/app metadata to include in the report
    ///   - screenshot: Optional screenshot image (encoded as PNG when possible, falls back to JPEG)
    ///   - logFile: Optional log file URL (typically from Logger.exportToFile())
    ///
    /// - Returns: Response containing URLs of created issues
    /// - Throws: BugScreenSDKError for various failure cases
    ///
    /// Example:
    /// ```swift
    /// let client = APIClient(apiKey: "fb_test_key")
    /// let metadata = MetadataCollector.collect()
    /// let response = try await client.submitBugReport(
    ///     description: "App crashes on login",
    ///     metadata: metadata,
    ///     screenshot: someUIImage,
    ///     logFile: logFileURL
    /// )
    /// print(response.issueUrls) // ["https://github.com/..."]
    /// ```
    func submitBugReport(
        description: String,
        metadata: BugReportMetadata,
        screenshot: UIImage? = nil,
        logFile: URL? = nil
    ) async throws -> BugReportResponse {
        // Validate description length
        guard !description.isEmpty && description.count <= 10000 else {
            throw BugScreenSDKError.apiError("Description must be between 1 and 10000 characters")
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

        // Build multipart body
        let body = try createMultipartBody(
            boundary: boundary,
            description: description,
            metadata: metadata,
            screenshot: screenshot,
            logFile: logFile
        )
        request.httpBody = body

        // Perform request
        let (data, response) = try await session.data(for: request)

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
        if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw BugScreenSDKError.apiError(errorResponse.message)
        }
        throw BugScreenSDKError.httpError(httpResponse.statusCode)
    }

    // MARK: - Private Helpers

    /// Creates a multipart/form-data request body.
    ///
    /// Follows the OpenAPI specification for the /reports endpoint.
    ///
    /// - Parameters:
    ///   - boundary: Unique boundary string for multipart sections
    ///   - description: Bug description (required field)
    ///   - metadata: Device/app metadata (encoded as JSON)
    ///   - screenshot: Optional screenshot image (encoded as PNG when possible, falls back to JPEG)
    ///   - logFile: Optional log file
    ///
    /// - Returns: Complete multipart form-data body
    /// - Throws: BugScreenSDKError.encodingError if JSON encoding fails
    private func createMultipartBody(
        boundary: String,
        description: String,
        metadata: BugReportMetadata,
        screenshot: UIImage?,
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

        // Prefer lossless PNG; fall back to JPEG q=0.8 so annotated
        // screenshots aren't degraded by default re-encoding. Retina PNGs can
        // exceed API Gateway's 10MB request limit, so PNGs above
        // `maxPngBytes` also fall back to JPEG.
        if let screenshot = screenshot {
            let maxPngBytes = 4 * 1024 * 1024
            let encoded: (data: Data, contentType: String, filename: String)? = {
                if let png = screenshot.pngData(), png.count <= maxPngBytes {
                    return (png, "image/png", "screenshot.png")
                }
                if let jpeg = screenshot.jpegData(compressionQuality: 0.8) {
                    return (jpeg, "image/jpeg", "screenshot.jpg")
                }
                return nil
            }()
            if let encoded = encoded {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"screenshot\"; filename=\"\(encoded.filename)\"\r\n")
                body.append("Content-Type: \(encoded.contentType)\r\n\r\n")
                body.append(encoded.data)
                body.append("\r\n")
            }
        }

        // Add log file (optional)
        if let logFile = logFile,
           let logData = try? Data(contentsOf: logFile) {
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
}
