import Foundation

extension FileExplorerStore {
    /// Shared by the right sidebar and tool panes; owns the workspace root observation.
    func syncWorkspaceRoot(from workspace: Workspace) {
        if workspaceRootObservation?.workspace !== workspace {
            workspaceRootObservation?.stop()
            workspaceRootObservation = FileExplorerWorkspaceObservation(
                workspace: workspace, resolver: FileExplorerWorkspaceRootResolver(),
                apply: { [weak self] in self?.applyWorkspaceRoot($0) }
            )
        }
        workspaceRootObservation?.refresh()
    }
}
