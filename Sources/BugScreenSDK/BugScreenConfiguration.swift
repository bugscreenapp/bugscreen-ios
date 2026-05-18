import Foundation

/// Internal snapshot of the active SDK configuration, captured by `BugScreenSDK.configure()`.
///
/// Immutable to ensure thread-safety and predictable behavior. Not exposed publicly —
/// consumers configure the SDK via the parameters on `BugScreenSDK.configure(...)`.
internal struct BugScreenConfiguration: Sendable {
    let apiKey: String
    let enableScreenshotDetection: Bool
    let debug: Bool
}
