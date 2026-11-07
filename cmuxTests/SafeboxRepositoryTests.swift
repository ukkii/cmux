import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Safebox repository")
struct SafeboxRepositoryTests {
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
        var current: [String: String] { lock.withLock { values } }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("safebox-repo-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("safebox.json")
    }

    private func makeRepository(
        url: URL,
        store: Store,
        interval: Duration = .seconds(3600)
    ) -> SafeboxRepository {
        let now = fixedNow
        return SafeboxRepository(
            metadataFile: SafeboxMetadataFile(fileURL: url),
            loadValues: { try store.load() },
            saveValues: { store.save($0) },
            now: { now },
            usageFlushInterval: interval
        )
    }

    private func name(_ raw: String) -> SafeboxSecretName {
        SafeboxSecretName(normalizing: raw)!
    }

    @Test("Add, update, rename and delete round trip")
    func addUpdateRenameDeleteRoundTrip() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = Store()
        let repository = makeRepository(url: url, store: store)

        let added = try await repository.add(name: "api_key", value: "v1", note: "first")
        #expect(added.name.rawValue == "API_KEY")
        #expect(added.createdAt == fixedNow)
        #expect(store.current == ["API_KEY": "v1"])

        _ = try await repository.update(name: name("API_KEY"), newName: "API_KEY", value: nil, note: "second")
        #expect(store.current == ["API_KEY": "v1"])
        #expect(try await repository.value(for: name("API_KEY")) == "v1")

        let renamed = try await repository.update(name: name("API_KEY"), newName: "token", value: "v2", note: "second")
        #expect(renamed.name.rawValue == "TOKEN")
        #expect(renamed.note == "second")
        #expect(renamed.createdAt == added.createdAt)
        #expect(store.current == ["TOKEN": "v2"])

        let snapshot = await repository.snapshot()
        #expect(snapshot.entries.map(\.metadata.name.rawValue) == ["TOKEN"])
        #expect(snapshot.entries.first?.state == .ok)

        try await repository.delete(name: name("TOKEN"))
        #expect(store.current.isEmpty)
        #expect(try SafeboxMetadataFile(fileURL: url).load().isEmpty)

        let reloaded = makeRepository(url: url, store: store)
        #expect(await reloaded.snapshot().entries.isEmpty)
    }

    @Test("Metadata file never contains values")
    func metadataFileNeverContainsValues() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = makeRepository(url: url, store: Store())
        _ = try await repository.add(name: "TOKEN", value: "s3cr3t-VALUE", note: "note")
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(contents.contains("TOKEN"))
        #expect(!contents.contains("s3cr3t-VALUE"))
    }

    @Test("Duplicate and invalid names are rejected")
    func duplicateAndInvalidNamesAreRejected() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = makeRepository(url: url, store: Store())
        _ = try await repository.add(name: "API_KEY", value: "a", note: "")
        _ = try await repository.add(name: "OTHER", value: "b", note: "")

        await #expect(throws: SafeboxError.duplicateName("API_KEY")) {
            _ = try await repository.add(name: "api_key", value: "x", note: "")
        }
        await #expect(throws: SafeboxError.invalidName("1X")) {
            _ = try await repository.add(name: "1X", value: "x", note: "")
        }
        await #expect(throws: SafeboxError.duplicateName("API_KEY")) {
            _ = try await repository.update(name: name("OTHER"), newName: "API_KEY", value: nil, note: "")
        }
        await #expect(throws: SafeboxError.invalidName("bad name")) {
            _ = try await repository.update(name: name("OTHER"), newName: "bad name", value: nil, note: "")
        }
    }

    @Test("Resolving unknown names lists all missing")
    func resolveUnknownNamesListsAllMissing() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = makeRepository(url: url, store: Store())
        _ = try await repository.add(name: "KNOWN", value: "value", note: "")
        await #expect(throws: SafeboxError.unknownSecrets(["A", "B"])) {
            _ = try await repository.resolveValues(for: [name("B"), name("KNOWN"), name("A")])
        }
    }

    @Test("Resolve records last use in memory and flushes coalesced")
    func resolveRecordsLastUsedAndFlushesCoalesced() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = makeRepository(url: url, store: Store(), interval: .seconds(3600))
        _ = try await repository.add(name: "TOKEN", value: "value", note: "")

        let first = try await repository.resolveValues(for: [name("TOKEN")])
        let second = try await repository.resolveValues(for: [name("TOKEN")])
        #expect(first == [name("TOKEN"): "value"])
        #expect(second == first)

        // Within the interval nothing is written yet, but the snapshot already shows the use.
        #expect(try SafeboxMetadataFile(fileURL: url).load().first?.lastUsedAt == nil)
        #expect(await repository.snapshot().entries.first?.metadata.lastUsedAt == fixedNow)

        try await repository.flushUsage()
        #expect(try SafeboxMetadataFile(fileURL: url).load().first?.lastUsedAt == fixedNow)

        // A flush without new usage does not write again.
        try FileManager.default.removeItem(at: url)
        try await repository.flushUsage()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Scheduled flush writes after the interval")
    func scheduledFlushWritesAfterInterval() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = makeRepository(url: url, store: Store(), interval: .milliseconds(50))
        _ = try await repository.add(name: "TOKEN", value: "value", note: "")
        _ = try await repository.resolveValues(for: [name("TOKEN")])
        var flushed = false
        for _ in 0..<100 {
            if try SafeboxMetadataFile(fileURL: url).load().first?.lastUsedAt == fixedNow {
                flushed = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(flushed)
    }

    @Test("Multiline values round trip")
    func roundTripsMultilineValue() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let value = "-----BEGIN KEY-----\nabc\"def\n-----END KEY-----\n"
        let repository = makeRepository(url: url, store: Store())
        _ = try await repository.add(name: "PEM", value: value, note: "")
        #expect(try await repository.value(for: name("PEM")) == value)
        #expect(try await repository.resolveValues(for: [name("PEM")]) == [name("PEM"): value])
    }

    @Test("Keychain read failure keeps metadata listable")
    func keychainReadFailureKeepsMetadataListable() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = Store()
        let repository = makeRepository(url: url, store: store)
        _ = try await repository.add(name: "TOKEN", value: "value", note: "")

        store.setLoadError(.keychainUnavailable(status: -25293))
        let snapshot = await repository.snapshot()
        #expect(snapshot.entries.map(\.metadata.name.rawValue) == ["TOKEN"])
        #expect(snapshot.keychainError == .keychainUnavailable(status: -25293))
        await #expect(throws: SafeboxError.keychainUnavailable(status: -25293)) {
            _ = try await repository.resolveValues(for: [name("TOKEN")])
        }
    }

    @Test("Crash between writes is reported")
    func crashBetweenWritesIsReported() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = Store()
        try SafeboxMetadataFile(fileURL: url).save([
            SafeboxSecretMetadata(
                name: name("NO_VALUE"), note: "", createdAt: fixedNow, updatedAt: fixedNow, lastUsedAt: nil
            ),
        ])
        store.setValues(["ORPHAN": "x"])
        let snapshot = await makeRepository(url: url, store: store).snapshot()
        #expect(snapshot.entries.map(\.state) == [.valueMissing])
        #expect(snapshot.orphanNames == ["ORPHAN"])
    }

    @Test("Duplicate metadata entries keep the first")
    func duplicateMetadataEntriesKeepFirst() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func entry(_ note: String) -> SafeboxSecretMetadata {
            SafeboxSecretMetadata(
                name: name("DUP"), note: note, createdAt: fixedNow, updatedAt: fixedNow, lastUsedAt: nil
            )
        }
        try SafeboxMetadataFile(fileURL: url).save([entry("first"), entry("second")])
        let snapshot = await makeRepository(url: url, store: Store()).snapshot()
        #expect(snapshot.entries.map(\.metadata.note) == ["first"])
    }

    @Test("Unreadable metadata file is reported and never overwritten")
    func corruptMetadataFileIsNotOverwritten() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: url)
        let store = Store()
        let repository = makeRepository(url: url, store: store)

        #expect(await repository.snapshot().metadataError == .metadataUnavailable)
        await #expect(throws: SafeboxError.metadataUnavailable) {
            _ = try await repository.add(name: "TOKEN", value: "v", note: "")
        }
        await #expect(throws: SafeboxError.metadataUnavailable) {
            _ = try await repository.resolveValues(for: [name("TOKEN")])
        }
        await #expect(throws: SafeboxError.metadataUnavailable) {
            try await repository.flushUsage()
        }
        #expect(store.current.isEmpty)
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("A repaired metadata file is picked up again and allows changes")
    func repairedMetadataFileRecovers() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let garbage = Data("{".utf8)
        try garbage.write(to: url)
        let store = Store()
        store.setValues(["KEPT": "kept-value"])
        let repository = makeRepository(url: url, store: store)
        #expect(await repository.snapshot().metadataError == .metadataUnavailable)

        // Still broken: retrying keeps blocking writes and leaves the file alone.
        #expect(await repository.snapshot().metadataError == .metadataUnavailable)
        await #expect(throws: SafeboxError.metadataUnavailable) {
            _ = try await repository.add(name: "TOKEN", value: "v", note: "")
        }
        #expect(try Data(contentsOf: url) == garbage)

        let kept = SafeboxSecretMetadata(
            name: name("KEPT"), note: "repaired", createdAt: fixedNow, updatedAt: fixedNow, lastUsedAt: nil
        )
        try SafeboxMetadataFile(fileURL: url).save([kept])

        let recovered = await repository.snapshot()
        #expect(recovered.metadataError == nil)
        #expect(recovered.entries.map(\.metadata.note) == ["repaired"])
        #expect(recovered.entries.map(\.state) == [.ok])
        _ = try await repository.add(name: "TOKEN", value: "v", note: "")
        #expect(store.current == ["KEPT": "kept-value", "TOKEN": "v"])
        #expect(try SafeboxMetadataFile(fileURL: url).load().map(\.name.rawValue) == ["KEPT", "TOKEN"])
    }

    @Test("Invalid name error text does not echo the input")
    func invalidNameDescriptionDoesNotEchoInput() {
        let description = SafeboxError.invalidName("ghp_SECRETTOKEN123").localizedDescription
        #expect(!description.contains("ghp_SECRETTOKEN123"))
    }
}
