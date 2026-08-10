import Foundation

/// Errors surfaced from the SDK to the bug report UI.
///
/// Carries both a user-facing localized message (`userMessage`) and an optional
/// `technicalDetail` that the UI reveals behind a "Show details" disclosure so
/// the reporter can share specifics with the app's support team.
enum BugScreenSDKError: LocalizedError {
    /// SDK has not been configured. Call `BugScreenSDK.configure()` first.
    case notConfigured

    /// Caller-side validation failed (e.g. a method argument was out of range).
    case invalidArgument(String)

    /// The provided URL is invalid.
    case invalidURL

    /// The server response was invalid or could not be parsed.
    case invalidResponse

    /// HTTP error with status code and optional stable backend `code`.
    case httpError(status: Int, code: String?, message: String?)

    /// API error with custom message from server.
    case apiError(String)

    /// The request was cancelled before it completed.
    case cancelled

    /// No usable network connection.
    case offline

    /// The request did not complete within the configured timeout.
    case timeout

    /// Network error with underlying system error.
    case networkError(any Error & Sendable)

    /// Failed to encode request data.
    case encodingError

    /// User-facing message localized via `Localizable.xcstrings`.
    var userMessage: String {
        switch self {
        case .notConfigured, .invalidArgument, .invalidURL, .encodingError, .apiError:
            SDKStrings.errorConfig
        case .invalidResponse:
            SDKStrings.errorServer
        case let .httpError(status, code, _):
            Self.userMessage(forStatus: status, code: code)
        case .cancelled:
            SDKStrings.errorServer
        case .offline:
            SDKStrings.errorOffline
        case .timeout:
            SDKStrings.errorTimeout
        case .networkError:
            SDKStrings.errorServer
        }
    }

    /// Technical detail revealed via "Show details" — empty when there is
    /// nothing useful to surface beyond `userMessage`.
    var technicalDetail: String? {
        switch self {
        case .notConfigured:
            return "BugScreenSDK not configured. Call BugScreenSDK.configure() before using the SDK."
        case let .invalidArgument(message):
            return "Invalid argument: \(message)"
        case .invalidURL:
            return "Invalid API URL."
        case .invalidResponse:
            return "Server returned an invalid response."
        case let .httpError(status, code, message):
            let parts = [
                "HTTP \(status)",
                code.map { "code=\($0)" },
                message,
            ].compactMap { $0 }
            return parts.joined(separator: " · ")
        case let .apiError(message):
            return "API error: \(message)"
        case .cancelled:
            return "Request cancelled."
        case .offline:
            return nil
        case .timeout:
            return nil
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case .encodingError:
            return "Failed to encode request data."
        }
    }

    /// `LocalizedError` conformance — returns the user-facing copy by default
    /// so callers using `error.localizedDescription` get the user message.
    var errorDescription: String? {
        userMessage
    }

    private static func userMessage(forStatus status: Int, code: String?) -> String {
        switch code {
        case "auth.missing", "auth.invalid_key",
             "config.no_integrations", "integrations.all_failed",
             "plan_limit.reports":
            return SDKStrings.errorConfig
        case "validation.description":
            return SDKStrings.validationDescriptionRequired
        case "validation.too_many_screenshots":
            return SDKStrings.validationTooManyScreenshots
        case "validation.file_too_large":
            return SDKStrings.validationFileTooLarge
        case "validation.log_type", "validation.multipart", "validation.field":
            return SDKStrings.errorServer
        case "server.storage":
            return SDKStrings.errorServer
        default:
            break
        }
        // Fallback for older backends that don't send `code`, or future codes
        // the SDK doesn't recognize. Mirrors Android's `ErrorMapper.fromHttp`
        // status-based fallback.
        switch status {
        case 401, 403, 404:
            return SDKStrings.errorConfig
        case 429:
            return SDKStrings.errorRateLimited
        default:
            return SDKStrings.errorServer
        }
    }
}
