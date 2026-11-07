import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Safebox approval banner model", .timeLimit(.minutes(1)))
struct SafeboxApprovalBannerModelTests {
    private let workspaceID = UUID()

    /// A long timeout so no request times out while a test runs.
    private func makeRegistry() -> SafeboxApprovalRegistry {
        SafeboxApprovalRegistry(timeout: .seconds(600))
    }

    private func name(_ raw: String) -> SafeboxSecretName {
        SafeboxSecretName(normalizing: raw)!
    }

    private func session(_ surfaceID: UUID) -> SafeboxSessionKey {
        SafeboxSessionKey(surfaceID: surfaceID, agentSessionID: nil)
    }

    /// A banner whose clicks happen well after the decision delay, so tests
    /// that are not about the delay are not affected by it.
    private func makeBanner(_ registry: SafeboxApprovalRegistry, surfaceID: UUID) -> SafeboxApprovalBannerModel {
        SafeboxApprovalBannerModel(
            approvals: registry,
            surfaceID: surfaceID,
            now: { Date().addingTimeInterval(SafeboxApprovalBannerModel.decisionDelay + 5) }
        )
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

    /// Awaits a request task; cancelling the test cancels the request.
    private func value(of task: Task<Bool, Never>) async -> Bool {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startRequest(
        _ registry: SafeboxApprovalRegistry,
        surfaceID: UUID,
        names: [SafeboxSecretName],
        command: String = "npm publish"
    ) -> Task<Bool, Never> {
        let key = session(surfaceID)
        let workspaceID = workspaceID
        return Task { @MainActor in
            await registry.requestAccess(session: key, workspaceID: workspaceID, names: names, command: command)
        }
    }

    @Test func pendingRequestShowsOnlyOnItsSurface() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let otherSurface = UUID()
        let request = startRequest(registry, surfaceID: surface, names: [name("NPM_TOKEN")])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })

        let banner = makeBanner(registry, surfaceID: surface)
        let otherBanner = makeBanner(registry, surfaceID: otherSurface)

        let presentation = try #require(banner.presentation)
        #expect(presentation.lines.map(\.text) == ["npm publish wants NPM_TOKEN from Safebox"])
        #expect(presentation.requestIDs == registry.pendingRequests.map(\.id))
        #expect(otherBanner.presentation == nil)

        banner.deny(presentation)
        #expect(await value(of: request) == false)
    }

    @Test func allowResolvesRequestAndHidesBanner() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let token = name("NPM_TOKEN")
        let request = startRequest(registry, surfaceID: surface, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let banner = makeBanner(registry, surfaceID: surface)

        banner.allow(try #require(banner.presentation))

        #expect(await value(of: request) == true)
        #expect(banner.presentation == nil)
        #expect(registry.grants(for: token) == [session(surface)])
    }

    @Test func denyResolvesRequestAndHidesBanner() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let token = name("NPM_TOKEN")
        let request = startRequest(registry, surfaceID: surface, names: [token])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let banner = makeBanner(registry, surfaceID: surface)

        banner.deny(try #require(banner.presentation))

        #expect(await value(of: request) == false)
        #expect(banner.presentation == nil)
        #expect(registry.grants(for: token).isEmpty)
    }

    /// {A} is pending and a second caller needs {A, B}: the surface has two
    /// requests. One banner lists both names and one Allow resolves both, while
    /// another surface's request stays pending.
    @Test func allowResolvesEveryPendingRequestOfTheSurface() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let otherSurface = UUID()
        let a = name("AWS_KEY")
        let b = name("GITHUB_TOKEN")
        let first = startRequest(registry, surfaceID: surface, names: [a], command: "deploy")
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let second = startRequest(registry, surfaceID: surface, names: [a, b], command: "deploy --all")
        try #require(await waitUntil { registry.pendingRequests.count == 2 })
        let unrelated = startRequest(registry, surfaceID: otherSurface, names: [a])
        try #require(await waitUntil { registry.pendingRequests.count == 3 })

        let banner = makeBanner(registry, surfaceID: surface)
        let presentation = try #require(banner.presentation)
        #expect(presentation.requestIDs.count == 2)
        #expect(presentation.lines.map(\.text) == [
            "deploy wants AWS_KEY from Safebox",
            "deploy --all wants GITHUB_TOKEN from Safebox",
        ])

        banner.allow(presentation)

        #expect(await value(of: first) == true)
        #expect(await value(of: second) == true)
        #expect(banner.presentation == nil)
        #expect(registry.pendingRequests.map(\.session) == [session(otherSurface)])

        let otherBanner = makeBanner(registry, surfaceID: otherSurface)
        otherBanner.deny(try #require(otherBanner.presentation))
        #expect(await value(of: unrelated) == false)
    }

    @Test func denyDeniesEveryPendingRequestOfTheSurface() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let a = name("AWS_KEY")
        let b = name("GITHUB_TOKEN")
        let first = startRequest(registry, surfaceID: surface, names: [a])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let second = startRequest(registry, surfaceID: surface, names: [a, b])
        try #require(await waitUntil { registry.pendingRequests.count == 2 })

        let banner = makeBanner(registry, surfaceID: surface)
        banner.deny(try #require(banner.presentation))

        #expect(await value(of: first) == false)
        #expect(await value(of: second) == false)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.grants(for: a).isEmpty)
        #expect(registry.grants(for: b).isEmpty)
    }

    /// Same command, several requests: one line that lists every name.
    @Test func requestsWithTheSameCommandShareOneLine() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let first = startRequest(registry, surfaceID: surface, names: [name("AWS_KEY")], command: "make")
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let second = startRequest(registry, surfaceID: surface, names: [name("GITHUB_TOKEN")], command: "make")
        try #require(await waitUntil { registry.pendingRequests.count == 2 })

        let banner = makeBanner(registry, surfaceID: surface)
        let presentation = try #require(banner.presentation)
        #expect(presentation.lines.map(\.text) == ["make wants AWS_KEY, GITHUB_TOKEN from Safebox"])

        banner.deny(presentation)
        #expect(await value(of: first) == false)
        #expect(await value(of: second) == false)
    }

    /// The command is shown as one plain line: control characters become
    /// spaces and markdown is left as typed (the view renders it verbatim).
    @Test func commandIsShownAsOnePlainLine() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let request = startRequest(
            registry,
            surfaceID: surface,
            names: [name("NPM_TOKEN")],
            command: "sh -c 'echo **hi**\n[x](https://example.invalid)\tdone'"
        )
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let banner = makeBanner(registry, surfaceID: surface)
        let presentation = try #require(banner.presentation)

        #expect(presentation.lines.map(\.text) == [
            "sh -c 'echo **hi** [x](https://example.invalid) done' wants NPM_TOKEN from Safebox",
        ])
        banner.deny(presentation)
        #expect(await value(of: request) == false)
    }

    @Test func emptyCommandFallsBackToGenericLabel() {
        #expect(SafeboxApprovalBannerModel.displayCommand("  \n ") == "A command")
        #expect(SafeboxApprovalBannerModel.displayCommand(String(repeating: "x", count: 300)).count == 200)
    }

    @Test func countdownCountsDownToTheTimeout() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SafeboxApprovalBannerModel.remainingSeconds(until: deadline, now: deadline.addingTimeInterval(-60)) == 60)
        #expect(SafeboxApprovalBannerModel.remainingSeconds(until: deadline, now: deadline.addingTimeInterval(-0.4)) == 1)
        #expect(SafeboxApprovalBannerModel.remainingSeconds(until: deadline, now: deadline.addingTimeInterval(5)) == 0)
    }

    /// A click right after the shown requests change is ignored, so a request
    /// that appeared just before the click cannot be approved unread.
    @Test func clicksAreIgnoredRightAfterTheShownRequestsChange() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let a = name("AWS_KEY")
        let b = name("GITHUB_TOKEN")
        let first = startRequest(registry, surfaceID: surface, names: [a], command: "deploy")
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let firstCreatedAt = try #require(registry.pendingRequests.first).createdAt
        let clock = ManualDate(firstCreatedAt.addingTimeInterval(0.5))
        let banner = SafeboxApprovalBannerModel(approvals: registry, surfaceID: surface, now: { clock.date })

        let early = try #require(banner.presentation)
        #expect(!banner.acceptsDecisions(for: early))
        banner.allow(early)
        banner.deny(early)
        #expect(registry.pendingRequests.count == 1)

        // A second request arrives just before the click: the banner that now
        // shows it ignores the click although the first request is old enough.
        clock.date = firstCreatedAt.addingTimeInterval(SafeboxApprovalBannerModel.decisionDelay)
        #expect(banner.acceptsDecisions(for: early))
        let second = startRequest(registry, surfaceID: surface, names: [b], command: "deploy --all")
        try #require(await waitUntil { registry.pendingRequests.count == 2 })
        let secondCreatedAt = try #require(registry.pendingRequests.last).createdAt
        try #require(secondCreatedAt > firstCreatedAt)
        let changed = try #require(banner.presentation)
        #expect(!banner.acceptsDecisions(for: changed))
        banner.allow(changed)
        #expect(registry.pendingRequests.count == 2)
        #expect(registry.grants(for: a).isEmpty)

        clock.date = secondCreatedAt.addingTimeInterval(SafeboxApprovalBannerModel.decisionDelay)
        banner.allow(try #require(banner.presentation))
        #expect(await value(of: first) == true)
        #expect(await value(of: second) == true)
    }

    @MainActor
    private final class ManualDate {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    @Test func deadlineIsTheOldestRequestPlusTheTimeout() async throws {
        let registry = makeRegistry()
        let surface = UUID()
        let request = startRequest(registry, surfaceID: surface, names: [name("NPM_TOKEN")])
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let createdAt = try #require(registry.pendingRequests.first).createdAt
        let banner = makeBanner(registry, surfaceID: surface)
        let presentation = try #require(banner.presentation)

        #expect(abs(presentation.deadline.timeIntervalSince(createdAt) - 600) < 0.001)
        banner.deny(presentation)
        #expect(await value(of: request) == false)
    }
}

@MainActor
@Suite("Safebox approval attention", .timeLimit(.minutes(1)))
struct SafeboxApprovalAttentionTrackerTests {
    /// Unread state per surface: the identity of the current mark, if any.
    @MainActor
    private final class FakeTarget: SafeboxAttentionMarking {
        var marks: [UUID: Date] = [:]
        var markCalls: [(surfaceID: UUID, workspaceID: UUID)] = []
        var clearCalls: [UUID] = []
        var announcements: [String] = []
        private var tick = 0.0

        func nextIdentity() -> Date {
            tick += 1
            return Date(timeIntervalSinceReferenceDate: tick)
        }

        /// What the user's "Mark as Unread" does: a new mark identity.
        func userMarksUnread(_ surfaceID: UUID) { marks[surfaceID] = nextIdentity() }
        func userMarksRead(_ surfaceID: UUID) { marks[surfaceID] = nil }

        func markUnread(surfaceID: UUID, workspaceID: UUID) -> Date? {
            markCalls.append((surfaceID, workspaceID))
            guard marks[surfaceID] == nil else { return nil }
            let identity = nextIdentity()
            marks[surfaceID] = identity
            return identity
        }

        func currentMark(surfaceID: UUID, workspaceID: UUID) -> Date? { marks[surfaceID] }

        func clearUnread(surfaceID: UUID, workspaceID: UUID) {
            clearCalls.append(surfaceID)
            marks[surfaceID] = nil
        }

        func announce(_ message: String) { announcements.append(message) }
    }

    private func makeRequest(surfaceID: UUID, workspaceID: UUID = UUID()) -> SafeboxApprovalRequest {
        SafeboxApprovalRequest(
            id: UUID(),
            session: SafeboxSessionKey(surfaceID: surfaceID, agentSessionID: nil),
            workspaceID: workspaceID,
            names: [SafeboxSecretName(normalizing: "NPM_TOKEN")!],
            command: "npm publish",
            createdAt: Date()
        )
    }

    private func makeTracker(_ target: FakeTarget) -> SafeboxApprovalAttentionTracker {
        SafeboxApprovalAttentionTracker(registry: SafeboxApprovalRegistry(timeout: .seconds(600)), target: target)
    }

    @Test func marksOnceWhilePendingAndClearsWhenResolved() {
        let target = FakeTarget()
        let tracker = makeTracker(target)
        let surface = UUID()
        let workspace = UUID()

        tracker.sync([makeRequest(surfaceID: surface, workspaceID: workspace)])
        tracker.sync([makeRequest(surfaceID: surface), makeRequest(surfaceID: surface)])
        #expect(target.markCalls.map(\.surfaceID) == [surface])
        // The request's workspace is passed for the panel lookup.
        #expect(target.markCalls.map(\.workspaceID) == [workspace])
        #expect(target.marks[surface] != nil)

        tracker.sync([])
        #expect(target.clearCalls == [surface])
        #expect(target.marks[surface] == nil)
    }

    /// A tab the user had already marked unread keeps that mark afterwards.
    @Test func doesNotClearAnIndicatorItDidNotSet() {
        let target = FakeTarget()
        let surface = UUID()
        target.userMarksUnread(surface)
        let before = target.marks[surface]
        let tracker = makeTracker(target)

        tracker.sync([makeRequest(surfaceID: surface)])
        tracker.sync([])

        #expect(target.clearCalls.isEmpty)
        #expect(target.marks[surface] == before)
    }

    /// The user marks the tab read and unread again while the request waits:
    /// that mark is the user's and survives the request.
    @Test func doesNotClearAMarkTheUserReapplied() {
        let target = FakeTarget()
        let tracker = makeTracker(target)
        let surface = UUID()

        tracker.sync([makeRequest(surfaceID: surface)])
        target.userMarksRead(surface)
        target.userMarksUnread(surface)
        let reapplied = target.marks[surface]
        tracker.sync([])

        #expect(target.clearCalls.isEmpty)
        #expect(target.marks[surface] == reapplied)
    }

    @Test func followsTheRegistryAndAnnouncesNewRequests() async throws {
        let target = FakeTarget()
        let registry = SafeboxApprovalRegistry(timeout: .seconds(600))
        let tracker = SafeboxApprovalAttentionTracker(registry: registry, target: target)
        tracker.start()
        let surface = UUID()
        let key = SafeboxSessionKey(surfaceID: surface, agentSessionID: nil)
        let request = Task { @MainActor in
            await registry.requestAccess(
                session: key,
                workspaceID: UUID(),
                names: [SafeboxSecretName(normalizing: "NPM_TOKEN")!],
                command: "npm publish"
            )
        }
        var marked = false
        for _ in 0..<10_000 where !marked {
            await Task.yield()
            marked = target.marks[surface] != nil
        }
        #expect(marked)
        #expect(target.announcements == ["npm publish wants NPM_TOKEN from Safebox"])

        let pending = try #require(registry.pendingRequests.first)
        registry.decide(requestID: pending.id, allow: false)
        #expect(await request.value == false)
        var cleared = false
        for _ in 0..<10_000 where !cleared {
            await Task.yield()
            cleared = target.marks[surface] == nil
        }
        #expect(cleared)
        #expect(target.announcements.count == 1)
    }
}
