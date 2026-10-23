import Foundation

/// A callback's read precondition, captured before an agent computes its title.
/// Names never identify a resource: the full projection and daemon generation do.
/// The wire encoding is opaque to callers; it round-trips through the socket unchanged.
public struct SurfaceAgentNameContext: Hashable, Codable, Sendable {
    public let projection: SurfaceProjection
    public let generation: String
    public let nameRevision: UInt64

    public init?(projection: SurfaceProjection, state: CloudVMState) {
        guard let tabID = projection.remoteTabID,
              let tab = state.lookupIndex.tab(id: tabID),
              tab.contentKind == "terminal", tab.contentID == projection.resource.key,
              let pane = state.lookupIndex.pane(id: tab.paneID),
              let screen = state.lookupIndex.screen(id: pane.screenID),
              screen.workspaceID == projection.remoteWorkspaceID,
              let authority = tab.nameAuthority,
              tab.name == nil || authority.source == .auto,
              let cursor = state.cursor else { return nil }
        self.projection = projection
        generation = cursor.generation
        nameRevision = authority.revision
    }

    public init?(wire: Any?) {
        guard let wire, JSONSerialization.isValidJSONObject(wire),
              let bytes = try? JSONSerialization.data(withJSONObject: wire),
              let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        self = value
    }

    public var wire: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
