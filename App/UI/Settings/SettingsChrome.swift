import SwiftUI

/// Shared furniture for the settings pages.
///
/// The pages are plain `Form`s, so this file is small on purpose: the grouped
/// container dressed in Uncoil's palette, a row that reflows when the window
/// gets narrow, and a couple of labels.

/// A settings page: grouped form, a header, and room to breathe.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            if let subtitle {
                Section {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .formStyle(.grouped)
        // The grouped form keeps its layout and insets; only the surfaces
        // change. `scrollContentBackground` clears the system fill so the page
        // sits on the app's background, and the row background paints the
        // grouped boxes in the panel colour.
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .listRowBackground(Theme.panel)
        .navigationTitle(title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `LabeledContent` that stacks its control under the label once the row gets
/// too tight — the whole point of the responsive pass, since a picker with a
/// long title is exactly what a 700-point window cannot fit side by side.
struct AdaptiveRow<Label: View, Control: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent {
                control
            } label: {
                label
            }

            VStack(alignment: .leading, spacing: 6) {
                label
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Title + explanation, the shape most settings rows want for their label.
struct SettingsLabel: View {
    let title: String
    var detail: String?
    var symbol: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .labelStyle(SettingsLabelStyle(hasIcon: symbol != nil))
    }
}

private struct SettingsLabelStyle: LabelStyle {
    let hasIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: hasIcon ? 8 : 0) {
            if hasIcon {
                configuration.icon.frame(width: 16)
            }
            configuration.title
        }
    }
}

/// A footnote under a section, for the "applies to new sessions only" kind of
/// caveat that used to be a dimmed mono line.
struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Status dot + text, used by the CLI, hook and login rows.
struct SettingsStatusLine: View {
    enum Level {
        case ok, warning, error, neutral

        // `Theme` reads the shared palette, which lives on the main actor.
        @MainActor var color: Color {
            switch self {
            case .ok: Theme.ok
            case .warning: Theme.warn
            case .error: Theme.danger
            case .neutral: Theme.textDim
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: 7, height: 7)
            Text(text)
                .foregroundStyle(level == .neutral ? Theme.textDim : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A text input: its label above it, the field full width underneath.
///
/// Deliberately not the platform's own arrangement. A grouped form puts the
/// label on the left and squeezes the field into whatever is left on the right,
/// where — stripped of AppKit's bezel — it reads as blank space rather than
/// something you can type into. Stacking is the ordinary shape of a form field
/// and gives the well the whole row to be visible in.
struct SettingsTextField: View {
    let title: String
    var detail: String?
    var prompt: String?
    @Binding var text: String
    var monospaced = false
    /// Multi-line fields grow between these bounds.
    var lineLimit: ClosedRange<Int>?
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            field
                .textFieldStyle(.plain)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { onSubmit?() }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The well is the page background, so it sits *below* the panel
                // the row is drawn on — an inset, which is what makes it read as
                // editable without a bezel.
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                // The edge does the actual work. `Theme.border` is only ~5/255
                // away from the panel in the dark palette and the well only
                // ~7/255 — measured, after both had been reported invisible —
                // so a field drawn from those two is a rectangle nobody can
                // see. `textFaint` is far enough from either surface, in both
                // palettes, to read as an edge.
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            focused ? Theme.highlight : Theme.textFaint.opacity(0.55),
                            lineWidth: focused ? 2 : 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { focused = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var field: some View {
        if let lineLimit {
            TextField(prompt ?? "", text: $text, axis: .vertical)
                .lineLimit(lineLimit)
        } else {
            TextField(prompt ?? "", text: $text)
        }
    }
}

extension View {
    /// Marks a control for the UI tests without repeating the prefix.
    func settingsID(_ suffix: String) -> some View {
        accessibilityIdentifier("settings.\(suffix)")
    }

}

/// A row that hosts an action button set, laid out the way every setup section
/// wants: buttons on the left, progress and a result note trailing.
struct SettingsActionRow<Buttons: View>: View {
    var isWorking = false
    var note: String?
    var noteLevel: SettingsStatusLine.Level = .neutral
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                buttons
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if let note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(noteLevel == .neutral ? Theme.textDim : noteLevel.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isWorking)
    }
}
