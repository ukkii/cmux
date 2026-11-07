import AppKit
import CmuxFoundation
import SwiftUI

/// What the editor sheet is open for.
enum SafeboxEditorTarget: Identifiable, Equatable {
    case add
    case edit(name: SafeboxSecretName, note: String, isValueMissing: Bool)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let name, _, _): return "edit:\(name.rawValue)"
        }
    }
}

/// Add/edit form for one secret: Name (uppercased as typed), Value (hidden
/// unless the eye is on) and an optional note for Claude.
///
/// Whether the value shows comes from the list model, so a window capture
/// can hide it (`SafeboxListModel.concealForCapture()`).
///
/// When editing, an empty Value keeps the stored value, so the editor never
/// needs to load it.
struct SafeboxSecretEditor: View {
    let target: SafeboxEditorTarget
    /// Saves the form; a thrown error is shown inline and keeps the sheet open.
    let onSave: (_ name: String, _ value: String?, _ note: String) async throws -> Void
    let onCancel: () -> Void
    /// Whether the value field shows the value in plain text.
    let isValueVisible: Bool
    /// Shows or hides the value; returns false when showing it was refused.
    let setValueVisible: (Bool) async -> Bool

    @State private var name: String
    @State private var value = ""
    @State private var note: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        target: SafeboxEditorTarget,
        onSave: @escaping (_ name: String, _ value: String?, _ note: String) async throws -> Void,
        onCancel: @escaping () -> Void,
        isValueVisible: Bool,
        setValueVisible: @escaping (Bool) async -> Bool
    ) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        self.isValueVisible = isValueVisible
        self.setValueVisible = setValueVisible
        switch target {
        case .add:
            _name = State(initialValue: "")
            _note = State(initialValue: "")
        case .edit(let name, let note, _):
            _name = State(initialValue: name.rawValue)
            _note = State(initialValue: note)
        }
    }

    /// Height of the single-line Value field; the eye button is centred in it.
    private static let valueFieldHeight: CGFloat = 22

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var keepsStoredValue: Bool {
        if case .edit(_, _, let isValueMissing) = target { return !isValueMissing }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing
                ? String(localized: "safebox.editor.editTitle", defaultValue: "Edit Secret")
                : String(localized: "safebox.editor.addTitle", defaultValue: "Add Secret"))
                .cmuxFont(size: 13, weight: .semibold)

            field(
                title: String(localized: "safebox.editor.name", defaultValue: "Name"),
                hint: String(
                    localized: "safebox.editor.nameHint",
                    defaultValue: "Also the environment variable name, for example CLOUDFLARE_TOKEN."
                )
            ) {
                SafeboxPlainTextField(
                    text: $name,
                    isSingleLine: true,
                    accessibilityLabel: String(localized: "safebox.editor.name", defaultValue: "Name"),
                    onSubmit: { save() }
                )
                .frame(height: 24)
                .accessibilityIdentifier("SafeboxEditorNameField")
            }

            field(
                title: String(localized: "safebox.editor.value", defaultValue: "Value"),
                hint: keepsStoredValue
                    ? String(localized: "safebox.editor.valueKeepHint", defaultValue: "Leave empty to keep the current value.")
                    : nil
            ) {
                // Top-aligned with the eye in a frame as tall as the single-line
                // field, so the eye is centred on that field and stays put when
                // the value turns into the taller multi-line view.
                HStack(alignment: .top, spacing: 6) {
                    valueInput
                    let eyeLabel = isValueVisible
                        ? String(localized: "safebox.row.hideValue", defaultValue: "Hide Value")
                        : String(localized: "safebox.row.showValue", defaultValue: "Show Value")
                    Button {
                        let show = !isValueVisible
                        Task {
                            if await setValueVisible(show) {
                                if errorMessage == SafeboxListModel.recordingMessage { errorMessage = nil }
                            } else {
                                errorMessage = SafeboxListModel.recordingMessage
                            }
                        }
                    } label: {
                        Image(systemName: isValueVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .frame(height: Self.valueFieldHeight)
                    .help(eyeLabel)
                    .accessibilityLabel(Text(eyeLabel))
                    .accessibilityIdentifier("SafeboxEditorRevealButton")
                }
            }

            field(
                title: String(localized: "safebox.editor.note", defaultValue: "Note for Claude (optional)"),
                hint: nil
            ) {
                TextField(
                    "",
                    text: $note,
                    prompt: Text(String(
                        localized: "safebox.editor.notePlaceholder",
                        defaultValue: "Zone token for example.com, DNS edit permission"
                    )),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .accessibilityIdentifier("SafeboxEditorNoteField")
            }

            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 11)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SafeboxEditorError")
            }

            HStack {
                Spacer()
                Button(String(localized: "safebox.editor.cancel", defaultValue: "Cancel"), role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "safebox.editor.save", defaultValue: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onDisappear {
            // Do not keep a typed or pasted value after the sheet closes, and
            // open the next sheet with the value hidden.
            value = ""
            Task { _ = await setValueVisible(false) }
        }
        .onChange(of: name) { _, newValue in
            let uppercased = newValue.uppercased()
            if uppercased != newValue { name = uppercased }
        }
    }

    /// Hidden: a `SecureField` for typing (secure event input), or for a
    /// multi-line value a placeholder, since a single-line field would lose
    /// its line breaks. Visible: a plain
    /// multi-line text view with every substitution off.
    @ViewBuilder
    private var valueInput: some View {
        if isValueVisible {
            SafeboxPlainTextField(
                text: $value,
                accessibilityLabel: String(localized: "safebox.editor.value", defaultValue: "Value")
            )
            .frame(height: 64)
            .accessibilityIdentifier("SafeboxEditorValueField")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                switch SafeboxHiddenValueInput(value: value) {
                case .secureField:
                    SecureField("", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(String(localized: "safebox.editor.value", defaultValue: "Value")))
                        .accessibilityIdentifier("SafeboxEditorValueField")
                case .multiLinePlaceholder(let lineCount):
                    Text(String(
                        localized: "safebox.editor.multiLineValue",
                        defaultValue: "Multi-line value (\(lineCount) lines)"
                    ))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .accessibilityIdentifier("SafeboxEditorMultiLinePlaceholder")
                }
                if SafeboxHiddenValueInput.isMultiLine(value) {
                    Button(String(localized: "safebox.editor.clear", defaultValue: "Clear")) {
                        value = ""
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("SafeboxEditorClearButton")
                }
            }
        }
    }

    private func field<Content: View>(
        title: String,
        hint: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .cmuxFont(size: 11, weight: .medium)
            content()
            if let hint {
                Text(hint)
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard SafeboxSecretName(normalizing: name) != nil else {
            errorMessage = SafeboxError.invalidName("").errorDescription
            return
        }
        let submittedValue: String?
        if value.isEmpty {
            guard keepsStoredValue else {
                errorMessage = SafeboxListModel.ValidationError.valueRequired.errorDescription
                return
            }
            submittedValue = nil
        } else {
            submittedValue = value
        }
        errorMessage = nil
        isSaving = true
        let name = name
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await onSave(name, submittedValue, note)
            } catch {
                errorMessage = SafeboxListModel.message(for: error)
            }
            isSaving = false
        }
    }
}
