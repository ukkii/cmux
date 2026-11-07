import Foundation

/// Identifies the terminal session a secret is granted to. Grants match on both
/// fields, so a new agent session in the same surface has a different key and
/// is asked again.
struct SafeboxSessionKey: Hashable, Sendable {
    let surfaceID: UUID
    let agentSessionID: String?
}
