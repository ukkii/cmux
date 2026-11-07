import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Safebox metadata file")
struct SafeboxMetadataFileTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("safebox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("safebox.json")
    }

    @Test("Names are trimmed, uppercased and validated")
    func normalizesAndValidatesNames() {
        #expect(SafeboxSecretName(normalizing: "cloudflare_token")?.rawValue == "CLOUDFLARE_TOKEN")
        #expect(SafeboxSecretName(normalizing: " API_KEY ")?.rawValue == "API_KEY")
        for invalid in ["", "1ABC", "A-B", "A B", "ÄBC"] {
            #expect(SafeboxSecretName(normalizing: invalid) == nil, "\(invalid) should be rejected")
        }
    }

    @Test("Entries round trip and the file has mode 0600")
    func roundTripsEntriesWithFilePermissions0600() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = SafeboxMetadataFile(fileURL: url)
        let entries = [
            SafeboxSecretMetadata(
                name: try #require(SafeboxSecretName(normalizing: "A_TOKEN")),
                note: "first",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastUsedAt: Date(timeIntervalSince1970: 1_700_000_200)
            ),
            SafeboxSecretMetadata(
                name: try #require(SafeboxSecretName(normalizing: "B_TOKEN")),
                note: "",
                createdAt: Date(timeIntervalSince1970: 1_700_001_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
                lastUsedAt: nil
            ),
        ]
        try file.save(entries)
        #expect(try file.load() == entries)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A missing file loads as empty")
    func missingFileLoadsEmpty() throws {
        let file = SafeboxMetadataFile(fileURL: makeTempURL())
        #expect(try file.load().isEmpty)
    }

    @Test("The default URL is per bundle identifier")
    func defaultURLIsPerBundleIdentifier() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        let release = SafeboxMetadataFile.defaultURL(bundleIdentifier: "com.cmuxterm.app", applicationSupport: support)
        let debug = SafeboxMetadataFile.defaultURL(bundleIdentifier: "com.cmuxterm.app.debug.rtfix", applicationSupport: support)
        #expect(release != debug)
        #expect(release.deletingLastPathComponent().path == "/tmp/support/cmux")
        #expect(release.lastPathComponent == "safebox-com.cmuxterm.app.json")
        #expect(debug.lastPathComponent == "safebox-com.cmuxterm.app.debug.rtfix.json")
        let odd = SafeboxMetadataFile.defaultURL(bundleIdentifier: "a b/c", applicationSupport: support)
        #expect(odd.lastPathComponent == "safebox-a_b_c.json")
    }
}
