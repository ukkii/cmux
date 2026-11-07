import CmuxFoundation
import SwiftUI

/// Actions a Safebox row can trigger. Rows get closures, never the model.
struct SafeboxSecretRowActions {
    let toggleReveal: (SafeboxSecretName) -> Void
    let edit: (SafeboxSecretRowSnapshot) -> Void
    let copyValue: (SafeboxSecretName) -> Void
    let revoke: (SafeboxSecretName, SafeboxSessionKey) -> Void
    let revokeAll: (SafeboxSecretName) -> Void
    let requestDelete: (SafeboxSecretName) -> Void
    /// A readable name for a granted session, or nil when it cannot be found.
    let sessionLabel: @MainActor (SafeboxSessionKey) -> String?
}

/// One secret in the Safebox list: name, masked or revealed value, eye
/// toggle, dates and grants.
struct SafeboxSecretRow: View {
    let row: SafeboxSecretRowSnapshot
    let now: Date
    let canModify: Bool
    let actions: SafeboxSecretRowActions

    private static let mask = String(repeating: "\u{2022}", count: 16)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name.rawValue)
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                valueLine
                Text(caption)
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !row.grants.isEmpty {
                    Text(grantsText)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            eyeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if canModify { actions.edit(row) }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SafeboxSecretRow.\(row.name.rawValue)")
    }

    @ViewBuilder
    private var valueLine: some View {
        switch row.valueState {
        case .missing:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .cmuxFont(size: 10)
                    .foregroundColor(.orange)
                Text(String(
                    localized: "safebox.row.valueMissing",
                    defaultValue: "Value missing. Edit the secret to set it."
                ))
                .cmuxFont(size: 11)
                .foregroundColor(.orange)
            }
        case .unknown:
            Text(String(localized: "safebox.row.valueUnavailable", defaultValue: "Value unavailable"))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
        case .present:
            if let revealed = row.revealedValue {
                Text(verbatim: revealed)
                    .cmuxFont(size: 11, design: .monospaced)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: Self.mask)
                    .cmuxFont(size: 11, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text(String(localized: "safebox.row.hiddenValue", defaultValue: "Hidden value")))
            }
        }
    }

    private var eyeButton: some View {
        let isRevealed = row.revealedValue != nil
        let label = isRevealed
            ? String(localized: "safebox.row.hideValue", defaultValue: "Hide Value")
            : String(localized: "safebox.row.showValue", defaultValue: "Show Value")
        return Button {
            actions.toggleReveal(row.name)
        } label: {
            HeaderChromeIconStyle.symbol(isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "safeboxRowEye"))
        .frame(width: RightSidebarChromeMetrics.headerControlSize, height: RightSidebarChromeMetrics.headerControlSize)
        .disabled(row.valueState != .present)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("SafeboxRevealButton.\(row.name.rawValue)")
    }

    @ViewBuilder
    private var menu: some View {
        Button(String(localized: "safebox.menu.edit", defaultValue: "Edit…")) {
            actions.edit(row)
        }
        .disabled(!canModify)
        Button(String(localized: "safebox.menu.copyValue", defaultValue: "Copy Value")) {
            actions.copyValue(row.name)
        }
        .disabled(row.valueState != .present)
        if row.grants.count == 1, let session = row.grants.first {
            Button(String(localized: "safebox.menu.revokeAccess", defaultValue: "Revoke Access")) {
                actions.revoke(row.name, session)
            }
        } else if row.grants.count > 1 {
            Menu(String(localized: "safebox.menu.revokeAccess", defaultValue: "Revoke Access")) {
                Button(String(localized: "safebox.menu.revokeAll", defaultValue: "All Sessions")) {
                    actions.revokeAll(row.name)
                }
                Divider()
                ForEach(row.grants, id: \.self) { session in
                    Button(sessionTitle(session)) {
                        actions.revoke(row.name, session)
                    }
                }
            }
        }
        Divider()
        Button(String(localized: "safebox.menu.delete", defaultValue: "Delete…"), role: .destructive) {
            actions.requestDelete(row.name)
        }
        .disabled(!canModify)
    }

    private func sessionTitle(_ session: SafeboxSessionKey) -> String {
        actions.sessionLabel(session)
            ?? String(localized: "safebox.menu.unknownSession", defaultValue: "Terminal Session")
    }

    private var caption: String {
        let updated = Self.dateFormatter.string(from: row.updatedAt)
        guard let lastUsed = row.lastUsedAt else {
            return String(
                localized: "safebox.row.captionNeverUsed",
                defaultValue: "Updated \(updated) · Never used"
            )
        }
        let used = SessionIndexView.relativeFormatter.localizedString(for: lastUsed, relativeTo: now)
        return String(
            localized: "safebox.row.captionUsed",
            defaultValue: "Updated \(updated) · Used \(used)"
        )
    }

    private var grantsText: String {
        if row.grants.count == 1 {
            return String(localized: "safebox.row.allowedForOne", defaultValue: "Allowed for 1 session")
        }
        let count = row.grants.count
        return String(localized: "safebox.row.allowedForMany", defaultValue: "Allowed for \(count) sessions")
    }
}
