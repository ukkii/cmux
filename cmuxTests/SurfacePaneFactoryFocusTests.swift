import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxPanes
import CmuxSurfaceCatalogModel
import Testing
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// ``SurfacePaneFactory`` drives the socket `surface.create` / `surface.split` handlers,
/// which honor a focus request only inside a focus-allowed socket command. An in-app
/// gesture runs with no socket command active, so without the factory setting that
/// policy itself the new tab would appear behind the current one.
@MainActor
@Suite(.serialized) struct SurfacePaneFactoryFocusTests {
    @Test func focusedTabIsSelectedOutsideASocketCommand() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)
        #expect(TerminalController.currentSocketCommandFocusAllowanceStack().isEmpty)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.workspaceID == workspace.id)
        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    /// A sidebar drop of a browser, display or port opens a pane for that link.
    /// It starts blank while it connects, but it is not a new tab to type into:
    /// focusing it must not select the address bar and open its suggestions.
    @Test(arguments: [false, true])
    func browserPaneOpenedForASidebarResourceDoesNotFocusTheAddressBar(split: Bool) throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId).id.uuidString
        let destination: SurfaceDestination = split
            ? .split(workspaceID: workspace.id, paneID: paneID, direction: .right)
            : .tab(workspaceID: workspace.id, paneID: paneID, index: nil)

        let created = try SurfacePaneFactory.makeBrowserPane(url: nil, at: destination, focus: true)
        let browser = try #require(SurfacePaneFactory.browserPanel(panelID: created.panelID, in: created.workspaceID))
        // The display caller relies on the factory itself focusing the new pane.
        #expect(workspace.focusedPanelId == created.panelID)
        #expect(browser.pendingAddressBarFocusRequestId == nil)

        // The drop handler focuses the pane again once it is created.
        SurfacePaneFactory.focus(panelID: created.panelID, in: created.workspaceID)
        #expect(workspace.focusedPanelId == created.panelID)
        #expect(browser.pendingAddressBarFocusRequestId == nil)
    }

    @Test func unfocusedTabStaysBehindTheCurrentOne() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: false
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    /// A split created through the factory must take focus when asked.
    @Test func focusedSplitFocusesTheNewPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .split(workspaceID: workspace.id, paneID: paneID.id.uuidString, direction: .right),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        #expect(workspace.paneId(forPanelId: created.panelID) != paneID)
    }

    /// A projected browser goes through the same create
    /// handler as a terminal; `focus: true` must select it too.
    @Test func focusedBrowserTabIsSelected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeBrowserPane(
            url: SurfacePaneFactory.blankURL,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    /// Inside a socket command whose policy forbids focus mutations, the factory must
    /// not re-enable them: the outer policy wins over the caller's `focus: true`.
    @Test func focusRequestCannotEscapeAFocusForbiddingSocketPolicy() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try TerminalController.withSocketCommandPolicyStack([false]) {
            try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil,
                workingDirectory: nil,
                at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
                focus: true
            )
        }

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            // createMainWindow copies the size of the current main window, and
            // earlier tests in the host leave 320-point windows behind. Split
            // admission then correctly refuses a side-by-side split, so give
            // the window and its split container a realistic size first.
            let window = try #require(appDelegate.mainWindow(for: windowId))
            window.setContentSize(Self.contentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            // Surface split behavior should not depend on AppKit having laid out
            // a hidden test window yet. Install deterministic geometry so the
            // factory can allocate the new pane immediately on a cold runner.
            workspace.bonsplitController.setContainerFrame(CGRect(origin: .zero, size: Self.contentSize))
        }

        private static let contentSize = CGSize(width: 1_000, height: 700)

        func tearDown() {
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
