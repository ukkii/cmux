import AppKit
import CMUXMobileCore
import WebKit

@MainActor
extension BrowserPanel {
    @discardableResult
    func presentMobileBrowserDialog(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [MobileBrowserDialogButton],
        textField: MobileBrowserDialogTextField?,
        informational: Bool,
        alert: NSAlert,
        response: @escaping @MainActor (_ buttonID: String, _ text: String?) -> Void,
        macResponse: @escaping @MainActor (NSApplication.ModalResponse) -> (buttonID: String, text: String?),
        cancelButtonID: String
    ) -> MobileBrowserDialogEvent {
        let dialog = mobileBrowserDialogBroker.begin(
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: buttons,
            textField: textField,
            informational: informational,
            resolve: response
        )
        // Keep the native completion pending for the CLI. A later reveal must
        // not turn an automation-owned dialog into a sheet on the user's window.
        if browserDialogsOwnedByCLI, Self.isJavaScriptDialog(kind) {
            return dialog
        }
        let broker = mobileBrowserDialogBroker
        let dismiss = presentBrowserAlert(
            alert,
            in: webView,
            completion: { [weak broker] modalResponse in
                let answer = macResponse(modalResponse)
                _ = broker?.respond(MobileBrowserDialogRespondParameters(
                    panelID: dialog.panelID,
                    dialogID: dialog.dialogID,
                    buttonID: answer.buttonID,
                    text: answer.text
                ))
            },
            cancel: { [weak broker] in
                _ = broker?.respond(MobileBrowserDialogRespondParameters(
                    panelID: dialog.panelID,
                    dialogID: dialog.dialogID,
                    buttonID: cancelButtonID,
                    text: nil
                ))
            }
        )
        mobileBrowserDialogBroker.attachDismissal(dialogID: dialog.dialogID, dismissal: dismiss)
        return dialog
    }

    static func isJavaScriptDialog(_ kind: MobileBrowserDialogKind) -> Bool {
        switch kind {
        case .javaScriptAlert, .javaScriptConfirm, .javaScriptPrompt: return true
        default: return false
        }
    }

    var pendingJavaScriptDialogs: [MobileBrowserDialogEvent] {
        mobileBrowserDialogBroker.pendingDialogs.filter { Self.isJavaScriptDialog($0.kind) }
    }

    /// Claims the navigation's JavaScript dialogs together before invoking cancellation callbacks.
    func cancelPendingJavaScriptDialogs() {
        mobileBrowserDialogBroker.resolveAll { Self.isJavaScriptDialog($0.kind) }
    }

    /// Resolves the oldest native JavaScript dialog without evaluating page script.
    func respondToJavaScriptDialog(accept: Bool, text: String?) -> MobileBrowserDialogEvent? {
        guard let dialog = pendingJavaScriptDialogs.first else { return nil }
        let button = dialog.kind == .javaScriptAlert || accept ? "ok" : "cancel"
        guard mobileBrowserDialogBroker.respond(MobileBrowserDialogRespondParameters(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID,
            buttonID: button,
            text: accept ? (text ?? dialog.textField?.initial ?? "") : nil
        )) else { return nil }
        return dialog
    }

    func beginInformationalMobileBrowserDialog(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        cancelLabel: String,
        cancel: @escaping @MainActor () -> Void
    ) -> MobileBrowserDialogEvent {
        mobileBrowserDialogBroker.begin(
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: [MobileBrowserDialogButton(id: "cancel", label: cancelLabel, role: .cancel)],
            textField: nil,
            informational: true,
            resolve: { _, _ in cancel() }
        )
    }

    @discardableResult
    func resolveMobileBrowserDialogFromMac(
        _ dialog: MobileBrowserDialogEvent,
        action: @escaping @MainActor () -> Void
    ) -> Bool {
        mobileBrowserDialogBroker.resolveFromMac(dialogID: dialog.dialogID, action: action)
    }

    func presentMobileClientCertificateAlert(
        _ alert: NSAlert,
        webView: WKWebView,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        let dialog = beginInformationalMobileBrowserDialog(
            kind: .clientCertificate,
            title: alert.messageText,
            message: alert.informativeText,
            host: webView.url?.host,
            cancelLabel: String(localized: "common.cancel", defaultValue: "Cancel"),
            cancel: cancel
        )
        let dismiss = presentBrowserAlert(
            alert,
            in: webView,
            completion: { [weak self] response in
                _ = self?.resolveMobileBrowserDialogFromMac(dialog) {
                    completion(response)
                }
            },
            cancel: { [weak self] in
                _ = self?.resolveMobileBrowserDialogFromMac(dialog, action: cancel)
            }
        )
        mobileBrowserDialogBroker.attachDismissal(dialogID: dialog.dialogID, dismissal: dismiss)
    }
}

// MARK: - Dialog broker


/// Owns panel-wide native browser dialog completions and arbitrates Mac/phone answers.
@MainActor
final class MobileBrowserDialogBroker {
    typealias Resolver = @MainActor (_ buttonID: String, _ text: String?) -> Void
    typealias Dismissal = @MainActor () -> Void

    private struct PendingResolution {
        let resolve: Resolver
        var dismiss: Dismissal?
    }

    let panelID: String
    var onPresented: (@MainActor (MobileBrowserDialogEvent) -> Void)?
    var onResolved: (@MainActor (MobileBrowserDialogResolvedEvent) -> Void)?

    private var queue = MobileBrowserDialogQueue()
    private var resolutions: [String: PendingResolution] = [:]

    init(panelID: String) {
        self.panelID = panelID
    }

    var currentDialog: MobileBrowserDialogEvent? { queue.current }

    /// Every unresolved dialog, including dialogs whose native presentation is deferred.
    var pendingDialogs: [MobileBrowserDialogEvent] { queue.pending }

    @discardableResult
    func begin(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [MobileBrowserDialogButton],
        textField: MobileBrowserDialogTextField?,
        informational: Bool,
        resolve: @escaping Resolver
    ) -> MobileBrowserDialogEvent {
        let shouldPublish = queue.current == nil
        let dialog = MobileBrowserDialogEvent(
            panelID: panelID,
            dialogID: UUID().uuidString,
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: buttons,
            textField: textField,
            informational: informational
        )
        _ = queue.install(dialog)
        resolutions[dialog.dialogID] = PendingResolution(resolve: resolve, dismiss: nil)
        if shouldPublish {
            onPresented?(dialog)
        }
        return dialog
    }

    func attachDismissal(dialogID: String, dismissal: @escaping Dismissal) {
        guard var pending = resolutions[dialogID] else {
            dismissal()
            return
        }
        pending.dismiss = dismissal
        resolutions[dialogID] = pending
    }

    @discardableResult
    func respond(_ response: MobileBrowserDialogRespondParameters) -> Bool {
        let wasCurrent = queue.current?.dialogID == response.dialogID
        guard response.panelID == panelID,
              let dialog = queue.pending.first(where: { $0.dialogID == response.dialogID }),
              dialog.buttons.contains(where: { $0.id == response.buttonID }),
              queue.claim(dialogID: response.dialogID) != nil,
              let pending = resolutions.removeValue(forKey: response.dialogID) else {
            return false
        }
        pending.resolve(response.buttonID, response.text)
        pending.dismiss?()
        onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: response.dialogID))
        if wasCurrent, let next = queue.current {
            onPresented?(next)
        }
        return true
    }

    @discardableResult
    func resolveFromMac(dialogID: String, action: @escaping @MainActor () -> Void) -> Bool {
        let wasCurrent = queue.current?.dialogID == dialogID
        guard queue.claim(dialogID: dialogID) != nil,
              resolutions.removeValue(forKey: dialogID) != nil else {
            return false
        }
        action()
        onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: dialogID))
        if wasCurrent, let next = queue.current {
            onPresented?(next)
        }
        return true
    }

    /// Cancels a batch atomically, preserving unrelated dialogs and FIFO completion order.
    /// - Parameter predicate: Selects dialogs to cancel; defaults to all dialogs for teardown.
    func resolveAll(where predicate: (MobileBrowserDialogEvent) -> Bool = { _ in true }) {
        let previousID = queue.current?.dialogID
        let dialogs = queue.claimAll(where: predicate)
        let next = queue.current
        let claimed = dialogs.compactMap { dialog -> (MobileBrowserDialogEvent, PendingResolution)? in
            guard let pending = resolutions.removeValue(forKey: dialog.dialogID) else { return nil }
            return (dialog, pending)
        }
        for (dialog, pending) in claimed {
            let cancelButton = dialog.buttons.first(where: { $0.role == .cancel }) ?? dialog.buttons.first
            pending.resolve(cancelButton?.id ?? "cancel", nil)
            pending.dismiss?()
            onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: dialog.dialogID))
        }
        if previousID != next?.dialogID, let next, queue.current?.dialogID == next.dialogID {
            onPresented?(next)
        }
    }
}
