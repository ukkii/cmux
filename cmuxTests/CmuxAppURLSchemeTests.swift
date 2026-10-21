import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("App URL scheme")
struct CmuxAppURLSchemeTests {
    @Test("debug scheme uses sanitized tag")
    func debugSchemeUsesSanitizedTag() {
        #expect(
            CmuxAppURLScheme.resolve(
                environment: ["CMUX_TAG": "Safari Auth!"],
                bundleIdentifier: "com.cmuxterm.app.debug.safari-auth",
                isDebugBuild: true
            ) == "cmux-dev-safari-auth"
        )
    }

    @Test("release scheme ignores ambient tag")
    func releaseSchemeIgnoresAmbientTag() {
        #expect(
            CmuxAppURLScheme.resolve(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false
            ) == "cmux"
        )
        #expect(
            CmuxAppURLScheme.resolve(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false
            ) == "cmux-nightly"
        )
    }

    @Test("rc bundle uses the cmux-rc scheme")
    func rcBundleUsesRCScheme() {
        #expect(
            CmuxAppURLScheme.resolve(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.rc",
                isDebugBuild: false
            ) == "cmux-rc"
        )
    }

    @Test("explicit scheme override wins")
    func explicitOverrideWins() {
        #expect(
            CmuxAppURLScheme.resolve(
                environment: ["CMUX_URL_SCHEME": "cmux-custom", "CMUX_TAG": "x"],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: true
            ) == "cmux-custom"
        )
    }
}
