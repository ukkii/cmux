import CmuxSurfaceCatalogModel
import Foundation

/// How much work a catalog read may do before exporting.
enum SurfaceCatalogReadMode: Equatable, Sendable {
    /// Export what the catalog already holds. Never refreshes a provider.
    case cached
    /// Refresh one machine that is not linked yet, then export. A machine that is
    /// already connected is served from the live catalog.
    case linked
    /// Force a new provider pass, then export.
    case forced
}

/// Reads the surface catalog for socket entrypoints, which share this query owner.
@MainActor
struct SurfaceCatalogQueryService {
    private let catalog: SurfaceCatalog
    private let projectionIdentities: @MainActor ([SurfaceProjection]) -> [SurfaceProjection: SurfaceProjectionIdentity]

    init(
        catalog: SurfaceCatalog,
        projectionIdentities: @escaping @MainActor ([SurfaceProjection]) -> [SurfaceProjection: SurfaceProjectionIdentity] = { _ in [:] }
    ) {
        self.catalog = catalog
        self.projectionIdentities = projectionIdentities
    }

    func provider(for machine: SurfaceMachineID) async -> (any SurfaceProvider)? {
        catalog.provider(for: machine)
    }

    func read(machine: SurfaceMachineID?, refresh: Bool) async -> SurfaceCatalogExport {
        await read(machine: machine, mode: refresh ? .forced : .cached)
    }

    func read(machine: SurfaceMachineID?, mode: SurfaceCatalogReadMode) async -> SurfaceCatalogExport {
        switch mode {
        case .cached:
            break
        case .linked:
            // Only a machine-scoped read can ask for a link. An unfiltered
            // `.linked` read would refresh every machine, which is `.forced`.
            if let machine, !isLinked(machine) {
                await catalog.refresh(machine: machine, force: false)
            }
        case .forced:
            if let machine {
                await catalog.refresh(machine: machine, force: true)
            } else {
                await catalog.refreshAll(force: true)
            }
        }
        // No suspension between the catalog export and owner-identity capture: both
        // describe the same main-actor turn, even if the pane later moves or restores.
        var export = catalog.export
        export.projectionIdentities = projectionIdentities(export.catalog.projections)
        return export
    }

    private func isLinked(_ machine: SurfaceMachineID) -> Bool {
        catalog.provider(for: machine) != nil && catalog.machineInfo(for: machine)?.linkState == .connected
    }
}
