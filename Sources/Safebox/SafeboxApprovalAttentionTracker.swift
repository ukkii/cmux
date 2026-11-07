import Foundation
import Observation

/// Where the attention tracker sets and clears unread marks. The app's
/// implementation goes through the workspace and Dock unread paths the sidebar
/// already shows; tests use a fake.
@MainActor
protocol SafeboxAttentionMarking: AnyObject {
    /// Marks the surface unread. Returns the identity of the mark when this
    /// call set it, nil when the surface was already unread or is not found.
    func markUnread(surfaceID: UUID, workspaceID: UUID) -> Date?
    /// The identity of the surface's current unread mark, nil when it has none.
    /// A mark the user removed and set again has a new identity.
    func currentMark(surfaceID: UUID, workspaceID: UUID) -> Date?
    func clearUnread(surfaceID: UUID, workspaceID: UUID)
    /// Posts an accessibility announcement without moving focus.
    func announce(_ message: String)
}

/// Marks a terminal tab unread while its surface has a pending Safebox
/// approval request, clears that mark when the last request of the surface
/// is answered, times out or is dropped, and announces each new request to
/// assistive technology.
///
/// It never moves focus or activates the app. It clears only a mark it set
/// that is still the current one: a tab the user had already marked unread,
/// or marked read and unread again while the request was pending, keeps its
/// mark.
@MainActor
final class SafeboxApprovalAttentionTracker {
    private struct OwnedMark {
        let workspaceID: UUID
        let identity: Date
    }

    private let registry: SafeboxApprovalRegistry
    private let target: SafeboxAttentionMarking

    /// Pending surfaces and the workspace of their oldest request.
    private var pendingWorkspaceBySurface: [UUID: UUID] = [:]
    private var ownedMarks: [UUID: OwnedMark] = [:]
    private var isStarted = false

    init(registry: SafeboxApprovalRegistry, target: SafeboxAttentionMarking) {
        self.registry = registry
        self.target = target
    }

    /// Follows the registry's pending requests from now on.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observe()
    }

    func sync(_ pendingRequests: [SafeboxApprovalRequest]) {
        var pending: [UUID: UUID] = [:]
        for request in pendingRequests where pending[request.session.surfaceID] == nil {
            pending[request.session.surfaceID] = request.workspaceID
        }

        // A mark that changed since the tracker set it belongs to the user now.
        for (surfaceID, owned) in ownedMarks
        where target.currentMark(surfaceID: surfaceID, workspaceID: owned.workspaceID) != owned.identity {
            ownedMarks[surfaceID] = nil
        }

        for (surfaceID, workspaceID) in pending where pendingWorkspaceBySurface[surfaceID] == nil {
            if let identity = target.markUnread(surfaceID: surfaceID, workspaceID: workspaceID) {
                ownedMarks[surfaceID] = OwnedMark(workspaceID: workspaceID, identity: identity)
            }
            let lines = SafeboxApprovalBannerModel(approvals: registry, surfaceID: surfaceID)
                .presentation?.lines.map(\.text) ?? []
            if !lines.isEmpty {
                target.announce(lines.joined(separator: ". "))
            }
        }

        for surfaceID in pendingWorkspaceBySurface.keys where pending[surfaceID] == nil {
            guard let owned = ownedMarks.removeValue(forKey: surfaceID) else { continue }
            target.clearUnread(surfaceID: surfaceID, workspaceID: owned.workspaceID)
        }
        pendingWorkspaceBySurface = pending
    }

    private func observe() {
        // Only the read of `pendingRequests` is tracked; the unread updates in
        // `sync` run outside the tracking scope.
        let pending = withObservationTracking {
            registry.pendingRequests
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        sync(pending)
    }
}
