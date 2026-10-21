import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// A provider that persists automatic names with a daemon-side user/epoch check.
@MainActor
protocol SurfaceAgentNaming: SurfaceProvider {
    func renameAgentTab(context: SurfaceAgentNameContext, name: String) async throws
}
