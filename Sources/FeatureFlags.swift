import CMUXMobileCore
import CmuxSettings
import Foundation
import Observation
import os

/// Runtime feature flags for the macOS app. Flags resolve locally only:
/// nothing is fetched from a server.
///
/// Resolution semantics (flags must never break the app):
/// - A value from the injected `remoteFlagValueProvider` (a test seam; the app
///   provides none) is authoritative when present.
/// - Otherwise a permitted local override applies, then the explicit per-flag
///   default.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags(publishesOffMainSnapshot: true)

    private static let agentChatUIDefault = false
    private static let sidebarWorkspaceAgentSpinnerDefault = false
    private static let computerUseUXDefault = true
    private nonisolated static let simulatorDefault = true
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = true
    private static let agentInboxQuickViewDefault = false
    private nonisolated static let conversationSidebarDefault = false

    private static let overrideKeyPrefix = "cmux.flags.override."
    /// Keys written by the removed remote flag fetch; cleared at launch so
    /// stale cached rollout values no longer apply.
    private static let legacyRemoteCacheKeyPrefix = "cmux.flags.remote."
    private static let legacyReleaseControlDistinctIDKey = "cmux.flags.releaseControlDistinctID"

    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default after the remote rollout reached 100%.
    static let appKitSidebarListFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-appkit-list-experiment",
        title: String(
            localized: "featureFlags.appKitSidebarList.title",
            defaultValue: "Lawrence Sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.appKitSidebarList.description",
            defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.appKitSidebarListDefault
    )

    // FLAG(key: simulator-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-16, defaultWhenUnavailable: true)
    // Controls every Simulator entrypoint and active pane. The enabled
    // fallback preserves access. Declared nonisolated so off-main readers
    // can gate on the same flag as RPC dispatch.
    nonisolated static let simulatorFlag = CmuxFeatureFlagDefinition(
        key: "simulator-enabled-release",
        title: String(
            localized: "featureFlags.simulator.title",
            defaultValue: "Simulator"
        ),
        flagDescription: String(
            localized: "featureFlags.simulator.description",
            defaultValue: "Enables iPhone and iPad Simulator panes, commands, and automation."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.simulatorDefault
    )

    // FLAG(key: agent-inbox-quick-view-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Keeps the agent inbox quick view behind an explicit rollout while the
    // placement and cross-agent attention model are evaluated.
    static let agentInboxQuickViewFlag = CmuxFeatureFlagDefinition(
        key: "agent-inbox-quick-view-enabled-release",
        title: String(localized: "featureFlags.agentInbox.title", defaultValue: "Agent Inbox quick view"),
        flagDescription: String(localized: "featureFlags.agentInbox.description", defaultValue: "Shows a keyboard-summoned inbox for agent messages, pending Feed decisions, and finished turns."),
        defaultWhenUnavailable: CmuxFeatureFlags.agentInboxQuickViewDefault
    )

    // FLAG(key: conversation-sidebar-release, owner: teamleaderleo,
    //      reviewBy: 2026-12-01, defaultWhenUnavailable: false)
    // Controls availability of the opt-in multi-provider conversation sidebar.
    // The user-facing beta setting is evaluated separately by the sidebar
    // integration; this flag is the remote rollout gate and emergency kill
    // switch for the feature.
    nonisolated static let conversationSidebarFlag = CmuxFeatureFlagDefinition(
        key: "conversation-sidebar-release",
        title: String(
            localized: "featureFlags.conversationSidebar.title",
            defaultValue: "Multi-provider conversation sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.conversationSidebar.description",
            defaultValue: "Enables the opt-in sidebar for conversations from multiple coding-agent providers."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.conversationSidebarDefault
    )

    // FLAG(key: window-hints-release, owner: teamleaderleo,
    //      reviewBy: 2027-01-31, defaultWhenUnavailable: false)
    // Hint mode (Show Hints, Cmd-J): labels every clickable control in the
    // window so typing a label clicks it. Off until the labels are styled;
    // a local debug override turns it on for testing.
    nonisolated static let windowHintsFlag = CmuxFeatureFlagDefinition(
        key: "window-hints-release",
        title: String(localized: "featureFlags.windowHints.title", defaultValue: "Click by Hint"),
        flagDescription: String(
            localized: "featureFlags.windowHints.description",
            defaultValue: "Labels every clickable control in the window so typing a label clicks it."
        ),
        defaultWhenUnavailable: false
    )

    // FLAG(key: agent-chat-ui-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Shows the Agent Chat entrypoints: the new-workspace dropdown item,
    // command-palette command, surface-tab-bar button, and shared action
    // executor. Hidden by default until the sidecar UX is ready to ship.
    static let agentChatUIFlag = CmuxFeatureFlagDefinition(
        key: "agent-chat-ui-enabled-release",
        title: String(localized: "featureFlags.agentChat.title", defaultValue: "Agent Chat UI"),
        flagDescription: String(
            localized: "featureFlags.agentChat.description",
            defaultValue: "Shows Agent Chat entrypoints in the new-workspace dropdown, command palette, and surface tab bar."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.agentChatUIDefault
    )

    // FLAG(key: sidebar-workspace-agent-spinner-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Shows the coding-agent activity spinner in workspace rows. Hidden
    // by default while multi-agent lifecycle edge cases are investigated.
    static let sidebarWorkspaceAgentSpinnerFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-workspace-agent-spinner-experiment",
        title: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.title",
            defaultValue: "Workspace agent spinner"
        ),
        flagDescription: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.description",
            defaultValue: "Shows a spinner in workspace rows while coding agents are running."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerDefault
    )

    // FLAG(key: computer-use-ux-enabled-release, owner: austinwang,
    //      reviewBy: 2027-01-19, defaultWhenUnavailable: true)
    // Shows the computer-use status item and allows automatic onboarding.
    // The settings and terminal kill switch remain available if this UI
    // flag is remotely disabled.
    static let computerUseUXFlag = CmuxFeatureFlagDefinition(
        key: "computer-use-ux-enabled-release",
        title: String(localized: "featureFlags.computerUseUX.title", defaultValue: "cmux Computer Use UX"),
        flagDescription: String(
            localized: "featureFlags.computerUseUX.description",
            defaultValue: "Shows the Computer Use menu-bar item and automatic onboarding."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.computerUseUXDefault
    )

    // FLAG(key: workspace-todo-controls-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-16, defaultWhenUnavailable: false)
    // Shows user-facing workspace todo controls that create checklist
    // items or set completion/status lanes. Hidden until the local
    // beta setting opts in or a local override enables it.
    static let workspaceTodoControlsFlag = CmuxFeatureFlagDefinition(
        key: "workspace-todo-controls-enabled-release",
        title: String(
            localized: "featureFlags.workspaceTodoControls.title",
            defaultValue: "Workspace todo controls"
        ),
        flagDescription: String(
            localized: "featureFlags.workspaceTodoControls.description",
            defaultValue: "Shows Add Checklist Item and workspace completion status controls."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.workspaceTodoControlsDefault
    )

    // Registry order is used only for remote loading; accessors bind to named definitions.
    static let allFlags: [CmuxFeatureFlagDefinition] = {
        [
            CmuxFeatureFlags.agentChatUIFlag,
            CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerFlag,
            CmuxFeatureFlags.computerUseUXFlag,
            CmuxFeatureFlags.simulatorFlag,
            CmuxFeatureFlags.workspaceTodoControlsFlag,
            CmuxFeatureFlags.appKitSidebarListFlag,
            CmuxFeatureFlags.agentInboxQuickViewFlag,
            CmuxFeatureFlags.conversationSidebarFlag,
            CmuxFeatureFlags.windowHintsFlag
        ]
    }()

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.agentChatUIFlag)
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.sidebarWorkspaceAgentSpinnerFlag)
    }

    var isComputerUseUXEnabled: Bool {
        effectiveValue(for: Self.computerUseUXFlag)
    }
    var isSimulatorEnabled: Bool {
        effectiveValue(for: Self.simulatorFlag)
    }
    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.workspaceTodoControlsFlag)
    }
    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.appKitSidebarListFlag)
    }

    var isAgentInboxQuickViewEnabled: Bool {
        effectiveValue(for: Self.agentInboxQuickViewFlag)
    }

    var isWindowHintsEnabled: Bool {
        effectiveValue(for: Self.windowHintsFlag) || ClickByHintPreview.isOptedIn()
    }

    var isConversationSidebarAvailable: Bool {
        effectiveValue(for: Self.conversationSidebarFlag)
    }

    /// Effective values mirrored for nonisolated readers that run off the
    /// main actor. Written only by the shared instance so test instances cannot
    /// stomp process-wide state. Before the shared instance exists, readers
    /// get the per-flag compile-time default (fail-closed for release flags).
    private nonisolated static let offMainEffectiveValues = OSAllocatedUnfairLock(
        initialState: [String: Bool]()
    )

    nonisolated static func offMainEffectiveValue(
        for definition: CmuxFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
    @ObservationIgnored
    private let overrideCapability: CmuxFeatureFlagOverrideCapability
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?

    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    /// A remote value outranks a local override, so a UI-test launch pins flags
    /// to their local values: otherwise a cached or freshly fetched rollout value
    /// swaps the surface under a test that deliberately selected the other one.
    private let pinsFlagsToLocalValues: Bool

    nonisolated static var pinsFlagsToLocalValuesForCurrentLaunch: Bool {
        ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1"
    }
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        overrideCapability: CmuxFeatureFlagOverrideCapability = .init(),
        remoteFlagValueProvider: @escaping (String) -> Any? = { _ in nil },
        publishesOffMainSnapshot: Bool = false,
        pinsFlagsToLocalValues: Bool = CmuxFeatureFlags.pinsFlagsToLocalValuesForCurrentLaunch
    ) {
        self.defaults = defaults
        self.overrideCapability = overrideCapability
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        self.pinsFlagsToLocalValues = pinsFlagsToLocalValues
        self.remoteFlagValueProvider = remoteFlagValueProvider
        Self.removeLegacyRemoteState(defaults: defaults)
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    private static func removeLegacyRemoteState(defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyReleaseControlDistinctIDKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyRemoteCacheKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? CmuxFeatureFlagResolution(
            remoteValue: remoteValuesByKey[definition.key],
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable,
            overridePolicy: overrideCapability.policy(for: definition)
        )
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func remoteValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        remoteValuesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        guard value == nil || resolution(for: definition).allowsLocalOverride else { return }

        let previousResolutions = resolutionsByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func clearAllOverrides() {
        let previousResolutions = resolutionsByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func applyLoadedFlags() {
        let previousResolutions = resolutionsByKey
        for definition in Self.allFlags {
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                remoteValuesByKey[definition.key] = value
            } else if remoteValuesByKey[definition.key] == true {
                remoteValuesByKey.removeValue(forKey: definition.key)
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    private func recomputeEffectiveValues() {
        resolutionsByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = CmuxFeatureFlagResolution(
                remoteValue: remoteValuesByKey[definition.key],
                overrideValue: localOverridesByKey[definition.key],
                defaultValue: definition.defaultWhenUnavailable,
                overridePolicy: overrideCapability.policy(for: definition)
            )
        }
        if publishesOffMainSnapshot {
            let effectiveValues = resolutionsByKey.mapValues(\.effectiveValue)
            Self.offMainEffectiveValues.withLock { $0 = effectiveValues }
        }
    }

    private func postChangeIfNeeded(previousResolutions: [String: CmuxFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        storedBoolValue(forKey: overrideDefaultsKey(for: key), defaults: defaults)
    }

    private static func storedBoolValue(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?, default fallback: Bool) -> Bool {
        coerceBoolFlagValue(value) ?? fallback
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
