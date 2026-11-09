import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("About licenses resources")
struct AboutLicensesResourceTests {
    @Test("The project GPL is available to the About licenses UI")
    func projectLicenseIsBundled() throws {
        let url = try #require(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.contains("Copyright (c) 2024-present Manaflow, Inc."))
        #expect(contents.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(contents.contains("Version 3, 29 June 2007"))
    }

    @Test("The About licenses content includes the project GPL and source directions")
    func aboutContentIncludesProjectLicenseAndSourceDirections() throws {
        let licenseContent = AboutLicenseContent(bundle: .main)
        let contents = licenseContent.load()

        #expect(contents.contains("Copyright (c) 2024-present Manaflow, Inc."))
        #expect(contents.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(contents.contains(licenseContent.repositoryURL.absoluteString))
        #expect(contents.contains(licenseContent.correspondingSourceURL().absoluteString))
    }

    @Test(
        "Builds link corresponding source to their exact fork commit",
        arguments: ["com.cmuxterm.app", "com.cmuxterm.app.debug.licpkg", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"]
    )
    func buildUsesForkCommit(bundleIdentifier: String) {
        let url = AboutLicenseContent(bundle: .main).correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: bundleIdentifier,
            commit: "abcdef123"
        )

        #expect(url.absoluteString == "https://github.com/ukkii/cmux/tree/abcdef123")
    }

    @Test("Stable builds without a commit fall back to the version tag")
    func stableBuildWithoutCommitUsesVersionTag() {
        let repositoryURL = URL(string: "https://example.com/cmux-source")!
        let url = AboutLicenseContent(
            bundle: .main,
            repositoryURL: repositoryURL
        ).correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: "com.cmuxterm.app",
            commit: nil
        )

        #expect(url.absoluteString == "https://example.com/cmux-source/tree/v0.64.19")
    }
}
