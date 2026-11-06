import BugScreenSDK
import Foundation

/// Snapshots the real SDK's value-type bodies as plain primitives. Isolating the
/// `import BugScreenSDK` here (and the no-op's import in NoOpValueSnapshot.swift)
/// lets NoOpValueParityTests compare the two without importing both modules into
/// one file — both export types named `BugScreenSDK`/`LogLevel`/…, so a single
/// file can't name them unambiguously.
enum RealSDKValueSnapshot {
    static var recordingDurations: [Int] {
        [-1, 30, 120].map { ScreenRecordingOptions(durationSeconds: $0).durationSeconds }
    }

    static var recordingQualities: [String] {
        ScreenRecordingQuality.allCases.map(\.rawValue)
    }

    static let logLevelDisplayNames: [Int: String] =
        Dictionary(uniqueKeysWithValues: LogLevel.allCases.map { ($0.rawValue, $0.displayName) })
    static let logLevelCaseCount = LogLevel.allCases.count
    static let verboseIsLessThanError = LogLevel.verbose < LogLevel.error

    static func decodedIssueURLs(from json: Data) throws -> [String] {
        try JSONDecoder().decode(BugReportResponse.self, from: json).issueURLs
    }

    static func userFields(id: String, role: String?, email: String?) -> (id: String, role: String?, email: String?) {
        let user = BugScreenUser(id: id, role: role, email: email)
        return (user.id, user.role, user.email)
    }
}
