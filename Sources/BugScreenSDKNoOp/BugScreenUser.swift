import Foundation

/// No-op mirror of ``BugScreenSDK/BugScreenUser``. Public value type reproduced
/// verbatim; the real SDK's internal `AccountKeys` / `toReservedKeys()` helpers are
/// omitted because the stub never assembles report metadata.
public struct BugScreenUser: Sendable, Equatable {
    public let id: String
    public let role: String?
    public let email: String?

    public init(id: String, role: String? = nil, email: String? = nil) {
        self.id = id
        self.role = role
        self.email = email
    }
}
