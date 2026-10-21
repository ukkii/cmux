import CmuxCloudTui
import CmuxTerminalSizing
import Foundation

/// Shared terminal sizing was removed with mobile pairing. The Cloud mirror
/// keeps its call sites until Cloud itself is removed, so this relay never
/// negotiates `shared-sizing-v1` and every daemon takes the legacy claim path.
struct CloudMirrorInertSizingRelay {
    /// The daemon capability shared sizing would negotiate; never requested.
    static let capability = "shared-sizing-v1"

    var isSupported: Bool { false }
    var selfParticipantID: String? { nil }
    var state: TerminalSizingState? { nil }

    func connectionStarted(capabilities: Set<String>) {}
    func noteHostParticipant(_ participant: String, forView view: String) {}
}

/// Placeholder for a remote "disconnected by" detachment, which only shared
/// sizing produced.
struct CloudMirrorSharingDetachment {}

@MainActor
extension CloudTuiManualMirrorSession {
    func bindSharing(surfaceID: UUID) {}

    func unbindSharing() {}

    /// This Mac's sizing identity; only sent when shared sizing is negotiated.
    static func localSharingIdentity() -> TerminalSizingParticipant {
        TerminalSizingParticipant(id: "", deviceKind: .mac)
    }

    func sharingSelfIdentity() -> TerminalSizingParticipant {
        Self.localSharingIdentity()
    }

    func sharingAttached(selfParticipantID: String?) {}

    func receiveSizeState(_ state: TerminalSizingState) {}

    func publishSharingSnapshot() {}

    func handleSharingDetached(reason: TerminalDetachReason, view: String?, viewOnly: Bool = false) {
        guard !viewOnly, !reason.reconnectsAutomatically else { return }
        disconnectForSharing(reconnect: false)
    }

    func sendSharingFocusActivity() {}
}
