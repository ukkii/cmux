import CmuxSettings
import Foundation

/// Resolves which override policy a feature flag uses from the installed app
/// identity. Every flag is remote-first: a delivered value outranks a local
/// override, and the app delivers none, so local overrides apply.
struct CmuxFeatureFlagOverrideCapability: Equatable, Sendable {
    let isDebugBuild: Bool
    let isTaggedDebugArtifact: Bool

    init(bundle: Bundle = .main) {
        #if DEBUG
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: true)
        #else
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: false)
        #endif
    }

    init(bundleIdentifier: String?, isDebugBuild: Bool) {
        self.isDebugBuild = isDebugBuild
        let debugID = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        isTaggedDebugArtifact = isDebugBuild && bundleIdentifier?.hasPrefix(debugID + ".") == true
    }

    func policy(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagOverridePolicy {
        _ = definition
        return .remoteFirst
    }
}
