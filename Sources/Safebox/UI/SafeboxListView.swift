import AppKit
import CmuxFoundation
import SwiftUI

/// The app's Safebox instances, handed to the Vault sidebar by the composition
/// root. The repository and registry are the app's single instances.
struct SafeboxUIDependencies {
    let repository: SafeboxRepository
    let approvals: SafeboxApprovalRegistry
    /// A readable name ("Workspace › Tab") for a granted session.
    let sessionLabel: @MainActor (SafeboxSessionKey) -> String?
    /// The app's hook that hides values before cmux captures its windows.
    let captureConcealment: SafeboxCaptureConcealment
}

private struct SafeboxUIDependenciesKey: EnvironmentKey {
    static let defaultValue: SafeboxUIDependencies? = nil
}

extension EnvironmentValues {
    /// Set on each main window's root view; nil hides the Safebox tab.
    var safeboxDependencies: SafeboxUIDependencies? {
        get { self[SafeboxUIDependenciesKey.self] }
        set { self[SafeboxUIDependenciesKey.self] = newValue }
    }
}

/// Content of the Vault sidebar's Safebox tab: search, add button, banners and
/// the secret list.
///
/// Revealed values are dropped when the tab goes away, when the sidebar
/// collapses (`isPresented` turns false), when the app resigns active (a
/// reveal still loading then finishes, see `appDidResignActive()`) and before
/// cmux captures one of its windows (`concealForCapture()`).
struct SafeboxListView: View {
    /// False while the sidebar that hosts the tab is collapsed but still mounted.
    let isPresented: Bool
    private let sessionLabel: @MainActor (SafeboxSessionKey) -> String?

    @State private var model: SafeboxListModel
    @State private var editorTarget: SafeboxEditorTarget?
    @State private var pendingDelete: SafeboxSecretName?
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    init(dependencies: SafeboxUIDependencies, isPresented: Bool) {
        self.isPresented = isPresented
        self.sessionLabel = dependencies.sessionLabel
        _model = State(initialValue: SafeboxListModel(
            repository: dependencies.repository,
            approvals: dependencies.approvals,
            captureConcealment: dependencies.captureConcealment
        ))
    }

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        return SidebarSearchField.visibleHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            banners
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.reload() }
        .onDisappear { model.hideAllValues() }
        .onChange(of: isPresented) { _, presented in
            if !presented { model.hideAllValues() }
        }
        // No reload on activation: a reload reads the Keychain, and after an
        // update its access prompt itself deactivates and reactivates cmux.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.appDidResignActive()
        }
        .sheet(item: $editorTarget) { target in
            SafeboxSecretEditor(
                target: target,
                onSave: { name, value, note in
                    try await model.save(editing: target.editedName, name: name, value: value, note: note)
                    editorTarget = nil
                },
                onCancel: { editorTarget = nil },
                isValueVisible: model.isEditorValueVisible,
                setValueVisible: { await model.setEditorValueVisible($0) }
            )
        }
        .alert(
            String(localized: "safebox.delete.title", defaultValue: "Delete Secret?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { name in
            Button(String(localized: "safebox.delete.confirm", defaultValue: "Delete"), role: .destructive) {
                delete(name)
            }
            Button(String(localized: "safebox.editor.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { name in
            Text(String(
                localized: "safebox.delete.message",
                defaultValue: "\(name.rawValue) and its value will be removed from Safebox. Sessions using it will no longer receive it."
            ))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            SidebarSearchFieldView(
                text: $model.searchText,
                placeholder: String(localized: "safebox.search.placeholder", defaultValue: "Search secrets…"),
                accessibilityIdentifier: "SafeboxSearchField",
                onSubmit: {},
                onCommandSubmit: {}
            )
            .frame(height: searchFieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .titlebarInteractiveControl()

            Button {
                editorTarget = .add
            } label: {
                HeaderChromeIconStyle.symbol("plus")
            }
            .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "safeboxAddIcon"))
            .frame(width: RightSidebarChromeMetrics.headerControlSize, height: RightSidebarChromeMetrics.headerControlSize)
            .disabled(!model.canModify)
            .help(String(localized: "safebox.add.tooltip", defaultValue: "Add Secret"))
            .accessibilityLabel(Text(String(localized: "safebox.add.tooltip", defaultValue: "Add Secret")))
            .accessibilityIdentifier("SafeboxAddButton")
            .titlebarInteractiveControl()
        }
        .frame(height: searchFieldHeight)
        .padding(.leading, SidebarSearchField.leadingPadding)
        .padding(.trailing, RightSidebarChromeMetrics.headerTrailingPadding)
        .padding(.top, SidebarSearchField.topPadding)
        .padding(.bottom, RightSidebarChromeMetrics.barVerticalPadding)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if model.metadataError != nil {
            banner(
                String(
                    localized: "safebox.banner.metadata",
                    defaultValue: "The Safebox metadata file could not be read. It has been left unchanged, and adding, editing and deleting secrets is disabled until it can be read."
                ),
                showsRetry: true
            )
        }
        if let keychainError = model.keychainError {
            banner(
                String(
                    localized: "safebox.banner.keychain",
                    defaultValue: "The Keychain could not be read, so values can't be shown or checked right now."
                ) + " " + (keychainError.errorDescription ?? ""),
                showsRetry: true
            )
        }
        if !model.orphanNames.isEmpty {
            let names = model.orphanNames.joined(separator: ", ")
            banner(
                String(
                    localized: "safebox.banner.orphans",
                    defaultValue: "The Keychain also holds values without a Safebox entry: \(names). They are kept unchanged."
                ),
                showsRetry: false
            )
        }
        if let actionError = model.actionError {
            banner(actionError, showsRetry: false, onDismiss: { model.actionError = nil })
        }
    }

    private func banner(_ message: String, showsRetry: Bool, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(size: 10)
                .foregroundColor(.orange)
            Text(message)
                .cmuxFont(size: 11)
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsRetry {
                Button(String(localized: "safebox.banner.retry", defaultValue: "Retry")) {
                    Task { await model.reload() }
                }
                .buttonStyle(.link)
                .cmuxFont(size: 11)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .cmuxFont(size: 9)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "safebox.banner.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(Text(String(localized: "safebox.banner.dismiss", defaultValue: "Dismiss")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isEmpty {
            emptyView
        } else {
            let rows = model.rows
            if rows.isEmpty {
                Text(String(localized: "safebox.search.noMatches", defaultValue: "No matching secrets"))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            } else {
                list(rows)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text(String(localized: "safebox.empty.title", defaultValue: "Safebox is empty"))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
            Text(String(
                localized: "safebox.empty.subtitle",
                defaultValue: "Store API tokens here once. Claude Code sessions run commands with them through cmux safebox run without ever seeing the values."
            ))
            .cmuxFont(size: 11)
            .foregroundColor(.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            Button(String(localized: "safebox.empty.add", defaultValue: "Add Secret")) {
                editorTarget = .add
            }
            .disabled(!model.canModify)
            .accessibilityIdentifier("SafeboxEmptyAddButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ rows: [SafeboxSecretRowSnapshot]) -> some View {
        let model = model
        let canModify = model.canModify
        let now = Date()
        let actions = SafeboxSecretRowActions(
            toggleReveal: { name in Task { await model.toggleReveal(name) } },
            edit: { row in
                editorTarget = .edit(name: row.name, note: row.note, isValueMissing: row.valueState == .missing)
            },
            copyValue: { name in Task { await model.copyValue(name) } },
            copyRunCommand: { name in
                // Plain text: it holds only the secret's name, never its value.
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(name.runCommandPrefix, forType: .string)
            },
            revoke: { name, session in model.revoke(name, session: session) },
            revokeAll: { name in model.revokeAllGrants(for: name) },
            requestDelete: { name in pendingDelete = name },
            sessionLabel: sessionLabel
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SafeboxSecretRow(row: row, now: now, canModify: canModify, actions: actions)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func delete(_ name: SafeboxSecretName) {
        pendingDelete = nil
        let model = model
        Task {
            do {
                try await model.delete(name)
            } catch {
                model.actionError = SafeboxListModel.message(for: error)
            }
        }
    }
}

private extension SafeboxEditorTarget {
    var editedName: SafeboxSecretName? {
        if case .edit(let name, _, _) = self { return name }
        return nil
    }
}
