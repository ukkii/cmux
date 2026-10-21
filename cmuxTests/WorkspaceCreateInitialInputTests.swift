import CmuxSurfaceCatalogModel
import Foundation
import struct CmuxSettings.AccountCatalogSection
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension WorkspaceCreateWorkingDirectoryTests {
    @Test func initialInputRunsInsideInteractiveShellWithoutWaitAfterCommand() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let initialInput = " printf '  preserved  '\t\r"

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_input": initialInput,
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.debugInitialInputForTesting() == initialInput)
        #expect(panel.surface.debugInitialCommand() == nil)
        #expect(panel.surface.debugWaitAfterCommand() == false)
    }

    @Test func focusedInitialInputDoesNotScheduleAutomaticWelcomeCommand() async throws {
        _ = try #require(AppDelegate.shared)
        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        let defaults = UserDefaults.standard
        let welcomeShownKey = AccountCatalogSection().welcomeShown.userDefaultsKey
        let previousWelcomeShown = defaults.object(forKey: welcomeShownKey)
        defer {
            controller.setActiveTabManager(previousManager)
            if let previousWelcomeShown {
                defaults.set(previousWelcomeShown, forKey: welcomeShownKey)
            } else {
                defaults.removeObject(forKey: welcomeShownKey)
            }
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let initialInput = "printf 'requested command only\\n'\r"
        let readyNotifications = NotificationCenter.default.notifications(
            named: .terminalSurfaceDidBecomeReady
        )
        controller.setActiveTabManager(manager)
        defaults.removeObject(forKey: welcomeShownKey)

        let response = try Self.v2SocketResponse(method: "workspace.create", params: [
            "initial_input": initialInput,
            "focus": true,
        ])

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        let createdID = try #require(
            (result["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let created = try #require(manager.tabs.first { $0.id == createdID })
        #expect(!initialWorkspaceIDs.contains(created.id))
        #expect(manager.selectedWorkspace?.id == created.id)
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        let didBecomeReady = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await notification in readyNotifications {
                    guard notification.userInfo?["workspaceId"] as? UUID == createdID else {
                        continue
                    }
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(
            didBecomeReady,
            "Timed out waiting for terminal readiness for workspace \(created.id)"
        )

        #expect(panel.surface.debugInitialInputForTesting() == initialInput)
        #expect(defaults.object(forKey: welcomeShownKey) == nil)
    }

    @Test func welcomeBannerUsesShellStartupOnlyWhenCmuxIntegrationLoads() {
        for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/opt/homebrew/bin/nu"] {
            #expect(
                WelcomeBannerDelivery.resolve(
                    shellIntegrationEnabled: true,
                    resolvedShell: shell,
                    hasUserGhosttyCommand: false
                ) == .shellStartup
            )
        }
        #expect(
            WelcomeBannerDelivery.resolve(
                shellIntegrationEnabled: true,
                resolvedShell: "/usr/local/bin/xonsh",
                hasUserGhosttyCommand: false
            ) == .typedCommand
        )
        #expect(
            WelcomeBannerDelivery.resolve(
                shellIntegrationEnabled: false,
                resolvedShell: "/bin/zsh",
                hasUserGhosttyCommand: false
            ) == .typedCommand
        )
        #expect(
            WelcomeBannerDelivery.resolve(
                shellIntegrationEnabled: true,
                resolvedShell: "/bin/zsh",
                hasUserGhosttyCommand: true
            ) == .typedCommand
        )
        #expect(
            WelcomeBannerDelivery.resolve(
                shellIntegrationEnabled: true,
                resolvedShell: nil,
                hasUserGhosttyCommand: false
            ) == .typedCommand
        )
        #expect(WelcomeBannerDelivery.typedCommandText.hasPrefix(" "))
    }

    @Test func automaticWelcomeRidesShellStartupEnvironmentInsteadOfTypedInput() throws {
        let defaults = UserDefaults.standard
        let welcomeShownKey = AccountCatalogSection().welcomeShown.userDefaultsKey
        let previousWelcomeShown = defaults.object(forKey: welcomeShownKey)
        defer {
            if let previousWelcomeShown {
                defaults.set(previousWelcomeShown, forKey: welcomeShownKey)
            } else {
                defaults.removeObject(forKey: welcomeShownKey)
            }
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.welcomeBannerDeliveryResolver = { .shellStartup }
        var typedWelcomeWorkspaces: [UUID] = []
        manager.typedWelcomeSender = { typedWelcomeWorkspaces.append($0.id) }
        defaults.removeObject(forKey: welcomeShownKey)
        let created = try #require(manager.addWorkspaceIfActive(select: true))
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)

        let tokenPath = try #require(
            panel.surface.respawnInitialEnvironmentOverrides[WelcomeBannerDelivery.environmentKey]
        )
        defer { try? FileManager.default.removeItem(atPath: tokenPath) }
        #expect(FileManager.default.fileExists(atPath: tokenPath))
        #expect(panel.surface.debugInitialInputForTesting() == nil)
        #expect(typedWelcomeWorkspaces.isEmpty)
        #expect(defaults.bool(forKey: welcomeShownKey))

        let second = try #require(manager.addWorkspaceIfActive(select: true))
        let secondPanel = try #require(second.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(secondPanel.surface.respawnInitialEnvironmentOverrides[WelcomeBannerDelivery.environmentKey] == nil)
        #expect(typedWelcomeWorkspaces.isEmpty)
    }

    @Test func automaticWelcomeTypesFallbackWhenShellIntegrationIsUnavailable() throws {
        let defaults = UserDefaults.standard
        let welcomeShownKey = AccountCatalogSection().welcomeShown.userDefaultsKey
        let previousWelcomeShown = defaults.object(forKey: welcomeShownKey)
        defer {
            if let previousWelcomeShown {
                defaults.set(previousWelcomeShown, forKey: welcomeShownKey)
            } else {
                defaults.removeObject(forKey: welcomeShownKey)
            }
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.welcomeBannerDeliveryResolver = { .typedCommand }
        var typedWelcomeWorkspaces: [UUID] = []
        manager.typedWelcomeSender = { typedWelcomeWorkspaces.append($0.id) }
        defaults.removeObject(forKey: welcomeShownKey)
        let created = try #require(manager.addWorkspaceIfActive(select: true))
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)

        #expect(typedWelcomeWorkspaces == [created.id])
        #expect(panel.surface.respawnInitialEnvironmentOverrides[WelcomeBannerDelivery.environmentKey] == nil)
        // The typed fallback marks the banner shown only once it is sent.
        #expect(defaults.object(forKey: welcomeShownKey) == nil)

        _ = try #require(manager.addWorkspaceIfActive(select: false))
        #expect(typedWelcomeWorkspaces == [created.id])
    }

    @Test func welcomeShellStartupFallsBackToTypedWhenTokenCannotBeWritten() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-welcome-token-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let blocked = WelcomeBannerDelivery.prepareLaunch(.shellStartup, tempDirectory: blocker)
        #expect(blocked.delivery == .typedCommand)
        #expect(blocked.environment.isEmpty)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-welcome-token-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WelcomeBannerDelivery.prepareLaunch(.shellStartup, tempDirectory: directory)
        let second = WelcomeBannerDelivery.prepareLaunch(.shellStartup, tempDirectory: directory)
        let firstPath = try #require(first.environment[WelcomeBannerDelivery.environmentKey])
        let secondPath = try #require(second.environment[WelcomeBannerDelivery.environmentKey])
        #expect(first.delivery == .shellStartup)
        #expect(firstPath != secondPath)
        #expect(FileManager.default.fileExists(atPath: firstPath))
    }

    @Test(
        "terminal creation RPCs inject input into an interactive shell",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationRPCInjectsInitialInput(method: String) throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let initialInput = " printf '  preserved  '\t\r"
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        var params: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "initial_input": initialInput,
            "focus": false,
        ]
        switch method {
        case "surface.split", "pane.create":
            params["direction"] = "right"
            params["surface_id"] = sourcePanelID.uuidString
        case "surface.create":
            params["pane_id"] = paneID.id.uuidString
        default:
            Issue.record("unexpected creation method \(method)")
            return
        }

        let response = try Self.v2SocketResponse(method: method, params: params)
        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        let createdSurfaceID = try #require(
            (result["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let panel = try #require(workspace.terminalPanel(for: createdSurfaceID))
        #expect(panel.surface.debugInitialInputForTesting() == initialInput)
        #expect(panel.surface.debugInitialCommand() == nil)
        #expect(panel.surface.debugWaitAfterCommand() == false)
    }

    private static func v2SocketResponse(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try #require(String(data: data, encoding: .utf8))
        let responseText = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(responseText.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }
}
