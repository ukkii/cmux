import CmuxFoundation
import Darwin
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7246:
// `cmux ssh` against a host whose ~/.ssh/config sets `RequestTTY yes` and
// `RemoteCommand sudo su -` fails with OpenSSH's
// "Cannot execute command-line and remote command." (exit 255) and loops the
// reconnect banner. Every cmux-controlled ssh invocation that supplies its own
// remote command must override the host-configured RemoteCommand (e.g.
// `-o RemoteCommand=none`), while the session hop that intentionally carries
// cmux's own `-o RemoteCommand=<bootstrap>` keeps doing so.
//
// The fake `ssh` below mirrors OpenSSH's actual rule: a positional remote
// command is fatal iff no `-o RemoteCommand=...` override appears on the argv
// (the first RemoteCommand option wins, like OpenSSH's first-obtained-value
// semantics). It records one `invocation kind=<...> override=<...>` event per
// spawn so assertions can distinguish config dumps, control operations,
// interactive sessions, and command-carrying invocations.
@Suite(.serialized)
struct SSHConfiguredRemoteCommandHostTests {
    private typealias MockSocketServerState =
        CLINotifyProcessIntegrationRegressionTests.MockSocketServerState

    private let processSupport = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    @Test
    func sshPTYAttachCarriesConfiguredRemoteCommandAcrossMissingSessionFallback() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-w-s",
            remoteCommand: "while true; do tmux attach -t work || sleep 5; done"
        )
        #expect(command.contains("--command-b64"))
        #expect(command.contains(Data("while true; do tmux attach -t work || sleep 5; done".utf8).base64EncodedString()))
        #expect(command.contains("--require-existing"))
    }

    /// The app-side restore/reattach startup script builder runs a
    /// foreground-auth `ssh ... <dest> true` hop that must override a
    /// host-configured RemoteCommand.
    @Test
    func sshPTYAttachForegroundAuthOverridesHostConfiguredRemoteCommand() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-w-s",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "cmux-remotecommand-host",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=/tmp/cmux-ssh-%C",
                    "RemoteCommand=printf caller-command",
                ],
                token: "auth-token"
            ),
            remoteCommand: "printf ready"
        )
        #expect(
            command.contains("-o RemoteCommand=none -T -- cmux-remotecommand-host true"),
            "Restore foreground auth must override a host-configured RemoteCommand before running its command-line `true`; command: \(command)"
        )
        #expect(
            command.contains("/usr/bin/ssh -o"),
            "Restore foreground auth must use the same system OpenSSH executable as config resolution; command: \(command)"
        )
        #expect(
            !command.contains("RemoteCommand=printf caller-command"),
            """
            Restore foreground auth must not forward the durable caller RemoteCommand \
            alongside cmux's override; command: \(command)
            """
        )
        #expect(!command.contains("-$$"), Comment(rawValue: command))
        #expect(
            command.contains("--lifecycle-id \"$cmux_ssh_attach_lifecycle_id\""),
            Comment(rawValue: command)
        )
        #expect(command.contains("ssh-session-end --lifecycle-only"), Comment(rawValue: command))
    }
}
