import CmuxFoundation
import Darwin
import Foundation

/// `cmux safebox …`: secrets stored in cmux, handed to one command at a time.
///
/// `list` shows names, notes and dates, never a value. `run` asks the app for
/// the values (`safebox.resolve`, which may wait for the user's approval),
/// starts the command with them in its environment only, and masks them in
/// its output. Every failure stops before the command starts, and no message
/// carries a value.
extension CMUXCLI {
    /// Covers the app's 60 second approval wait with room to spare.
    static let safeboxResolveTimeout: TimeInterval = 75

    static let safeboxUsage = String(
        localized: "safebox.cli.usage",
        defaultValue: """
        Usage: cmux safebox <subcommand> [options]

        Use secrets stored in cmux (the Safebox tab beside Recent, Folder and
        Agent in the sessions sidebar) without printing them.

        Subcommands:
          list [--json]
              List secret names, notes, and when each was changed and last
              used. Values are never shown.
          run NAME [NAME ...] [--as ENV=NAME ...] -- <command> [args...]
              Start <command> with each secret's value in an environment
              variable named after the secret. --as ENV=NAME puts the value of
              NAME in variable ENV instead (ENV must match ^[A-Z_][A-Z0-9_]*$).
              Exits with the command's exit status.

        Example:
          cmux safebox run CLOUDFLARE_TOKEN -- sh -c 'curl -H "Authorization: Bearer $CLOUDFLARE_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify'

        Notes:
          - Values are passed only through the environment, never as arguments.
            Expand $VAR inside the command (hence sh -c with single quotes): the
            shell you type in would expand it before cmux runs, to nothing.
            Tools that read the variable themselves can run directly.
          - Every occurrence of a value in the command's output is replaced
            with ***. Values shorter than 4 bytes are not masked.
          - The first use of a secret in a session waits for you to Allow or
            Deny it in cmux (up to 60 seconds).
          - The command's output always goes through pipes so it can be
            masked; interactive full-screen programs (TUIs) are not supported.
          - run waits until every process holding the command's output open
            has exited, so a background daemon the command starts keeps it
            waiting.
          - Secrets are added and changed only in the cmux app.
        """
    )

    func runSafeboxNamespace(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            print(Self.safeboxUsage)
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "list", "ls":
            if let unexpected = rest.first {
                throw Self.safeboxUnexpectedArgument(unexpected, subcommand: "list")
            }
            let payload = try client.sendV2(method: "safebox.list")
            printSafeboxList(payload, jsonOutput: jsonOutput)
        case "run":
            let exitCode = try runSafeboxRun(arguments: rest, client: client)
            if exitCode != 0 {
                client.close()
                Darwin.exit(exitCode)
            }
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "safebox.cli.error.unknownSubcommand",
                    defaultValue: "Unknown safebox subcommand '%@'. Try: list, run"
                ),
                CLITerminalText.printable(subcommand)
            ))
        }
    }

    // MARK: - list

    private func printSafeboxList(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        if let status = payload["keychain_status"] as? Int {
            cliWriteStderr(String(
                format: String(
                    localized: "safebox.cli.list.keychainWarning",
                    defaultValue: "warning: cmux could not read the Keychain (status %@), so it cannot tell which secrets have a stored value."
                ),
                String(status)
            ) + "\n")
        }
        let secrets = payload["secrets"] as? [[String: Any]] ?? []
        if secrets.isEmpty {
            print(String(localized: "safebox.cli.list.empty", defaultValue: "No secrets in Safebox."))
            return
        }
        let never = String(localized: "safebox.cli.list.never", defaultValue: "never")
        for secret in secrets {
            let name = Self.safeboxField(secret["name"])
            let note = Self.safeboxField(secret["note"])
            let updated = Self.safeboxField(secret["updated_at"])
            let lastUsed = (secret["last_used_at"] as? String).map { Self.safeboxField($0) } ?? never
            print("\(name)\t\(note)\tupdated \(updated)\tlast used \(lastUsed)")
            if secret["state"] as? String == "value_missing" {
                cliWriteStderr(String(
                    format: String(
                        localized: "safebox.cli.list.valueMissing",
                        defaultValue: "warning: %@ has no stored value; set it again in cmux."
                    ),
                    name
                ) + "\n")
            }
        }
    }

    /// One tab-separated field: no tabs, line breaks or terminal controls.
    private static func safeboxField(_ value: Any?) -> String {
        let text = value as? String ?? ""
        return CLITerminalText.printable(
            text.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        )
    }

    // MARK: - run

    struct SafeboxRunRequest: Equatable {
        /// Secrets to request, in order, without duplicates.
        var names: [String] = []
        /// Environment variable to secret name.
        var variables: [String: String] = [:]
        var command: [String] = []
    }

    /// Parses `NAME [NAME ...] [--as ENV=NAME ...] -- <command> [args...]`.
    /// Names are uppercased, as the app does; nothing here is echoed except
    /// a rejected `--as` variable, which is a name, not a value.
    static func parseSafeboxRun(_ arguments: [String]) throws -> SafeboxRunRequest {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw CLIError(message: String(
                localized: "safebox.cli.error.separatorRequired",
                defaultValue: "safebox run needs -- before the command: cmux safebox run NAME -- <command> [args...]"
            ))
        }
        var request = SafeboxRunRequest()
        request.command = Array(arguments[(separator + 1)...])
        var index = 0
        let options = Array(arguments[..<separator])
        while index < options.count {
            let argument = options[index]
            index += 1
            if argument == "--as" || argument.hasPrefix("--as=") {
                let assignment: String
                if argument == "--as" {
                    guard index < options.count else {
                        throw CLIError(message: String(
                            localized: "safebox.cli.error.asValueRequired",
                            defaultValue: "--as requires ENV=NAME"
                        ))
                    }
                    assignment = options[index]
                    index += 1
                } else {
                    assignment = String(argument.dropFirst("--as=".count))
                }
                guard let equals = assignment.firstIndex(of: "=") else {
                    throw CLIError(message: String(
                        localized: "safebox.cli.error.asValueRequired",
                        defaultValue: "--as requires ENV=NAME"
                    ))
                }
                let variable = String(assignment[..<equals])
                guard isSafeboxVariableName(variable) else {
                    throw CLIError(message: String(
                        format: String(
                            localized: "safebox.cli.error.invalidVariable",
                            defaultValue: "--as: '%@' is not a valid variable name. Use capital letters, digits and underscores, not starting with a digit."
                        ),
                        CLITerminalText.printable(variable)
                    ))
                }
                let name = try safeboxSecretName(String(assignment[assignment.index(after: equals)...]))
                request.variables[variable] = name
                if !request.names.contains(name) { request.names.append(name) }
            } else if argument.hasPrefix("-") {
                throw safeboxUnexpectedArgument(argument, subcommand: "run")
            } else {
                let name = try safeboxSecretName(argument)
                request.variables[name] = request.variables[name] ?? name
                if !request.names.contains(name) { request.names.append(name) }
            }
        }
        guard !request.names.isEmpty else {
            throw CLIError(message: String(
                localized: "safebox.cli.error.namesRequired",
                defaultValue: "safebox run needs at least one secret name: cmux safebox run NAME -- <command> [args...]"
            ))
        }
        guard !request.command.isEmpty else {
            throw CLIError(message: String(
                localized: "safebox.cli.error.commandRequired",
                defaultValue: "safebox run needs a command after --"
            ))
        }
        return request
    }

    static func isSafeboxVariableName(_ value: String) -> Bool {
        guard let first = value.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    /// A secret name as the app stores it. A rejected name is not echoed:
    /// a value pasted in its place must not reach the terminal.
    private static func safeboxSecretName(_ raw: String) throws -> String {
        let name = raw.uppercased()
        guard isSafeboxVariableName(name) else {
            throw CLIError(message: String(
                localized: "safebox.cli.error.invalidName",
                defaultValue: "safebox run: a secret name is not valid. Names use letters, digits and underscores, not starting with a digit (see cmux safebox list)."
            ))
        }
        return name
    }

    private func runSafeboxRun(arguments: [String], client: SocketClient) throws -> Int32 {
        let request = try Self.parseSafeboxRun(arguments)
        let environment = ProcessInfo.processInfo.environment
        let program = request.command[0]
        let executable: String
        if program.contains("/") {
            // Check before resolving: a mistyped path must never ask for approval.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: program, isDirectory: &isDirectory) else {
                throw Self.safeboxCommandNotFound(program)
            }
            guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: program) else {
                throw CLIError(
                    message: String(
                        format: String(
                            localized: "safebox.cli.error.commandNotExecutable",
                            defaultValue: "safebox run: not an executable file: %@"
                        ),
                        CLITerminalText.printable(program)
                    ),
                    exitCode: 126
                )
            }
            executable = program
        } else if let resolved = resolveExecutableInSearchPath(program, searchPath: environment["PATH"]) {
            executable = resolved
        } else {
            throw Self.safeboxCommandNotFound(program)
        }

        let values = try resolveSafeboxValues(
            names: request.names,
            command: request.command.map(\.posixShellWord).joined(separator: " "),
            client: client
        )
        // The socket is not needed while the command runs.
        client.close()

        var childEnvironment = environment
        for (variable, name) in request.variables {
            childEnvironment[variable] = values[name]
        }
        let runner = SafeboxChildRunner(secrets: Array(values.values))
        return try runner.run(executable: executable, arguments: request.command, environment: childEnvironment)
    }

    /// The values of `names`, or an error that names the secrets involved.
    private func resolveSafeboxValues(
        names: [String],
        command: String,
        client: SocketClient
    ) throws -> [String: String] {
        let response = try client.sendV2Envelope(
            method: "safebox.resolve",
            params: ["names": names, "command": command],
            responseTimeout: Self.safeboxResolveTimeout
        )
        if response["ok"] as? Bool == true {
            let values = (response["result"] as? [String: Any])?["values"] as? [String: String] ?? [:]
            let missing = names.filter { values[$0] == nil }
            guard missing.isEmpty else {
                throw Self.safeboxResolveError(code: "unknown_secret", data: ["names": missing], message: nil)
            }
            return values.filter { names.contains($0.key) }
        }
        let error = response["error"] as? [String: Any] ?? [:]
        throw Self.safeboxResolveError(
            code: error["code"] as? String ?? "error",
            data: error["data"] as? [String: Any],
            message: error["message"] as? String
        )
    }

    /// An English message for a `safebox.resolve` failure. Only names and
    /// Keychain status codes reach it; the app never sends values in errors.
    static func safeboxResolveError(code: String, data: [String: Any]?, message: String?) -> CLIError {
        let names = (data?["names"] as? [String] ?? [])
            .map { CLITerminalText.printable($0) }
            .joined(separator: ", ")
        let text: String
        switch code {
        case "unknown_secret":
            text = String(
                format: String(
                    localized: "safebox.cli.error.unknownSecret",
                    defaultValue: "safebox: no stored value for %@. Check the names with cmux safebox list. The command was not run."
                ),
                names
            )
        case "not_approved":
            text = String(
                format: String(
                    localized: "safebox.cli.error.notApproved",
                    defaultValue: "safebox: access to %@ was not approved. The command was not run."
                ),
                names
            )
        case "not_in_cmux_terminal":
            text = String(
                localized: "safebox.cli.error.notInCmuxTerminal",
                defaultValue: "safebox: run this from a cmux terminal. The command was not run."
            )
        case "keychain_unavailable":
            if let status = data?["status"] as? Int {
                text = String(
                    format: String(
                        localized: "safebox.cli.error.keychainStatus",
                        defaultValue: "safebox: cmux could not read secret values from the Keychain (status %@). The command was not run."
                    ),
                    String(status)
                )
            } else {
                text = String(
                    localized: "safebox.cli.error.keychainUnavailable",
                    defaultValue: "safebox: cmux could not read Safebox. The command was not run."
                )
            }
        case "not_authorized":
            text = String(
                localized: "safebox.cli.error.notAuthorized",
                defaultValue: "safebox: secrets are not available through a remote session. The command was not run."
            )
        default:
            let detail = message.map { CLITerminalText.printable($0) } ?? code
            text = String(
                format: String(
                    localized: "safebox.cli.error.resolveFailed",
                    defaultValue: "safebox: %@ The command was not run."
                ),
                detail
            )
        }
        return CLIError(message: text, v2Code: code, isStructuredProtocolResponse: true, v2Method: "safebox.resolve")
    }

    private static func safeboxCommandNotFound(_ program: String) -> CLIError {
        CLIError(
            message: String(
                format: String(
                    localized: "safebox.cli.error.commandNotFound",
                    defaultValue: "safebox run: command not found: %@"
                ),
                CLITerminalText.printable(program)
            ),
            exitCode: 127
        )
    }

    private static func safeboxUnexpectedArgument(_ argument: String, subcommand: String) -> CLIError {
        CLIError(message: String(
            format: String(
                localized: "safebox.cli.error.unexpectedArgument",
                defaultValue: "Unexpected argument '%@' for cmux safebox %@"
            ),
            CLITerminalText.printable(argument),
            subcommand
        ))
    }
}
