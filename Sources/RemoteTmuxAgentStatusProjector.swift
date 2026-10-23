import CmuxFoundation
import CmuxSidebar
import CmuxSurfaceCatalogModel
import Foundation

/// Aggregates mirrored tmux panes into their window panels and workspace sidebar.
/// Owns only the status/lifecycle slots it wrote; idle never enables hibernation.
@MainActor
final class RemoteTmuxAgentStatusProjector {
    private var lifecycleKeysByPanel: [UUID: Set<String>] = [:]
    private var statusKeys: Set<String> = []

    func reconcile(statuses: [Int: RemoteTmuxAgentStatus], panelByPane: [Int: UUID], workspace: Workspace) {
        var byPanel: [UUID: [RemoteAgentSidebarStatus]] = [:]
        for (pane, status) in statuses {
            guard let panel = panelByPane[pane], workspace.panels[panel] != nil else { continue }
            byPanel[panel, default: []].append(status.sidebarStatus)
        }
        var nextKeys: [UUID: Set<String>] = [:]
        for (panel, statuses) in byPanel {
            for (key, activity) in RemoteAgentSidebarStatus.workspaceSlots(statuses) {
                guard let lifecycle = Self.lifecycle(for: activity) else { continue }
                if workspace.agentLifecycleStatesByPanelId[panel]?[key] != lifecycle {
                    workspace.setAgentLifecycle(key: key, panelId: panel, lifecycle: lifecycle)
                }
                nextKeys[panel, default: []].insert(key)
            }
        }
        for (panel, keys) in lifecycleKeysByPanel {
            for key in keys.subtracting(nextKeys[panel] ?? []) {
                workspace.clearAgentLifecycle(key: key, panelId: panel)
            }
        }
        lifecycleKeysByPanel = nextKeys

        // Apply entries after clearing old lifecycle slots: clearAgentLifecycle also
        // removes the panel's previous entry, and idle has no lifecycle to retain.
        for (panel, statuses) in byPanel {
            for (key, activity) in RemoteAgentSidebarStatus.workspaceSlots(statuses) {
                let entry = Self.statusEntry(key: key, activity: activity)
                if let current = workspace.agentStatusEntry(key: key, panelId: panel),
                   current.value == entry.value, current.icon == entry.icon,
                   current.color == entry.color, current.priority == entry.priority {
                    continue
                }
                workspace.setStatusEntry(entry, key: key, panelId: panel)
            }
        }

        let slots = RemoteAgentSidebarStatus.workspaceSlots(byPanel.values.flatMap { $0 })
        for key in statusKeys where slots[key] == nil { workspace.removeStatusEntry(forKey: key) }
        for (key, activity) in slots {
            let entry = Self.statusEntry(key: key, activity: activity)
            // Panel writes above are intentionally retained for panel-local rows,
            // but the workspace row must use the aggregate winner. Dictionary
            // iteration order is not an urgency policy.
            workspace.setStatusEntry(entry, key: key, panelId: nil)
        }
        statusKeys = Set(slots.keys)
    }

    /// Idle stays out of the lifecycle map: an idle lifecycle marks a panel
    /// eligible for agent hibernation, which only applies to local agents.
    static func lifecycle(for activity: RemoteAgentSidebarStatus.Activity) -> AgentHibernationLifecycleState? {
        switch activity {
        case .running: .running
        case .needsInput: .needsInput
        case .idle: nil
        }
    }

    /// The same text, symbol, and color the local agent hooks write.
    static func statusEntry(key: String, activity: RemoteAgentSidebarStatus.Activity) -> SidebarStatusEntry {
        switch activity {
        case .running:
            SidebarStatusEntry(key: key, value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
                               icon: "bolt.fill", color: CmuxAccentColor.builtInAgentStatusHex, timestamp: Date())
        case .needsInput:
            SidebarStatusEntry(key: key, value: String(localized: "feed.status.needsInput", defaultValue: "Needs input"),
                               icon: "bell.fill", color: CmuxAccentColor.builtInAgentStatusHex, priority: 100, timestamp: Date())
        case .idle:
            SidebarStatusEntry(key: key, value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
                               icon: "pause.circle.fill", color: "#8E8E93", timestamp: Date())
        }
    }
}
