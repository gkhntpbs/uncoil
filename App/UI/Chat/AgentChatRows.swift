import AppKit
import SwiftUI

/// One row of the transcript, by what the timeline says it is.
///
/// Every case here is a case of the common model — an `AgentItemKind`, a
/// timeline marker, a pending approval. Nothing asks which provider produced
/// it: a Codex command and a Claude `Bash` call are the same row.
struct AgentChatRowView: View {
    let row: AgentChatRow
    /// Not observed: the row reads its own item model, so a streamed word
    /// redraws that row and not the list around it.
    let model: AgentChatModel
    let provider: AgentProvider

    var body: some View {
        switch row {
        case .item(let id):
            if let item = model.itemModel(for: id) {
                AgentChatItemRow(itemModel: item)
            }
        case .marker(let marker):
            ChatMarkerRow(marker: marker)
        case .approval(let approval):
            ApprovalPanel(
                title: approval.title,
                detail: approval.detail,
                decisions: approval.decisions,
                respond: { model.respond(to: approval.id, decision: $0) },
                identifier: "chat.approval"
            )
            .padding(.top, 10)
            .padding(.bottom, 4)
        case .working:
            ChatWorkingRow(provider: provider)
        case .speaker(let source, _):
            ChatSpeakerRow(source: source)
        }
    }
}

/// Names the agent the rows below it came from. Clicking it opens that
/// agent's own terminal in a window — the full CLI, one click away.
private struct ChatSpeakerRow: View {
    let source: AgentItemSource
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        Button {
            openWindow(.session, value: source.sessionID)
        } label: {
            HStack(spacing: 7) {
                ProviderMark(provider: source.provider, size: 13)
                Text("@\(source.handle)")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(source.provider.color)
                Text(source.provider.displayName)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                if hovering {
                    HStack(spacing: 3) {
                        TablerIcon(name: "external-link", size: 10, color: Theme.textFaint)
                        Text("Open terminal")
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .help(String(localized: "Open @\(source.handle)'s own terminal in a window"))
        .accessibilityIdentifier("chat.speaker")
    }
}

// MARK: - Items

struct AgentChatItemRow: View {
    @ObservedObject var itemModel: AgentChatItemModel
    @ObservedObject private var theme = ThemeStore.shared

    private var item: AgentItem { itemModel.item }

    var body: some View {
        if let source = item.source {
            // What another agent said sits on a bar of its colour, so a long
            // exchange stays attributable after its header scrolls away.
            content
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(source.provider.color.opacity(0.45))
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .userMessage(let text, let attachments):
            if item.source != nil {
                // Typed into the agent's own terminal, not sent from here.
                ChatUserMessage(text: text, attachments: attachments, recipients: [], typedInAgent: true)
                    .padding(.vertical, 4)
            } else {
                ChatUserMessage(text: text, attachments: attachments, recipients: item.recipients ?? [])
                    .padding(.top, 18)
                    .padding(.bottom, 6)
            }
        case .agentMessage(let text):
            ChatAssistantMessage(text: text, isStreaming: item.status == .inProgress)
                .padding(.vertical, 6)
        case .reasoning(let summary):
            ChatReasoningRow(summary: summary, isStreaming: item.status == .inProgress, isExpanded: $itemModel.isExpanded)
                .padding(.vertical, 3)
        case .command(let command, let output, let exitCode):
            ChatCommandRow(command: command, output: output, exitCode: exitCode, status: item.status, isExpanded: $itemModel.isExpanded)
                .padding(.vertical, 2)
        case .fileChange(let changes):
            ChatFileChangeRow(changes: changes, status: item.status, isExpanded: $itemModel.isExpanded)
                .padding(.vertical, 2)
        case .toolCall(let call):
            ChatToolRow(call: call, status: item.status, native: item.native, isExpanded: $itemModel.isExpanded)
                .padding(.vertical, 2)
        case .plan(let plan):
            ChatPlanCard(plan: plan)
                .padding(.vertical, 6)
        case .other(let type):
            ChatUnknownRow(type: type, native: item.native, isExpanded: $itemModel.isExpanded)
                .padding(.vertical, 2)
        }
    }
}

private struct ChatUserMessage: View {
    let text: String
    let attachments: [AgentAttachment]
    var recipients: [AgentItemSource] = []
    var typedInAgent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("›")
                .font(Theme.mono(.large, .bold))
                .foregroundStyle(Theme.highlight)
            VStack(alignment: .leading, spacing: 8) {
                if !text.isEmpty {
                    Text(text)
                        .font(Theme.ui(.large))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !recipients.isEmpty || typedInAgent {
                    HStack(spacing: 6) {
                        TablerIcon(name: "arrow-right", size: 10, color: Theme.textFaint)
                        if typedInAgent {
                            Text("typed in the agent's terminal")
                                .font(Theme.ui(.small))
                                .foregroundStyle(Theme.textFaint)
                        }
                        ForEach(recipients, id: \.self) { recipient in
                            HStack(spacing: 4) {
                                ProviderMark(provider: recipient.provider, size: 10)
                                Text("@\(recipient.handle)")
                                    .font(Theme.mono(.small, .medium))
                                    .foregroundStyle(recipient.provider.color)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(recipient.provider.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                    }
                }
                if !attachments.isEmpty {
                    // Attachments belong to the message that carried them.
                    HStack(spacing: 6) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                            HStack(spacing: 4) {
                                TablerIcon(name: attachment.kind == .image ? "photo" : "file", size: 11, color: Theme.textDim)
                                Text(attachment.displayName)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .contextMenu { CopyButton(text: text) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.userMessage")
    }
}

private struct ChatAssistantMessage: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        ChatMarkdownView(text: text)
            .overlay(alignment: .bottomTrailing) {
                if isStreaming { StreamingDot().offset(x: 14, y: -4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { CopyButton(text: text) }
            .accessibilityIdentifier("chat.agentMessage")
    }
}

/// A thought is context for the answer, not part of it: one quiet line, open
/// on request. While it streams, its latest line shows so the wait has a face.
private struct ChatReasoningRow: View {
    let summary: String
    let isStreaming: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    TablerIcon(name: "bulb", size: 12, color: Theme.textFaint)
                    Text(isStreaming ? String(localized: "Thinking") : String(localized: "Thought"))
                        .font(Theme.ui(.body, .medium))
                        .foregroundStyle(Theme.textDim)
                    if !isExpanded {
                        Text(AgentChatTranscript.headline(isStreaming ? lastLine : summary))
                            .font(Theme.ui(.body))
                            .italic()
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Disclosure(isExpanded: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ChatMarkdownView(text: summary, tone: .quiet)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.border).frame(width: 2)
                    }
                    .padding(.leading, 5)
            }
        }
        .accessibilityIdentifier("chat.reasoning")
    }

    private var lastLine: String {
        summary.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? summary
    }
}

private struct ChatCommandRow: View {
    let command: String
    let output: String
    let exitCode: Int?
    let status: AgentItem.Status
    @Binding var isExpanded: Bool

    /// Lines of a running command's output shown under it without opening it.
    private static let liveTail = 4
    /// Lines an opened command shows; the terminal has the rest.
    private static let openTail = 400

    private var isSlashCommand: Bool { command.hasPrefix("/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ChatActivityHeader(
                icon: "terminal-2",
                isExpanded: $isExpanded,
                canExpand: !output.isEmpty,
                status: ChatStatusGlyph(status: status, exitCode: exitCode)
            ) {
                Text(command.isEmpty ? String(localized: "Command") : AgentChatTranscript.displayCommand(command))
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(command)
            }
            if isSlashCommand, !output.isEmpty, !isExpanded {
                // An agent's own command answers in a line or two, and that
                // line is the point: shown, not folded away.
                Text(AgentChatTranscript.tail(output, lines: 6).text)
                    .font(Theme.ui(.body))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            } else if isExpanded {
                ChatOutputBox(text: output, tail: Self.openTail)
            } else if status == .inProgress, !output.isEmpty {
                let tail = AgentChatTranscript.tail(output, lines: Self.liveTail)
                Text(tail.text)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(Self.liveTail)
                    .padding(.leading, 22)
            }
        }
        .accessibilityIdentifier("chat.command")
    }
}

private struct ChatFileChangeRow: View {
    let changes: [AgentFileChange]
    let status: AgentItem.Status
    @Binding var isExpanded: Bool

    private var stats: (added: Int, removed: Int) {
        changes.compactMap(\.diff).map(UnifiedDiff.stats).reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }

    private var title: String {
        if changes.count == 1, let change = changes.first {
            let name = (change.path as NSString).lastPathComponent
            switch change.kind {
            case .add: return String(localized: "Created \(name)")
            case .delete: return String(localized: "Deleted \(name)")
            case .update: return String(localized: "Edited \(name)")
            }
        }
        if changes.isEmpty { return String(localized: "Changed files") }
        return String(localized: "Edited \(changes.count) files")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatActivityHeader(
                icon: "file-diff",
                isExpanded: $isExpanded,
                canExpand: changes.contains { $0.diff != nil } || changes.count > 1,
                status: ChatStatusGlyph(status: status, exitCode: nil)
            ) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(changes.map(\.path).joined(separator: "\n"))
                    let stats = stats
                    if stats.added > 0 {
                        Text("+\(stats.added)").font(Theme.mono(.small)).foregroundStyle(Theme.ok)
                    }
                    if stats.removed > 0 {
                        Text("−\(stats.removed)").font(Theme.mono(.small)).foregroundStyle(Theme.danger)
                    }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(change.path)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.panelActive)
                            if let diff = change.diff {
                                // Bounded like output: a long diff scrolls in
                                // its box instead of stretching the chat.
                                ScrollView(.vertical) {
                                    UnifiedDiffView(diff: diff)
                                        .padding(.vertical, 4)
                                }
                                .frame(maxHeight: 360)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .background(Theme.bg.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    }
                }
                .padding(.leading, 22)
            }
        }
        .accessibilityIdentifier("chat.fileChange")
    }
}

private struct ChatToolRow: View {
    let call: AgentToolCall
    let status: AgentItem.Status
    let native: JSONValue?
    @Binding var isExpanded: Bool

    private var icon: String {
        switch call.origin {
        case .mcp: "plug"
        case .agent: "tool"
        case .delegation: "users"
        }
    }

    private var label: String {
        switch call.origin {
        case .mcp(let server): "\(server) › \(call.name)"
        case .agent: call.name
        case .delegation: String(localized: "Delegated to \(call.name)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ChatActivityHeader(
                icon: icon,
                isExpanded: $isExpanded,
                canExpand: native != nil,
                status: ChatStatusGlyph(status: status, exitCode: nil)
            ) {
                Text(label)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isExpanded, let details = AgentChatTranscript.details(native) {
                ChatOutputBox(text: details, tail: 300)
            }
        }
        .accessibilityIdentifier("chat.toolCall")
    }
}

/// Something the common model has no name for yet. Shown, small, with what the
/// provider sent a click away — never silently dropped.
private struct ChatUnknownRow: View {
    let type: String
    let native: JSONValue?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ChatActivityHeader(
                icon: "puzzle",
                isExpanded: $isExpanded,
                canExpand: native != nil,
                status: nil
            ) {
                HStack(spacing: 8) {
                    Text(type)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textDim)
                    Text("not drawn in chat yet")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            if isExpanded, let details = AgentChatTranscript.details(native) {
                ChatOutputBox(text: details, tail: 300)
            }
        }
        .accessibilityIdentifier("chat.unknownItem")
    }
}

private struct ChatPlanCard: View {
    let plan: AgentPlan

    private var done: Int { plan.steps.filter { $0.status == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TablerIcon(name: "list-check", size: 13, color: Theme.textDim)
                Text("Plan")
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.text)
                if !plan.steps.isEmpty {
                    Text("\(done) of \(plan.steps.count) done")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
            }
            if let text = plan.text, !text.isEmpty {
                ChatMarkdownView(text: text, tone: .quiet)
            }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TablerIcon(name: icon(step.status), size: 12, color: color(step.status))
                    Text(ChatMarkdown.inline(step.text))
                        .font(Theme.ui(.body, step.status == .inProgress ? .medium : .regular))
                        .foregroundStyle(step.status == .completed ? Theme.textFaint : Theme.text)
                        .strikethrough(step.status == .completed, color: Theme.textFaint)
                }
            }
        }
        .padding(12)
        .panel()
        .accessibilityIdentifier("chat.plan")
    }

    private func icon(_ status: AgentPlan.Step.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle-dot"
        case .completed: "circle-check"
        }
    }

    private func color(_ status: AgentPlan.Step.Status) -> Color {
        switch status {
        case .pending: Theme.textFaint
        case .inProgress: Theme.highlight
        case .completed: Theme.ok
        }
    }
}

// MARK: - Markers

struct ChatMarkerRow: View {
    let marker: AgentTimelineMarker
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        Group {
            switch marker.kind {
            case .notice(let notice) where notice.action != nil:
                actionLine(notice)
            case .notice(let notice):
                switch notice.level {
                case .info:
                    quietLine(icon: "info-circle", text: notice.message, color: Theme.textFaint)
                case .warning:
                    callout(icon: "alert-triangle", text: notice.message, tint: Theme.warn)
                case .error:
                    callout(icon: "alert-circle", text: notice.message, tint: Theme.danger)
                }
            case .turnEnded(.interrupted):
                quietLine(icon: "hand-stop", text: String(localized: "Interrupted"), color: Theme.textDim)
            case .turnEnded(.failed(let message)):
                callout(
                    icon: "alert-circle",
                    text: message.map { String(localized: "The turn failed: \($0)") } ?? String(localized: "The turn failed."),
                    tint: Theme.danger
                )
            case .turnEnded(.completed):
                EmptyView()
            case .approvalResolved(let approval, let decision):
                approvalLine(approval, decision: decision)
            }
        }
        .accessibilityIdentifier("chat.marker")
    }

    @Environment(\.openWindow) private var openWindow

    /// A notice that can be acted on: the button is the reason it is here.
    private func actionLine(_ notice: AgentNotice) -> some View {
        HStack(spacing: 10) {
            TablerIcon(name: "terminal-2", size: 13, color: Theme.highlight)
            Text(notice.message)
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if case .openTerminal(let sessionID, let handle) = notice.action {
                Button {
                    openWindow(.session, value: sessionID)
                } label: {
                    HStack(spacing: 5) {
                        TablerIcon(name: "external-link", size: 11, color: Theme.textOnHighlight)
                        Text("Open @\(handle)'s Terminal")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("chat.marker.openTerminal")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.highlight.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.highlightBorder, lineWidth: 1)
        )
        .padding(.vertical, 6)
    }

    private func quietLine(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 7) {
            TablerIcon(name: icon, size: 11, color: color)
            Text(text)
                .font(Theme.ui(.small))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
    }

    private func callout(icon: String, text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TablerIcon(name: icon, size: 12, color: tint)
            Text(text)
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, 6)
    }

    private func approvalLine(_ approval: AgentApproval, decision: String) -> some View {
        let (icon, color, verb): (String, Color, String) = switch decision {
        case "accept": ("shield-check", Theme.ok, String(localized: "Allowed once"))
        case "acceptForSession": ("shield-check", Theme.ok, String(localized: "Allowed for the session"))
        case "decline": ("shield-x", Theme.danger, String(localized: "Denied"))
        case "cancelled": ("shield-x", Theme.textFaint, String(localized: "Withdrawn"))
        default: ("shield-lock", Theme.textDim, decision)
        }
        return HStack(spacing: 7) {
            TablerIcon(name: icon, size: 11, color: color)
            Text(verb)
                .font(Theme.ui(.small, .medium))
                .foregroundStyle(color)
            Text(approval.title)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

private struct ChatWorkingRow: View {
    let provider: AgentProvider

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
            Text("\(provider.displayName) is working")
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("chat.working")
    }
}

// MARK: - Shared pieces

/// The one-line head of a command, a file change, a tool call: icon, what it
/// is, how it went, and a disclosure when there is more to see.
private struct ChatActivityHeader<Label: View>: View {
    let icon: String
    @Binding var isExpanded: Bool
    let canExpand: Bool
    let status: ChatStatusGlyph?
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button {
            guard canExpand else { return }
            withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                TablerIcon(name: icon, size: 13, color: Theme.textDim)
                    .frame(width: 14)
                label()
                if let status { status }
                if canExpand { Disclosure(isExpanded: isExpanded) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                hovering && canExpand ? Theme.panelHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.leading, -6)
    }
}

/// How an item ended, as small as it can be said.
struct ChatStatusGlyph: View {
    let status: AgentItem.Status
    let exitCode: Int?

    var body: some View {
        switch status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        case .failed:
            label(exitCode.map { String(localized: "exit \($0)") } ?? String(localized: "failed"), Theme.danger)
        case .declined:
            label(String(localized: "declined"), Theme.warn)
        case .completed:
            if let exitCode, exitCode != 0 {
                label(String(localized: "exit \(exitCode)"), Theme.danger)
            } else {
                TablerIcon(name: "check", size: 11, color: Theme.ok.opacity(0.8))
            }
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(.small))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct Disclosure: View {
    let isExpanded: Bool

    var body: some View {
        TablerIcon(name: "chevron-right", size: 10, color: Theme.textFaint)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

/// Output, bounded: the end of it, in a box that scrolls on its own rather
/// than stretching the conversation.
private struct ChatOutputBox: View {
    let text: String
    let tail: Int

    @State private var hovering = false

    var body: some View {
        let shown = AgentChatTranscript.tail(text, lines: tail)
        VStack(alignment: .leading, spacing: 0) {
            if shown.hidden > 0 {
                Text("\(shown.hidden) earlier lines not shown")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(shown.text.isEmpty ? " " : shown.text)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                CopyIconButton(text: text).padding(5)
            }
        }
        .onHover { hovering = $0 }
        .padding(.leading, 22)
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button(String(localized: "Copy")) { ChatClipboard.copy(text) }
    }
}

private struct CopyIconButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            ChatClipboard.copy(text)
            copied = true
        } label: {
            TablerIcon(name: copied ? "check" : "copy", size: 11, color: Theme.textDim)
                .frame(width: 22, height: 20)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .help(String(localized: "Copy"))
    }
}

enum ChatClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A reply still arriving: one soft pulse after its last word.
private struct StreamingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.highlight)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Markdown

/// An agent's reply, drawn by block: prose in the interface face, code in the
/// fixed-width one, headings and lists as themselves.
struct ChatMarkdownView: View {
    enum Tone {
        /// The answer.
        case primary
        /// Context around it: a thought, a plan's preamble.
        case quiet
    }

    let text: String
    var tone: Tone = .primary

    private var textColor: Color { tone == .primary ? Theme.text : Theme.textDim }
    private var size: Theme.TypeScale { tone == .primary ? .large : .body }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let body):
            Text(ChatMarkdown.inline(body))
                .font(Theme.ui(size))
                .foregroundStyle(textColor)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let body):
            Text(ChatMarkdown.inline(body))
                .font(Theme.ui(level <= 2 ? .title : .large, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
                .textSelection(.enabled)
        case .listItem(let marker, let body, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(Theme.ui(size, .medium))
                    .foregroundStyle(Theme.textFaint)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(ChatMarkdown.inline(body))
                    .font(Theme.ui(size))
                    .foregroundStyle(textColor)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code)
        case .quote(let body):
            Text(ChatMarkdown.inline(body))
                .font(Theme.ui(size))
                .italic()
                .foregroundStyle(Theme.textDim)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
                .textSelection(.enabled)
        case .table(let source):
            ScrollView(.horizontal) {
                Text(source)
                    .font(Theme.mono(.small))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
            }
            .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let code: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering { CopyIconButton(text: code).padding(5) }
        }
        .onHover { hovering = $0 }
    }
}
