import CmuxCore
import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SSHStartupManualReconnectTests {

    /// These tests cover the Workspace reconnect path for a cmuxd-remote SSH workspace.
    static func makeRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
    }

    /// Set only while priming, so a primed fixture exits before doing any work.
    static let primeExecEnvironmentKey = "CMUX_TEST_PRIME_EXEC"

    /// The line a primeable fixture carries right after its shebang.
    static let primeExecGuard = "if [ -n \"${\(primeExecEnvironmentKey):-}\" ]; then exit 0; fi"

    /// Pays macOS's first-exec assessment for new fixtures before a timed wait.
    ///
    /// The first exec of every newly written file, scripts included, blocks
    /// while syspolicyd assesses it; later execs of the same file do not. On
    /// loaded fleet minis the first new file a fresh app host ran waited 6 to
    /// 13 s, longer than the 3 s prompt waits, so each fixture runs once here,
    /// untimed, as soon as it is written.
    static func primeFirstExec(_ executables: URL...) throws {
        for executable in executables {
            let result = runProcess(
                executablePath: executable.path,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin", primeExecEnvironmentKey: "1"],
                timeout: 120
            )
            try #require(
                !result.timedOut && result.status == 0,
                "priming \(executable.lastPathComponent) failed with status \(result.status): \(result.stderr)"
            )
        }
    }

    /// Writes an executable shell fixture and primes it (see `primeFirstExec`).
    static func writeShellFile(at url: URL, lines: [String]) throws {
        var lines = lines
        let isScript = lines.first?.hasPrefix("#!") == true
        if isScript {
            lines.insert(primeExecGuard, at: 1)
        }
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        guard isScript else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try primeFirstExec(url)
    }

    /// Foreground-auth token the supervisor command expects in its environment.
    static let persistentAttachSupervisorAuthToken = UUID().uuidString.lowercased()

    static func persistentAttachSupervisorCommand(replacingSystemSSHWith fakeSSH: URL) -> String {
        // Direct process signals belong to the attach supervisor that the app
        // builds for restore and reattach.
        SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "fixture.example.test",
                port: 2222,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: persistentAttachSupervisorAuthToken
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
    }

}
