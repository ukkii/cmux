import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A clock that only moves when a test calls `advance(by:)`.
final class SafeboxManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Checked under the lock so a cancellation whose handler already
                // ran never leaves a sleeper behind.
                let outcome: Result<Bool, Error> = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current { return .success(true) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .success(false)
                }
                switch outcome {
                case .failure(let error): continuation.resume(throwing: error)
                case .success(true): continuation.resume()
                case .success(false): break
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let dueIDs = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

@MainActor
@Suite("Safebox approval registry", .timeLimit(.minutes(1)))
struct SafeboxApprovalRegistryTests {
    private let clock = SafeboxManualTestClock()
    private let workspaceID = UUID()

    private func makeRegistry() -> SafeboxApprovalRegistry {
        SafeboxApprovalRegistry(timeout: .seconds(60), clock: clock)
    }

    private func name(_ raw: String) -> SafeboxSecretName {
        SafeboxSecretName(normalizing: raw)!
    }

    private func session(_ surfaceID: UUID = UUID(), agent: String? = nil) -> SafeboxSessionKey {
        SafeboxSessionKey(surfaceID: surfaceID, agentSessionID: agent)
    }

    /// Yields to the main actor until `condition` holds. Bounded so a bug fails
    /// the test instead of hanging it.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() || Task.isCancelled { return condition() }
            await Task.yield()
        }
        return condition()
    }

    /// The oldest pending request; fails the test instead of crashing when
    /// there is none.
    private func firstPending(_ registry: SafeboxApprovalRegistry) throws -> SafeboxApprovalRequest {
        try #require(registry.pendingRequests.first)
    }

    /// Awaits a request task. Cancelling the test (for example by its time
    /// limit) cancels the request, which the registry resolves to false, so a
    /// wedged request cannot keep the run from finishing.
    private func value(of task: Task<Bool, Never>) async -> Bool {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startRequest(
        _ registry: SafeboxApprovalRegistry,
        session: SafeboxSessionKey,
        names: [SafeboxSecretName],
        command: String = "curl https://example.invalid"
    ) -> Task<Bool, Never> {
        let workspaceID = workspaceID
        return Task { @MainActor in
            await registry.requestAccess(session: session, workspaceID: workspaceID, names: names, command: command)
        }
    }

    @Test func firstRequestWaitsAndAllowIsRemembered() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")

        let first = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let request = try firstPending(registry)
        #expect(request.session == key)
        #expect(request.workspaceID == workspaceID)
        #expect(request.names == [token])
        #expect(request.command == "curl https://example.invalid")

        registry.decide(requestID: request.id, allow: true)
        #expect(await value(of: first) == true)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.grants(for: token) == [key])

        let second = await registry.requestAccess(session: key, workspaceID: workspaceID, names: [token], command: "x")
        #expect(second == true)
        #expect(registry.pendingRequests.isEmpty)
    }

    @Test func otherSecretOrOtherSessionAsksAgain() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")
        let other = name("GITHUB_TOKEN")

        let first = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: first) == true)

        // Same session, both names: only the ungranted one is asked for.
        let otherSecret = startRequest(registry, session: key, names: [token, other])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        #expect(try firstPending(registry).names == [other])
        try registry.decide(requestID: firstPending(registry).id, allow: false)
        #expect(await value(of: otherSecret) == false)

        // Granted secret, different surface.
        let otherKey = session()
        let otherSession = startRequest(registry, session: otherKey, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        #expect(try firstPending(registry).session == otherKey)
        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: otherSession) == true)
        #expect(Set(registry.grants(for: token)) == [key, otherKey])
        #expect(registry.grants(for: other).isEmpty)
    }

    @Test func denyAndTimeoutAreNotRemembered() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")

        let denied = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        try registry.decide(requestID: firstPending(registry).id, allow: false)
        #expect(await value(of: denied) == false)
        #expect(registry.grants(for: token).isEmpty)

        let timedOut = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(registry.pendingRequests.count == 1)
        clock.advance(by: .seconds(1))
        #expect(await value(of: timedOut) == false)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.grants(for: token).isEmpty)

        let third = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        try registry.decide(requestID: firstPending(registry).id, allow: false)
        #expect(await value(of: third) == false)
    }

    @Test func concurrentRequestsForSameGrantShareOnePrompt() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")

        let first = startRequest(registry, session: key, names: [token])
        let second = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 && registry.waiterCount == 2 })
        #expect(registry.pendingRequests.count == 1)

        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: first) == true)
        #expect(await value(of: second) == true)
        #expect(registry.pendingRequests.isEmpty)
    }

    @Test func closingSurfaceDeniesPendingRequests() async throws {
        let registry = makeRegistry()
        let surfaceID = UUID()
        let key = session(surfaceID)
        let token = name("CLOUDFLARE_TOKEN")
        let other = name("GITHUB_TOKEN")

        let granted = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: granted) == true)

        let unrelatedKey = session()
        let unrelated = startRequest(registry, session: unrelatedKey, names: [other])
        let pending = startRequest(registry, session: key, names: [other])
        try #require(await waitUntil { registry.pendingRequests.count == 2 })

        registry.surfaceClosed(surfaceID)
        #expect(await value(of: pending) == false)
        #expect(registry.pendingRequests.map(\.session) == [unrelatedKey])
        #expect(registry.grants(for: token).isEmpty)

        let unrelatedRequest = try #require(registry.pendingRequests.first)
        registry.decide(requestID: unrelatedRequest.id, allow: true)
        #expect(await value(of: unrelated) == true)
    }

    @Test func newAgentSessionInSameSurfaceAsksAgain() async throws {
        let registry = makeRegistry()
        let surfaceID = UUID()
        let token = name("CLOUDFLARE_TOKEN")
        let firstAgent = session(surfaceID, agent: "agent-1")

        let first = startRequest(registry, session: firstAgent, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: first) == true)

        let secondAgent = session(surfaceID, agent: "agent-2")
        let second = startRequest(registry, session: secondAgent, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        #expect(try firstPending(registry).session == secondAgent)
        try registry.decide(requestID: firstPending(registry).id, allow: false)
        #expect(await value(of: second) == false)
        #expect(registry.grants(for: token) == [firstAgent])
    }

    @Test func cancellingTheCallerDeniesItAndDropsAnUnwantedPrompt() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")

        let waiter = startRequest(registry, session: key, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 && clock.sleeperCount == 1 })
        waiter.cancel()
        #expect(await value(of: waiter) == false)
        try #require(await waitUntil { registry.pendingRequests.isEmpty && clock.sleeperCount == 0 })
        #expect(registry.waiterCount == 0)
    }

    @Test func revokeRemovesOnlyThatGrant() async throws {
        let registry = makeRegistry()
        let key = session()
        let token = name("CLOUDFLARE_TOKEN")
        let other = name("GITHUB_TOKEN")

        let first = startRequest(registry, session: key, names: [token, other])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        #expect(try firstPending(registry).names == [token, other])
        try registry.decide(requestID: firstPending(registry).id, allow: true)
        #expect(await value(of: first) == true)

        registry.revoke(name: token, session: key)
        #expect(registry.grants(for: token).isEmpty)
        #expect(registry.grants(for: other) == [key])
    }

    @Test func commandIsTruncatedTo200Characters() async throws {
        let registry = makeRegistry()
        let request = startRequest(
            registry,
            session: session(),
            names: [name("CLOUDFLARE_TOKEN")],
            command: String(repeating: "a", count: 500)
        )
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        #expect(try firstPending(registry).command.count == 200)
        try registry.decide(requestID: firstPending(registry).id, allow: false)
        _ = await value(of: request)
    }

    /// A pending prompt for {A}, then a caller that needs {A, B}: it joins the
    /// A prompt and gets a new prompt for B only.
    private func startPartialOverlap(
        _ registry: SafeboxApprovalRegistry,
        key: SafeboxSessionKey,
        a: SafeboxSecretName,
        b: SafeboxSecretName
    ) async throws -> (onlyA: Task<Bool, Never>, both: Task<Bool, Never>, promptA: SafeboxApprovalRequest, promptB: SafeboxApprovalRequest) {
        let onlyA = startRequest(registry, session: key, names: [a])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let promptA = try firstPending(registry)
        let both = startRequest(registry, session: key, names: [a, b])
        try #require(await waitUntil { registry.pendingRequests.count == 2 && registry.waiterCount == 2 })
        let promptB = try #require(registry.pendingRequests.last)
        #expect(promptA.names == [a])
        #expect(promptB.names == [b])
        return (onlyA, both, promptA, promptB)
    }

    @Test func partialOverlapNeedsBothPromptsAllowed() async throws {
        let registry = makeRegistry()
        let key = session()
        let a = name("CLOUDFLARE_TOKEN")
        let b = name("GITHUB_TOKEN")
        let started = try await startPartialOverlap(registry, key: key, a: a, b: b)

        registry.decide(requestID: started.promptA.id, allow: true)
        #expect(await value(of: started.onlyA) == true)
        #expect(registry.pendingRequests.map(\.id) == [started.promptB.id])
        #expect(registry.waiterCount == 1)

        registry.decide(requestID: started.promptB.id, allow: true)
        #expect(await value(of: started.both) == true)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.grants(for: a) == [key])
        #expect(registry.grants(for: b) == [key])
    }

    @Test func partialOverlapDenyingTheExtraNameDeniesOnlyTheWiderCaller() async throws {
        let registry = makeRegistry()
        let key = session()
        let a = name("CLOUDFLARE_TOKEN")
        let b = name("GITHUB_TOKEN")
        let started = try await startPartialOverlap(registry, key: key, a: a, b: b)

        registry.decide(requestID: started.promptB.id, allow: false)
        #expect(await value(of: started.both) == false)
        // The A prompt stays: the first caller still waits for it.
        #expect(registry.pendingRequests.map(\.id) == [started.promptA.id])
        #expect(registry.grants(for: b).isEmpty)

        registry.decide(requestID: started.promptA.id, allow: true)
        #expect(await value(of: started.onlyA) == true)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.grants(for: a) == [key])
    }
}
