import CmuxSettings
import Foundation
import os

/// W3C trace context the client mints for one Cloud VM API request.
///
/// The server keeps the trace id when it can (its sampler still makes its own
/// sampling decision) and always answers with `x-cmux-trace-id`, so a failure
/// seen on the Mac and the span stored in Axiom share a key even when the
/// response never arrived.
public struct VMRequestTraceContext: Sendable, Equatable {
    public init(
        traceId: String,
        spanId: String,
        clientRequestId: String
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.clientRequestId = clientRequestId
    }

    /// 32 lowercase hex characters, never all zero.
    public let traceId: String
    /// 16 lowercase hex characters, never all zero.
    public let spanId: String
    /// Stable id for the logical request across 429 retries.
    public let clientRequestId: String

    static let traceparentHeader = "traceparent"
    static let clientRequestIdHeader = "X-Cmux-Client-Request-Id"
    static let serverTraceIdHeader = "x-cmux-trace-id"

    /// `00-<trace id>-<span id>-01`; sampled flag set so intermediaries keep it.
    public var traceparent: String { "00-\(traceId)-\(spanId)-01" }

    public var headers: [String: String] {
        [
            Self.traceparentHeader: traceparent,
            Self.clientRequestIdHeader: clientRequestId,
        ]
    }

    public static func mint() -> VMRequestTraceContext {
        VMRequestTraceContext(
            traceId: randomHex(bytes: 16),
            spanId: randomHex(bytes: 8),
            clientRequestId: UUID().uuidString.lowercased()
        )
    }

    private static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        repeat {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        } while bytes.allSatisfy { $0 == 0 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// How one Cloud VM API request ended, as seen by the client.
public enum VMRequestOutcome: Sendable, Equatable {
    /// The server answered. `errorCode` is its machine-readable `error` for a
    /// 4xx/5xx body, `nil` on success.
    case response(status: Int, errorCode: String?, serverTraceId: String?)
    /// No HTTP response: DNS, connect, TLS, timeout, or a local precondition.
    case transportFailure(kind: VMTransportFailureKind, detail: String)

    /// Whether the server answered below 400.
    public var isSuccess: Bool {
        if case .response(let status, _, _) = self { return status < 400 }
        return false
    }

    public var httpStatus: Int? {
        if case .response(let status, _, _) = self { return status }
        return nil
    }

    /// One token that names the failure class for grouping.
    public var errorCode: String? {
        switch self {
        case .response(let status, let errorCode, _):
            if status < 400 { return nil }
            return errorCode ?? "http_\(status)"
        case .transportFailure(let kind, _):
            return kind.rawValue
        }
    }

    public var serverTraceId: String? {
        if case .response(_, _, let traceId) = self { return traceId }
        return nil
    }
}

public enum VMTransportFailureKind: String, Sendable {
    case notSignedIn = "not_signed_in"
    case sessionRefreshFailed = "session_refresh_failed"
    case backendUnreachable = "backend_unreachable"
    case malformedResponse = "malformed_response"
    case cancelled = "cancelled"
    case urlError = "url_error"
    case unknown = "unknown"
}

/// One measured Cloud VM API request.
public struct VMRequestTelemetryRecord: Sendable, Equatable {
    public init(
        method: String,
        route: String,
        outcome: VMRequestOutcome,
        durationMs: Double,
        retryCount: Int,
        trace: VMRequestTraceContext
    ) {
        self.method = method
        self.route = route
        self.outcome = outcome
        self.durationMs = durationMs
        self.retryCount = retryCount
        self.trace = trace
    }

    public let method: String
    /// Request path with machine ids replaced by `{id}` (`/api/vm/{id}/exec`).
    public let route: String
    public let outcome: VMRequestOutcome
    public let durationMs: Double
    public let retryCount: Int
    public let trace: VMRequestTraceContext

    /// `"POST /api/vm"`; the same shape the server's `cmux.api.*` span names use.
    public var operation: String { "\(method) \(route)" }

    /// The id operators look up: the server's when it answered, else ours.
    var referenceTraceId: String { outcome.serverTraceId ?? trace.traceId }
}

/// Client-side diagnostics for the Cloud VM control plane: every request is
/// written to `os.log` (subsystem `com.cmuxterm.app`, category `CloudVM`),
/// readable from release builds with `log show`. Nothing leaves the machine.
public final class VMClientTelemetry: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudVM")

    public init() {}

    /// Identity headers sent with every request so server spans and events can
    /// be broken down by client, version, build and channel.
    public static func clientIdentityHeaders(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        channel: String = BuildFlavor.current.rawValue
    ) -> [String: String] {
        var headers = ["X-Cmux-Client": "cmux-mac", "X-Cmux-Channel": channel]
        if let version = infoDictionary["CFBundleShortVersionString"] as? String, !version.isEmpty {
            headers["X-Cmux-App-Version"] = version
        }
        if let build = infoDictionary["CFBundleVersion"] as? String, !build.isEmpty {
            headers["X-Cmux-App-Build"] = build
        }
        return headers
    }

    public func record(_ record: VMRequestTelemetryRecord) {
        log(record)
    }

    // MARK: - Routes

    /// `/api/vm/<machine id>/exec` -> `/api/vm/{id}/exec`. Machine ids are the
    /// segment after `/api/vm/` unless it is a fixed sub-resource.
    public static func normalizedRoute(path: String) -> String {
        let fixed: Set<String> = ["base", "leases", "restore", "tunnel"]
        var segments = path.split(separator: "?", maxSplits: 1)[0].split(separator: "/").map(String.init)
        if segments.count >= 3, segments[0] == "api", segments[1] == "vm", !fixed.contains(segments[2]) {
            segments[2] = "{id}"
        }
        return "/" + segments.joined(separator: "/")
    }

    // MARK: - Private

    private func log(_ record: VMRequestTelemetryRecord) {
        let duration = Int(record.durationMs.rounded())
        switch record.outcome {
        case .response(let status, let errorCode, _):
            if status < 400 {
                logger.info("\(record.operation, privacy: .public) \(status) \(duration)ms trace=\(record.referenceTraceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public)")
            } else {
                logger.error("\(record.operation, privacy: .public) \(status) \(errorCode ?? "-", privacy: .public) \(duration)ms trace=\(record.referenceTraceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public)")
            }
        case .transportFailure(let kind, let detail):
            logger.error("\(record.operation, privacy: .public) \(kind.rawValue, privacy: .public) \(duration)ms trace=\(record.trace.traceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public) detail=\(detail, privacy: .public)")
        }
    }
}
