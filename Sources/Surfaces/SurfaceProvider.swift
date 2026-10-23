import CmuxSurfaceCatalogModel
import Foundation

/// A provider owns the resources of one machine and knows how to put one on screen.
/// Providers push resource changes into the catalog (`catalog.replaceResources`) and the
/// catalog asks them to materialize a projection. They never track projections themselves.
@MainActor
protocol SurfaceProvider: AnyObject {
    var machine: SurfaceMachineID { get }
    var info: SurfaceMachineInfo { get }
    /// Re-sync from the source of truth (local panels).
    func refresh() async
    /// Re-sync this provider, optionally bypassing provider-side caches.
    func refresh(force: Bool) async
    /// Create the pane that shows `resource` at `destination` and return the panel it created
    /// (or reused). The catalog records the projection.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Create a new terminal on this machine and return its resource.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource
    /// Called when a pane projecting one of this provider's resources goes away.
    func projectionDidEnd(_ projection: SurfaceProjection)
    /// Carries the user/lifecycle distinction to providers that care about it.
    func projectionDidEnd(_ projection: SurfaceProjection, reason: SurfaceProjectionEndReason)
    /// Called after a restore recorded projections of resources this provider has
    /// already published. Their panes are placeholders until the provider
    /// materializes them, and no later publish is guaranteed to follow.
    func projectionsRestored()
    /// Rebinds only the restored resources that became available in a publication.
    func projectionsRestored(resources: Set<SurfaceResourceID>)
    /// Close a projection's pane: a materialization that lost a race with an existing
    /// projection. The default implementation handles providers that use the shared pane
    /// factory. Return true when the provider preserved the projection, as the local
    /// provider does for a moved pane.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool
}

extension SurfaceProvider {
    func projectionDidEnd(_ projection: SurfaceProjection, reason: SurfaceProjectionEndReason) {
        projectionDidEnd(projection)
    }

    func refresh(force: Bool) async {
        await refresh()
    }

    func projectionsRestored() {}

    func projectionsRestored(resources: Set<SurfaceResourceID>) { projectionsRestored() }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}
