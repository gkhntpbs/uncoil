import SwiftUI

/// Reads the prompt being written and asks the advisor, per addressed agent,
/// which effort it deserves. Debounced, so typing is never waited on, and a
/// newer draft cancels the reading of an older one.
@MainActor
final class EffortSuggestionModel: ObservableObject {
    /// How long typing has to pause before the prompt is read. Long enough
    /// that a word being typed is not read letter by letter.
    static let debounce: Duration = .milliseconds(600)
    /// How much of the conversation the advisor reads as its "course".
    static let recentLimit = 6

    private var task: Task<Void, Never>?
    /// What was last sent to be read — the agents and the text, whitespace
    /// folded — so a keystroke that changes neither asks nothing.
    private var lastKey: String?

    /// Called on every keystroke. Cheap by design: it parses the line and
    /// compares a key, and only a pause in typing reaches the advisor. The
    /// chips already on screen stay while the next reading is made; they go
    /// only when the agents named change or the line empties.
    func update(
        draft: String,
        conversation: UncoilAutoConversationState,
        roster: [UncoilAutoRoster.Entry],
        records: [SessionRecord],
        settings: SettingsStore
    ) {
        let advisorSettings = settings.uncoilAuto.advisor
        guard advisorSettings.enabled, UpdateChannel.installed() == .edge,
              case .message(let text, let mentions) = UncoilAutoInput.parse(draft),
              !text.isEmpty, !text.hasPrefix("/")
        else {
            task?.cancel()
            lastKey = nil
            conversation.hide()
            return
        }
        let allows = { conversation.allows($0, settings: settings.uncoilAuto) }
        // Named agents, or the one a prompt naming nobody would go to.
        let targets = (mentions.isEmpty
            ? UncoilAutoRouting.target(chosen: conversation.target, roster: roster, allows: allows).map { [$0] } ?? []
            : mentions.compactMap { handle in roster.first { $0.handle == handle } })
            .filter { allows($0.provider) }
            .filter { advisorSettings.policy(for: $0.provider).enabled }
        let handles = targets.map(\.handle)
        if !Set(conversation.suggestions.map(\.entry.handle)).isSubset(of: Set(handles)) {
            conversation.hide()
        }
        let key = handles.joined(separator: ",") + "|" + Self.folded(text)
        guard key != lastKey else { return }
        lastKey = key
        task?.cancel()
        guard !targets.isEmpty else { return }
        let recent = Self.recent(in: conversation.sessionID)
        task = Task { [weak conversation] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let advisor = await LayaSidecar.shared.advisor(for: advisorSettings)
            var items: [EffortSuggestionItem] = []
            for entry in targets {
                guard let conversation else { return }
                let ladder = await EffortLadder.detect(entry.provider, settings: settings)
                guard !ladder.isEmpty else { continue }
                let context = EffortContext(prompt: text, provider: entry.provider, recent: recent)
                guard let features = try? await advisor.features(for: context), !Task.isCancelled else { continue }
                let record = entry.sessionID.flatMap { id in records.first { $0.id == id } }
                guard let suggestion = EffortPolicy.decide(
                    features, ladder: ladder,
                    policy: advisorSettings.policy(for: entry.provider),
                    current: conversation.currentEffort(for: entry, record: record)),
                      suggestion.confidence >= advisorSettings.confidenceThreshold
                else { continue }
                items.append(EffortSuggestionItem(
                    entry: entry, suggestion: suggestion,
                    application: EffortSuggestionItem.application(
                        for: entry, isStructured: entry.sessionID.map(TerminalRegistry.shared.isStructured) ?? false)))
            }
            guard !Task.isCancelled, let conversation else { return }
            conversation.publish(items)
        }
    }

    static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The conversation's last few turns, one short line each.
    static func recent(in sessionID: UUID, hub: AgentEventHub = .shared) -> [String] {
        let items = hub.timeline(for: sessionID)?.items ?? []
        let lines = items.compactMap { item -> String? in
            let who = item.source.map { "@\($0.handle)" } ?? "user"
            switch item.kind {
            case .userMessage(let text, _): return "\(who): \(oneLine(text))"
            case .agentMessage(let text): return "\(who): \(oneLine(text))"
            default: return nil
            }
        }
        return Array(lines.suffix(recentLimit))
    }

    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}

/// The advisor's suggestions for the prompt being written, one chip per
/// addressed agent, just above the composer.
struct EffortSuggestionBar: View {
    @ObservedObject var conversation: UncoilAutoConversationState
    let draft: String
    @ObservedObject private var theme = ThemeStore.shared

    private var items: [EffortSuggestionItem] {
        draft.isEmpty ? [] : conversation.suggestions
    }

    var body: some View {
        // Fades only when the chips appear or go, not on every reading that
        // updates them in place.
        chips.animation(Theme.Motion.quick, value: items.isEmpty)
    }

    @ViewBuilder
    private var chips: some View {
        if !items.isEmpty {
            // Scrolls sideways rather than wrapping or clipping when a prompt
            // names more agents than the column is wide.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        EffortSuggestionChip(item: item) {
                            Task { await conversation.apply(item) }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.effortSuggestions")
        }
    }
}

private struct EffortSuggestionChip: View {
    let item: EffortSuggestionItem
    let onApply: () -> Void

    private var suggestion: EffortSuggestion { item.suggestion }

    var body: some View {
        HStack(spacing: 6) {
            ProviderMark(provider: item.entry.provider, size: 11)
            Text("@\(item.entry.handle)")
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(item.entry.provider.color)
            Text("effort \(suggestion.level)")
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(Theme.text)
            Text("\(Int((suggestion.confidence * 100).rounded()))%")
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
            if suggestion.isChange {
                Text("now \(suggestion.current ?? String(localized: "default"))")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                applyControl
            } else {
                TablerIcon(name: "check", size: 11, color: Theme.ok)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize()
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.effortSuggestion.\(item.entry.handle)")
    }

    @ViewBuilder
    private var applyControl: some View {
        switch item.application {
        case .command, .atLaunch:
            Button(String(localized: "Apply"), action: onApply)
                .buttonStyle(.plain)
                .font(Theme.ui(.small, .semibold))
                .foregroundStyle(Theme.highlight)
                .accessibilityIdentifier("chat.effortSuggestion.apply")
        case .unavailable:
            TablerIcon(name: "info-circle", size: 11, color: Theme.textFaint)
        }
    }

    private var tooltip: String {
        var lines = suggestion.reasons.map { "• \($0)" }
        let engine: String = switch suggestion.features.source {
        case .laya: "Laya"
        case .blended: "Laya + heuristic"
        case .heuristic: "Heuristic"
        }
        let latency = suggestion.features.latencyMilliseconds.map { " · \(Int($0)) ms" } ?? ""
        lines.append("\(engine)\(suggestion.features.model.map { " (\($0))" } ?? "")\(latency)")
        switch item.application {
        case .command:
            lines.append(String(localized: "Apply sends /effort \(suggestion.level) to @\(item.entry.handle). Claude saves it as its default for this model."))
        case .atLaunch:
            lines.append(String(localized: "Apply starts @\(item.entry.handle) at this effort."))
        case .unavailable(let reason):
            lines.append(reason)
        }
        return lines.joined(separator: "\n")
    }
}
