import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Retired panel decoding")
struct RetiredPanelDecodingTests {
    @Test("a persisted account sign-in panel is dropped instead of failing the list")
    func accountSignInPanelIsDropped() throws {
        let data = Data(#"[{"type":"accountSignIn"}]"#.utf8)
        let list = try JSONDecoder().decode(RetiredPanelTolerantList.self, from: data)
        #expect(list.wrappedValue.isEmpty)
    }

    @Test("the account sign-in kind no longer decodes as a live panel type")
    func accountSignInIsNotALivePanelType() {
        let data = Data(#""accountSignIn""#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PanelType.self, from: data)
        }
    }
}
