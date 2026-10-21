import CmuxFoundation
import CmuxTerminal
import Foundation
import os

/// One C callback fans raw PTY output out to every opt-in cmux consumer.
let cmuxTerminalOutputTeeCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt
) -> Void = { userdata, bytes, length in
    guard let userdata, let bytes, length > 0 else { return }
    let context = Unmanaged<TerminalOutputTeeContext>.fromOpaque(userdata).takeUnretainedValue()
    let count = Int(length)
    bytes.withMemoryRebound(to: UInt8.self, capacity: count) { rebound in
        let buffer = UnsafeBufferPointer(start: rebound, count: count)
        TerminalScrollbackCheckpointActivity.recordOutput(context.scrollbackCheckpointFlags)
        TerminalOutputUpdateTee.shared.append(surfaceID: context.surfaceID, bytes: buffer)
        TerminalPredictionCenter.shared.consumeOutput(
            surfaceID: context.surfaceID,
            bytes: buffer
        )
        context.consume(buffer)
    }
}

/// Fans raw PTY output out to in-process subscribers that wait for a terminal
/// to print (`surface.wait_text_change`).
///
/// The hot path runs on the Ghostty PTY/IO read thread for every surface, so it
/// bails before any allocation or main-actor hop unless a subscriber exists.
@MainActor
final class TerminalOutputUpdateTee {
    struct OutputChunk: Sendable {
        let sequence: UInt64
        let data: Data
    }

    // nonisolated: the singleton is an immutable `let` constructed once; the
    // only cross-thread entry point (`append`) is `nonisolated` and hops to the
    // main actor internally.
    nonisolated static let shared = TerminalOutputUpdateTee()

    private var sequencesBySurfaceID: [UUID: UInt64] = [:]
    private var continuationsBySurfaceID: [
        UUID: [UUID: AsyncStream<OutputChunk>.Continuation]
    ] = [:]
    nonisolated private let subscriberCount = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private let demand = AtomicBooleanGate(false)
    /// Serial queue so fan-out preserves byte order even though the upstream
    /// callback runs off the main thread.
    private let publishQueue = DispatchQueue(
        label: "dev.cmux.terminal.output-tee.publish",
        qos: .userInitiated
    )

    nonisolated private init() {}

    /// Non-isolated entry point called from the C tee trampoline. Safe to
    /// invoke from any thread.
    nonisolated func append(surfaceID: UUID, bytes: UnsafeBufferPointer<UInt8>) {
        guard demand.loadAcquire() else { return }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let copy = Data(bytes: base, count: bytes.count)
        publishQueue.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishFromMain(surfaceID: surfaceID, data: copy)
            }
        }
    }

    /// Opens a bounded raw-output subscription for one surface. If a slow
    /// consumer drops a chunk, the stream ends so the caller rereads instead of
    /// trusting a gap.
    func outputUpdates(surfaceID: UUID) -> AsyncStream<OutputChunk> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            continuationsBySurfaceID[surfaceID, default: [:]][id] = continuation
            subscriberCount.withLock { $0 += 1 }
            demand.storeRelease(true)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.removeContinuation(id: id, surfaceID: surfaceID)
                }
            }
        }
    }

    /// Drops subscription state for a surface (e.g. when the surface closes).
    func dropSurface(surfaceID: UUID) {
        sequencesBySurfaceID.removeValue(forKey: surfaceID)
        let continuations = continuationsBySurfaceID.removeValue(forKey: surfaceID)
            .map { Array($0.values) } ?? []
        guard !continuations.isEmpty else { return }
        let remainingCount = subscriberCount.withLock { count in
            count = max(0, count - continuations.count)
            return count
        }
        demand.storeRelease(remainingCount > 0)
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func publishFromMain(surfaceID: UUID, data: Data) {
        let chunkSequence = sequencesBySurfaceID[surfaceID] ?? 0
        sequencesBySurfaceID[surfaceID] = chunkSequence &+ UInt64(data.count)
        guard let continuations = continuationsBySurfaceID[surfaceID] else { return }
        let chunk = OutputChunk(sequence: chunkSequence, data: data)
        var droppedIDs: [UUID] = []
        for (id, continuation) in continuations {
            if case .dropped = continuation.yield(chunk) {
                continuation.finish()
                droppedIDs.append(id)
            }
        }
        for id in droppedIDs {
            removeContinuation(id: id, surfaceID: surfaceID)
        }
    }

    private func removeContinuation(id: UUID, surfaceID: UUID) {
        guard continuationsBySurfaceID[surfaceID]?.removeValue(forKey: id) != nil else {
            return
        }
        if continuationsBySurfaceID[surfaceID]?.isEmpty == true {
            continuationsBySurfaceID[surfaceID] = nil
        }
        let remainingCount = subscriberCount.withLock { count in
            count = max(0, count - 1)
            return count
        }
        demand.storeRelease(remainingCount > 0)
    }
}
