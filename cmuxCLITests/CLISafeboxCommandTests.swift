import Darwin
import Foundation
import Testing

/// `cmux safebox list|run` against a fake control socket: values reach the
/// child only through its environment, its output is masked, and every
/// `safebox.resolve` failure stops the command before it starts.
@Suite(.serialized)
struct CLISafeboxCommandTests {
    private static let timeout: TimeInterval = 60
    private static let value = "s3cr3t-VALUE"

    // MARK: - list

    @Test func listPrintsNamesAndNeverValues() throws {
        let run = try runCLI(
            arguments: ["safebox", "list"],
            responses: ["safebox.list": .ok(Self.listResult)]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.request("safebox.list") != nil)
        let lines = run.result.stdout.split(separator: "\n").map(String.init)
        #expect(lines == [
            "API_KEY\tdeploy key\tupdated 2026-11-01T10:00:00Z\tlast used 2026-11-02T11:30:00Z",
            "OTHER\t\tupdated 2026-11-03T09:00:00Z\tlast used never",
        ], Comment(rawValue: run.result.stdout))
        #expect(!run.result.stdout.contains(Self.value))
        #expect(!run.result.stderr.contains(Self.value))
        #expect(run.request("safebox.resolve") == nil)
    }

    @Test func listWarnsWhenTheKeychainCannotBeRead() throws {
        var result = Self.listResult
        result["keychain_status"] = -25308
        let text = try runCLI(arguments: ["safebox", "list"], responses: ["safebox.list": .ok(result)])
        #expect(text.result.status == 0, Comment(rawValue: text.result.stderr))
        #expect(text.result.stderr.contains("-25308"), Comment(rawValue: text.result.stderr))
        #expect(text.result.stdout.contains("API_KEY"))

        let json = try runCLI(arguments: ["safebox", "list", "--json"], responses: ["safebox.list": .ok(result)])
        #expect(json.result.status == 0, Comment(rawValue: json.result.stderr))
        let object = try #require(codexHookJSONObject(json.result.stdout))
        #expect(object["keychain_status"] as? Int == -25308)
        #expect((object["secrets"] as? [[String: Any]])?.count == 2)
    }

    @Test func listFailsWhenMetadataIsUnreadable() throws {
        let run = try runCLI(
            arguments: ["safebox", "list"],
            responses: ["safebox.list": .error(code: "keychain_unavailable", message: "Safebox metadata could not be read.", data: nil)]
        )
        #expect(run.result.status != 0)
        #expect(!run.result.stderr.isEmpty)
    }

    // MARK: - run

    @Test func runInjectsValuesAndMasksOutput() throws {
        let run = try runCLI(
            arguments: [
                "safebox", "run", "API_KEY", "--",
                "sh", "-c", #"printf "%s|" "$API_KEY"; printf "%s" "$API_KEY" >&2"#,
            ],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout == "***|", Comment(rawValue: run.result.stdout))
        #expect(run.result.stderr == "***", Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("safebox.resolve")?["params"] as? [String: Any])
        #expect(params["names"] as? [String] == ["API_KEY"])
    }

    @Test func runReachesTheChildWithTheValueUnmaskedInItsEnvironment() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("value")
        let run = try runCLI(
            arguments: [
                "safebox", "run", "api_key", "--",
                "sh", "-c", #"printf "%s" "$API_KEY" > "$1""#, "sh", capture.path,
            ],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(try String(contentsOf: capture, encoding: .utf8) == Self.value)
        let params = try #require(run.request("safebox.resolve")?["params"] as? [String: Any])
        #expect(params["names"] as? [String] == ["API_KEY"])
    }

    @Test func runAsAliasSetsOtherVariable() throws {
        let run = try runCLI(
            arguments: [
                "safebox", "run", "--as", "CF_API_TOKEN=API_KEY", "--",
                "sh", "-c", #"test "$CF_API_TOKEN" = "s3cr3t-VALUE" && test -z "${API_KEY+set}" && printf ok"#,
            ],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.result.stdout == "ok")
        let params = try #require(run.request("safebox.resolve")?["params"] as? [String: Any])
        #expect(params["names"] as? [String] == ["API_KEY"])
    }

    @Test func runRejectsAnInvalidAliasVariable() throws {
        let run = try runCLI(
            arguments: ["safebox", "run", "--as", "cf-token=API_KEY", "--", "true"],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status != 0)
        #expect(run.result.stderr.contains("cf-token"), Comment(rawValue: run.result.stderr))
        #expect(run.request("safebox.resolve") == nil)
    }

    @Test func runPropagatesExitCode() throws {
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY", "--", "sh", "-c", "exit 7"],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 7, Comment(rawValue: run.result.stderr))
    }

    @Test func runReportsATerminatingSignalAsOneHundredTwentyEightPlusSignal() throws {
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY", "--", "sh", "-c", "kill -TERM $$"],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 128 + SIGTERM, Comment(rawValue: run.result.stderr))
    }

    @Test func notApprovedDoesNotStartCommand() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY", "--", "touch", marker.path],
            responses: [
                "safebox.resolve": .error(
                    code: "not_approved",
                    message: "Access to API_KEY was not approved.",
                    data: ["names": ["API_KEY"]]
                ),
            ]
        )

        #expect(run.result.status != 0)
        #expect(run.result.stderr.contains("API_KEY"), Comment(rawValue: run.result.stderr))
        #expect(run.result.stderr.contains("not approved"), Comment(rawValue: run.result.stderr))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func unknownSecretFailsClosed() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let run = try runCLI(
            arguments: ["safebox", "run", "MISSING_ONE", "--", "touch", marker.path],
            responses: [
                "safebox.resolve": .error(
                    code: "unknown_secret",
                    message: "No secret named MISSING_ONE.",
                    data: ["names": ["MISSING_ONE"]]
                ),
            ]
        )

        #expect(run.result.status != 0)
        #expect(run.result.stderr.contains("MISSING_ONE"), Comment(rawValue: run.result.stderr))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func everyResolveFailureStopsTheCommand() throws {
        let failures: [(code: String, data: [String: Any]?)] = [
            ("invalid_params", ["param": "names"]),
            ("not_in_cmux_terminal", nil),
            ("keychain_unavailable", ["status": -25308]),
            ("not_authorized", nil),
        ]
        for failure in failures {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("started")
            let run = try runCLI(
                arguments: ["safebox", "run", "API_KEY", "--", "touch", marker.path],
                responses: [
                    "safebox.resolve": .error(code: failure.code, message: "failure", data: failure.data),
                ]
            )

            #expect(run.result.status != 0, Comment(rawValue: failure.code))
            #expect(!run.result.stderr.isEmpty, Comment(rawValue: failure.code))
            #expect(!FileManager.default.fileExists(atPath: marker.path), Comment(rawValue: failure.code))
        }
    }

    @Test func runFailsClosedWhenTheAppOmitsARequestedValue() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY", "OTHER", "--", "touch", marker.path],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status != 0)
        #expect(run.result.stderr.contains("OTHER"), Comment(rawValue: run.result.stderr))
        #expect(!run.result.stderr.contains(Self.value))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func resolveRequestCarriesCommandText() throws {
        let run = try runCLI(
            arguments: [
                "safebox", "run", "API_KEY", "--",
                "sh", "-c", "curl -H \"Authorization: Bearer $API_KEY\" https://example.invalid", "--json",
            ],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        let params = try #require(run.request("safebox.resolve")?["params"] as? [String: Any])
        #expect(
            params["command"] as? String
                == #"sh -c 'curl -H "Authorization: Bearer $API_KEY" https://example.invalid' --json"#
        )
        #expect(!(params["command"] as? String ?? "").contains(Self.value))
    }

    @Test func missingCommandPathFailsBeforeResolving() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notExecutable = root.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\n".utf8).write(to: notExecutable)
        for path in [root.appendingPathComponent("no-such-command").path, notExecutable.path, root.path] {
            let run = try runCLI(
                arguments: ["safebox", "run", "API_KEY", "--", path],
                responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
            )

            #expect(run.result.status != 0, Comment(rawValue: path))
            #expect(run.result.stderr.contains(path), Comment(rawValue: run.result.stderr))
            #expect(run.request("safebox.resolve") == nil, Comment(rawValue: path))
        }
    }

    @Test func runWithoutACommandFailsBeforeResolving() throws {
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY"],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status != 0)
        #expect(run.request("safebox.resolve") == nil)
    }

    @Test func helpExplainsShellExpansionAndNeedsNoSocket() throws {
        let run = try runCLI(arguments: ["safebox", "--help"], responses: [:])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains(
            #"cmux safebox run CLOUDFLARE_TOKEN -- sh -c 'curl -H "Authorization: Bearer $CLOUDFLARE_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify'"#
        ), Comment(rawValue: run.result.stdout))
        #expect(run.requests.isEmpty)
    }

    @Test(arguments: [
        ["safebox", "--help"],
        ["safebox", "-h"],
        ["safebox", "run", "--help"],
        ["safebox", "run", "-h"],
        ["safebox", "run", "API_KEY", "--help"],
        ["safebox", "list", "--help"],
        ["safebox", "ls", "-h"],
    ])
    func helpFlagsPrintUsageAndExitZero(arguments: [String]) throws {
        let run = try runCLI(arguments: arguments, responses: [:])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains("Usage: cmux safebox <subcommand> [options]"), Comment(rawValue: run.result.stdout))
        #expect(run.requests.isEmpty)
    }

    /// A help flag after `--` belongs to the command, not to cmux.
    @Test func helpFlagAfterSeparatorReachesTheCommand() throws {
        let run = try runCLI(
            arguments: ["safebox", "run", "API_KEY", "--", "sh", "-c", "echo got \"$1\"", "sh", "--help"],
            responses: ["safebox.resolve": .ok(["values": ["API_KEY": Self.value]])]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.contains("got --help"), Comment(rawValue: run.result.stdout))
        #expect(!run.result.stdout.contains("Usage: cmux safebox"))
    }

    // MARK: - Harness

    private static var listResult: [String: Any] {
        [
            "secrets": [
                [
                    "name": "API_KEY",
                    "note": "deploy key",
                    "updated_at": "2026-11-01T10:00:00Z",
                    "last_used_at": "2026-11-02T11:30:00Z",
                    "state": "ok",
                ],
                [
                    "name": "OTHER",
                    "note": "",
                    "updated_at": "2026-11-03T09:00:00Z",
                    "last_used_at": NSNull(),
                    "state": "ok",
                ],
            ],
        ]
    }

    private enum Response {
        case ok([String: Any])
        case error(code: String, message: String, data: [String: Any]?)

        func line(id: String) -> String {
            var payload: [String: Any] = ["id": id]
            switch self {
            case .ok(let result):
                payload["ok"] = true
                payload["result"] = result
            case .error(let code, let message, let data):
                var error: [String: Any] = ["code": code, "message": message]
                if let data { error["data"] = data }
                payload["ok"] = false
                payload["error"] = error
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]

        func request(_ method: String) -> [String: Any]? {
            requests.last { $0["method"] as? String == method }
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-safebox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runCLI(arguments: [String], responses: [String: Response]) throws -> Run {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let socketPath = makeCodexHookSocketPath("safebox")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(listenerFD: listenerFD, recorder: recorder, responses: responses)
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SOCKET_PASSWORD": "",
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: environment,
            standardInput: "",
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private final class CannedResponses: @unchecked Sendable {
        let byMethod: [String: Response]

        init(_ byMethod: [String: Response]) {
            self.byMethod = byMethod
        }
    }

    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder,
        responses: [String: Response]
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        let canned = CannedResponses(responses)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder, canned: canned, stop: stop)
            }
        }
        return (done, stop)
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder, canned: CannedResponses, stop: StopFlag) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stop.isSet {
            // Poll so a client that keeps the connection open while its child
            // runs cannot hold the fixture past the test's teardown.
            var pollFD = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollFD, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            guard ready > 0 else { continue }
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let request = codexHookJSONObject(line)
                let id = (request?["id"] as? String) ?? "unknown"
                let method = request?["method"] as? String ?? ""
                let response = canned.byMethod[method] ?? .ok([:])
                guard writeAllToFixtureSocket(response.line(id: id) + "\n", fd: clientFD) else { return }
            }
        }
    }
}
