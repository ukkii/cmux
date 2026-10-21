
/// What the sidebar footer's Upgrade badge does. The view calls these; tests
/// call them with a no-op opener.
@MainActor
struct ProBadgeActions {
    static let source = ProUpgradeSource.sidebarBadge

    var openPricing: @MainActor (ProUpgradeSource) -> Void = { ProUpgradePresenter.presentAppPricingWeb(source: $0) }

    /// The badge was clicked: opens pricing with its source.
    func upgrade() {
        ProUpgradePresenter.present(source: Self.source, open: openPricing)
    }
}
