import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import cmux_DEV

/// Counts the async notifications that land inside a measured window, so a
/// failure can name the input that drove an extra sidebar body pass.
@MainActor
private final class RevealSignalLog {
    private var countsByName: [String: Int] = [:]

    func record(_ name: Notification.Name) {
        countsByName[name.rawValue, default: 0] += 1
    }

    var summary: String {
        countsByName
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct SidebarHiddenPresentationTests {
    @Test
    func focusBoundaryUsesScrollableRespondersVisibleRect() throws {
        let boundary = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let scrollView = NSScrollView(frame: boundary.bounds)
        let responder = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 240, height: 1_200))
        scrollView.documentView = responder
        boundary.addSubview(scrollView)

        let window = NSWindow(
            contentRect: boundary.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = boundary
        defer { window.close() }
        boundary.layoutSubtreeIfNeeded()

        let reference = SidebarFocusBoundaryReference()
        reference.attach(boundary)
        #expect(window.makeFirstResponder(responder))
        let firstResponder = try #require(window.firstResponder)
        #expect(
            reference.contains(firstResponder, in: window),
            "A clipped document view belongs to the sidebar when its visible portion is inside it."
        )
    }

    @Test
    func staleFocusHostTeardownDoesNotReplaceCurrentBoundary() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let firstHost = FocusProbeView(frame: root.bounds)
        root.addSubview(firstHost)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        defer { window.close() }

        let reference = SidebarFocusBoundaryReference()
        reference.attach(firstHost)
        let replacementHost = FocusProbeView(frame: root.bounds)
        root.addSubview(replacementHost)
        reference.attach(replacementHost)
        reference.detach(firstHost)
        firstHost.removeFromSuperview()

        #expect(window.makeFirstResponder(replacementHost))
        let firstResponder = try #require(window.firstResponder)
        #expect(
            reference.contains(firstResponder, in: window),
            "Teardown from an older host must not overwrite its mounted replacement."
        )
    }

    @Test
    func controllerHideReleasesLiveRowPayloadWithoutDiscardingRowIdentity() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceId = UUID()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: workspaceId,
            payload: payload!
        )

        controller.apply(
            rows: [row!],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        payload = nil
        row = nil
        #expect(retainedPayload != nil)

        controller.setPresentationActive(false, workspaceIds: [workspaceId])

        #expect(retainedPayload == nil)
        #expect(container.tableView.numberOfRows == 1)
    }

    @Test
    func controllerHideSuspendsCreatedCellOutsideTableRowLookup() async throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let model = SidebarWorkspaceRowSuspensionTests.makeModel()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: model,
                onCommitRename: { [capturedPayload = payload!] _ in _ = capturedPayload }
            ),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
        controller.apply(
            rows: [row!], actions: makeTableActions(), workspaceIds: [model.workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        let cell = try #require(
            controller.tableView(
                container.tableView,
                viewFor: container.tableView.tableColumns.first,
                row: 0
            ) as? SidebarWorkspaceRowTableCellView
        )
        payload = nil
        row = nil
        #expect(retainedPayload != nil)

        controller.setPresentationActive(false, workspaceIds: [model.workspaceId])

        withExtendedLifetime(cell) {
            #expect(retainedPayload == nil, "Hiding must suspend cells parked outside row lookup.")
        }
    }

    @Test
    func hostedCellClearReleasesItsLiveRowPayload() {
        let cell = SidebarWorkspaceTableCellView()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: UUID(),
            payload: payload!
        )
        cell.configure(
            row: row!,
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        payload = nil
        row = nil
        #expect(retainedPayload != nil)
        cell.clearRetainedPayload()
        #expect(retainedPayload == nil)
    }

    @Test
    func inactivePresentationRemovesAnInstalledSpinnerAnimation() {
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.contentLayer.add(
            CABasicAnimation(keyPath: "transform.rotation.z"),
            forKey: GPUSpinnerNSView.animationKey
        )
        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) != nil)

        spinner.isPresentationActive = false

        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) == nil)
    }

    @Test
    func hiddenSpinnerRemovesItsInstalledAnimation() {
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.contentLayer.add(
            CABasicAnimation(keyPath: "transform.rotation.z"),
            forKey: GPUSpinnerNSView.animationKey
        )
        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) != nil)

        spinner.isHidden = true

        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) == nil)
    }

    @Test
    func spinnerAnimationsRequestTheirStepRateFromTheCompositor() {
        let spokes = GPUSpinnerNSView.makeRotationAnimation(style: .macOSSpokes, beginTime: 0)
        #expect(spokes.preferredFrameRateRange.maximum <= 20)
        #expect(spokes.preferredFrameRateRange.minimum >= 10)

        let arc = GPUSpinnerNSView.makeRotationAnimation(style: .arc, beginTime: 0)
        #expect(arc.preferredFrameRateRange.maximum <= 60)
    }

    @Test
    func persistenceIsScopedToDefaultProvider() throws {
        #expect(
            ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.hostedExtensionsProviderId
            )
        )
        let bundledProviderId = try #require(CmuxExtensionSidebarSelection.providers.first?.descriptor.id)
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: bundledProviderId
            )
        )

        let customSidebarsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: customSidebarsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customSidebarsDirectory) }
        let customProviderId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + "lifecycle-test"
        try Data().write(to: customSidebarsDirectory.appendingPathComponent("lifecycle-test.swift"))
        CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(customSidebarsDirectory) {
            #expect(
                !ContentView.retainsDefaultAppKitSidebar(
                    appKitListEnabled: true,
                    effectiveProviderId: customProviderId
                )
            )
        }
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: false,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var matches: [View] = []
        if let match = root as? View {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }

    private func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private func makeRetainingRow(
        workspaceId: UUID,
        payload: NSObject
    ) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent()
        ) { [payload] _, _ in
            AnyView(TestRowContent().onAppear { _ = payload })
        }
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private struct TestRowContent: View, Equatable {
        var body: some View { EmptyView() }
    }

    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
