import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceProjectionMaterialization {
    /// Coalesces opens of one resource within an optional destination workspace.
    struct Key: Hashable {
        let resource: SurfaceResourceID
        let workspaceID: UUID?
        var machine: SurfaceMachineID { resource.machine }
    }
}
