import CmuxSSHClipboardTrust
import CmuxSurfaceCatalogModel
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHClipboardWriteTrustStoreTests {
    @Test("Dock trust propagation resolves transferred terminal ownership")
    @MainActor
    func dockClipboardMachineUsesDockOwnershipFallback() throws {
        let machine = SurfaceMachineID.ssh("dock-ssh-machine")
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: dock.workspaceId)
        panel.retainTransferredSurfaceMachine(machine)
        dock.panels[panel.id] = panel

        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        #expect(GhosttyNSView.sshClipboardMachine(for: panel, dock: dock, ownership: ownership) == machine)
    }

    @Test("Dock trust prefers transferred SSH ownership over a local placeholder")
    @MainActor
    func dockClipboardMachineSkipsLocalCatalogPlaceholder() throws {
        let machine = SurfaceMachineID.ssh("dock-aliased-ssh-machine")
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: dock.workspaceId)
        panel.retainTransferredSurfaceMachine(machine)
        dock.panels[panel.id] = panel

        let localProjection = SurfaceProjection(
            resource: SurfaceResourceID(
                machine: .local,
                kind: .terminal,
                key: panel.id.uuidString
            ),
            workspaceID: dock.workspaceId,
            panelID: panel.id
        )
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(
            projections: [localProjection],
            pendingRestores: []
        )
        #expect(GhosttyNSView.sshClipboardMachine(for: panel, dock: dock, ownership: ownership) == machine)
    }

    @Test("Workspace trust lookup skips a local placeholder for transferred SSH ownership")
    @MainActor
    func workspaceClipboardMachineSkipsLocalCatalogPlaceholder() throws {
        let machine = SurfaceMachineID.ssh("workspace-aliased-ssh-machine")
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceId: workspace.id)
        panel.retainTransferredSurfaceMachine(machine)
        workspace.panels[panel.id] = panel

        let localProjection = SurfaceProjection(
            resource: SurfaceResourceID(
                machine: .local,
                kind: .terminal,
                key: panel.id.uuidString
            ),
            workspaceID: workspace.id,
            panelID: panel.id
        )
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(
            projections: [localProjection],
            pendingRestores: []
        )

        #expect(workspace.sshClipboardMachine(for: panel.id, ownership: ownership) == machine)
    }

    @Test("plain SSH tmux mirrors keep the grant for future nested panes")
    @MainActor
    func plainSSHMirrorUsesHostIdentityForNewPanes() throws {
        let suiteName = "cmux.ssh-clipboard-remote-tmux-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHClipboardWriteTrustStore(defaults: defaults)
        let host = RemoteTmuxHost(
            destination: "user@example.test",
            port: 2222,
            identityFile: "/tmp/id_test"
        )
        let configuration = WorkspaceRemoteConfiguration(
            destination: host.destination,
            port: host.port,
            identityFile: host.identityFile,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let machine = SurfaceMachineID.ssh(configuration.sshClipboardIdentityDigest)
        store.setTrusted(true, for: machine)

        let manager = TabManager(sshClipboardWriteTrustStore: store)
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let firstLayout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(4)
        )
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: 80, height: 24, layout: firstLayout
        )
        connection.windowOrder = [1]
        connection.activePaneByWindow[1] = 4
        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }

        let windowMirror = try #require(sessionMirror.windowMirrorByWindowId[1])
        let firstPanel = try #require(windowMirror.panel(forPane: 4))
        #expect(firstPanel.surface.allowsRemoteClipboardWrites)
        #expect(workspace.sshClipboardMachine(
            for: firstPanel.id,
            ownership: SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        ) == machine)
        #expect(workspace.sshClipboardMachine(
            for: windowMirror.panelId,
            ownership: SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        ) == machine)

        let splitLayout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(4)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(5)),
            ])
        )
        windowMirror.apply(window: RemoteTmuxWindow(
            id: 1, name: "main", width: 80, height: 24, layout: splitLayout
        ))

        let newPanel = try #require(windowMirror.panel(forPane: 5))
        #expect(newPanel.surface.allowsRemoteClipboardWrites)

        // Keep only the mirror ownership: wrapper removal must not strand the
        // original or later split pane's grant.
        workspace.panels.removeValue(forKey: windowMirror.panelId)
        store.setTrusted(false, for: machine)
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(projections: [], pendingRestores: [])
        #expect(workspace.sshClipboardMachine(for: windowMirror.panelId, ownership: ownership) == machine)
        workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        #expect(!firstPanel.surface.allowsRemoteClipboardWrites)
        #expect(!newPanel.surface.allowsRemoteClipboardWrites)
    }
}
