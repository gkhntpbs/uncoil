import SwiftUI

/// The shape every Uncoil sheet takes.
///
/// The sheets had each grown their own header, their own padding and their own
/// footer, and they read as three different apps. This is the one that already
/// worked — the "New Window" overlay: a title, one line saying what is being
/// asked, the content, and the actions along the bottom.
///
/// Prose here is `Theme.ui`, not `Theme.mono`. The monospaced face is for data
/// a person scans — session titles, paths, counts. A sheet asking a question is
/// something they read, and reading it in a terminal font is what made these
/// feel like a debug panel rather than part of the app.
struct SheetScaffold<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    /// Shown to the left of the title, for going back a page.
    var onBack: (() -> Void)?
    var width: CGFloat = 520
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                HStack(spacing: Theme.Space.tight) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textDim)
                                .frame(width: 22, height: 22)
                                .background(Theme.panel, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("sheet.back")
                    }
                    Text(title)
                        .font(Theme.ui(.title, .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.ui(.body))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, onBack == nil ? 0 : 30)
                }
            }
            .padding(.horizontal, Theme.Space.section)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.roomy)

            content()

            HStack(spacing: Theme.Space.tight) {
                actions()
            }
            .padding(.horizontal, Theme.Space.section)
            .padding(.top, Theme.Space.roomy)
            .padding(.bottom, Theme.Space.roomy)
        }
        .frame(width: width)
        .background(Theme.bg)
    }
}

/// A choosable card: a mark, a title, and a line saying what it does.
///
/// The same object the "New Window" overlay offers, made selectable. Rows
/// rather than a grid of tiles, because the thing that decides the choice is
/// the sentence underneath and a tile has no room for one.
struct SheetOptionRow<Leading: View>: View {
    let title: String
    var detail: String?
    var badge: String?
    let isSelected: Bool
    @ViewBuilder var leading: () -> Leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                leading()
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.tight) {
                        Text(title)
                            .font(Theme.ui(.body, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(Theme.ui(.micro, .medium))
                                .foregroundStyle(Theme.warn)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Theme.warn.opacity(0.14),
                                    in: Capsule()
                                )
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Theme.Space.tight)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.highlight : Theme.border)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(isSelected ? Theme.panelActive : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .stroke(
                        isSelected ? Theme.highlight.opacity(0.55) : Theme.border,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A labelled field group inside a sheet.
struct SheetField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            Text(label)
                .font(Theme.ui(.small, .medium))
                .foregroundStyle(Theme.textDim)
            content()
            if let hint {
                Text(hint)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The one-line text field the sheets use.
struct SheetTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.ui(.body))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 9)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}
