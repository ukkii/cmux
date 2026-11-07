import Foundation

/// Replaces every exact byte occurrence of a secret value in a stream of
/// output chunks with `***`.
///
/// The masker compares bytes, so multi-line values and output that is not
/// valid UTF-8 are handled the same as text. Overlapping or adjacent
/// occurrences, of one value or of several, are masked as one `***`. A
/// value split across two chunks is still masked: after each chunk the masker holds back at most `maxLen - 1`
/// trailing bytes that could still begin a value, and ``finish()`` releases
/// them once the stream ends. Values shorter than `minimumLength` bytes are
/// left alone so that short strings do not garble ordinary output.
struct SafeboxOutputMasker {
    static let replacement = Data("***".utf8)

    /// Values to mask, longest first, without duplicates.
    private let secrets: [[UInt8]]
    private let maximumLength: Int
    private var pending: [UInt8] = []
    /// Whether a masked run is open; its `***` has already been written.
    private var masking = false
    /// End of the open masked run, as an offset into `pending`.
    private var maskEnd = 0

    init(secrets: [String], minimumLength: Int = 4) {
        let unique = Set(secrets.map { Array($0.utf8) }.filter { $0.count >= max(1, minimumLength) })
        self.secrets = unique.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
        self.maximumLength = self.secrets.first?.count ?? 0
    }

    /// Masks `chunk` and returns the bytes that can be written now.
    mutating func process(_ chunk: Data) -> Data {
        guard maximumLength > 0 else { return chunk }
        pending.append(contentsOf: chunk)
        return drain(final: false)
    }

    /// Masks and returns the bytes held back at the end of the stream.
    mutating func finish() -> Data {
        guard maximumLength > 0 else { return Data() }
        return drain(final: true)
    }

    /// Emits every byte whose fate is decided. A position is decided when a
    /// value matches there, or when enough bytes follow it to rule out the
    /// longest value; at the end of the stream every position is decided.
    ///
    /// Masked bytes are the union of all match ranges: matches that overlap
    /// or touch form one run, written as a single `***`, so no value leaves
    /// a tail behind when it overlaps another.
    private mutating func drain(final: Bool) -> Data {
        var output = Data()
        output.reserveCapacity(pending.count)
        var index = 0
        let count = pending.count
        while index < count {
            if let length = matchLength(at: index, final: final) {
                if !masking {
                    output.append(Self.replacement)
                    masking = true
                    maskEnd = index
                }
                maskEnd = max(maskEnd, index + length)
                // Keep scanning inside the run: a later value may extend it.
                index += 1
                continue
            }
            guard final || count - index >= maximumLength else { break }
            if masking, index < maskEnd {
                index += 1
                continue
            }
            masking = false
            output.append(pending[index])
            index += 1
        }
        pending.removeFirst(index)
        if final {
            masking = false
            maskEnd = 0
        } else if masking {
            maskEnd -= index
        }
        return output
    }

    /// The length of the longest value that matches completely at `index`,
    /// when one does and no longer value could still match there once more
    /// bytes arrive.
    private func matchLength(at index: Int, final: Bool) -> Int? {
        let available = pending.count - index
        for secret in secrets {
            guard secret.count <= available else {
                // A longer value might still match once the rest arrives.
                if !final, pending[index...].elementsEqual(secret.prefix(available)) { return nil }
                continue
            }
            if pending[index..<(index + secret.count)].elementsEqual(secret) {
                return secret.count
            }
        }
        return nil
    }
}
