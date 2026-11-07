import Foundation
import Testing

/// `cmux safebox run` output masking. The masker is compiled into this
/// target from `CLI/SafeboxOutputMasker.swift`.
@Suite("cmux safebox run: output masking")
struct SafeboxOutputMaskerTests {
    @Test func masksExactOccurrences() {
        var masker = SafeboxOutputMasker(secrets: ["s3cr3t-VALUE"])
        let output = Self.run(&masker, chunks: [Data("token=s3cr3t-VALUE and s3cr3t-VALUE.\n".utf8)])
        #expect(output == Data("token=*** and ***.\n".utf8))
    }

    @Test func masksValueSplitAcrossChunks() {
        var masker = SafeboxOutputMasker(secrets: ["s3cr3t-VALUE"])
        let input = Data("before s3cr3t-VALUE after s3cr3t-VALUE".utf8)
        let chunks = input.map { Data([$0]) }
        let output = Self.run(&masker, chunks: chunks)
        #expect(output == Data("before *** after ***".utf8))
    }

    @Test func holdsBackFewerBytesThanTheLongestValue() {
        var masker = SafeboxOutputMasker(secrets: ["abcdefgh"])
        let emitted = masker.process(Data("0123456789".utf8))
        // Everything but the last seven bytes can no longer start a match.
        #expect(emitted == Data("012".utf8))
        #expect(masker.finish() == Data("3456789".utf8))
    }

    @Test func longerOverlappingValueWinsOverShorter() {
        var masker = SafeboxOutputMasker(secrets: ["abcd", "abcdefgh"])
        let output = Self.run(&masker, chunks: [Data("abcdefgh abcd".utf8)])
        #expect(output == Data("*** ***".utf8))

        var split = SafeboxOutputMasker(secrets: ["abcd", "abcdefgh"])
        let splitOutput = Self.run(&split, chunks: Data("abcdefgh abcd".utf8).map { Data([$0]) })
        #expect(splitOutput == Data("*** ***".utf8))
    }

    @Test func overlappingDifferentValuesLeaveNoTail() {
        var masker = SafeboxOutputMasker(secrets: ["xxab", "abcdefgh"])
        let output = Self.run(&masker, chunks: [Data("xxabcdefgh".utf8)])
        #expect(output == Data("***".utf8))

        var split = SafeboxOutputMasker(secrets: ["xxab", "abcdefgh"])
        let splitOutput = Self.run(&split, chunks: Data("<xxabcdefgh>".utf8).map { Data([$0]) })
        #expect(splitOutput == Data("<***>".utf8))
    }

    @Test func adjacentOccurrencesBecomeOneRun() {
        var masker = SafeboxOutputMasker(secrets: ["abcd"])
        let output = Self.run(&masker, chunks: Data("abcdabcd abcd".utf8).map { Data([$0]) })
        #expect(output == Data("*** ***".utf8))
    }

    @Test func masksMultilineAndBinarySafeValues() {
        let pem = "-----BEGIN KEY-----\nAAAA\r\nBBBB\n-----END KEY-----"
        var masker = SafeboxOutputMasker(secrets: [pem])
        let output = Self.run(&masker, chunks: [Data("key:\n\(pem)\ndone".utf8)])
        #expect(output == Data("key:\n***\ndone".utf8))

        // A value whose bytes are not valid UTF-8 text around it: the masker
        // compares bytes, so 0xFF and 0x00 in the stream do not matter.
        var binary = SafeboxOutputMasker(secrets: ["\u{00}x-key"])
        var stream = Data([0xFF, 0x00])
        stream.append(Data("\u{00}x-key".utf8))
        stream.append(contentsOf: [0x00, 0xFF])
        let binaryOutput = Self.run(&binary, chunks: stream.map { Data([$0]) })
        var expected = Data([0xFF, 0x00])
        expected.append(Data("***".utf8))
        expected.append(contentsOf: [0x00, 0xFF])
        #expect(binaryOutput == expected)
    }

    @Test func shortValuesAreNotMasked() {
        var masker = SafeboxOutputMasker(secrets: ["abc", "", "abcd"])
        let output = Self.run(&masker, chunks: [Data("abc abcd ab".utf8)])
        #expect(output == Data("abc *** ab".utf8))
    }

    @Test func finishFlushesHeldBytes() {
        var masker = SafeboxOutputMasker(secrets: ["s3cr3t-VALUE"])
        let emitted = masker.process(Data("tail s3cr3t".utf8))
        let flushed = masker.finish()
        var all = emitted
        all.append(flushed)
        #expect(all == Data("tail s3cr3t".utf8))
        #expect(masker.finish().isEmpty)
    }

    @Test func passesOutputThroughWithoutSecrets() {
        var masker = SafeboxOutputMasker(secrets: [])
        #expect(masker.process(Data("plain".utf8)) == Data("plain".utf8))
        #expect(masker.finish().isEmpty)
    }

    private static func run(_ masker: inout SafeboxOutputMasker, chunks: [Data]) -> Data {
        var output = Data()
        for chunk in chunks {
            output.append(masker.process(chunk))
        }
        output.append(masker.finish())
        return output
    }
}
