import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Safebox list model", .timeLimit(.minutes(1)))
struct SafeboxListModelTests {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var loadError: SafeboxError?
        private var gate: DispatchSemaphore?
        private var blockedLoads = 0

        func setLoadError(_ error: SafeboxError?) { lock.withLock { loadError = error } }
        /// Makes the next loads wait until `openGate()` is called.
        func closeGate() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
        func openGate() {
            let current = lock.withLock { () -> DispatchSemaphore? in
                defer { gate = nil }
                return gate
            }
            current?.signal()
        }
        private var loads = 0
        var blockedLoadCount: Int { lock.withLock { blockedLoads } }
        /// Every Keychain read the repository made.
        var loadCount: Int { lock.withLock { loads } }
        func load() throws -> [String: String] {
            if let gate = lock.withLock({ () -> DispatchSemaphore? in
                loads += 1
                if gate != nil { blockedLoads += 1 }
                return gate
            }) {
                gate.wait()
            }
            return try lock.withLock {
                if let loadError { throw loadError }
                return values
            }
        }
        func save(_ newValues: [String: String]) { lock.withLock { values = newValues } }
        var current: [String: String] { lock.withLock { values } }
    }

    private let store = Store()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("safebox-list-model-tests-\(UUID().uuidString)", isDirectory: true)

    private var metadataURL: URL { directory.appendingPathComponent("safebox.json") }

    private func makeRepository() -> SafeboxRepository {
        let store = store
        return SafeboxRepository(
            metadataFile: SafeboxMetadataFile(fileURL: metadataURL),
            loadValues: { try store.load() },
            saveValues: { store.save($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            usageFlushInterval: .seconds(3600)
        )
    }

    private func makeModel(
        repository: SafeboxRepository? = nil,
        approvals: SafeboxApprovalRegistry? = nil,
        copied: CopyRecorder? = nil,
        pasteboardClock: SafeboxManualTestClock = SafeboxManualTestClock(),
        captureConcealment: SafeboxCaptureConcealment? = nil
    ) -> SafeboxListModel {
        SafeboxListModel(
            repository: repository ?? makeRepository(),
            approvals: approvals ?? SafeboxApprovalRegistry(),
            pasteboard: copied ?? CopyRecorder(),
            pasteboardClock: pasteboardClock,
            captureConcealment: captureConcealment
        )
    }

    /// A pasteboard that records writes; `changeCount` moves on every change
    /// like `NSPasteboard`'s.
    @MainActor
    private final class CopyRecorder: SafeboxValuePasteboard {
        var values: [String] = []
        private(set) var changeCount = 0
        private(set) var clearCount = 0

        func writeConcealed(_ value: String) {
            values.append(value)
            changeCount += 1
        }

        func clearContents() {
            clearCount += 1
            changeCount += 1
        }

        /// Something outside Safebox copied.
        func otherAppCopied() { changeCount += 1 }
    }

    /// Whether a recording runs, for the capture tests.
    private final class RecordingFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var recording = false
        var isOn: Bool {
            get { lock.withLock { recording } }
            set { lock.withLock { recording = newValue } }
        }
    }

    private func makeConcealment(recording: RecordingFlag = RecordingFlag()) -> SafeboxCaptureConcealment {
        SafeboxCaptureConcealment(isRecording: { recording.isOn }, flushDisplay: {})
    }

    private func name(_ raw: String) -> SafeboxSecretName {
        SafeboxSecretName(normalizing: raw)!
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

    /// Lets woken tasks run, for checks that something did not happen.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func searchFiltersByNameAndNote() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "CLOUDFLARE_TOKEN", value: "cf-value", note: "zone example.com")
        try await model.save(editing: nil, name: "COOLIFY_TOKEN", value: "co-value", note: "deploys")
        try await model.save(editing: nil, name: "OPENAI_KEY", value: "oa-value", note: "")

        #expect(model.rows.map(\.name.rawValue) == ["CLOUDFLARE_TOKEN", "COOLIFY_TOKEN", "OPENAI_KEY"])

        model.searchText = "coolify"
        #expect(model.rows.map(\.name.rawValue) == ["COOLIFY_TOKEN"])

        model.searchText = "EXAMPLE.COM"
        #expect(model.rows.map(\.name.rawValue) == ["CLOUDFLARE_TOKEN"])

        model.searchText = "  token "
        #expect(model.rows.map(\.name.rawValue) == ["CLOUDFLARE_TOKEN", "COOLIFY_TOKEN"])

        model.searchText = "nothing-matches"
        #expect(model.rows.isEmpty)
    }

    @Test func revealIsResetOnHideAll() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "API_KEY", value: "secret-api-value", note: "")
        try await model.save(editing: nil, name: "OTHER", value: "secret-other-value", note: "")

        await model.toggleReveal(name("API_KEY"))
        #expect(model.revealedNames == [name("API_KEY")])
        #expect(model.rows.first { $0.name == name("API_KEY") }?.revealedValue == "secret-api-value")
        #expect(model.rows.first { $0.name == name("OTHER") }?.revealedValue == nil)

        await model.toggleReveal(name("OTHER"))
        model.hideAllValues()
        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })

        // A second toggle on a revealed row hides it again.
        await model.toggleReveal(name("API_KEY"))
        await model.toggleReveal(name("API_KEY"))
        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })
    }

    @Test func revealFinishingAfterHideAllStaysHidden() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "API_KEY", value: "secret-api-value", note: "")

        store.closeGate()
        let reveal = Task { await model.toggleReveal(name("API_KEY")) }
        try await waitForBlockedLoad()
        model.hideAllValues()
        store.openGate()
        await reveal.value
        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })
    }

    @Test func revealStillShowsWhenAppResignsDuringFetch() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "API_KEY", value: "secret-api-value", note: "")
        try await model.save(editing: nil, name: "OTHER", value: "secret-other-value", note: "")
        await model.toggleReveal(name("OTHER"))

        // The Keychain prompt shown during the fetch makes cmux resign active.
        store.closeGate()
        let reveal = Task { await model.toggleReveal(name("API_KEY")) }
        try await waitForBlockedLoad()
        let loadsBeforeResign = store.loadCount
        model.appDidResignActive()
        #expect(store.loadCount == loadsBeforeResign)
        #expect(model.revealedNames.isEmpty)
        store.openGate()
        await reveal.value

        #expect(model.revealedNames == [name("API_KEY")])
        #expect(model.rows.first { $0.name == name("API_KEY") }?.revealedValue == "secret-api-value")
        #expect(model.rows.first { $0.name == name("OTHER") }?.revealedValue == nil)
    }

    @Test func eyeClickWhileLoadingDoesNotFetchAgain() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "API_KEY", value: "secret-api-value", note: "")

        store.closeGate()
        let reveal = Task { await model.toggleReveal(name("API_KEY")) }
        try await waitForBlockedLoad()
        let loads = store.loadCount
        // Returns at once; a second fetch would block on the closed gate.
        await model.toggleReveal(name("API_KEY"))
        #expect(store.loadCount == loads)
        store.openGate()
        await reveal.value

        #expect(model.revealedNames == [name("API_KEY")])
    }

    @Test func multiLineValueRoundTripsByteForByte() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let model = makeModel(repository: repository)
        let pem = "-----BEGIN KEY-----\nline one\r\nline two\n  indented\t\"quoted\" -- dash\n-----END KEY-----\n"

        try await model.save(editing: nil, name: "PEM_KEY", value: pem, note: "")
        #expect(store.current["PEM_KEY"] == pem)
        #expect(Array(try await repository.value(for: name("PEM_KEY")).utf8) == Array(pem.utf8))

        let updated = "{\r\n  \"k\": \"v\"\r\n}\r\n\n"
        try await model.save(editing: name("PEM_KEY"), name: "PEM_KEY", value: updated, note: "")
        #expect(Array(try #require(store.current["PEM_KEY"]).utf8) == Array(updated.utf8))

        await model.toggleReveal(name("PEM_KEY"))
        #expect(model.rows.first?.revealedValue == updated)
    }

    @Test func visibleValueFieldPasteKeepsTextVerbatim() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("safebox-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let pem = "-----BEGIN KEY-----\nabc\r\n\"q\" -- d\n-----END KEY-----\n"
        pasteboard.clearContents()
        pasteboard.setString(pem, forType: .string)

        let textView = SafeboxPlainTextView.make()
        textView.pasteboardForPaste = pasteboard
        textView.paste(nil)

        #expect(Array(textView.string.utf8) == Array(pem.utf8))
        #expect(!textView.allowsUndo)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
        if #available(macOS 14.0, *) {
            #expect(textView.inlinePredictionType == .no)
        }
        if #available(macOS 15.0, *) {
            #expect(textView.writingToolsBehavior == .none)
        }
        #expect(textView.validRequestor(forSendType: .string, returnType: nil) == nil)

        textView.wipe()
        #expect(textView.string.isEmpty)
    }

    @Test func multiLineValueIsNotPutIntoSecureField() {
        #expect(SafeboxHiddenValueInput(value: "") == .secureField)
        #expect(SafeboxHiddenValueInput(value: "single-line token") == .secureField)
        #expect(SafeboxHiddenValueInput(value: "a\nb") == .multiLinePlaceholder(lineCount: 2))
        #expect(SafeboxHiddenValueInput(value: "a\r\nb\r\nc") == .multiLinePlaceholder(lineCount: 3))
        #expect(SafeboxHiddenValueInput(value: "a\rb") == .multiLinePlaceholder(lineCount: 2))
        #expect(SafeboxHiddenValueInput(value: "token\n") == .multiLinePlaceholder(lineCount: 1))
        #expect(SafeboxHiddenValueInput(value: "-----BEGIN-----\nx\n-----END-----\n") == .multiLinePlaceholder(lineCount: 3))
    }

    @Test func saveNewSecretAppearsSorted() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "ZETA", value: "z", note: "")
        try await model.save(editing: nil, name: "alpha_token", value: "a", note: "for tests")
        try await model.save(editing: nil, name: "MIDDLE", value: "m", note: "")

        #expect(model.rows.map(\.name.rawValue) == ["ALPHA_TOKEN", "MIDDLE", "ZETA"])
        let alpha = try #require(model.rows.first)
        #expect(alpha.note == "for tests")
        #expect(alpha.valueState == .present)
        #expect(alpha.lastUsedAt == nil)
        #expect(store.current["ALPHA_TOKEN"] == "a")

        await #expect(throws: SafeboxError.duplicateName("ZETA")) {
            try await model.save(editing: nil, name: "zeta", value: "again", note: "")
        }
        await #expect(throws: SafeboxListModel.ValidationError.valueRequired) {
            try await model.save(editing: nil, name: "NO_VALUE", value: nil, note: "")
        }
        #expect(model.rows.count == 3)
    }

    @Test func renameKeepsValue() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let model = makeModel(repository: repository)
        try await model.save(editing: nil, name: "OLD_NAME", value: "kept-value", note: "first")
        await model.toggleReveal(name("OLD_NAME"))

        try await model.save(editing: name("OLD_NAME"), name: "new_name", value: nil, note: "second")

        #expect(model.rows.map(\.name.rawValue) == ["NEW_NAME"])
        #expect(model.rows.first?.note == "second")
        #expect(try await repository.value(for: name("NEW_NAME")) == "kept-value")
        #expect(store.current == ["NEW_NAME": "kept-value"])
        // A value revealed under the old name is not carried over.
        #expect(model.revealedNames.isEmpty)
    }

    @Test func deleteRemovesRow() async throws {
        defer { cleanUp() }
        let approvals = SafeboxApprovalRegistry()
        let model = makeModel(approvals: approvals)
        try await model.save(editing: nil, name: "KEEP", value: "k", note: "")
        try await model.save(editing: nil, name: "DROP", value: "d", note: "")
        await model.toggleReveal(name("DROP"))
        let session = SafeboxSessionKey(surfaceID: UUID(), agentSessionID: "s1")
        try await grant(approvals, name("DROP"), to: session)

        try await model.delete(name("DROP"))

        #expect(model.rows.map(\.name.rawValue) == ["KEEP"])
        #expect(store.current == ["KEEP": "k"])
        #expect(model.revealedNames.isEmpty)
        // A later secret with the same name does not inherit the old grant.
        #expect(approvals.grants(for: name("DROP")).isEmpty)
    }

    @Test func rowShowsGrantCount() async throws {
        defer { cleanUp() }
        let approvals = SafeboxApprovalRegistry()
        let model = makeModel(approvals: approvals)
        try await model.save(editing: nil, name: "TOKEN", value: "t", note: "")
        try await model.save(editing: nil, name: "UNUSED", value: "u", note: "")
        let first = SafeboxSessionKey(surfaceID: UUID(), agentSessionID: "a")
        let second = SafeboxSessionKey(surfaceID: UUID(), agentSessionID: nil)
        try await grant(approvals, name("TOKEN"), to: first)
        try await grant(approvals, name("TOKEN"), to: second)

        let token = try #require(model.rows.first { $0.name == name("TOKEN") })
        #expect(token.grants == [first, second])
        #expect(model.rows.first { $0.name == name("UNUSED") }?.grants.isEmpty == true)

        model.revoke(name("TOKEN"), session: first)
        #expect(model.rows.first { $0.name == name("TOKEN") }?.grants == [second])
    }

    @Test func copyValueWritesThePasteboard() async throws {
        defer { cleanUp() }
        let copied = CopyRecorder()
        let model = makeModel(copied: copied)
        try await model.save(editing: nil, name: "TOKEN", value: "copy-me", note: "")

        await model.copyValue(name("TOKEN"))

        #expect(copied.values == ["copy-me"])
        // Copying does not reveal the value in the list.
        #expect(model.revealedNames.isEmpty)
    }

    @Test func copiedValueIsClearedAfterAMinuteWhenNothingElseWasCopied() async throws {
        defer { cleanUp() }
        let copied = CopyRecorder()
        let clock = SafeboxManualTestClock()
        let model = makeModel(copied: copied, pasteboardClock: clock)
        try await model.save(editing: nil, name: "TOKEN", value: "copy-me", note: "")

        await model.copyValue(name("TOKEN"))
        try #require(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(59))
        await settle()
        #expect(copied.clearCount == 0)

        clock.advance(by: .seconds(1))
        #expect(await waitUntil { copied.clearCount == 1 })
    }

    @Test func copiedValueIsKeptWhenSomethingElseWasCopied() async throws {
        defer { cleanUp() }
        let copied = CopyRecorder()
        let clock = SafeboxManualTestClock()
        let model = makeModel(copied: copied, pasteboardClock: clock)
        try await model.save(editing: nil, name: "TOKEN", value: "copy-me", note: "")

        await model.copyValue(name("TOKEN"))
        try #require(await waitUntil { clock.sleeperCount == 1 })
        copied.otherAppCopied()
        clock.advance(by: .seconds(60))
        try #require(await waitUntil { clock.sleeperCount == 0 })
        await settle()

        #expect(copied.clearCount == 0)
    }

    @Test func aSecondCopyRestartsTheMinute() async throws {
        defer { cleanUp() }
        let copied = CopyRecorder()
        let clock = SafeboxManualTestClock()
        let model = makeModel(copied: copied, pasteboardClock: clock)
        try await model.save(editing: nil, name: "TOKEN", value: "copy-me", note: "")

        await model.copyValue(name("TOKEN"))
        try #require(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(30))
        await model.copyValue(name("TOKEN"))
        // The first timer was cancelled; only the second one sleeps.
        try #require(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(30))
        await settle()
        #expect(copied.clearCount == 0)

        clock.advance(by: .seconds(30))
        #expect(await waitUntil { copied.clearCount == 1 })
        #expect(copied.values == ["copy-me", "copy-me"])
    }

    @Test func captureHidesRevealedValuesAndTheEditorValue() async throws {
        defer { cleanUp() }
        let concealment = makeConcealment()
        let model = makeModel(captureConcealment: concealment)
        try await model.save(editing: nil, name: "TOKEN", value: "shown-value", note: "")
        await model.toggleReveal(name("TOKEN"))
        #expect(await model.setEditorValueVisible(true))
        try #require(model.rows.first?.revealedValue == "shown-value")
        try #require(model.isEditorValueVisible)

        concealment.concealForCapture()

        // Synchronously: nothing is left for the capture to render.
        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })
        #expect(!model.isEditorValueVisible)
    }

    @Test func captureDiscardsARevealStillLoading() async throws {
        defer { cleanUp() }
        let concealment = makeConcealment()
        let model = makeModel(captureConcealment: concealment)
        try await model.save(editing: nil, name: "TOKEN", value: "late-value", note: "")
        store.closeGate()
        let reveal = Task { await model.toggleReveal(name("TOKEN")) }
        try #require(await waitUntil { store.blockedLoadCount == 1 })

        concealment.concealForCapture()
        store.openGate()
        await reveal.value

        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })
    }

    @Test func nothingIsRevealedWhileARecordingRuns() async throws {
        defer { cleanUp() }
        let recording = RecordingFlag()
        let model = makeModel(captureConcealment: makeConcealment(recording: recording))
        try await model.save(editing: nil, name: "TOKEN", value: "secret-value", note: "")
        recording.isOn = true

        await model.toggleReveal(name("TOKEN"))
        #expect(model.revealedNames.isEmpty)
        #expect(model.actionError == SafeboxListModel.recordingMessage)
        #expect(await model.setEditorValueVisible(true) == false)
        #expect(!model.isEditorValueVisible)

        recording.isOn = false
        await model.toggleReveal(name("TOKEN"))
        #expect(model.rows.first?.revealedValue == "secret-value")
    }

    @Test func everyCaptureEntryPointCallsTheHideHook() async throws {
        defer { cleanUp() }
        let appDelegate = try #require(AppDelegate.shared)
        let model = makeModel(captureConcealment: appDelegate.safeboxCaptureConcealment)
        try await model.save(editing: nil, name: "TOKEN", value: "shown-value", note: "")
        await model.toggleReveal(name("TOKEN"))
        try #require(!model.revealedNames.isEmpty)

        // `window.screenshot` and `window.record.start` resolve their window
        // here, before any frame is read; an unknown handle still conceals.
        _ = TerminalController.shared.captureWindowID(handle: "not-a-window")

        #expect(model.revealedNames.isEmpty)
        #expect(model.rows.allSatisfy { $0.revealedValue == nil })
    }

    @Test func unreadableKeychainIsUnknownState() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "TOKEN", value: "t", note: "")
        store.setLoadError(.keychainUnavailable(status: -25293))

        await model.reload()

        #expect(model.keychainError == .keychainUnavailable(status: -25293))
        #expect(model.rows.map(\.valueState) == [.unknown])
        await model.toggleReveal(name("TOKEN"))
        #expect(model.revealedNames.isEmpty)
        #expect(model.actionError != nil)
    }

    @Test func missingValueIsReported() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "TOKEN", value: "t", note: "")
        store.save([:])

        await model.reload()

        #expect(model.rows.map(\.valueState) == [.missing])
    }

    @Test func unreadableMetadataDisablesChanges() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: metadataURL)
        store.save(["SOME_VALUE": "v"])
        let model = makeModel()

        await model.reload()

        #expect(model.metadataError == .metadataUnavailable)
        #expect(!model.canModify)
        // While metadata is unreadable every stored value looks like an orphan,
        // so none are offered.
        #expect(model.orphanNames.isEmpty)
        await #expect(throws: SafeboxError.metadataUnavailable) {
            try await model.save(editing: nil, name: "NEW", value: "n", note: "")
        }
        #expect(try String(contentsOf: metadataURL, encoding: .utf8) == "not json")
    }

    @Test func retryAfterRepairingMetadataReenablesChanges() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: metadataURL)
        let model = makeModel()
        await model.reload()
        #expect(!model.canModify)

        try FileManager.default.removeItem(at: metadataURL)
        try SafeboxMetadataFile(fileURL: metadataURL).save([])
        // The banner's Retry reloads the model.
        await model.reload()

        #expect(model.metadataError == nil)
        #expect(model.canModify)
        try await model.save(editing: nil, name: "NEW", value: "n", note: "")
        #expect(model.rows.map(\.name.rawValue) == ["NEW"])
    }

    @Test func orphanValuesAreListed() async throws {
        defer { cleanUp() }
        let model = makeModel()
        try await model.save(editing: nil, name: "TOKEN", value: "t", note: "")
        store.save(["TOKEN": "t", "STRAY": "s"])

        await model.reload()

        #expect(model.canModify)
        #expect(model.orphanNames == ["STRAY"])
    }

    // MARK: - Helpers

    /// Waits until a Keychain load is parked on the closed gate.
    private func waitForBlockedLoad() async throws {
        for _ in 0..<1000 where store.blockedLoadCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(store.blockedLoadCount == 1)
    }

    private func grant(
        _ approvals: SafeboxApprovalRegistry,
        _ secret: SafeboxSecretName,
        to session: SafeboxSessionKey
    ) async throws {
        let access = Task { @MainActor in
            await approvals.requestAccess(session: session, workspaceID: UUID(), names: [secret], command: "test")
        }
        for _ in 0..<1000 where approvals.pendingRequests.isEmpty {
            await Task.yield()
        }
        let request = try #require(approvals.pendingRequests.first)
        approvals.decide(requestID: request.id, allow: true)
        #expect(await access.value)
    }
}
