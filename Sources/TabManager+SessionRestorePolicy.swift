import Foundation

extension TabManager {
    /// Whether a snapshot belongs to the removed cmux Cloud product: a legacy
    /// managed Cloud VM remote (`managedCloudVMID`) or a cmux-tui Cloud binding
    /// (`cloudVM`). Such workspaces are dropped from restore.
    static func isLegacyCloudWorkspaceSnapshot(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        if snapshot.cloudVM != nil { return true }
        guard let managedCloudVMID = snapshot.remote?.managedCloudVMID else { return false }
        return !managedCloudVMID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reconciles task-create provenance only when the caller owns a cache.
    /// A nil cache intentionally leaves unrelated snapshot restores isolated.
    static func recordRestoredTaskCreateProvenance(
        for workspace: Workspace,
        in cache: TerminalController.WorkspaceCreateIdempotencyCache?
    ) {
        guard let operationID = workspace.taskCreateOperationID, let cache else { return }
        cache.record(operationID: operationID, workspaceID: workspace.id)
    }
}
