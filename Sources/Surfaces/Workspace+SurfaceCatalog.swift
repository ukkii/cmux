import CmuxSurfaceCatalogModel
import Foundation

/// The workspace's side of the surface catalog: the single seams through which a pane
/// joins, leaves, moves between, or changes inside a workspace tell the local provider.
extension Workspace {
    /// The live workspace with `id` in any window, or nil once it was retired.
    static func liveWorkspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    /// Called from `panelsWillChange(to:)` with the old set still in `panels`.
    func surfaceCatalogPanelsWillChange(to newValue: [UUID: any Panel]) {
        let provider = LocalSurfaceProvider.shared
        let old = panels
        for (panelID, panel) in newValue where old[panelID] == nil {
            provider.panelDidAppear(panel, in: self)
        }
        for panelID in old.keys where newValue[panelID] == nil {
            // A pane in flight to another workspace keeps its resource; the target's
            // `panelDidAppear` moves the projection.
            if surfaceTransferringPanelIds.contains(panelID) { continue }
            provider.panelWillDisappear(panelID: panelID)
        }
    }

    /// Titles and working directories are per-workspace dictionaries; forward the keys
    /// whose value changed so the local resource follows the tab bar.
    func surfaceCatalogPanelMetadataDidChange(old: [UUID: String], new: [UUID: String]) {
        guard old != new else { return }
        let provider = LocalSurfaceProvider.shared
        for panelID in Set(old.keys).union(new.keys) where old[panelID] != new[panelID] {
            provider.panelDidChange(panelID: panelID, in: self)
        }
    }
}
