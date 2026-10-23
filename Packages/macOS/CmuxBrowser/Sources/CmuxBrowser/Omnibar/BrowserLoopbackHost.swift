import Foundation

/// Recognizes local development hosts without accepting dotted-host lookalikes.
/// lint:allow namespace-type: a single pure predicate shared by the omnibar resolver.
enum BrowserLoopbackHost {
    /// Whether `candidate` names `localhost`, a `*.localhost` subdomain, `::1`
    /// or a `127.x.x.x` IPv4 address.
    static func matches(_ candidate: String) -> Bool {
        let host = candidate.lowercased()
        if host == "localhost" || host == "::1" {
            return true
        }
        if host != ".localhost", host.hasSuffix(".localhost") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.allSatisfy { UInt8($0) != nil }
            && octets[0] == "127"
    }
}
