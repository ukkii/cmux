import CmuxControlSocket
import Darwin
import Foundation

/// `safebox.*`: secrets for commands run from cmux terminals (`cmux safebox`).
///
/// Both methods run on the socket worker (`ControlCommandExecutionPolicy`);
/// `safebox.resolve` can wait up to the approval timeout for the user's
/// answer, parked outside the socket's running slots while it waits. Neither is in the remote relay allowlist (`RemoteRelayCommandPolicy`
/// denies by default) and both refuse relay provenance again here: they read
/// the user's local secrets. The caller's pane comes from the socket peer's
/// process (its controlling terminal), never from a `surface_id` the caller
/// sends.
extension TerminalController {
    nonisolated func safeboxResponse(_ request: ControlRequest) async -> String {
        let result = await safeboxResult(request)
        return Self.v2Encoder.response(id: request.id, Self.controlCallResult(fromLegacy: result))
    }

    /// Internal so tests can pin the relay refusal; the socket calls
    /// ``safeboxResponse(_:)``.
    nonisolated func safeboxResult(_ request: ControlRequest) async -> V2CallResult {
        // Defense in depth: the relay policy already denies `safebox.*`.
        if request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil {
            return .err(
                code: "not_authorized",
                message: String(
                    localized: "safebox.socket.error.remoteDenied",
                    defaultValue: "Safebox is not available through a remote session."
                ),
                data: nil
            )
        }
        switch request.method {
        case "safebox.list":
            guard let service = await Self.safeboxService() else { return Self.safeboxUnavailable }
            return await service.list()
        case "safebox.resolve":
            let peer = SocketCommandTaskPolicy.peerProcessID
            let context = await Task { @MainActor in
                (service: Self.safeboxService(), caller: Self.safeboxCaller(peer: peer))
            }.value
            guard let service = context.service else { return Self.safeboxUnavailable }
            let pool = socketClientWorkerPool
            return await service.resolve(
                params: request.params.mapValues(\.foundationObject),
                caller: context.caller,
                // The approval wait can last the whole timeout: park outside
                // the running slots the way a blocking `feed.push` does.
                // In-process callers are not pool jobs and simply proceed.
                parkBeforeWaiting: { await pool.parkCurrentJob() != .parkedJobsFull }
            )
        default:
            return .err(
                code: "method_not_found",
                message: String(localized: "socket.error.unknownMethod", defaultValue: "Unknown method"),
                data: nil
            )
        }
    }

    /// Hides every revealed Safebox value and the editor's visible value field
    /// in every window, synchronously, before cmux captures one of its own
    /// windows (`window.screenshot`, `window.record.start`,
    /// `debug.window.screenshot`): these do not make cmux resign active, so
    /// the usual hide triggers do not run.
    @MainActor
    static func concealSafeboxValuesForCapture() {
        AppDelegate.shared?.safeboxCaptureConcealment.concealForCapture()
    }

    @MainActor
    private static func safeboxService() -> SafeboxSocketService? {
        AppDelegate.shared?.safeboxSocketService
    }

    /// The session of the cmux terminal pane the peer runs in, or nil when it
    /// runs in none. Every process of the pane (the agent, its subagents and
    /// the commands they start) shares the key: the pane's surface plus the
    /// agent session cmux's hooks recorded for it, when there is one.
    ///
    /// Only PTYs the panes own count (``AppDelegate/safeboxOwnedTTYBindings()``),
    /// never a TTY a socket client reported with `surface.report_tty`: any
    /// local client can report one, which would let it act as another pane.
    @MainActor
    private static func safeboxCaller(peer: pid_t?) -> SafeboxCaller? {
        guard let app = AppDelegate.shared else { return nil }
        let terminals = app.safeboxOwnedTTYBindings()
        let locator = SafeboxCallerLocator(
            host: getpid(),
            identity: { pid in
                agentLiveProcessIdentity(pid: pid).map {
                    SafeboxCallerLocator.Identity(ttyDevice: $0.ttyDevice, birth: $0.scopeCacheKey)
                }
            },
            parent: safeboxParentProcessID,
            terminal: { agentDeliveryTargetMatchingTTYDevice($0, surfaceTTYDevices: terminals) }
        )
        guard let target = locator.terminal(ofPeer: peer) else { return nil }
        let agentSessionID = app.workspaceFor(tabId: target.workspaceId)?
            .restoredAgentSnapshotsByPanelId[target.surfaceId]?.sessionId
            ?? DockSplitStore.liveStores
            .first { $0.panels[target.surfaceId] != nil }?
            .restoredAgentLifecycle.snapshotsByPanelId[target.surfaceId]?.sessionId
        return SafeboxCaller(
            session: SafeboxSessionKey(surfaceID: target.surfaceId, agentSessionID: agentSessionID),
            workspaceID: target.workspaceId
        )
    }

    /// The parent of a live process, or nil.
    private nonisolated static func safeboxParentProcessID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize)) == expectedSize else { return nil }
        return pid_t(bitPattern: info.pbi_ppid)
    }

    private nonisolated static var safeboxUnavailable: V2CallResult {
        .err(
            code: "keychain_unavailable",
            message: String(
                localized: "safebox.socket.error.unavailable",
                defaultValue: "Safebox is not available in this cmux process."
            ),
            data: nil
        )
    }
}

@MainActor
extension AppDelegate {
    /// Local terminal panes and the PTY devices they own, across every
    /// window's workspaces and every Dock. Unlike
    /// ``liveAgentDeliveryTTYBindings()`` this leaves out TTYs reported over
    /// the socket: only the device of the PTY Ghostty spawned for the pane.
    func safeboxOwnedTTYBindings() -> [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] {
        var bindings: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] = []
        for manager in agentDeliveryTabManagers() {
            for workspace in manager.tabs {
                for binding in workspace.safeboxOwnedTTYDevices {
                    bindings.append((workspace.id, binding.surfaceId, binding.ttyDevice))
                }
            }
        }
        for dock in DockSplitStore.liveStores {
            for binding in dock.safeboxOwnedTTYDevices {
                bindings.append((dock.workspaceId, binding.surfaceId, binding.ttyDevice))
            }
        }
        return bindings
    }
}

@MainActor
extension Workspace {
    /// The PTY device each local terminal panel owns. Remote terminals and
    /// socket-reported TTYs are left out.
    var safeboxOwnedTTYDevices: [(surfaceId: UUID, ttyDevice: Int64)] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }
        return panels.compactMap { panelId, panel in
            guard let terminal = panel as? TerminalPanel,
                  !isRemoteTerminalSurface(panelId),
                  let device = terminal.surface.controllingTTYDeviceIdentifier else { return nil }
            return (panelId, device)
        }
    }
}

@MainActor
extension DockSplitStore {
    /// The PTY device each local terminal panel of this Dock owns. Remote
    /// terminals and socket-reported TTYs are left out.
    var safeboxOwnedTTYDevices: [(surfaceId: UUID, ttyDevice: Int64)] {
        panels.compactMap { panelId, panel in
            guard let terminal = panel as? TerminalPanel,
                  detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal != true,
                  let device = terminal.surface.controllingTTYDeviceIdentifier else { return nil }
            return (panelId, device)
        }
    }
}
