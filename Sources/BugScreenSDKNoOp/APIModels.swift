import Foundation

/// No-op mirror of the public API response models. The stub never performs a
/// network request, so these are declared purely to keep the public surface
/// identical to the real SDK (a consumer may reference these types). The internal
/// `SdkConfig` / `ErrorResponse` models are omitted — they are not public.
public struct BugReportResponse: Codable, Sendable {
    public let success: Bool
    public let message: String
    public let issueURLs: [String]
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
