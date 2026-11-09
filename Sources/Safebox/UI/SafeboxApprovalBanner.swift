import AppKit
import Foundation
import SwiftUI

/// What the approval banner of one surface shows: every pending request of
/// that surface, grouped by command. Contains names and the command only,
/// never a secret value.
struct SafeboxApprovalBannerPresentation: Equatable {
    struct Line: Equatable, Identifiable {
        /// "<command> wants <NAME[, NAME…]> from Safebox".
        let text: String
        var id: String { text }
    }

    /// The requests Allow and Deny answer: exactly the ones on screen.
    let requestIDs: [UUID]
    let lines: [Line]
    /// When the oldest shown request times out and is denied.
    let deadline: Date
    /// Allow and Deny are ignored before this moment: one
    /// ``SafeboxApprovalBannerModel/decisionDelay`` after the newest shown
    /// request appeared, so a click aimed at the banner as it was cannot
    /// answer a request that showed up just before it.
    let acceptsDecisionsAt: Date
}

/// The Allow/Deny state of one terminal surface, read from the app's
/// `SafeboxApprovalRegistry`. Reading `presentation` from a view body tracks
/// only the registry's pending requests.
@MainActor
struct SafeboxApprovalBannerModel {
    /// How long Allow and Deny ignore clicks after the shown requests change.
    static let decisionDelay: TimeInterval = 1

    let approvals: SafeboxApprovalRegistry
    let surfaceID: UUID
    /// The time a click happens; injected by tests.
    var now: @MainActor () -> Date = { Date() }

    var presentation: SafeboxApprovalBannerPresentation? {
        let requests = approvals.pendingRequests.filter { $0.session.surfaceID == surfaceID }
        guard let oldest = requests.map(\.createdAt).min(),
              let newest = requests.map(\.createdAt).max() else { return nil }

        // One line per distinct command, in request order, each listing its
        // names once.
        var commands: [String] = []
        var namesByCommand: [String: [String]] = [:]
        for request in requests {
            let command = Self.displayCommand(request.command)
            if namesByCommand[command] == nil { commands.append(command) }
            var names = namesByCommand[command, default: []]
            for name in request.names.map(\.rawValue) where !names.contains(name) {
                names.append(name)
            }
            namesByCommand[command] = names
        }
        let lines = commands.map { command in
            SafeboxApprovalBannerPresentation.Line(
                text: Self.message(command: command, names: namesByCommand[command] ?? [])
            )
        }
        return SafeboxApprovalBannerPresentation(
            requestIDs: requests.map(\.id),
            lines: lines,
            deadline: oldest.addingTimeInterval(Self.seconds(approvals.timeout)),
            acceptsDecisionsAt: newest.addingTimeInterval(Self.decisionDelay)
        )
    }

    /// Allows every request in `presentation`, unless it changed too recently
    /// for the user to have read it.
    func allow(_ presentation: SafeboxApprovalBannerPresentation) {
        guard acceptsDecisions(for: presentation) else { return }
        for id in presentation.requestIDs {
            approvals.decide(requestID: id, allow: true)
        }
    }

    /// Denies every request in `presentation`, unless it changed too recently
    /// for the user to have read it.
    func deny(_ presentation: SafeboxApprovalBannerPresentation) {
        guard acceptsDecisions(for: presentation) else { return }
        for id in presentation.requestIDs {
            approvals.decide(requestID: id, allow: false)
        }
    }

    func acceptsDecisions(for presentation: SafeboxApprovalBannerPresentation) -> Bool {
        now() >= presentation.acceptsDecisionsAt
    }

    /// The command as one line of plain text: control characters (newlines,
    /// tabs, escapes) become spaces, length is capped like the registry caps it.
    static func displayCommand(_ command: String) -> String {
        let scalars = command.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            return String(localized: "safebox.banner.unknownCommand", defaultValue: "A command")
        }
        return String(line.prefix(SafeboxApprovalRegistry.maxCommandLength))
    }

    static func message(command: String, names: [String]) -> String {
        String(
            format: String(
                localized: "safebox.banner.message",
                defaultValue: "%1$@ wants %2$@ from Safebox"
            ),
            command,
            names.joined(separator: ", ")
        )
    }

    /// Whole seconds left until `deadline`, rounded up, never negative.
    static func remainingSeconds(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Mounts the approval banner of one terminal surface. It is the only view
/// that reads the registry, so a pending-request change re-renders this view
/// and not the terminal panel around it.
///
/// The registry comes from the environment. A hosting view the window's
/// environment does not reach (a canvas pane, a separately hosted pane) falls
/// back to the app's single registry; no other registry is ever created.
struct SafeboxApprovalBannerHost: View {
    let surfaceID: UUID
    @Environment(\.safeboxDependencies) private var dependencies

    private var approvals: SafeboxApprovalRegistry? {
        dependencies?.approvals ?? AppDelegate.shared?.safeboxApprovals
    }

    var body: some View {
        if let approvals {
            let model = SafeboxApprovalBannerModel(approvals: approvals, surfaceID: surfaceID)
            if let presentation = model.presentation {
                SafeboxApprovalBanner(
                    presentation: presentation,
                    onAllow: { model.allow(presentation) },
                    onDeny: { model.deny(presentation) }
                )
            }
        }
    }
}

/// Shown above a terminal while a `cmux safebox run` in it waits for the
/// user's Allow or Deny.
///
/// It never activates the app or moves focus: its buttons are not focusable
/// and neither is the default button, so Return typed into the terminal can
/// never approve.
struct SafeboxApprovalBanner: View {
    let presentation: SafeboxApprovalBannerPresentation
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(presentation.lines) { line in
                    // Verbatim: the command is never read as markdown or links.
                    Text(verbatim: line.text)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("safebox-approval-message")
                }
                // Only this text re-renders every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: countdownText(now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("safebox-approval-countdown")
                }
            }
            Spacer(minLength: 0)
            Button(denyTitle, action: onDeny)
                .controlSize(.small)
                .focusable(false)
                .accessibilityLabel(denyAccessibilityLabel)
                .accessibilityIdentifier("safebox-approval-deny")
            Button(allowTitle, action: onAllow)
                .controlSize(.small)
                .focusable(false)
                .accessibilityLabel(allowAccessibilityLabel)
                .accessibilityIdentifier("safebox-approval-allow")
        }
        .padding(10)
        // Opaque, because in a canvas pane it overlays the terminal's top rows.
        // Tinted so a pending request stands out from the terminal chrome.
        .background(Color(nsColor: Self.backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safebox-approval-banner")
    }

    /// Pale mint in light appearance; a dark green in dark appearance so the
    /// primary (light) text keeps its contrast.
    private static var backgroundColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.13, green: 0.25, blue: 0.15, alpha: 1)
                : NSColor(srgbRed: 0.87, green: 0.98, blue: 0.85, alpha: 1)
        }
    }

    private func countdownText(now: Date) -> String {
        String(
            format: String(
                localized: "safebox.banner.countdown",
                defaultValue: "Denied automatically in %lld s"
            ),
            Int64(SafeboxApprovalBannerModel.remainingSeconds(until: presentation.deadline, now: now))
        )
    }

    private var allowTitle: String {
        String(localized: "safebox.banner.allow", defaultValue: "Allow")
    }

    private var denyTitle: String {
        String(localized: "safebox.banner.deny", defaultValue: "Deny")
    }

    private var allowAccessibilityLabel: String {
        String(localized: "safebox.banner.allow.accessibility", defaultValue: "Allow Safebox access")
    }

    private var denyAccessibilityLabel: String {
        String(localized: "safebox.banner.deny.accessibility", defaultValue: "Deny Safebox access")
    }
}
