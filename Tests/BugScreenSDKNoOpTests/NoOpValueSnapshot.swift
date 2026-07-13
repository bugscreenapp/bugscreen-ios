import BugScreenSDKNoOp
import Foundation

/// Mirror of RealSDKValueSnapshot for the no-op module. Same shape, plain
/// primitives out, so NoOpValueParityTests can diff the two without importing
/// either SDK module (both export the same type names).
enum NoOpValueSnapshot {
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
