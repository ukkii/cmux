import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceAgentNameContext {
    public func renameRequest(name: String) -> CloudTuiRequest {
        CloudTuiRequest("tab.rename", ["tab": projection.remoteTabID ?? "", "workspace": projection.remoteWorkspaceID ?? "",
            "name": name, "source": "auto", "expected_generation": generation,
            "expected_name_revision": String(nameRevision)], mutation: true)
    }

    /// Preserve this callback's identity and revision when encoding the daemon command.
    func renameArguments(socketPath: String, name: String) -> [String] {
        CloudTuiCommandLine.renameTabArguments(
            socketPath: socketPath, tabID: projection.remoteTabID ?? "", name: name
        ) + ["--workspace", projection.remoteWorkspaceID ?? "",
             "--source", "auto", "--expected-generation", generation,
             "--expected-name-revision", String(nameRevision)]
    }
}
