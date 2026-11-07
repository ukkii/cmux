import Foundation

/// Reads and writes the safebox metadata JSON file (names, notes, timestamps).
/// The file never contains secret values.
struct SafeboxMetadataFile: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// `<applicationSupport>/cmux/safebox-<sanitized bundle id>.json`.
    static func defaultURL(bundleIdentifier: String, applicationSupport: URL) -> URL {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        let sanitized = String(bundleIdentifier.map { allowed.contains($0) ? $0 : "_" })
        return applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("safebox-\(sanitized).json", isDirectory: false)
    }

    /// Returns the stored entries, or an empty array when the file does not exist.
    func load() throws -> [SafeboxSecretMetadata] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SafeboxSecretMetadata].self, from: data)
    }

    /// Atomically writes the entries with file mode 0600.
    func save(_ entries: [SafeboxSecretMetadata]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
