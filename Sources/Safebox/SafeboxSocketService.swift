import CmuxControlSocket
import Foundation
import Security

/// The terminal session a `safebox.resolve` request comes from, derived by
/// the app from the socket peer's process (never from what the caller claims).
struct SafeboxCaller: Sendable {
    let session: SafeboxSessionKey
    let workspaceID: UUID
}

/// Traces a socket peer to the cmux terminal pane it runs in.
///
/// The nearest process of the peer's ancestry, the peer first, whose
/// controlling terminal is a pane's PTY names the pane. Walking up covers
/// workers that an agent starts without a controlling terminal (for example
/// in a new session): they still belong to the pane their parent runs in. The
/// walk ends without a pane at the cmux process itself, at launchd, at a
/// process that is gone or whose parent cannot be read, on a parent loop and
/// after ``maximumDepth`` processes.
///
/// Every visited process is identified by its pid and start time. After a
/// match the walk reads them all again and fails when any of them changed, so
/// a pid reused during the walk cannot lend its terminal or parent to a caller.
struct SafeboxCallerLocator {
    /// A process's controlling terminal device and its pid plus start time.
    struct Identity: Equatable {
        let ttyDevice: Int64?
        let birth: CmuxTopProcessScopeCacheKey
    }

    static let maximumDepth = 256

    private let host: Int32
    private let identity: (Int32) -> Identity?
    private let parent: (Int32) -> Int32?
    private let terminal: (Int64) -> AgentDeliveryTargetCandidate?

    /// - Parameters:
    ///   - host: The cmux process id; the walk stops there.
    ///   - identity: The identity of a live process, or `nil` when it is gone.
    ///   - parent: The parent process id of a live process, or `nil`.
    ///   - terminal: The pane that owns the PTY with this device, or `nil`.
    init(
        host: Int32,
        identity: @escaping (Int32) -> Identity?,
        parent: @escaping (Int32) -> Int32?,
        terminal: @escaping (Int64) -> AgentDeliveryTargetCandidate?
    ) {
        self.host = host
        self.identity = identity
        self.parent = parent
        self.terminal = terminal
    }

    func terminal(ofPeer peer: Int32?) -> AgentDeliveryTargetCandidate? {
        guard var current = peer else { return nil }
        var visited: [Int32: CmuxTopProcessScopeCacheKey] = [:]
        for _ in 0..<Self.maximumDepth {
            guard current > 1, current != host, visited[current] == nil,
                  let info = identity(current) else { return nil }
            visited[current] = info.birth
            if let device = info.ttyDevice, let found = terminal(device) {
                let unchanged = visited.allSatisfy { pid, birth in identity(pid)?.birth == birth }
                return unchanged ? found : nil
            }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }
}

/// `safebox.list` and `safebox.resolve` for the control socket.
///
/// `list` returns names, notes, dates and whether a value is stored, never a
/// value, and needs no approval. `resolve` returns values only to a caller in
/// a cmux terminal, after the user allowed that session to receive each
/// secret. Error messages and data never contain a value.
struct SafeboxSocketService: Sendable {
    typealias V2CallResult = TerminalController.V2CallResult

    private let repository: SafeboxRepository
    private let approvals: SafeboxApprovalRegistry

    init(repository: SafeboxRepository, approvals: SafeboxApprovalRegistry) {
        self.repository = repository
        self.approvals = approvals
    }

    /// `{"secrets": [{"name", "note", "updated_at", "last_used_at", "state"}]}`.
    /// When the Keychain cannot be read, states are unknown: every entry is
    /// reported as `ok` and `keychain_status` carries the Keychain status.
    func list() async -> V2CallResult {
        let snapshot = await repository.snapshot()
        if let metadataError = snapshot.metadataError {
            return Self.failure(metadataError)
        }
        let secrets: [[String: Any]] = snapshot.entries.map { entry in
            [
                "name": entry.metadata.name.rawValue,
                "note": entry.metadata.note,
                "updated_at": Self.timestamp(entry.metadata.updatedAt),
                "last_used_at": entry.metadata.lastUsedAt.map(Self.timestamp) ?? NSNull(),
                "state": entry.state == .ok ? "ok" : "value_missing",
            ]
        }
        var payload: [String: Any] = ["secrets": secrets]
        if case .keychainUnavailable(let status) = snapshot.keychainError {
            payload["keychain_status"] = Int(status)
        }
        return .ok(payload)
    }

    /// Params `{"names": [String], "command": String}`; result
    /// `{"values": {name: value}}`. The first request of each secret from
    /// each session waits for the user's Allow or Deny.
    ///
    /// - Parameter parkBeforeWaiting: Called once before waiting for the user,
    ///   and only when some name is not granted yet. The socket passes
    ///   `ControlClientWorkerPool.parkCurrentJob()` so a pending prompt does
    ///   not hold a running slot for up to the approval timeout. Returning
    ///   false (no parked slot left) answers `overloaded` without prompting.
    func resolve(
        params: [String: Any],
        caller: SafeboxCaller?,
        parkBeforeWaiting: @Sendable () async -> Bool = { true }
    ) async -> V2CallResult {
        guard let rawNames = params["names"] as? [String], !rawNames.isEmpty else {
            return Self.invalidParams(
                String(
                    localized: "safebox.socket.error.namesRequired",
                    defaultValue: "names must be a non-empty array of secret names."
                ),
                param: "names"
            )
        }
        var names: [SafeboxSecretName] = []
        for raw in rawNames {
            // The input is not echoed: a value pasted in place of a name must not leak.
            guard let name = SafeboxSecretName(normalizing: raw) else {
                return Self.invalidParams(SafeboxError.invalidName(raw).localizedDescription, param: "names")
            }
            if !names.contains(name) { names.append(name) }
        }
        guard let command = params["command"] as? String else {
            return Self.invalidParams(
                String(
                    localized: "safebox.socket.error.commandRequired",
                    defaultValue: "command must be the command line that receives the secrets."
                ),
                param: "command"
            )
        }
        guard let caller else {
            return Self.failure(.notInCmuxTerminal)
        }

        // Ask only for secrets that exist and whose values can be read.
        let snapshot = await repository.snapshot()
        if let error = snapshot.metadataError ?? snapshot.keychainError {
            return Self.failure(error)
        }
        let available = Set(snapshot.entries.filter { $0.state == .ok }.map(\.metadata.name))
        let missing = names.filter { !available.contains($0) }
        if !missing.isEmpty {
            return Self.failure(.unknownSecrets(missing.map(\.rawValue)))
        }

        if await approvals.needsDecision(session: caller.session, names: names),
           await !parkBeforeWaiting() {
            return Self.overloaded
        }

        let allowed = await approvals.requestAccess(
            session: caller.session,
            workspaceID: caller.workspaceID,
            names: names,
            command: command
        )
        guard allowed else {
            return Self.failure(.notApproved(names.map(\.rawValue)))
        }

        do {
            let resolved = try await repository.resolveValues(for: names)
            var values: [String: String] = [:]
            for (name, value) in resolved { values[name.rawValue] = value }
            return .ok(["values": values])
        } catch let error as SafeboxError {
            return Self.failure(error)
        } catch {
            return Self.failure(.keychainUnavailable(status: errSecInternalError))
        }
    }

    // MARK: - Private

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// The error `feed.push` returns when no parked slot is left.
    private static var overloaded: V2CallResult {
        .err(
            code: ControlOverloadResponder.errorCode,
            message: String(
                localized: "socket.overloaded.message",
                defaultValue: "cmux is handling too many control-socket requests right now, so this one was not run. Retry in a moment."
            ),
            data: nil
        )
    }

    private static func invalidParams(_ message: String, param: String) -> V2CallResult {
        .err(code: "invalid_params", message: message, data: ["param": param])
    }

    /// Maps a repository or approval failure to its wire error. Metadata
    /// failures share `keychain_unavailable`: either way no value can be served.
    private static func failure(_ error: SafeboxError) -> V2CallResult {
        let message = error.localizedDescription
        switch error {
        case .unknownSecrets(let names):
            return .err(code: "unknown_secret", message: message, data: ["names": names])
        case .notApproved(let names):
            return .err(code: "not_approved", message: message, data: ["names": names])
        case .notInCmuxTerminal:
            return .err(code: "not_in_cmux_terminal", message: message, data: nil)
        case .keychainUnavailable(let status):
            return .err(code: "keychain_unavailable", message: message, data: ["status": Int(status)])
        case .metadataUnavailable:
            return .err(code: "keychain_unavailable", message: message, data: nil)
        case .invalidName, .duplicateName:
            return .err(code: "invalid_params", message: message, data: nil)
        }
    }
}
