import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceProvider {
    /// Checks the provider receipt before it can become a catalog projection.
    func materializeValidated(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        let projection = try await materialize(resource, at: destination, focus: focus)
        guard projection.resource == resource.id,
              projection.workspaceID == destination.workspaceID else {
            discardMaterialization(projection)
            throw SurfaceCatalogError.unavailable(resource.id, reason: "the provider opened a different surface")
        }
        return projection
    }
}
