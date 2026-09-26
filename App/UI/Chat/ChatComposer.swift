import AppKit
import SwiftUI

/// Where the user talks to the session.
///
/// One field and one button beside it. The button says what Return would do
/// right now — send, stop, or nothing — by its icon, rather than a line of
/// instructions under the field saying it for ever. Typing `@` or `/` opens
/// the completions above the field; the arrows move through them and Return or
/// Tab takes one.
struct ChatComposer: View {
    @ObservedObject var model: AgentChatModel
    let placeholder: String
    /// Something the user may want to stop is running — the session's own turn,
    /// or the agents it speaks for.
    var isBusy: Bool = false
    var onStop: (() -> Void)?

    @ObservedObject private var theme = ThemeStore.shared
    @State private var height: CGFloat = ChatComposerField.minimumHeight
    @State private var focusRequest = 0

    private var hasText: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var busy: Bool { isBusy || model.turnInProgress }

    private enum Action { case send, stop, idle }

    /// Text waiting to go wins over a stop: with agents working, the user may
    /// well be writing to another one.
    private var action: Action {
        if hasText, model.isReady, !model.turnInProgress { return .send }
        if busy { return .stop }
        return .idle
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(model.isReady ? placeholder : String(localized: "The session is not running"))
                        .font(Theme.ui(.large))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.leading, 5)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                ChatComposerField(
                    text: $model.draft,
                    height: $height,
                    focusRequest: focusRequest,
                    cursorRequest: model.cursorRequest,
                    onCursorRequestHandled: model.cursorRequestHandled,
                    onCursor: { model.updateCompletion(cursor: $0) },
                    onKey: handle
                )
                .frame(height: height)
                .accessibilityIdentifier("chat.composer.field")
            }
            .padding(.vertical, 4)
            actionButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .panel(radius: Theme.Radius.sheet)
        .elevated(.low)
        .contentShape(Rectangle())
        .onTapGesture { focusRequest += 1 }
        .overlay(alignment: .topLeading) {
            if !model.suggestions.isEmpty {
                // A zero-height frame on the composer's top edge, with the list
                // hanging from its bottom: the list grows upwards, above the
                // field, however many lines it has.
                ChatSuggestionList(model: model)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -8)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.quick, value: model.suggestions.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer")
    }

    private var actionButton: some View {
        let (icon, help, enabled): (String, String, Bool) = switch action {
        case .send: ("arrow-up", String(localized: "Send (Return)"), true)
        case .stop: ("player-stop", String(localized: "Stop (Esc)"), true)
        case .idle: ("arrow-up", String(localized: "Send (Return)"), false)
        }
        return Button {
            switch action {
            case .send: model.send()
            case .stop: stop()
            case .idle: break
            }
        } label: {
            TablerIcon(name: icon, size: 14, color: enabled ? Theme.textOnHighlight : Theme.textFaint)
                .frame(width: 28, height: 28)
                .background(enabled ? Theme.highlight : Theme.panelActive, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .help(help)
        .animation(Theme.Motion.quick, value: icon)
        .accessibilityIdentifier(action == .stop ? "chat.composer.stop" : "chat.composer.send")
    }

    private func stop() {
        if let onStop { onStop() } else { model.interrupt() }
    }

    /// Keys the field hands over before acting on them itself.
    private func handle(_ key: ChatComposerField.Key) -> Bool {
        let completing = !model.suggestions.isEmpty
        switch key {
        case .up where completing:
            model.moveSuggestion(by: -1)
            return true
        case .down where completing:
            model.moveSuggestion(by: 1)
            return true
        case .tab where completing, .returnKey where completing:
            return model.acceptSuggestion()
        case .escape:
            if completing {
                model.dismissCompletion()
            } else if busy {
                stop()
            }
            return true
        case .returnKey:
            model.send()
            return true
        default:
            return false
        }
    }
}

/// The completions for the word being typed, floating above the composer.
private struct ChatSuggestionList: View {
    @ObservedObject var model: AgentChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.suggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    model.acceptSuggestion(at: index)
                } label: {
                    HStack(spacing: 9) {
                        if let provider = suggestion.provider {
                            ProviderMark(provider: provider, size: 12)
                        }
                        Text(suggestion.title)
                            .font(Theme.mono(.body, .medium))
                            .foregroundStyle(Theme.text)
                        Text(suggestion.detail)
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        index == model.selectedSuggestion ? Theme.panelActive : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.selectedSuggestion = index } }
            }
        }
        .padding(5)
        .frame(width: 440, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .elevated(.floating)
        .accessibilityIdentifier("chat.composer.suggestions")
    }
}

/// The composer's text: an `NSTextView`, because SwiftUI's editor on macOS 14
/// cannot tell Return from Shift-Return, cannot say how tall its text is or
/// where its cursor is, and cannot be handed focus on demand.
struct ChatComposerField: NSViewRepresentable {
    static let minimumHeight: CGFloat = 20
    static let maximumHeight: CGFloat = 220

    enum Key {
        case returnKey, tab, up, down, escape
    }

    @Binding var text: String
    @Binding var height: CGFloat
    /// Changing it takes focus: the view appeared, or the panel was clicked.
    var focusRequest: Int
    /// A cursor position to move to after the text was changed elsewhere.
    var cursorRequest: Int?
    var onCursorRequestHandled: () -> Void = {}
    /// Where the cursor is, in UTF-16 offsets, whenever it moves.
    var onCursor: (Int) -> Void = { _ in }
    /// Offered each key first; true means it was handled.
    var onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let coordinator = context.coordinator
        textView.onEscape = { [weak coordinator] in _ = coordinator?.parent.onKey(.escape) }
        textView.onWidthChange = { [weak coordinator] in
            DispatchQueue.main.async { coordinator?.measure() }
        }
        style(textView)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.measure()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(cursorRequest ?? end, end), length: 0))
            DispatchQueue.main.async { context.coordinator.measure() }
        }
        if cursorRequest != nil {
            let handled = onCursorRequestHandled
            DispatchQueue.main.async { handled() }
        }
        style(textView)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    private func style(_ textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: Theme.TypeScale.large.rawValue)
        let color = NSColor(Theme.text)
        if textView.font != font { textView.font = font }
        if textView.textColor != color { textView.textColor = color }
        textView.insertionPointColor = NSColor(Theme.highlight)
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerField
        weak var textView: NSTextView?
        var lastFocusRequest = 0

        init(_ parent: ChatComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
            reportCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportCursor()
        }

        private func reportCursor() {
            guard let textView, !textView.hasMarkedText() else { return }
            let cursor = textView.selectedRange().location
            let report = parent.onCursor
            // Out of the delegate call: the report publishes, and this runs
            // inside AppKit's own text change.
            DispatchQueue.main.async { report(cursor) }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return parent.onKey(.returnKey)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            default:
                return false
            }
        }

        /// The text's own height, within the composer's limits.
        func measure() {
            guard let textView, let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(ChatComposerField.maximumHeight, max(ChatComposerField.minimumHeight, ceil(used)))
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }
    }
}

/// Escape belongs to the composer while it has focus.
final class ComposerTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// The text's height depends on the width it wraps in, which is only known
    /// once the view is laid out — and changes whenever the window does.
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
