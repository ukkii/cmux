import CmuxSSHClipboardTrust
import AppKit
import Bonsplit
import CmuxCore
import CmuxFoundation
import CmuxSurfaceCatalogModel
import CryptoKit
import Foundation

extension WorkspaceRemoteConfiguration {
    /// Stable digest of the SSH route inputs (destination, port, identity, persistent
    /// options). The SSH clipboard trust store keys its per-host grants by this value,
    /// so it must stay byte-compatible with grants persisted by earlier builds.
    var sshClipboardIdentityDigest: String {
        let resolver = SSHAgentSocketResolver(environment: [:])
        let persistentOptions = sshOptions.filter {
            let key = resolver.optionKey($0) ?? ""
            return !["controlmaster", "controlpersist", "controlpath"].contains(key)
        }
        var components = [destination, port.map(String.init) ?? "", identityFile ?? ""] + persistentOptions
        if let routeIdentifier = routeSensitiveIdentifier {
            components.append(routeIdentifier)
        } else if routeSensitivity == .unidentified {
            // Before the marker moved out of the options, the `true`
            // placeholder was hashed as one of them.
            components.append(SSHConnectionSharingOptions.unidentifiedRouteSensitiveMarkerOption)
        }
        return SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension Workspace {
    /// The configured SSH identity for this workspace, when present.
    var configuredSSHClipboardMachine: SurfaceMachineID? {
        guard let configuration = remoteConfiguration,
              configuration.transport == .ssh else { return nil }
        return .ssh(configuration.sshClipboardIdentityDigest)
    }

    /// The SSH identity for a plain `ssh-tmux` mirror, when this workspace is
    /// backed by one. Plain mirrors do not have a ``remoteConfiguration``;
    /// derive the same endpoint digest from the mirror host that the trust menu
    /// and newly-created manual panes use.
    var remoteTmuxSSHClipboardMachine: SurfaceMachineID? {
        guard let host = remoteTmuxSessionMirror?.host,
              host.transport == .ssh else { return nil }
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
        return .ssh(configuration.sshClipboardIdentityDigest)
    }

    /// Whether a new pane created by this plain `ssh-tmux` mirror may emit OSC 52.
    var allowsRemoteTmuxClipboardWrites: Bool {
        guard let machine = remoteTmuxSSHClipboardMachine else { return false }
        return sshClipboardWriteTrustStore.allowsRemoteClipboardWrites(for: machine)
    }

    /// Every workspace on this Mac accepts surfaces from any machine.
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        SurfaceOwnershipPolicy(cloudMachine: nil)
    }

    /// A pane's projection or remote transport owns its machine, never its title
    /// or merely the workspace it happens to be displayed in.
    func machineOwningSurface(_ panelID: UUID, catalog: SurfaceCatalog? = nil) -> SurfaceMachineID? {
        let catalog = catalog ?? SurfaceCatalog.shared
        guard panels[panelID] != nil else { return nil }
        if let machine = catalog.machineOwningPanel(panelID), !machine.isLocal { return machine }
        return panels[panelID]?.transferredSurfaceMachine ?? .local
    }

    /// Returns the machine identity for a terminal surface, including a pane
    /// owned by a nested remote-tmux window mirror.
    func sshClipboardMachine(
        for panelID: UUID,
        ownership: SSHClipboardWriteSurfaceOwnershipIndex
    ) -> SurfaceMachineID? {
        // A local catalog projection can be a placeholder while a transferred
        // SSH surface is still being restored. Keep it as a final fallback,
        // but let the live session, mirror host, or transfer ownership resolve
        // the actual remote machine first.
        let catalogMachine = ownership.machine(for: panelID)
        if let machine = catalogMachine, !machine.isLocal {
            return machine
        }

        // A window container remains an owner even when its terminal panel
        // has retired. Catalog ownership above takes precedence over its host.
        if remoteTmuxWindowMirrors[panelID] != nil {
            return remoteTmuxSSHClipboardMachine
        }

        guard let panel = panels[panelID] else {
            // Inner panes are mirror-owned, not Workspace.panels entries. This
            // lookup is needed for a single context-menu target, never per
            // ordinary panel in a batch propagation pass.
            guard let containerID = remoteTmuxWindowMirrors.first(where: { _, mirror in
                mirror.panelsByPaneId.values.contains { $0.id == panelID }
            })?.key else { return nil }
            return sshClipboardMachine(for: containerID, ownership: ownership)
        }
        if let terminal = panel as? TerminalPanel,
           terminal.surface.ioMode == .manualMirror {
            // An unprojected generic/device mirror cannot borrow the SSH
            // identity of the workspace it happens to be displayed in.
            return panel.transferredSurfaceMachine
        }
        return panel.transferredSurfaceMachine ?? catalogMachine ?? .local
    }

    /// Reconciles every live terminal surface owned by `machine` from the
    /// injected trust store, including panes outside `Workspace.panels`.
    @MainActor
    func applySSHClipboardWritePermission(
        for machine: SurfaceMachineID,
        ownership: SSHClipboardWriteSurfaceOwnershipIndex
    ) {
        let allowed = sshClipboardWriteTrustStore.allowsRemoteClipboardWrites(for: machine)
        for panel in panels.values.compactMap({ $0 as? TerminalPanel })
        where sshClipboardMachine(for: panel.id, ownership: ownership) == machine {
            panel.surface.setAllowsRemoteClipboardWrites(allowed)
        }

        for (containerID, mirror) in remoteTmuxWindowMirrors
        where sshClipboardMachine(for: containerID, ownership: ownership) == machine {
            for panel in mirror.panelsByPaneId.values {
                panel.surface.setAllowsRemoteClipboardWrites(allowed)
            }
        }
    }

    func surfaceDropRejection(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source
    ) -> SurfaceTransferRejection? {
        guard surfaceOwnershipPolicy.cloudMachine != nil else { return nil }
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: surfaceOwnershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return surfaceOwnershipPolicy.rejection(for: nil) }
            // A surface already in this workspace crosses no machine boundary when
            // it is reordered or split within it.
            if panelIdFromSurfaceId(TabID(uuid: transfer.tabId)) != nil { return nil }
            guard let app = AppDelegate.shared else { return surfaceOwnershipPolicy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: surfaceOwnershipPolicy)
        case .vaultSession, .filePreview, .rightSidebarTool, .chiefConversation:
            return surfaceOwnershipPolicy.rejection(for: .local)
        case .workspaceMerge:
            // `canMergeWorkspace` checks every tab's machine; a refused merge stays quiet.
            return nil
        }
    }

    func surfaceDropRejection(_ transfer: TabDragTransfer) -> SurfaceTransferRejection? {
        let paneTransfer = PaneDragTransfer(tabDragTransfer: transfer)
        guard let source = PaneTransferSourceResolver().source(for: paneTransfer) else {
            return surfaceOwnershipPolicy.rejection(for: nil)
        }
        return surfaceDropRejection(paneTransfer, source: source)
    }

    func acceptsSurface(from source: Workspace, panelID: UUID) -> Bool {
        !isRetiredFromOwningTabManager
            && surfaceOwnershipPolicy.rejection(for: source.machineOwningSurface(panelID),
                                                kind: AppDelegate.shared?.surfaceResourceKind(for: source.panels[panelID])) == nil
    }

    func acceptsDetachedSurface(_ transfer: DetachedSurfaceTransfer) -> Bool {
        // A failed transfer must be able to restore the exact source, including
        // pre-existing mixed workspaces created before ownership was enforced.
        if transfer.origin == .workspace(id) { return true }
        let machine = transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? .local
        return surfaceOwnershipPolicy.rejection(for: machine, kind: AppDelegate.shared?.surfaceResourceKind(for: transfer.panel)) == nil
    }
}
