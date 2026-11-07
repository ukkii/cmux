import AppKit

/// The pasteboard Safebox's Copy Value writes to.
@MainActor
protocol SafeboxValuePasteboard: AnyObject, Sendable {
    /// Changes whenever anything writes to the pasteboard.
    var changeCount: Int { get }
    /// Writes `value` as the only item, marked concealed and transient.
    func writeConcealed(_ value: String)
    func clearContents()
}

/// `NSPasteboard.general`.
@MainActor
final class SafeboxGeneralPasteboard: SafeboxValuePasteboard {
    var changeCount: Int { NSPasteboard.general.changeCount }

    /// The concealed and transient markers make clipboard managers that honor
    /// them skip the item.
    func writeConcealed(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
    }

    func clearContents() {
        NSPasteboard.general.clearContents()
    }
}

/// Copies a Safebox value and clears it from the pasteboard after
/// ``defaultDelay``, the way password managers do, unless something else was
/// copied meanwhile (the pasteboard's change count moved). A local timer only.
@MainActor
final class SafeboxCopiedValueExpiry {
    static let defaultDelay: Duration = .seconds(60)

    private let pasteboard: any SafeboxValuePasteboard
    private let delay: Duration
    private let clock: any Clock<Duration>
    private var pendingClear: Task<Void, Never>?

    init(
        pasteboard: any SafeboxValuePasteboard,
        delay: Duration = SafeboxCopiedValueExpiry.defaultDelay,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.pasteboard = pasteboard
        self.delay = delay
        self.clock = clock
    }

    /// Writes `value` and schedules its removal. A later copy replaces the
    /// pending removal with its own.
    func copy(_ value: String) {
        pendingClear?.cancel()
        pasteboard.writeConcealed(value)
        let copiedChangeCount = pasteboard.changeCount
        let pasteboard = pasteboard
        let delay = delay
        let clock = clock
        // Holds the pasteboard, not the expiry: the value is cleared even
        // when the Safebox tab that copied it is gone.
        pendingClear = Task { @MainActor in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard pasteboard.changeCount == copiedChangeCount else { return }
            pasteboard.clearContents()
        }
    }
}
