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

    /// Integrations that failed to receive the report. Only present when at
    /// least one integration succeeded and at least one failed.
    public let partialFailures: [BugReportPartialFailure]?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case issueURLs = "issueUrls"
        case partialFailures
    }
}

public struct BugReportPartialFailure: Codable, Sendable {
    public let type: String
    public let message: String
}

// MARK: - SDK Config

/// Runtime configuration returned by `GET /config`, resolved from the API key.
///
/// `showBranding` is `true` on Free plans and `false` when the org's effective
/// plan removes branding.
struct SdkConfig: Decodable {
    let appId: String
    let showBranding: Bool
    let reportTypes: [String]?
    let severityEnabled: Bool?
    let videoAttachmentLimits: VideoAttachmentLimits?
    let reporterCopy: ReporterCopy?

    private enum CodingKeys: String,
        CodingKey { case appId, showBranding, reportTypes, severityEnabled, videoAttachmentLimits, reporterCopy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(String.self, forKey: .appId)
        showBranding = try c.decode(Bool.self, forKey: .showBranding)
        reportTypes = try c.decodeIfPresent([String].self, forKey: .reportTypes)
        severityEnabled = try c.decodeIfPresent(Bool.self, forKey: .severityEnabled)
        videoAttachmentLimits = try c.decodeIfPresent(VideoAttachmentLimits.self, forKey: .videoAttachmentLimits)
        reporterCopy = c.contains(.reporterCopy) ? try c.decode(ReporterCopy.self, forKey: .reporterCopy) : nil
    }
}

struct ResolvedSdkConfig {
    let showBranding: Bool
    let reportTypes: [String]
    let severityEnabled: Bool
    let videoAttachmentLimits: VideoAttachmentLimits?
    let copy: ReporterCopy

    init(
        showBranding: Bool,
        reportTypes: [String],
        severityEnabled: Bool = true,
        videoAttachmentLimits: VideoAttachmentLimits? = nil,
        copy: ReporterCopy = ReporterCopy()
    ) {
        self.showBranding = showBranding
        self.reportTypes = reportTypes
        self.severityEnabled = severityEnabled
        self.videoAttachmentLimits = videoAttachmentLimits
        self.copy = copy
    }
}

// MARK: - Error Response

/// Error response from the bug reports API.
///
/// Returned for 400 (Bad Request), 401 (Unauthorized), and 500 (Internal Server Error) responses.
struct ErrorResponse: Codable {
    /// Error type (e.g., "Bad Request", "Unauthorized", "Internal Server Error")
    let error: String

    /// Human-readable error message with details
    let message: String

    /// HTTP status code
    let statusCode: Int

    /// Stable machine-readable error code (e.g. `validation.description`,
    /// `auth.invalid_key`). Used by the SDK to map errors to user-facing copy.
    let code: String?

    enum CodingKeys: String, CodingKey {
        case error
        case message
        case statusCode
        case code
    }
}
