import AppKit
import Foundation
import Observation

/// Immutable row data for one secret in the Safebox list. Rows below the list
/// boundary receive this snapshot plus closures, never the model.
struct SafeboxSecretRowSnapshot: Identifiable, Equatable {
    /// What the list may claim about the stored value.
    enum ValueState: Equatable {
        case present
        case missing
        /// The Keychain could not be read, so presence is not known.
        case unknown
    }

    let name: SafeboxSecretName
    let note: String
    let updatedAt: Date
    let lastUsedAt: Date?
    let valueState: ValueState
    /// The plain value while the user has it revealed, otherwise nil.
    let revealedValue: String?
    /// Sessions currently allowed to receive this secret, in grant order.
    let grants: [SafeboxSessionKey]

    var id: SafeboxSecretName { name }
}

extension SafeboxSecretRowSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// Keeps a revealed value out of `print`, `dump` and string interpolation.
    var description: String {
        "SafeboxSecretRowSnapshot(name: \(name.rawValue), revealed: \(revealedValue != nil))"
    }

    var debugDescription: String { description }
}

/// State of the Vault "Safebox" tab: the secret list, search, revealed values
/// and the add/edit/delete/copy/revoke actions.
///
/// Revealed values live only here and are dropped by `hideAllValues()`. They
/// are never logged. Before cmux captures one of its windows they are dropped
/// along with the editor's visible value field (``concealForCapture()``), and
/// nothing is revealed while a window recording runs.
@MainActor
@Observable
final class SafeboxListModel: SafeboxCaptureConcealing {
    enum ValidationError: Error, Equatable, LocalizedError {
        case valueRequired

        var errorDescription: String? {
            switch self {
            case .valueRequired:
                return String(localized: "safebox.editor.valueRequired", defaultValue: "Enter a value.")
            }
        }
    }

    var searchText = ""
    /// The last failed reveal or copy, shown above the list. Never contains a value.
    var actionError: String?
    private(set) var hasLoaded = false
    private(set) var keychainError: SafeboxError?
    private(set) var metadataError: SafeboxError?
    private(set) var revealedNames: Set<SafeboxSecretName> = []
    /// Whether the editor sheet shows its value field in plain text.
    private(set) var isEditorValueVisible = false

    private var entries: [SafeboxEntry] = []
    private var storedOrphanNames: [String] = []
    private var revealedValues: [SafeboxSecretName: String] = [:]
    /// Bumped by `hideAllValues()` so a reveal that was in flight is discarded.
    @ObservationIgnored private var revealGeneration = 0
    /// One token per reveal that is still loading. A click on a name that is
    /// loading is ignored; removing the token (rename, delete, hide all)
    /// discards the result when it arrives.
    @ObservationIgnored private var pendingRevealTokens: [SafeboxSecretName: UUID] = [:]
    /// Bumped by `concealForCapture()` so an editor reveal that was waiting
    /// for the recording check is discarded.
    @ObservationIgnored private var editorRevealGeneration = 0

    @ObservationIgnored private let repository: SafeboxRepository
    @ObservationIgnored private let approvals: SafeboxApprovalRegistry
    @ObservationIgnored private let copiedValueExpiry: SafeboxCopiedValueExpiry
    @ObservationIgnored private let captureConcealment: SafeboxCaptureConcealment?

    /// - Parameters:
    ///   - pasteboard: Where Copy Value writes (default: the general
    ///     pasteboard); the value is cleared from it after a minute unless
    ///     something else was copied.
    ///   - pasteboardClock: Times that clearing.
    ///   - captureConcealment: The app's capture hook; the model registers
    ///     with it so window captures never show a value.
    init(
        repository: SafeboxRepository,
        approvals: SafeboxApprovalRegistry,
        pasteboard: (any SafeboxValuePasteboard)? = nil,
        pasteboardClock: any Clock<Duration> = ContinuousClock(),
        captureConcealment: SafeboxCaptureConcealment? = nil
    ) {
        self.repository = repository
        self.approvals = approvals
        self.copiedValueExpiry = SafeboxCopiedValueExpiry(
            pasteboard: pasteboard ?? SafeboxGeneralPasteboard(),
            clock: pasteboardClock
        )
        self.captureConcealment = captureConcealment
        captureConcealment?.register(self)
    }

    /// False while the metadata file is unreadable: any write could replace it.
    var canModify: Bool { metadataError == nil }

    /// True when no secret is stored at all (independent of the search).
    var isEmpty: Bool { entries.isEmpty }

    /// Values in the Keychain that have no metadata entry. Empty while the
    /// metadata file is unreadable, because then every value would be listed.
    var orphanNames: [String] { metadataError == nil ? storedOrphanNames : [] }

    /// Secrets matching `searchText` by name or note, sorted by name.
    var rows: [SafeboxSecretRowSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries
            .filter { entry in
                query.isEmpty
                    || entry.metadata.name.rawValue.localizedCaseInsensitiveContains(query)
                    || entry.metadata.note.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.metadata.name < $1.metadata.name }
            .map { entry in
                let name = entry.metadata.name
                return SafeboxSecretRowSnapshot(
                    name: name,
                    note: entry.metadata.note,
                    updatedAt: entry.metadata.updatedAt,
                    lastUsedAt: entry.metadata.lastUsedAt,
                    valueState: valueState(of: entry),
                    revealedValue: revealedValues[name],
                    grants: approvals.grants(for: name)
                )
            }
    }

    func reload() async {
        let snapshot = await repository.snapshot()
        entries = snapshot.entries
        storedOrphanNames = snapshot.orphanNames
        keychainError = snapshot.keychainError
        metadataError = snapshot.metadataError
        hasLoaded = true
        let known = Set(entries.map(\.metadata.name))
        for name in revealedNames where !known.contains(name) {
            forgetRevealed(name)
        }
    }

    /// Shows the value of `name`, or hides it when it is shown.
    func toggleReveal(_ name: SafeboxSecretName) async {
        if revealedNames.contains(name) {
            forgetRevealed(name)
            return
        }
        // The value is still loading (possibly behind a Keychain prompt).
        guard pendingRevealTokens[name] == nil else { return }
        let token = UUID()
        pendingRevealTokens[name] = token
        let generation = revealGeneration
        if await isRecordingWindow() {
            if pendingRevealTokens[name] == token { pendingRevealTokens[name] = nil }
            actionError = Self.recordingMessage
            return
        }
        let result: Result<String, Error>
        do {
            result = .success(try await repository.value(for: name))
        } catch {
            result = .failure(error)
        }
        guard pendingRevealTokens[name] == token else { return }
        pendingRevealTokens[name] = nil
        guard generation == revealGeneration else { return }
        switch result {
        case .success(let value):
            revealedValues[name] = value
            revealedNames.insert(name)
            actionError = nil
        case .failure(let error):
            actionError = Self.message(for: error)
        }
    }

    /// Drops every revealed value from memory and from the rows, and discards
    /// reveals that are still loading. Used when the tab goes away or the
    /// sidebar collapses.
    func hideAllValues() {
        revealGeneration &+= 1
        pendingRevealTokens = [:]
        concealShownValues()
    }

    /// Called on the main actor right before cmux captures one of its own
    /// windows: hides every revealed value, discards reveals still loading
    /// and turns the editor's value field back to hidden.
    func concealForCapture() {
        hideAllValues()
        editorRevealGeneration &+= 1
        isEditorValueVisible = false
    }

    /// Shows or hides the editor's value in plain text. Showing it is refused
    /// while a window recording runs; returns false then.
    @discardableResult
    func setEditorValueVisible(_ visible: Bool) async -> Bool {
        guard visible else {
            isEditorValueVisible = false
            return true
        }
        let generation = editorRevealGeneration
        if await isRecordingWindow() { return false }
        guard generation == editorRevealGeneration else { return true }
        isEditorValueVisible = true
        return true
    }

    /// Called when the app resigns active. Drops the values on screen but lets
    /// a reveal that is still loading finish: the Keychain access prompt
    /// itself makes cmux resign active, and the click that caused it must
    /// still show the value. Reads nothing from the repository.
    func appDidResignActive() {
        concealShownValues()
    }

    /// Adds a secret (`editing == nil`) or updates `editing`. A nil `value`
    /// keeps the stored value on update and is rejected on add.
    func save(editing: SafeboxSecretName?, name: String, value: String?, note: String) async throws {
        if let editing {
            let updated = try await repository.update(name: editing, newName: name, value: value, note: note)
            forgetRevealed(editing)
            forgetRevealed(updated.name)
            if updated.name != editing {
                // Grants follow the name; a later secret reusing the old name
                // must be approved again.
                revokeAllGrants(for: editing)
            }
        } else {
            guard let value else { throw ValidationError.valueRequired }
            _ = try await repository.add(name: name, value: value, note: note)
        }
        await reload()
    }

    func delete(_ name: SafeboxSecretName) async throws {
        try await repository.delete(name: name)
        forgetRevealed(name)
        revokeAllGrants(for: name)
        await reload()
    }

    /// Puts the value of `name` on the pasteboard without revealing it, and
    /// removes it from there after a minute unless something else was copied.
    func copyValue(_ name: SafeboxSecretName) async {
        do {
            let value = try await repository.value(for: name)
            copiedValueExpiry.copy(value)
            actionError = nil
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func revoke(_ name: SafeboxSecretName, session: SafeboxSessionKey) {
        approvals.revoke(name: name, session: session)
    }

    func revokeAllGrants(for name: SafeboxSecretName) {
        for session in approvals.grants(for: name) {
            approvals.revoke(name: name, session: session)
        }
    }

    // MARK: - Private

    private func valueState(of entry: SafeboxEntry) -> SafeboxSecretRowSnapshot.ValueState {
        // An unreadable Keychain reports every entry as `.ok`; do not claim it.
        if keychainError != nil { return .unknown }
        switch entry.state {
        case .ok: return .present
        case .valueMissing: return .missing
        }
    }

    private func concealShownValues() {
        guard !revealedNames.isEmpty || !revealedValues.isEmpty else { return }
        revealedValues = [:]
        revealedNames = []
    }

    /// Hides `name` and discards a reveal of it that is still loading.
    private func forgetRevealed(_ name: SafeboxSecretName) {
        pendingRevealTokens[name] = nil
        revealedValues[name] = nil
        revealedNames.remove(name)
    }

    private func isRecordingWindow() async -> Bool {
        guard let captureConcealment else { return false }
        return await captureConcealment.isRecordingWindow()
    }

    static let recordingMessage = String(
        localized: "safebox.error.recording",
        defaultValue: "Values are not shown while cmux is recording a window."
    )

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(localized: "safebox.error.generic", defaultValue: "The operation could not be completed.")
    }
}
