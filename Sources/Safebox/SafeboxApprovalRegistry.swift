import Foundation
import Observation

/// One Allow/Deny prompt shown to the user.
struct SafeboxApprovalRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let session: SafeboxSessionKey
    let workspaceID: UUID
    let names: [SafeboxSecretName]
    /// The command that asked for the secrets, truncated to
    /// `SafeboxApprovalRegistry.maxCommandLength` characters.
    let command: String
    let createdAt: Date
}

/// Decides whether a terminal session may receive a secret.
///
/// The first request for each secret from each session waits for the user's
/// Allow or Deny. Allow is remembered in memory for that session and secret;
/// Deny and the timeout are not remembered. A request that is not answered
/// within `timeout` is denied.
///
/// A request whose ungranted names overlap a pending request of the same
/// session joins that request instead of opening a second prompt. Names that no
/// pending request covers get one new request, so a caller can wait on more
/// than one prompt; it is allowed only when all of them are allowed, and it is
/// denied as soon as one of them is denied.
///
/// Each caller is a waiter with its own continuation, resumed exactly once:
/// every resume path removes the waiter first. A pending request no waiter
/// needs any more (all its callers were cancelled or already denied) is dropped.
@MainActor
@Observable
final class SafeboxApprovalRegistry {
    static let maxCommandLength = 200

    private(set) var pendingRequests: [SafeboxApprovalRequest] = []
    private var grantsByName: [SafeboxSecretName: [SafeboxSessionKey]] = [:]

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        var outstandingRequestIDs: Set<UUID>
    }

    /// How long a request waits before it is denied.
    @ObservationIgnored let timeout: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
    @ObservationIgnored private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(timeout: Duration = .seconds(60), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// Number of callers currently waiting for a decision.
    var waiterCount: Int { waiters.count }

    /// Returns true when `session` may receive every secret in `names`. Waits for
    /// the user when some of them are not granted yet.
    func requestAccess(
        session: SafeboxSessionKey,
        workspaceID: UUID,
        names: [SafeboxSecretName],
        command: String
    ) async -> Bool {
        if ungrantedNames(names, for: session).isEmpty { return true }
        if Task.isCancelled { return false }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Runs on the main actor without suspending, so checking grants,
                // joining or creating requests and registering the waiter happen
                // without interleaving with decide/timeout/surfaceClosed.
                let ungranted = self.ungrantedNames(names, for: session)
                guard !ungranted.isEmpty else {
                    continuation.resume(returning: true)
                    return
                }
                let requestIDs = self.requestIDs(
                    covering: ungranted,
                    session: session,
                    workspaceID: workspaceID,
                    command: command
                )
                self.waiters[waiterID] = Waiter(continuation: continuation, outstandingRequestIDs: requestIDs)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    /// Records the user's answer. Allow grants each name of the request to its
    /// session; Deny records nothing. Unknown ids are ignored.
    func decide(requestID: UUID, allow: Bool) {
        resolve(requestID: requestID, allowed: allow)
    }

    /// True when ``requestAccess(session:workspaceID:names:command:)`` would
    /// wait for the user because some of `names` is not granted to `session`.
    func needsDecision(session: SafeboxSessionKey, names: [SafeboxSecretName]) -> Bool {
        !ungrantedNames(names, for: session).isEmpty
    }

    /// Sessions currently allowed to receive `name`, in grant order.
    func grants(for name: SafeboxSecretName) -> [SafeboxSessionKey] {
        grantsByName[name] ?? []
    }

    func revoke(name: SafeboxSecretName, session: SafeboxSessionKey) {
        guard var sessions = grantsByName[name] else { return }
        sessions.removeAll { $0 == session }
        grantsByName[name] = sessions.isEmpty ? nil : sessions
    }

    /// Drops every grant of the surface and denies its pending requests.
    func surfaceClosed(_ surfaceID: UUID) {
        for (name, sessions) in grantsByName {
            let kept = sessions.filter { $0.surfaceID != surfaceID }
            grantsByName[name] = kept.isEmpty ? nil : kept
        }
        let closedIDs = pendingRequests.filter { $0.session.surfaceID == surfaceID }.map(\.id)
        for id in closedIDs {
            resolve(requestID: id, allowed: false)
        }
    }

    // MARK: - Private

    private func isGranted(_ name: SafeboxSecretName, for session: SafeboxSessionKey) -> Bool {
        grantsByName[name]?.contains(session) ?? false
    }

    /// `names` without duplicates and without the ones already granted, in order.
    private func ungrantedNames(_ names: [SafeboxSecretName], for session: SafeboxSessionKey) -> [SafeboxSecretName] {
        var seen = Set<SafeboxSecretName>()
        return names.filter { seen.insert($0).inserted && !isGranted($0, for: session) }
    }

    /// Pending requests that cover `names` for `session`: overlapping existing
    /// ones plus, for names none of them covers, one new request.
    private func requestIDs(
        covering names: [SafeboxSecretName],
        session: SafeboxSessionKey,
        workspaceID: UUID,
        command: String
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        var uncovered = names
        for request in pendingRequests where request.session == session {
            let requestNames = Set(request.names)
            guard uncovered.contains(where: requestNames.contains) else { continue }
            ids.insert(request.id)
            uncovered.removeAll(where: requestNames.contains)
        }
        if !uncovered.isEmpty {
            let request = SafeboxApprovalRequest(
                id: UUID(),
                session: session,
                workspaceID: workspaceID,
                names: uncovered,
                command: String(command.prefix(Self.maxCommandLength)),
                createdAt: Date()
            )
            pendingRequests.append(request)
            startTimeout(for: request.id)
            ids.insert(request.id)
        }
        return ids
    }

    private func startTimeout(for requestID: UUID) {
        let clock = clock
        let timeout = timeout
        timeoutTasks[requestID] = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            // A clock may return normally after cancellation; a cancelled
            // timeout must not deny anything.
            guard !Task.isCancelled else { return }
            self?.resolve(requestID: requestID, allowed: false)
        }
    }

    private func resolve(requestID: UUID, allowed: Bool) {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = pendingRequests.remove(at: index)
        timeoutTasks.removeValue(forKey: requestID)?.cancel()

        if allowed {
            for name in request.names where !isGranted(name, for: request.session) {
                grantsByName[name, default: []].append(request.session)
            }
        }

        for (waiterID, waiter) in waiters where waiter.outstandingRequestIDs.contains(requestID) {
            var remaining = waiter.outstandingRequestIDs
            remaining.remove(requestID)
            if !allowed {
                finishWaiter(waiterID, result: false)
            } else if remaining.isEmpty {
                finishWaiter(waiterID, result: true)
            } else {
                waiters[waiterID]?.outstandingRequestIDs = remaining
            }
        }
        if !allowed {
            dropUnwantedRequests()
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard waiters[waiterID] != nil else { return }
        finishWaiter(waiterID, result: false)
        dropUnwantedRequests()
    }

    /// The only place a continuation is resumed; removing the waiter first makes
    /// every later call for it a no-op.
    private func finishWaiter(_ waiterID: UUID, result: Bool) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: result)
    }

    /// Removes pending requests no remaining waiter is waiting for.
    private func dropUnwantedRequests() {
        let wanted = waiters.values.reduce(into: Set<UUID>()) { $0.formUnion($1.outstandingRequestIDs) }
        let unwanted = pendingRequests.filter { !wanted.contains($0.id) }.map(\.id)
        guard !unwanted.isEmpty else { return }
        pendingRequests.removeAll { !wanted.contains($0.id) }
        for id in unwanted {
            timeoutTasks.removeValue(forKey: id)?.cancel()
        }
    }
}
