import SwiftUI

/// Furniture shared by every onboarding step: the frame around the content, the
/// progress dots, the always-present Skip, and the cards a step is built from.

/// One step's page. The content scrolls; the two bars never move, so Skip and
/// Back stay where the user last saw them.
struct OnboardingScaffold<Content: View>: View {
    let step: OnboardingStep
    /// Big title above the content. Empty for a step that draws its own hero.
    var title: String?
    var subtitle: String?
    /// Label of the primary button; nil hides it.
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var onBack: (() -> Void)?
    var onSkipAll: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(step: step, onSkipAll: onSkipAll)

            ScrollView {
                VStack(spacing: 18) {
                    if let title {
                        VStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            if let subtitle {
                                Text(subtitle)
                                    .font(Theme.mono(.large))
                                    .foregroundStyle(Theme.textDim)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 520)
                            }
                        }
                        .padding(.top, 12)
                    }
                    content
                        .frame(maxWidth: 620)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .uncoilScrollers()
            }

            OnboardingBottomBar(
                primaryTitle: primaryTitle,
                primaryAction: primaryAction,
                onBack: onBack
            )
        }
        .background(Theme.bg)
    }
}

private struct OnboardingTopBar: View {
    let step: OnboardingStep
    let onSkipAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Clearance for the traffic lights: the window is title-bar-less.
            Spacer().frame(width: 78)
            ForEach(OnboardingFlow.all) { candidate in
                Capsule()
                    .fill(candidate == step ? Theme.text : Theme.textFaint.opacity(0.5))
                    .frame(width: candidate == step ? 16 : 5, height: 5)
                    .animation(uncoilAnimation(.easeOut(duration: 0.18)), value: step)
            }
            Spacer()
            Button(action: onSkipAll) {
                Text("Skip")
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding.skipAll")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

private struct OnboardingBottomBar: View {
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    let onBack: (() -> Void)?

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                    }
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.back")
            }
            Spacer()
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("onboarding.primary")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

// MARK: - Building blocks

/// A titled card — the shape every explanatory block on these pages takes.
struct OnboardingCard<Content: View>: View {
    var symbol: String?
    let title: String
    var badge: String?
    var badgeTint: Color?
    var detail: String?
    var toggle: Binding<Bool>?
    @ViewBuilder var content: Content

    init(
        symbol: String? = nil,
        title: String,
        badge: String? = nil,
        badgeTint: Color? = nil,
        detail: String? = nil,
        toggle: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.badge = badge
        self.badgeTint = badgeTint
        self.detail = detail
        self.toggle = toggle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 20)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.mono(.large, .semibold))
                        .foregroundStyle(Theme.text)
                    if let badge {
                        OnboardingBadge(text: badge, tint: badgeTint ?? Theme.textDim)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            Spacer(minLength: 0)
            if let toggle {
                Toggle("", isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

struct OnboardingBadge: View {
    let text: String
    var tint: Color = Theme.textDim

    var body: some View {
        Text(text)
            .font(Theme.mono(.micro, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surface(for: tint), in: Capsule())
    }
}

/// Icon + one line of copy: the welcome and finish pages' bullet list.
struct OnboardingBullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textDim)
                .frame(width: 22)
            Text(text)
                .font(Theme.mono(.large))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The "Not now" affordance under a step's own controls. Deliberately quiet and
/// deliberately always there.
struct OnboardingSkipLink: View {
    var title: String = String(localized: "Or skip this for now.")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.skipStep")
    }
}

/// A shell command the user runs themselves. Uncoil never runs an install for
/// them, so the one action offered is Copy.
struct OnboardingCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(.plain)
            .font(Theme.mono(.small, .semibold))
            .foregroundStyle(Theme.highlight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
    }
}
