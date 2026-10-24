import SwiftUI

/// The tab row of a sheet, drawn the way the project page draws its own: an
/// icon and a word per tab inside one panel, the chosen one lifted onto the
/// active surface. A system segmented control looked like a form field and
/// nothing else in Uncoil did.
struct SheetTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let icon: (Tab) -> String
    var badge: (Tab) -> Int = { _ in 0 }
    var identifier: (Tab) -> String = { "\($0.id)" }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                button(tab)
            }
        }
        .padding(3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func button(_ tab: Tab) -> some View {
        let isOn = selection == tab
        let count = badge(tab)
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 6) {
                TablerIcon(name: icon(tab), size: 12, color: isOn ? Theme.text : Theme.textFaint)
                Text(title(tab))
                    .font(Theme.ui(.small, isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.ui(.micro, .medium))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Theme.text : Theme.textFaint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.bg.opacity(0.6), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isOn ? Theme.panelActive : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.panel - 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier(tab))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
