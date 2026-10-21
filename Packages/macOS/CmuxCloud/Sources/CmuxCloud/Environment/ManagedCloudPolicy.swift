import CmuxSettings
import Foundation

/// MDM master switch for cmux Cloud (`DisableCloud`), for the gates that
/// have no injectable resolver of their own: the action chokepoint, the
/// non-`vm.*` control-plane socket verbs, and the control-plane clients.
/// `VMClient`, the tunnel coordinator, and session restore keep their
/// injected resolvers.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedCloudPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableCloud`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableCloud)
    }

    public static var isEnabled: Bool { !isDisabled }

    /// The stable socket error code every Cloud refusal carries.
    public static let socketErrorCode = "cloud_disabled"

    public static var disabledMessage: String {
        String(
            localized: "cloud.managed.disabled",
            defaultValue: "Cloud Machines are disabled by your administrator."
        )
    }
}

/// MDM master switch for uploading local AI credentials (Claude/Codex OAuth
/// tokens, Anthropic/OpenAI API keys) to the cmux tenant. Independent of
/// `DisableCloud`, which already refuses the same families.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedAICredentialUploadPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableAICredentialUpload`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableAICredentialUpload)
    }

    public static var isEnabled: Bool { !isDisabled }

    public static let socketErrorCode = "ai_credential_upload_disabled"

    public static var disabledMessage: String {
        String(
            localized: "managedPolicy.aiCredentialUpload.disabled",
            defaultValue: "Uploading AI account credentials is disabled by your organization."
        )
    }

    public static func refusalError() -> ManagedPolicyRefusal {
        ManagedPolicyRefusal(message: disabledMessage)
    }
}
