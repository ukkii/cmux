@testable import CmuxCloud
import Foundation
import Testing

@Suite
struct VMClientTelemetryTests {
    @Test("minted trace context is a valid W3C traceparent")
    func mintedTraceContextIsValidTraceparent() {
        let trace = VMRequestTraceContext.mint()
        #expect(trace.traceId.count == 32)
        #expect(trace.spanId.count == 16)
        #expect(trace.traceId.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(trace.traceId != String(repeating: "0", count: 32))
        #expect(trace.traceparent == "00-\(trace.traceId)-\(trace.spanId)-01")
        #expect(trace.headers["traceparent"] == trace.traceparent)
        #expect(trace.headers["X-Cmux-Client-Request-Id"] == trace.clientRequestId)
        #expect(VMRequestTraceContext.mint().traceId != trace.traceId)
    }

    @Test("client identity headers name the app, version, build and channel")
    func clientIdentityHeaders() {
        let headers = VMClientTelemetry.clientIdentityHeaders(
            infoDictionary: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "456"],
            channel: "nightly"
        )
        #expect(headers == [
            "X-Cmux-Client": "cmux-mac",
            "X-Cmux-Channel": "nightly",
            "X-Cmux-App-Version": "1.2.3",
            "X-Cmux-App-Build": "456",
        ])
    }

    @Test("machine ids normalize to {id} but fixed sub-resources do not")
    func normalizedRoute() {
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm") == "/api/vm")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123") == "/api/vm/{id}")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123/exec") == "/api/vm/{id}/exec")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123/cmux-remote/approve") == "/api/vm/{id}/cmux-remote/approve")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/base/open") == "/api/vm/base/open")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/tunnel?x=1") == "/api/vm/tunnel")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/leases/revoke") == "/api/vm/leases/revoke")
    }

    @Test("the reference line carries the server trace id")
    func referenceLine() {
        #expect(cloudVMReferenceLine(traceId: "abc123").contains("abc123"))
    }

    @Test("VM retries never shorten Retry-After")
    func vmRetryAfterIsAuthoritative() {
        #expect(VMClient.retryDelaySeconds(statusCode: 429, retryAfterHeader: "45") == 45)
        #expect(VMClient.retryDelaySeconds(statusCode: 429, retryAfterHeader: nil) == 60)
        #expect(VMClient.retryDelaySeconds(statusCode: 503, retryAfterHeader: "45") == nil)
    }
}
