import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `safebox.*` lists the user's local secrets and returns their values to a
/// local terminal session. A remote session has no product need for either,
/// so the family stays off the relay allowlist, even with a workspace the
/// session owns.
@Suite("Remote relay Safebox methods")
struct RemoteRelaySafeboxPolicyTests {
    static let methods = ["safebox.list", "safebox.resolve"]

    @Test("safebox.* is never forwarded, even for an owned workspace", arguments: methods)
    func safeboxMethodIsDenied(method: String) throws {
        let workspace = UUID()
        let request: [String: Any] = [
            "id": "safebox",
            "method": method,
            "params": ["workspace_id": workspace.uuidString, "names": ["API_TOKEN"], "command": "env"],
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        let verdict = RemoteRelayCommandPolicy().evaluate(
            commandLine: line,
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [:]
        )
        guard case .deny = verdict else {
            Issue.record("\(method) was allowed through the relay")
            return
        }
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: [method]).isEmpty)
    }
}
