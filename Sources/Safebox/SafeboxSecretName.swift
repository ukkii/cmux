import Foundation

/// A validated secret name. It doubles as the environment variable name the
/// secret is injected under, so it follows `^[A-Z_][A-Z0-9_]*$`.
struct SafeboxSecretName: Hashable, Codable, Sendable, Comparable {
    let rawValue: String

    /// Trims whitespace, uppercases and validates the input. Returns nil when
    /// the result is not a valid environment variable style name.
    init?(normalizing input: String) {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValid(candidate) else { return nil }
        self.rawValue = candidate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid safebox secret name"
            )
        }
        self.rawValue = raw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: SafeboxSecretName, rhs: SafeboxSecretName) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isValid(_ candidate: String) -> Bool {
        guard let first = candidate.utf8.first, !candidate.isEmpty else { return false }
        func isUpperOrUnderscore(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || b == 0x5F }
        guard isUpperOrUnderscore(first) else { return false }
        return candidate.utf8.allSatisfy { isUpperOrUnderscore($0) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
