/// Metadata for a registered runtime feature flag.
struct CmuxFeatureFlagDefinition: Identifiable, Equatable, Sendable {
    var id: String { key }

    let key: String
    let title: String
    let flagDescription: String
    let defaultWhenUnavailable: Bool
}
