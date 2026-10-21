import Foundation

/// Which local notification records a read action covers, in the local
/// store's own terms. Mirrors `TerminalNotification.matches(tabId:surfaceId:)`:
/// `.workspace` covers every record in the workspace, `.surface` with a nil
/// surface covers only the workspace-level records, and `.all` covers
/// everything. Cloud rows are placed with the same vocabulary, so a read of a
/// target also covers the rows that would land there.
public enum NotificationReadTarget: Equatable, Sendable {
    case all
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID?)
}
