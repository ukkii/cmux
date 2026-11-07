import Foundation

/// Non-secret information about a stored secret. Never contains the value.
struct SafeboxSecretMetadata: Codable, Equatable, Sendable {
    var name: SafeboxSecretName
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
}
