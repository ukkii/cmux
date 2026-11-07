import AppKit
import Foundation

/// The app's unread marks for Safebox requests: the workspace tab "Mark as
/// Unread" state for workspace panels and the Dock store's unread state for
/// Dock panels, both shown by the sidebar. Never moves focus.
@MainActor
final class SafeboxAppAttentionMarking: SafeboxAttentionMarking {
    private enum Owner {
        case workspace(Workspace)
        case dock(DockSplitStore)
    }

    private weak var appDelegate: AppDelegate?
    /// Dock unread state has no timestamp; these stand in for the identity of
    /// the Dock marks this object set.
    private var dockMarks: [UUID: Date] = [:]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func markUnread(surfaceID: UUID, workspaceID: UUID) -> Date? {
        switch owner(surfaceID: surfaceID, workspaceID: workspaceID) {
        case .workspace(let workspace):
            guard !workspace.panelIsUnread(surfaceID) else { return nil }
            workspace.markPanelUnread(surfaceID)
            return workspaceMark(workspace, surfaceID: surfaceID)
        case .dock(let dock):
            guard !dock.panelIsUnread(surfaceID),
                  dock.setDockPanelUnread(panelId: surfaceID, unread: true) else { return nil }
            let identity = Date()
            dockMarks[surfaceID] = identity
            return identity
        case nil:
            return nil
        }
    }

    func currentMark(surfaceID: UUID, workspaceID: UUID) -> Date? {
        switch owner(surfaceID: surfaceID, workspaceID: workspaceID) {
        case .workspace(let workspace):
            return workspaceMark(workspace, surfaceID: surfaceID)
        case .dock(let dock):
            // A Dock mark the user removed is noticed; one removed and set
            // again between two registry changes is not.
            guard dock.panelIsUnread(surfaceID) else {
                dockMarks[surfaceID] = nil
                return nil
            }
            return dockMarks[surfaceID] ?? .distantPast
        case nil:
            return nil
        }
    }

    func clearUnread(surfaceID: UUID, workspaceID: UUID) {
        switch owner(surfaceID: surfaceID, workspaceID: workspaceID) {
        case .workspace(let workspace):
            workspace.clearManualUnread(panelId: surfaceID)
        case .dock(let dock):
            dock.setDockPanelUnread(panelId: surfaceID, unread: false)
        case nil:
            break
        }
        dockMarks[surfaceID] = nil
    }

    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// The workspace's manual-unread timestamp for the panel; a new
    /// "Mark as Unread" sets a new one.
    private func workspaceMark(_ workspace: Workspace, surfaceID: UUID) -> Date? {
        guard workspace.manualUnreadPanelIds.contains(surfaceID) else { return nil }
        return workspace.manualUnreadMarkedAt[surfaceID]
    }

    private func owner(surfaceID: UUID, workspaceID: UUID) -> Owner? {
        guard let appDelegate else { return nil }
        if let workspace = appDelegate.workspaceContainingPanel(
            panelId: surfaceID,
            preferredWorkspaceId: workspaceID
        )?.workspace, workspace.panels[surfaceID] != nil {
            return .workspace(workspace)
        }
        if let dock = appDelegate.tabManagerFor(tabId: workspaceID)?
            .dockSplitStore(ownerID: workspaceID, containingPanel: surfaceID)
            ?? appDelegate.windowDockContainingPanel(surfaceID) {
            return .dock(dock)
        }
        return nil
    }
}
