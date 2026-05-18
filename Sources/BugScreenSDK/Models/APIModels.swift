import Foundation

// MARK: - Success Response

/// Response from the bug reports API when submission is successful.
///
/// Conforms to the OpenAPI specification at `/packages/shared-types/specs/reports-api.yaml`.
public struct BugReportResponse: Codable, Sendable {
    /// Always true for successful responses
    public let success: Bool

    /// Human-readable success message
    public let message: String

    /// Array of URLs to created issues (one per integration)
    ///
    /// Example: `["https://github.com/example/repo/issues/123"]`
    public let issueURLs: [String]

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case issueURLs = "issueUrls"
    }
}

// MARK: - Error Response

/// Error response from the bug reports API.
///
/// Returned for 400 (Bad Request), 401 (Unauthorized), and 500 (Internal Server Error) responses.
struct ErrorResponse: Codable, Sendable {
    /// Error type (e.g., "Bad Request", "Unauthorized", "Internal Server Error")
    let error: String

    /// Human-readable error message with details
    let message: String

    /// HTTP status code
    let statusCode: Int

    enum CodingKeys: String, CodingKey {
        case error
        case message
        case statusCode
    }
}
