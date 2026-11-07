import Foundation

/// Failures of safebox operations. Descriptions never contain secret values.
enum SafeboxError: Error, Equatable, Sendable {
    case invalidName(String)
    case duplicateName(String)
    case unknownSecrets([String])
    case keychainUnavailable(status: Int32)
    case notApproved([String])
    case notInCmuxTerminal
    /// The metadata file exists but cannot be read or decoded; it is left untouched.
    case metadataUnavailable
}

extension SafeboxError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidName:
            return String(
                localized: "safebox.error.invalidName",
                defaultValue: "Secret names may contain only A-Z, 0-9 and _, and must not start with a digit."
            )
        case .duplicateName(let name):
            return String(
                localized: "safebox.error.duplicateName",
                defaultValue: "A secret named \(name) already exists."
            )
        case .unknownSecrets(let names):
            return String(
                localized: "safebox.error.unknownSecrets",
                defaultValue: "Unknown secrets: \(names.joined(separator: ", "))."
            )
        case .keychainUnavailable(let status):
            return String(
                localized: "safebox.error.keychainUnavailable",
                defaultValue: "The Keychain is unavailable (status \(status))."
            )
        case .notApproved(let names):
            return String(
                localized: "safebox.error.notApproved",
                defaultValue: "Access was not approved for: \(names.joined(separator: ", "))."
            )
        case .metadataUnavailable:
            return String(
                localized: "safebox.error.metadataUnavailable",
                defaultValue: "The safebox metadata file could not be read. It has been left unchanged."
            )
        case .notInCmuxTerminal:
            return String(
                localized: "safebox.error.notInCmuxTerminal",
                defaultValue: "This command must run inside a cmux terminal."
            )
        }
    }
}

/// A listed secret and whether its value is present in the Keychain.
struct SafeboxEntry: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ok
        case valueMissing
    }

    let metadata: SafeboxSecretMetadata
    let state: State
}

/// Single owner of safebox state: metadata on disk plus values in the Keychain.
/// Values are only ever returned from `value(for:)` and `resolveValues(for:)`.
actor SafeboxRepository {
    struct Snapshot: Sendable {
        /// Entries sorted by name. When the Keychain is unreadable they are
        /// reported as `.ok` and `keychainError` explains why values are unavailable.
        var entries: [SafeboxEntry]
        /// Names that have a stored value but no metadata entry.
        var orphanNames: [String]
        var keychainError: SafeboxError?
        /// Set when the metadata file is unreadable; all changes are refused meanwhile.
        var metadataError: SafeboxError?
    }

    private let metadataFile: SafeboxMetadataFile
    private let loadValues: @Sendable () throws -> [String: String]
    private let saveValues: @Sendable ([String: String]) throws -> Void
    private let now: @Sendable () -> Date
    private let usageFlushInterval: Duration

    private var metadata: [SafeboxSecretMetadata]
    /// Set while the metadata file cannot be read. Every snapshot and change
    /// tries the file again, so a repaired file is picked up without a restart.
    private var metadataError: SafeboxError?
    private var usageDirty = false
    private var flushTask: Task<Void, Never>?

    init(
        metadataFile: SafeboxMetadataFile,
        loadValues: @escaping @Sendable () throws -> [String: String],
        saveValues: @escaping @Sendable ([String: String]) throws -> Void,
        now: @escaping @Sendable () -> Date,
        usageFlushInterval: Duration = .seconds(5)
    ) {
        self.metadataFile = metadataFile
        self.loadValues = loadValues
        self.saveValues = saveValues
        self.now = now
        self.usageFlushInterval = usageFlushInterval
        do {
            self.metadata = try Self.loadMetadata(from: metadataFile)
            self.metadataError = nil
        } catch {
            self.metadata = []
            self.metadataError = .metadataUnavailable
        }
    }

    /// Reads the current state. When the metadata file was unreadable it is
    /// read again first; on success the error clears and changes are allowed.
    func snapshot() -> Snapshot {
        retryMetadataIfNeeded()
        var values: [String: String] = [:]
        var keychainError: SafeboxError?
        do {
            values = try loadValues()
        } catch {
            keychainError = error as? SafeboxError ?? .keychainUnavailable(status: errSecInternalError)
        }
        let entries = metadata
            .sorted { $0.name < $1.name }
            .map { entry in
                SafeboxEntry(
                    metadata: entry,
                    state: keychainError != nil || values[entry.name.rawValue] != nil ? .ok : .valueMissing
                )
            }
        let known = Set(metadata.map(\.name.rawValue))
        let orphans = keychainError == nil ? values.keys.filter { !known.contains($0) }.sorted() : []
        return Snapshot(entries: entries, orphanNames: orphans, keychainError: keychainError, metadataError: metadataError)
    }

    func add(name: String, value: String, note: String) throws -> SafeboxSecretMetadata {
        try requireMetadata()
        let secretName = try validatedName(name)
        guard !metadata.contains(where: { $0.name == secretName }) else {
            throw SafeboxError.duplicateName(secretName.rawValue)
        }
        var values = try loadValues()
        values[secretName.rawValue] = value
        try saveValues(values)
        let date = now()
        let entry = SafeboxSecretMetadata(
            name: secretName, note: note, createdAt: date, updatedAt: date, lastUsedAt: nil
        )
        try persistMetadata(metadata + [entry])
        return entry
    }

    func update(
        name: SafeboxSecretName,
        newName: String,
        value: String?,
        note: String
    ) throws -> SafeboxSecretMetadata {
        try requireMetadata()
        guard let index = metadata.firstIndex(where: { $0.name == name }) else {
            throw SafeboxError.unknownSecrets([name.rawValue])
        }
        let targetName = try validatedName(newName)
        if targetName != name, metadata.contains(where: { $0.name == targetName }) {
            throw SafeboxError.duplicateName(targetName.rawValue)
        }
        var values = try loadValues()
        let finalValue = value ?? values[name.rawValue]
        values[name.rawValue] = nil
        if let finalValue { values[targetName.rawValue] = finalValue }
        try saveValues(values)
        var entry = metadata[index]
        entry.name = targetName
        entry.note = note
        entry.updatedAt = now()
        var updated = metadata
        updated[index] = entry
        try persistMetadata(updated)
        return entry
    }

    func delete(name: SafeboxSecretName) throws {
        try requireMetadata()
        guard metadata.contains(where: { $0.name == name }) else {
            throw SafeboxError.unknownSecrets([name.rawValue])
        }
        var values = try loadValues()
        try persistMetadata(metadata.filter { $0.name != name })
        values[name.rawValue] = nil
        try saveValues(values)
    }

    /// Returns one value for display or copy. Does not count as a use.
    func value(for name: SafeboxSecretName) throws -> String {
        let values = try loadValues()
        guard metadata.contains(where: { $0.name == name }), let value = values[name.rawValue] else {
            throw SafeboxError.unknownSecrets([name.rawValue])
        }
        return value
    }

    /// Returns values for injection. Throws `.unknownSecrets` listing every name
    /// that is missing, and records the use when all names resolve.
    func resolveValues(for names: [SafeboxSecretName]) throws -> [SafeboxSecretName: String] {
        try requireMetadata()
        let values = try loadValues()
        let known = Set(metadata.map(\.name))
        let missing = Set(names).filter { !known.contains($0) || values[$0.rawValue] == nil }
        guard missing.isEmpty else {
            throw SafeboxError.unknownSecrets(missing.map(\.rawValue).sorted())
        }
        var resolved: [SafeboxSecretName: String] = [:]
        for name in names { resolved[name] = values[name.rawValue] }
        let date = now()
        for index in metadata.indices where resolved[metadata[index].name] != nil {
            metadata[index].lastUsedAt = date
        }
        if !resolved.isEmpty { markUsageDirty() }
        return resolved
    }

    /// Writes pending `lastUsedAt` changes now. Also called on app termination.
    func flushUsage() throws {
        flushTask?.cancel()
        flushTask = nil
        try requireMetadata()
        guard usageDirty else { return }
        try persistMetadata(metadata)
    }

    // MARK: - Private

    private func validatedName(_ input: String) throws -> SafeboxSecretName {
        guard let name = SafeboxSecretName(normalizing: input) else {
            throw SafeboxError.invalidName(input)
        }
        return name
    }

    private func requireMetadata() throws {
        retryMetadataIfNeeded()
        if let metadataError { throw metadataError }
    }

    private static func loadMetadata(from file: SafeboxMetadataFile) throws -> [SafeboxSecretMetadata] {
        var seen = Set<SafeboxSecretName>()
        return try file.load().filter { seen.insert($0.name).inserted }
    }

    /// Re-reads an unreadable metadata file. It stays untouched either way;
    /// while it still fails, every change keeps being refused.
    private func retryMetadataIfNeeded() {
        guard metadataError != nil else { return }
        guard let loaded = try? Self.loadMetadata(from: metadataFile) else { return }
        metadata = loaded
        metadataError = nil
    }

    /// Saves the candidate list and only then adopts it, so a failed save leaves state unchanged.
    private func persistMetadata(_ candidate: [SafeboxSecretMetadata]) throws {
        try requireMetadata()
        try metadataFile.save(candidate)
        metadata = candidate
        usageDirty = false
    }

    private func markUsageDirty() {
        usageDirty = true
        guard flushTask == nil else { return }
        let interval = usageFlushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.runScheduledFlush()
        }
    }

    private func runScheduledFlush() {
        flushTask = nil
        try? flushUsage()
    }
}

extension SafeboxRepository {
    /// The app's repository: metadata in
    /// `~/Library/Application Support/cmux/safebox-<bundle id>.json`, values in
    /// the Keychain item `<bundle id>.safebox` / `values`. Reads the metadata
    /// file; the Keychain is only touched when a value or state is needed.
    static func live(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> SafeboxRepository {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = trimmed.isEmpty ? "com.cmuxterm.app" : trimmed
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let store = SafeboxKeychainValueStore(service: "\(bundleID).safebox")
        return SafeboxRepository(
            metadataFile: SafeboxMetadataFile(
                fileURL: SafeboxMetadataFile.defaultURL(
                    bundleIdentifier: bundleID,
                    applicationSupport: applicationSupport
                ),
                fileManager: fileManager
            ),
            loadValues: { try store.loadValues() },
            saveValues: { try store.saveValues($0) },
            now: { Date() }
        )
    }
}
