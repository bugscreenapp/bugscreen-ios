import Foundation

/// The account a bug report was filed under — the test login a triager needs to
/// reproduce the issue.
///
/// Set it eagerly with ``BugScreenSDK/setUser(id:role:email:)``, or supply it
/// lazily with ``BugScreenSDK/setUserProvider(_:)`` so it is read fresh at capture
/// time (when the report screen opens) rather than pushed on login. The backend
/// renders it as a dedicated Account section at the top of the created issue.
///
/// Privacy: `id` and `role` are the intended fields — `role` is promoted to a
/// filterable label on the issue. `email` is optional and off by default; only
/// pass it when your team explicitly wants a contactable address in the tracker.
/// Nothing is auto-collected.
public struct BugScreenUser: Sendable, Equatable {
    /// Stable account identifier (e.g. your internal user id). Required.
    public let id: String
    /// Account role or tier (e.g. `admin`, `pro`). Optional.
    public let role: String?
    /// Contact email. Optional; attach only when opted in.
    public let email: String?

    public init(id: String, role: String? = nil, email: String? = nil) {
        self.id = id
        self.role = role
        self.email = email
    }
}

/// Reserved customData keys the backend partitions into the Account section. The
/// `bugscreen.account.` prefix is a machine key that can never collide with the
/// SDK's human-readable device labels.
enum AccountKeys {
    static let prefix = "bugscreen.account."
    static let id = prefix + "id"
    static let role = prefix + "role"
    static let email = prefix + "email"
}

extension BugScreenUser {
    /// Flatten a user into the reserved account keys merged into the report
    /// metadata. Blank fields are dropped so an empty section never renders.
    func toReservedKeys() -> [String: String] {
        var out: [String: String] = [:]
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedID.isEmpty { out[AccountKeys.id] = trimmedID }
        if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            out[AccountKeys.role] = role
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            out[AccountKeys.email] = email
        }
        return out
    }
}
