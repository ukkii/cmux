import Foundation
import CmuxBrowser
import WebKit

/// Web view adoption support for ``BrowserPanel``: shared profile resolution
/// and the popup web view a new panel adopts instead of making its own.
extension BrowserPanel {
    /// The profile a panel would use for the given requested ID. Shared with
    /// other callers so they resolve the same profile and website data store.
    static func resolvedProfileID(requested: UUID?) -> UUID {
        let requestedProfileID = requested ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
    }

    /// A web view WebKit asked for (`createWebViewWith`), created from its
    /// configuration so the page keeps its opener, that the next panel created
    /// for `url` adopts instead of making its own. Set and consumed within one
    /// main-actor turn by ``BrowserReplTabAttachment/adoptPopup``.
    @MainActor static var pendingPopupWebView: (url: URL, webView: CmuxWebView)?

    @MainActor static func takePendingPopupWebView(for url: URL?) -> CmuxWebView? {
        guard let pending = pendingPopupWebView, let url, pending.url == url else { return nil }
        pendingPopupWebView = nil
        return pending.webView
    }
}
