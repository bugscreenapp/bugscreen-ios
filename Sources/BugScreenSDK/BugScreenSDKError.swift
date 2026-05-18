import Foundation

/// Errors that can occur internally inside the BugScreen SDK.
internal enum BugScreenSDKError: LocalizedError, Sendable {
    /// SDK has not been configured. Call `BugScreenSDK.configure()` first.
    case notConfigured

    /// Caller-side validation failed (e.g. a method argument was out of range).
    case invalidArgument(String)

    /// The provided URL is invalid
    case invalidURL

    /// The server response was invalid or could not be parsed
    case invalidResponse

    /// HTTP error with status code
    case httpError(Int)

    /// API error with custom message from server
    case apiError(String)

    /// The request was cancelled before it completed.
    case cancelled

    /// The request did not complete within the configured timeout.
    case timeout

    /// Network error with underlying system error
    case networkError(any Error & Sendable)

    /// Failed to encode request data
    case encodingError

    /// Human-readable error description
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "BugScreenSDK not configured. Call BugScreenSDK.configure() before using the SDK."

        case .invalidArgument(let message):
            return "Invalid argument: \(message)"

        case .invalidURL:
            return "Invalid API URL. Please check your configuration."

        case .invalidResponse:
            return "Invalid server response. Please try again."

        case .httpError(let code):
            return "HTTP error: \(code). \(Self.httpErrorMessage(for: code))"

        case .apiError(let message):
            return "API error: \(message)"

        case .cancelled:
            return "Request cancelled."

        case .timeout:
            return "Request timed out. Please try again."

        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"

        case .encodingError:
            return "Failed to encode request data. Please check your input."
        }
    }

    /// Detailed error message for common HTTP status codes
    private static func httpErrorMessage(for code: Int) -> String {
        switch code {
        case 400:
            return "Bad request. Please check your input."
        case 401:
            return "Unauthorized. Please check your API key."
        case 403:
            return "Forbidden. Your API key may not have permission."
        case 404:
            return "Not found. Please check the API URL."
        case 429:
            return "Too many requests. Please try again later."
        case 500:
            return "Internal server error. Please try again later."
        case 503:
            return "Service unavailable. Please try again later."
        default:
            return "Please try again."
        }
    }
}
