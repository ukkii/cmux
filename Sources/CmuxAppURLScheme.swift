import Foundation

/// The app's own deep-link URL scheme (`cmux://`, `cmux-nightly://`,
/// `cmux-dev-<tag>://`, ...), used for SSH, workspace, pane and surface links.
/// Each build channel registers its own scheme so tagged Debug builds can
/// coexist with the installed stable app.
/// lint:allow namespace-type: a static namespace for one resolved value and its pure resolver.
enum CmuxAppURLScheme {
    /// The scheme this running build registers and emits.
    static var current: String {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isDebugBuild: isDebugBuild
        )
    }

    /// Pure resolver so the per-channel rule is testable without the process
    /// environment. An explicit `CMUX_URL_SCHEME` wins; otherwise Debug builds
    /// use `cmux-dev[-<tag>]` and release channels map from the bundle ID.
    static func resolve(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> String {
        if let overridden = environment["CMUX_URL_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            if let tag = environment["CMUX_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedTag(tag) {
                return "cmux-dev-\(schemeTag)"
            }
            return "cmux-dev"
        }
        if bundleIdentifier == "com.cmuxterm.app.nightly" { return "cmux-nightly" }
        if bundleIdentifier == "com.cmuxterm.app.rc" { return "cmux-rc" }
        return "cmux"
    }

    /// Lowercases the tag and collapses every run of characters outside
    /// `[a-z0-9]` into one hyphen, trimming hyphens at either end.
    static func sanitizedTag(_ rawTag: String) -> String? {
        var result = ""
        var previousWasHyphen = false
        for scalar in rawTag.lowercased().unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? nil : result
    }
}
