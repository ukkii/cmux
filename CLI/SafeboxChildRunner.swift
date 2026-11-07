import Darwin
import Dispatch
import Foundation

/// Runs the command of `cmux safebox run` with secret values in its
/// environment and masks those values in everything it prints.
///
/// The child inherits standard input. Its standard output and error are
/// always pipes, even when the CLI's own are a terminal: masking needs to see
/// every byte, so interactive full-screen programs do not work under
/// `safebox run`. Each pipe goes through its own ``SafeboxOutputMasker`` to the
/// CLI's matching descriptor.
///
/// SIGINT, SIGTERM, SIGHUP and SIGQUIT sent to the CLI are forwarded to the
/// child. A keyboard SIGINT or SIGQUIT is not forwarded while the CLI's process
/// group owns its terminal: the terminal already sent it to the child, which
/// shares that group.
///
/// The values exist only in the environment block handed to `posix_spawn`;
/// the CLI never sets them in its own environment. Other descriptors of the
/// CLI, such as its control socket, are not inherited.
struct SafeboxChildRunner {
    static let forwardedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    /// Values to mask in the child's output.
    let secrets: [String]

    init(secrets: [String]) {
        self.secrets = secrets
    }

    /// Starts `executable` and waits for it and its output to finish.
    ///
    /// - Parameters:
    ///   - executable: Absolute path of the program; the caller resolves a bare
    ///     command name through `PATH` first.
    ///   - arguments: The child's `argv`, the program name first.
    ///   - environment: The child's complete environment.
    /// - Returns: The child's exit status, or `128 + signal` when a signal
    ///   ended it.
    func run(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        let output = try Self.makePipe()
        let errors: (read: Int32, write: Int32)
        do {
            errors = try Self.makePipe()
        } catch {
            Darwin.close(output.read)
            Darwin.close(output.write)
            throw error
        }

        let forwarder = SignalForwarder(signals: Self.forwardedSignals)
        defer { forwarder.stop() }

        let processID: pid_t
        do {
            processID = try Self.spawn(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardOutput: output.write,
                standardError: errors.write
            )
        } catch {
            for descriptor in [output.read, output.write, errors.read, errors.write] {
                Darwin.close(descriptor)
            }
            throw error
        }
        Darwin.close(output.write)
        Darwin.close(errors.write)
        forwarder.attach(to: processID)

        pump(streams: [
            MaskedPipe(source: output.read, destination: STDOUT_FILENO, masker: SafeboxOutputMasker(secrets: secrets)),
            MaskedPipe(source: errors.read, destination: STDERR_FILENO, masker: SafeboxOutputMasker(secrets: secrets)),
        ])

        let status = Self.waitForExit(processID)
        forwarder.detach()
        return status
    }

    // MARK: - Spawning

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw CLIError(message: startFailureMessage(errno))
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CLIError(message: startFailureMessage(errno))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var status = posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
        if status == 0 { status = posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO) }
        if status == 0 { status = posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO) }
        guard status == 0 else { throw CLIError(message: startFailureMessage(status)) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CLIError(message: startFailureMessage(errno))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // The child starts from the signal state a shell gives a program (see
        // `cliResetInheritedSignalStateForExec()`): nothing blocked, and the
        // signals the CLI ignores or forwards back at their defaults.
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in cliChildLaunchDefaultDispositionSignals + forwardedSignals {
            sigaddset(&defaultSignals, signalNumber)
        }
        status = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        if status == 0 { status = posix_spawnattr_setsigmask(&attributes, &signalMask) }
        if status == 0 { status = posix_spawnattr_setsigdefault(&attributes, &defaultSignals) }
        guard status == 0 else { throw CLIError(message: startFailureMessage(status)) }

        var processID: pid_t = 0
        status = withCStrings(arguments) { argv in
            withCStrings(environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }) { envp in
                posix_spawn(&processID, executable, &fileActions, &attributes, argv, envp)
            }
        }
        guard status == 0 else {
            throw CLIError(message: startFailureMessage(status), exitCode: status == ENOENT ? 127 : 126)
        }
        return processID
    }

    private static func withCStrings<Result>(
        _ strings: [String],
        body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                // Environment strings hold secret values: clear them before
                // they go back to the allocator.
                if let pointer { memset_s(pointer, strlen(pointer), 0, strlen(pointer)) }
                free(pointer)
            }
        }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func startFailureMessage(_ code: Int32) -> String {
        String(
            format: String(
                localized: "safebox.cli.error.startFailed",
                defaultValue: "safebox: could not start the command: %@"
            ),
            String(cString: strerror(code))
        )
    }

    private static func waitForExit(_ processID: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 {
            guard errno == EINTR else { return 1 }
        }
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    // MARK: - Output

    private struct MaskedPipe {
        let source: Int32
        let destination: Int32
        var masker: SafeboxOutputMasker
        /// Whether output is still written; a closed destination drops it.
        var writable = true
    }

    /// Copies both pipes through their maskers until the child and every
    /// process that inherited the pipes close them.
    private func pump(streams initial: [MaskedPipe]) {
        var streams = initial
        var isOpen = streams.indices.map { _ in true }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while isOpen.contains(true) {
            var descriptors = streams.indices.map { index in
                pollfd(fd: isOpen[index] ? streams[index].source : -1, events: Int16(POLLIN), revents: 0)
            }
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in streams.indices where isOpen[index] && descriptors[index].revents != 0 {
                let count = Darwin.read(streams[index].source, &buffer, buffer.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                if count <= 0 {
                    let tail = streams[index].masker.finish()
                    Self.write(tail, to: &streams[index])
                    Darwin.close(streams[index].source)
                    isOpen[index] = false
                    continue
                }
                let masked = streams[index].masker.process(Data(buffer[0..<count]))
                Self.write(masked, to: &streams[index])
                if !streams[index].writable {
                    // Like a shell pipeline: once the reader is gone, closing
                    // the pipe lets the child see EPIPE or SIGPIPE.
                    Darwin.close(streams[index].source)
                    isOpen[index] = false
                }
            }
        }
        // Clear the read buffer: it held unmasked output.
        buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    private static func write(_ data: Data, to stream: inout MaskedPipe) {
        guard stream.writable, !data.isEmpty else { return }
        let written = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(stream.destination, base + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var descriptor = pollfd(fd: stream.destination, events: Int16(POLLOUT), revents: 0)
                        _ = Darwin.poll(&descriptor, 1, -1)
                        continue
                    }
                    return false
                }
                offset += count
            }
            return true
        }
        if !written { stream.writable = false }
    }
}

/// Forwards termination signals the CLI receives to the child.
///
/// The signals are ignored by the CLI's default handlers while the child runs
/// and delivered through dispatch sources instead. A signal that arrives
/// before the child exists is held and sent once it starts.
private final class SignalForwarder: @unchecked Sendable {
    private let signals: [Int32]
    private let queue = DispatchQueue(label: "com.cmuxterm.cli.safebox.signals")
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(signal: Int32, handler: sig_t?)] = []
    private let lock = NSLock()
    private var childProcessID: pid_t = 0
    private var held: [Int32] = []

    init(signals: [Int32]) {
        self.signals = signals
        for signalNumber in signals {
            previousHandlers.append((signalNumber, Darwin.signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in self?.received(signalNumber) }
            source.resume()
            sources.append(source)
        }
    }

    func attach(to processID: pid_t) {
        lock.lock()
        childProcessID = processID
        let pending = held
        held.removeAll()
        lock.unlock()
        for signalNumber in pending {
            Darwin.kill(processID, signalNumber)
        }
    }

    /// Stops forwarding once the child has been reaped, so a reused pid
    /// cannot receive a late signal.
    func detach() {
        lock.lock()
        childProcessID = 0
        lock.unlock()
    }

    func stop() {
        detach()
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        for previous in previousHandlers {
            _ = Darwin.signal(previous.signal, previous.handler ?? SIG_DFL)
        }
        previousHandlers.removeAll()
    }

    private func received(_ signalNumber: Int32) {
        if (signalNumber == SIGINT || signalNumber == SIGQUIT), Self.ownsForegroundOfTerminal() {
            return
        }
        lock.lock()
        let processID = childProcessID
        if processID == 0 { held.append(signalNumber) }
        lock.unlock()
        if processID > 0 {
            Darwin.kill(processID, signalNumber)
        }
    }

    /// Whether the CLI's process group is the foreground group of the
    /// terminal on one of its standard descriptors. The terminal driver sends
    /// keyboard signals to that whole group, child included.
    private static func ownsForegroundOfTerminal() -> Bool {
        let group = getpgrp()
        return [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains { descriptor in
            isatty(descriptor) == 1 && tcgetpgrp(descriptor) == group
        }
    }
}
