import AppKit
import QuartzCore

/// Something on screen that can show a Safebox value and must hide it before
/// cmux captures one of its own windows.
@MainActor
protocol SafeboxCaptureConcealing: AnyObject {
    /// Hides every value it shows, synchronously.
    func concealForCapture()
}

/// Keeps Safebox values out of cmux's own window captures: `cmux shot`
/// (`window.screenshot`), `cmux record` (`window.record.start`) and the DEBUG
/// `debug.window.screenshot`.
///
/// These capture cmux's windows, sidebar and sheets included, without making
/// cmux resign active, so the usual hide triggers do not run. Every capture
/// entry point calls ``concealForCapture()`` on the main actor before the
/// capture starts. While a recording runs, ``isRecordingWindow()`` is true
/// and values are not revealed.
///
/// The app owns one instance; list models register themselves and are held
/// weakly.
@MainActor
final class SafeboxCaptureConcealment {
    private struct WeakTarget {
        weak var target: (any SafeboxCaptureConcealing)?
    }

    private var targets: [WeakTarget] = []
    private let isRecording: @Sendable () async -> Bool
    private let flushDisplay: @MainActor () -> Void

    /// - Parameters:
    ///   - isRecording: Whether a window recording is running.
    ///   - flushDisplay: Puts the concealed state on screen before the capture
    ///     reads the window server (default: ``flushVisibleWindows()``).
    init(
        isRecording: @escaping @Sendable () async -> Bool = { await WindowRecordingRegistry.shared.isRecording() },
        flushDisplay: (@MainActor () -> Void)? = nil
    ) {
        self.isRecording = isRecording
        self.flushDisplay = flushDisplay ?? { SafeboxCaptureConcealment.flushVisibleWindows() }
    }

    func register(_ target: any SafeboxCaptureConcealing) {
        targets.removeAll { $0.target == nil || $0.target === target }
        targets.append(WeakTarget(target: target))
    }

    /// Hides every revealed value and the editor's visible value field, then
    /// redraws cmux's windows so the capture cannot see the old frame.
    func concealForCapture() {
        targets.removeAll { $0.target == nil }
        for entry in targets {
            entry.target?.concealForCapture()
        }
        flushDisplay()
    }

    /// True while a capture that keeps reading frames (a recording) runs.
    func isRecordingWindow() async -> Bool {
        await isRecording()
    }

    /// Lays out and draws every visible window now and commits the layer
    /// tree, so SwiftUI's concealed state reaches the window server before
    /// ScreenCaptureKit reads it.
    static func flushVisibleWindows() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        CATransaction.flush()
    }
}
