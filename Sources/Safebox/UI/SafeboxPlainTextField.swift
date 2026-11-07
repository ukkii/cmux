import AppKit
import SwiftUI

/// Plain-text NSTextView for a secret's name and for its value while the user
/// has chosen to see it. It keeps every character exactly as typed or pasted:
/// no smart quotes, dashes, text replacement, spelling or grammar correction,
/// completion, inline prediction or Writing Tools. Paste inserts the
/// pasteboard string verbatim, so `\n`, `\r\n` and a trailing newline survive.
///
/// It never shows a hidden value; the hidden state uses `SecureField`.
final class SafeboxPlainTextView: NSTextView {
    /// Source for `paste(_:)`; tests use a private pasteboard.
    var pasteboardForPaste: NSPasteboard = .general
    /// Single-line fields hand Return to `onSubmit` instead of inserting it.
    var isSingleLine = false
    var onSubmit: (() -> Void)?

    /// Builds the view on TextKit 1 with plain-text settings.
    static func make() -> SafeboxPlainTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = SafeboxPlainTextView(frame: .zero, textContainer: container)
        view.configurePlainText()
        return view
    }

    func configurePlainText() {
        isRichText = false
        importsGraphics = false
        // Typed and pasted secrets must not outlive the editor in an undo stack.
        allowsUndo = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        if #available(macOS 14.0, *) {
            inlinePredictionType = .no
        }
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
            mathExpressionCompletionType = .no
        }
        font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 2, height: 3)
    }

    /// Clears the text and any undo actions, for when the editor closes.
    func wipe() {
        undoManager?.removeAllActions(withTarget: self)
        if let textStorage {
            undoManager?.removeAllActions(withTarget: textStorage)
            textStorage.setAttributedString(NSAttributedString())
        }
    }

    // MARK: - Verbatim paste

    override func paste(_ sender: Any?) {
        insertVerbatim(pasteboardForPaste.string(forType: .string))
    }

    override func pasteAsPlainText(_ sender: Any?) {
        insertVerbatim(pasteboardForPaste.string(forType: .string))
    }

    override func pasteAsRichText(_ sender: Any?) {
        insertVerbatim(pasteboardForPaste.string(forType: .string))
    }

    private func insertVerbatim(_ string: String?) {
        guard let string, isEditable, let textStorage else { return }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage.replaceCharacters(in: range, with: string)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
    }

    // MARK: - Sharing

    /// No Services entries: they would hand the text to another app.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }

    /// Drops Share from the context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let share = #selector(NSTextView.orderFrontSharingServicePicker(_:))
        for item in menu.items where item.action == share
            || item.submenu?.items.contains(where: { $0.representedObject is NSSharingService }) == true {
            menu.removeItem(item)
        }
        return menu
    }

    // MARK: - Keys

    override func insertNewline(_ sender: Any?) {
        if isSingleLine {
            onSubmit?()
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }
}

/// SwiftUI wrapper around `SafeboxPlainTextView`, in a bordered scroll view.
struct SafeboxPlainTextField: NSViewRepresentable {
    @Binding var text: String
    var isSingleLine = false
    var accessibilityLabel: String
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SafeboxPlainTextView.make()
        textView.delegate = context.coordinator
        textView.string = text
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = !isSingleLine
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView)
        // Only push external changes (e.g. live uppercasing, Clear); never
        // during marked-text composition.
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.wipe()
    }

    private func apply(to textView: SafeboxPlainTextView) {
        textView.isSingleLine = isSingleLine
        textView.onSubmit = onSubmit
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SafeboxPlainTextField
        weak var textView: SafeboxPlainTextView?

        init(parent: SafeboxPlainTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Rules for the editor's hidden Value state, kept apart from the view so
/// they can be tested.
enum SafeboxHiddenValueInput: Equatable {
    /// Typing goes through `SecureField` (secure event input, no services).
    case secureField
    /// The value has line breaks a single-line secure field would lose, so it
    /// is shown only as a placeholder with Clear.
    case multiLinePlaceholder(lineCount: Int)

    init(value: String) {
        guard Self.isMultiLine(value) else {
            self = .secureField
            return
        }
        self = .multiLinePlaceholder(lineCount: Self.lineCount(of: value))
    }

    static func isMultiLine(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// Lines as a reader counts them: `\r\n` is one break, and a trailing
    /// break does not start another line.
    static func lineCount(of value: String) -> Int {
        var lines = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return max(lines.count, 1)
    }
}
