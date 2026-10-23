import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// The provider rows every sidebar and CLI reader sees.
    var snapshot: SurfaceCatalogSnapshot {
        SurfaceCatalogSnapshot(
            machines: machines.values.sorted {
                if $0.id.isLocal != $1.id.isLocal { return $0.id.isLocal }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            resources: resources.values.sorted(by: Self.catalogOrder),
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        )
    }

    /// Stable catalog order shared by whole-catalog and machine-scoped snapshots.
    nonisolated static func catalogOrder(_ lhs: SurfaceResource, _ rhs: SurfaceResource) -> Bool {
        if lhs.machine != rhs.machine { return lhs.machine.rawValue < rhs.machine.rawValue }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.key < rhs.id.key
    }

    /// Complete export for the local control socket.
    var export: SurfaceCatalogExport {
        SurfaceCatalogExport(catalog: snapshot, cloudStates: [])
    }
}
