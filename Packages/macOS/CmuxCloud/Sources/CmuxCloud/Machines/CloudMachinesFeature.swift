import CmuxSettings
import Foundation

/// The one application-side Cloud activation decision. Cloud is permanently
/// disabled in this build: every answer is `false` regardless of managed
/// policy or the persisted first-use activation marker, so no Cloud code path
/// runs. The signatures stay until the remaining call sites are removed.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudMachinesFeature: Sendable {
    public nonisolated static var disabledMessage: String {
        if ManagedDevicePolicy().isEnforced(.disableCloud) { return ManagedCloudPolicy.disabledMessage }
        return String(localized: "cloud.feature.disabled", defaultValue: "Cloud Machines are temporarily unavailable.")
    }

    /// Whether Cloud can be discovered on this Mac.
    public nonisolated static func isAvailable(policy: ManagedDevicePolicy) -> Bool {
        false
    }

    /// Whether Cloud work is enabled after local first-use activation.
    public nonisolated static func isEnabled(
        defaults: UserDefaults,
        policy: ManagedDevicePolicy
    ) -> Bool {
        false
    }

    public nonisolated static func localOptIn(defaults: UserDefaults) -> Bool {
        false
    }
}
