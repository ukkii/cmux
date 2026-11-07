import CmuxControlSocket
import CmuxRemoteWorkspace
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Safebox socket service", .timeLimit(.minutes(1)))
struct SafeboxSocketServiceTests {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var loadError: SafeboxError?

        func setLoadError(_ error: SafeboxError?) { lock.withLock { loadError = error } }
        func setValues(_ newValues: [String: String]) { lock.withLock { values = newValues } }
        func load() throws -> [String: String] {
            try lock.withLock {
                if let loadError { throw loadError }
                return values
            }
        }
        func save(_ newValues: [String: String]) { lock.withLock { values = newValues } }
    }

    /// Counts `parkBeforeWaiting` calls and answers with `parks`.
    private final class ParkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let parks: Bool

        init(parks: Bool) { self.parks = parks }

        var calls: Int { lock.withLock { count } }
        func park() -> Bool {
            lock.withLock { count += 1 }
            return parks
        }
    }

    private static let tokenValue = "cf-secret-value-7d1e9a"
    private static let otherValue = "coolify-secret-value-41b2"

    private let store = Store()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("safebox-socket-tests-\(UUID().uuidString)", isDirectory: true)
    private let workspaceID = UUID()

    private func makeRepository() -> SafeboxRepository {
        let store = store
        return SafeboxRepository(
            metadataFile: SafeboxMetadataFile(fileURL: directory.appendingPathComponent("safebox.json")),
            loadValues: { try store.load() },
            saveValues: { store.save($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            usageFlushInterval: .seconds(3600)
        )
    }

    /// A long timeout on the real clock: a wedged test is denied well before
    /// the suite's time limit instead of hanging.
    private func makeRegistry() -> SafeboxApprovalRegistry {
        SafeboxApprovalRegistry(timeout: .seconds(30))
    }

    private func caller(surface: UUID = UUID(), agent: String? = "agent-session-1") -> SafeboxCaller {
        SafeboxCaller(session: SafeboxSessionKey(surfaceID: surface, agentSessionID: agent), workspaceID: workspaceID)
    }

    private func name(_ raw: String) -> SafeboxSecretName {
        SafeboxSecretName(normalizing: raw)!
    }

    /// The wire shape of a result, which is Sendable and comparable.
    private static func wire(_ result: TerminalController.V2CallResult) -> ControlCallResult {
        TerminalController.controlCallResult(fromLegacy: result)
    }

    /// Serializes everything a result carries (payload, message, data) so a
    /// test can assert that no secret value appears anywhere in it.
    private static func serialized(_ result: ControlCallResult) -> String {
        let object: Any
        switch result {
        case .ok(let value):
            object = ["result": value.foundationObject]
        case .err(let code, let message, let data):
            object = ["code": code, "message": message, "data": data?.foundationObject ?? NSNull()]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func errorCode(_ result: ControlCallResult) -> String? {
        if case .err(let code, _, _) = result { return code }
        return nil
    }

    private func errorData(_ result: ControlCallResult) -> [String: Any]? {
        if case .err(_, _, let data) = result { return data?.foundationObject as? [String: Any] }
        return nil
    }

    private func resolvedValues(_ result: ControlCallResult) -> [String: String]? {
        guard case .ok(let value) = result,
              let payload = value.foundationObject as? [String: Any] else { return nil }
        return payload["values"] as? [String: String]
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() || Task.isCancelled { return condition() }
            await Task.yield()
        }
        return condition()
    }

    /// Awaits a resolve task; cancelling the test cancels the request, which
    /// the registry resolves as denied, so a wedged request cannot hang the run.
    private func value(of task: Task<ControlCallResult, Never>) async -> ControlCallResult {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startResolve(
        _ service: SafeboxSocketService,
        names: [String],
        command: String = "curl https://api.cloudflare.com",
        caller: SafeboxCaller?,
        parker: ParkRecorder? = nil
    ) -> Task<ControlCallResult, Never> {
        Task { @MainActor in
            let params: [String: Any] = ["names": names, "command": command]
            guard let parker else {
                return Self.wire(await service.resolve(params: params, caller: caller))
            }
            return Self.wire(await service.resolve(params: params, caller: caller, parkBeforeWaiting: { parker.park() }))
        }
    }

    @Test func listNeverContainsValues() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "Cloudflare API")
        _ = try await repository.add(name: "COOLIFY_TOKEN", value: Self.otherValue, note: "")
        // A value removed outside cmux is reported, not hidden.
        store.setValues(["CLOUDFLARE_TOKEN": Self.tokenValue])
        let service = SafeboxSocketService(repository: repository, approvals: makeRegistry())

        let result = Self.wire(await service.list())
        let json = Self.serialized(result)
        #expect(!json.contains(Self.tokenValue))
        #expect(!json.contains(Self.otherValue))

        guard case .ok(let value) = result,
              let payload = value.foundationObject as? [String: Any],
              let secrets = payload["secrets"] as? [[String: Any]] else {
            Issue.record("list did not return secrets: \(json)")
            return
        }
        #expect(secrets.map { $0["name"] as? String } == ["CLOUDFLARE_TOKEN", "COOLIFY_TOKEN"])
        #expect(secrets.map { $0["state"] as? String } == ["ok", "value_missing"])
        #expect(secrets.first?["note"] as? String == "Cloudflare API")
        #expect(secrets.first?["updated_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(secrets.first?["last_used_at"] is NSNull)
        #expect(Set(secrets.first?.keys.map { $0 } ?? []) == ["name", "note", "updated_at", "last_used_at", "state"])
    }

    @Test func listReportsUnreadableMetadataWithoutValues() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("safebox.json"))
        store.setValues(["CLOUDFLARE_TOKEN": Self.tokenValue])
        let service = SafeboxSocketService(repository: makeRepository(), approvals: makeRegistry())

        let result = Self.wire(await service.list())
        #expect(errorCode(result) == "keychain_unavailable")
        #expect(!Self.serialized(result).contains(Self.tokenValue))
    }

    @Test func resolveWithoutCallerIsNotInCmuxTerminal() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)

        let result = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: nil))
        #expect(errorCode(result) == "not_in_cmux_terminal")
        #expect(registry.pendingRequests.isEmpty)
        #expect(!Self.serialized(result).contains(Self.tokenValue))
    }

    @Test func resolveUnknownNameReturnsUnknownSecret() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)

        let result = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN", "missing_one"], caller: caller()))
        #expect(errorCode(result) == "unknown_secret")
        #expect(errorData(result)?["names"] as? [String] == ["MISSING_ONE"])
        // Nothing is asked for a request that cannot succeed.
        #expect(registry.pendingRequests.isEmpty)
        #expect(!Self.serialized(result).contains(Self.tokenValue))
    }

    @Test func resolveWaitsForApprovalThenReturnsValues() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        _ = try await repository.add(name: "COOLIFY_TOKEN", value: Self.otherValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)
        let caller = caller()

        let pending = startResolve(service, names: ["cloudflare_token", "COOLIFY_TOKEN"], caller: caller)
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let request = try #require(registry.pendingRequests.first)
        #expect(request.session == caller.session)
        #expect(request.workspaceID == workspaceID)
        #expect(request.names == [name("CLOUDFLARE_TOKEN"), name("COOLIFY_TOKEN")])
        #expect(request.command == "curl https://api.cloudflare.com")

        registry.decide(requestID: request.id, allow: true)
        let result = await value(of: pending)
        #expect(resolvedValues(result) == ["CLOUDFLARE_TOKEN": Self.tokenValue, "COOLIFY_TOKEN": Self.otherValue])

        // The grant covers the same session (the agent and its workers) without asking again.
        let again = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller))
        #expect(resolvedValues(again) == ["CLOUDFLARE_TOKEN": Self.tokenValue])
        #expect(registry.pendingRequests.isEmpty)

        let snapshot = await repository.snapshot()
        #expect(snapshot.entries.allSatisfy { $0.metadata.lastUsedAt != nil })
    }

    @Test func resolveParksOnlyBeforeWaitingForApproval() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)
        let caller = caller()
        let parker = ParkRecorder(parks: true)

        let pending = startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller, parker: parker)
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        // The socket job left its running slot before the prompt appeared.
        #expect(parker.calls == 1)
        let request = try #require(registry.pendingRequests.first)
        registry.decide(requestID: request.id, allow: true)
        #expect(resolvedValues(await value(of: pending)) == ["CLOUDFLARE_TOKEN": Self.tokenValue])

        // A granted request does not wait, so it does not park.
        let again = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller, parker: parker))
        #expect(resolvedValues(again) == ["CLOUDFLARE_TOKEN": Self.tokenValue])
        #expect(parker.calls == 1)
    }

    @Test func resolveWithoutParkedSlotIsOverloadedWithoutPrompt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)
        let parker = ParkRecorder(parks: false)

        let result = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller(), parker: parker))
        #expect(errorCode(result) == ControlOverloadResponder.errorCode)
        #expect(parker.calls == 1)
        #expect(registry.pendingRequests.isEmpty)
        #expect(registry.waiterCount == 0)
        #expect(!Self.serialized(result).contains(Self.tokenValue))
    }

    @Test func resolveDeniedReturnsNotApprovedWithoutValues() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)

        let pending = startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller())
        try #require(await waitUntil { registry.pendingRequests.count == 1 })
        let request = try #require(registry.pendingRequests.first)
        registry.decide(requestID: request.id, allow: false)

        let result = await value(of: pending)
        #expect(errorCode(result) == "not_approved")
        #expect(errorData(result)?["names"] as? [String] == ["CLOUDFLARE_TOKEN"])
        #expect(!Self.serialized(result).contains(Self.tokenValue))
        let snapshot = await repository.snapshot()
        #expect(snapshot.entries.first?.metadata.lastUsedAt == nil)
    }

    @Test func resolveWithUnreadableKeychainReturnsKeychainUnavailable() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        _ = try await repository.add(name: "CLOUDFLARE_TOKEN", value: Self.tokenValue, note: "")
        store.setLoadError(.keychainUnavailable(status: -25293))
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: repository, approvals: registry)

        let result = await value(of: startResolve(service, names: ["CLOUDFLARE_TOKEN"], caller: caller()))
        #expect(errorCode(result) == "keychain_unavailable")
        #expect(errorData(result)?["status"] as? Int == -25293)
        #expect(registry.pendingRequests.isEmpty)
    }

    @Test(arguments: [
        ["command": "curl"] as [String: Any],
        ["names": [String](), "command": "curl"],
        ["names": "CLOUDFLARE_TOKEN", "command": "curl"],
        ["names": ["CLOUDFLARE_TOKEN"]],
        ["names": ["CLOUDFLARE_TOKEN"], "command": 1],
    ] as [[String: Any]])
    func resolveRejectsMalformedParams(params: [String: Any]) async throws {
        let registry = makeRegistry()
        let service = SafeboxSocketService(repository: makeRepository(), approvals: registry)
        let result = Self.wire(await service.resolve(params: params, caller: caller()))
        #expect(errorCode(result) == "invalid_params")
        #expect(registry.pendingRequests.isEmpty)
    }

    @Test func resolveInvalidNameDoesNotEchoInput() async throws {
        let pasted = "sk-live-pasted-token-value"
        let service = SafeboxSocketService(repository: makeRepository(), approvals: makeRegistry())
        let result = Self.wire(await service.resolve(params: ["names": [pasted], "command": "curl"], caller: caller()))
        #expect(errorCode(result) == "invalid_params")
        #expect(!Self.serialized(result).lowercased().contains(pasted))
    }

    private static func identity(_ pid: Int32, tty: Int64? = nil, start: Int = 1) -> SafeboxCallerLocator.Identity {
        SafeboxCallerLocator.Identity(
            ttyDevice: tty,
            birth: CmuxTopProcessScopeCacheKey(pid: Int(pid), startSeconds: start, startMicroseconds: 0)
        )
    }

    @Test func callerLocatorUsesNearestTerminalAncestor() {
        let surface = UUID()
        let workspace = UUID()
        let paneDevice: Int64 = 0x1000_0010
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 50, 50: 1]
        let identities: [Int32: SafeboxCallerLocator.Identity] = [
            300: Self.identity(300),
            200: Self.identity(200),
            100: Self.identity(100, tty: paneDevice),
            50: Self.identity(50),
        ]
        let locator = SafeboxCallerLocator(
            host: 50,
            identity: { identities[$0] },
            parent: { parents[$0] },
            terminal: { $0 == paneDevice ? AgentDeliveryTargetCandidate(workspaceId: workspace, surfaceId: surface) : nil }
        )

        // A detached worker (no controlling terminal) inherits its session's pane.
        #expect(locator.terminal(ofPeer: 300)?.surfaceId == surface)
        #expect(locator.terminal(ofPeer: 100)?.workspaceId == workspace)
        // The walk stops at cmux itself and at launchd.
        #expect(locator.terminal(ofPeer: 50) == nil)
        #expect(locator.terminal(ofPeer: nil) == nil)
    }

    @Test func callerLocatorRefusesParentLoopsAndGoneProcesses() {
        let parents: [Int32: Int32] = [300: 200, 200: 300, 400: 401]
        let identities: [Int32: SafeboxCallerLocator.Identity] = [
            300: Self.identity(300), 200: Self.identity(200), 400: Self.identity(400),
        ]
        let locator = SafeboxCallerLocator(
            host: 50,
            identity: { identities[$0] },
            parent: { parents[$0] },
            terminal: { _ in AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID()) }
        )
        #expect(locator.terminal(ofPeer: 300) == nil)
        // 401 has no identity (it exited): fail closed.
        #expect(locator.terminal(ofPeer: 400) == nil)
    }

    @Test func callerLocatorRefusesPIDReusedDuringTheWalk() {
        let paneDevice: Int64 = 0x1000_0011
        let parents: [Int32: Int32] = [300: 100]
        var reads = 0
        let locator = SafeboxCallerLocator(
            host: 50,
            identity: { pid in
                if pid == 300 {
                    // The peer exited after the walk read it; a new process got its pid.
                    reads += 1
                    return Self.identity(300, start: reads == 1 ? 1 : 2)
                }
                return pid == 100 ? Self.identity(100, tty: paneDevice) : nil
            },
            parent: { parents[$0] },
            terminal: { $0 == paneDevice ? AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID()) : nil }
        )
        #expect(locator.terminal(ofPeer: 300) == nil)
    }

    @Test func reportedTTYDoesNotIdentifyACaller() throws {
        // `surface.report_tty` lets any local socket client claim a TTY for a
        // pane. Agent delivery accepts such reports; Safebox must not.
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let reportedName = "/dev/tty"
        let reportedDevice = try #require(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: reportedName))
        workspace.registerReportedSurfaceTTYName(reportedName, panelId: panelID)

        #expect(workspace.localAgentDeliveryTTYDevices.contains { $0.ttyDevice == reportedDevice })
        #expect(!workspace.safeboxOwnedTTYDevices.contains { $0.ttyDevice == reportedDevice })
        #expect(!workspace.safeboxOwnedTTYDevices.contains { $0.surfaceId == panelID })
    }

    @Test(arguments: ["safebox.list", "safebox.resolve"])
    func handlerRefusesRelayProvenance(method: String) async {
        let request = ControlRequest(
            id: .string("relay"),
            method: method,
            params: [
                WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey: .string(UUID().uuidString),
                "names": .array([.string("CLOUDFLARE_TOKEN")]),
                "command": .string("env"),
            ]
        )
        let result = Self.wire(await TerminalController.shared.safeboxResult(request))
        #expect(errorCode(result) == "not_authorized")
    }
}
