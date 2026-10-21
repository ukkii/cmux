import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RemoteLinkTestContainer: TerminalLinkOpenContainer {
    let terminalLinkContainerDebugName = "remote-fixture"
    var opened: [URL] = []
    var focus = true
    var accepts = true
    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? { nil }
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool { true }
    func deferTerminalFileLinkOpen(sourcePanelId: UUID, filePath: String, fallback: @escaping @MainActor @Sendable () -> Void) -> Bool { false }
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool) -> Bool {
        self.focus = focus
        opened.append(url)
        return accepts
    }
}
