import AppKit
import SwiftUI

/// The run in progress, above the composer: where it is and who is working.
/// The conversation stays the conversation; this is one line beside it.
struct AutoRunStrip: View {
    @ObservedObject var conversation: UncoilAutoConversationState
    let projectID: UUID

    @State private var showsDiagnostics = false

    var body: some View {
        if conversation.isRunning, let run = conversation.currentRun {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.phase.displayName)
                    .font(Theme.ui(.small, .semibold))
                    .foregroundStyle(Theme.text)
                if let working = run.participants.last(where: { $0.state == .working }) {
                    Text(working.label)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button(String(localized: "Diagnostics")) { showsDiagnostics = true }
                    .buttonStyle(.borderless)
                    .font(Theme.ui(.small))
                Button(String(localized: "Cancel Run")) { conversation.cancelRun?() }
                    .buttonStyle(.borderless)
                    .font(Theme.ui(.small))
                    .accessibilityIdentifier("chat.autoRun.cancel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.top, 4)
            .sheet(isPresented: $showsDiagnostics) {
                AutoRunDiagnosticsView(conversation: conversation)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.autoRun.strip")
        }
    }
}

/// The last run in the agents panel: its phase and every session in it,
/// each one a click away from its own terminal.
struct AutoRunPanelSection: View {
    @ObservedObject var conversation: UncoilAutoConversationState
    let onOpen: (UUID) -> Void

    @State private var showsDiagnostics = false

    var body: some View {
        if let run = conversation.currentRun {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(color(for: run.phase)).frame(width: 7, height: 7)
                    Text("Auto run")
                        .font(Theme.ui(.small, .semibold))
                        .foregroundStyle(Theme.text)
                    Text(run.phase.displayName)
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        showsDiagnostics = true
                    } label: {
                        TablerIcon(name: "list-details", size: 12, color: Theme.textDim)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Auto run diagnostics"))
                    .accessibilityIdentifier("chat.autoRun.diagnostics")
                }
                Text(run.task)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
                ForEach(run.participants) { participant in
                    Button { onOpen(participant.sessionID) } label: {
                        HStack(spacing: 6) {
                            ProviderMark(provider: participant.provider, size: 11)
                            Text(participant.label)
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(stateLabel(participant.state))
                                .font(Theme.mono(.micro))
                                .foregroundStyle(participant.state == .working ? Theme.brand : Theme.textFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open this session in a window"))
                }
                if let reason = run.reason, run.phase != .completed {
                    Text(reason)
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.border, lineWidth: 1))
            .sheet(isPresented: $showsDiagnostics) {
                AutoRunDiagnosticsView(conversation: conversation)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.autoRun.panel")
        }
    }

    private func color(for phase: AutoPhase) -> Color {
        switch phase {
        case .completed: Theme.ok
        case .failed: Theme.danger
        case .cancelled: Theme.textFaint
        default: Theme.brand
        }
    }

    private func stateLabel(_ state: AutoParticipant.State) -> String {
        switch state {
        case .working: String(localized: "working")
        case .idle: String(localized: "idle")
        case .done: String(localized: "done")
        case .failed: String(localized: "failed")
        case .timedOut: String(localized: "timed out")
        case .crashed: String(localized: "ended")
        case .stopped: String(localized: "stopped")
        }
    }
}

/// Everything a run did and why: each step, each decision with what Laya
/// would have chosen, each verification with its evidence.
struct AutoRunDiagnosticsView: View {
    @ObservedObject var conversation: UncoilAutoConversationState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var run: AutoRun? {
        conversation.runs.first { $0.id == selection } ?? conversation.currentRun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Auto Run Diagnostics")
                    .font(Theme.ui(.large, .semibold))
                Spacer()
                if conversation.runs.count > 1 {
                    Picker(String(localized: "Run"), selection: Binding(
                        get: { run?.id },
                        set: { selection = $0 }
                    )) {
                        ForEach(conversation.runs.reversed()) { run in
                            Text("\(run.startedAt.formatted(date: .omitted, time: .shortened)) — \(String(run.task.prefix(40)))")
                                .tag(Optional(run.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                Button(String(localized: "Copy as JSON")) { copy() }
                    .disabled(run == nil)
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let run {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(run)
                        if !run.decisions.isEmpty { decisions(run) }
                        if !run.verifications.isEmpty { verifications(run) }
                        events(run)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .uncoilScrollers()
            } else {
                Text("No Auto run in this conversation yet.")
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 680)
        .accessibilityIdentifier("autoRun.diagnostics")
    }

    private func summary(_ run: AutoRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.task).font(Theme.ui(.body, .medium)).textSelection(.enabled)
            line("Outcome", run.phase.displayName + (run.reason.map { " — \($0)" } ?? ""))
            line("Started", run.startedAt.formatted(date: .abbreviated, time: .standard))
            if let ended = run.endedAt {
                line("Duration", Duration.seconds(ended.timeIntervalSince(run.startedAt))
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
            }
            ForEach(run.participants) { participant in
                line(participant.roleName, "\(participant.label) — @\(participant.handle), \(participant.state.rawValue)"
                    + (participant.worktreePath.map { "\n\($0)" } ?? ""))
            }
        }
    }

    private func decisions(_ run: AutoRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decisions").font(Theme.ui(.body, .semibold))
            ForEach(run.decisions) { decision in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(decision.kind.schema.title).font(Theme.ui(.small, .semibold))
                        Text(decision.authority.rawValue)
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Text("→ \(decision.action)").font(Theme.mono(.small, .semibold))
                    }
                    if let answer = decision.answer {
                        ForEach(decision.options, id: \.self) { option in
                            let probability = answer.probabilities[option] ?? 0
                            HStack(spacing: 8) {
                                Text(option)
                                    .font(Theme.mono(.micro))
                                    .frame(width: 150, alignment: .leading)
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(option == answer.choice ? Theme.brand : Theme.textFaint.opacity(0.4))
                                        .frame(width: max(2, proxy.size.width * probability))
                                }
                                .frame(height: 6)
                                Text(String(format: "%.2f", probability))
                                    .font(Theme.mono(.micro))
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                        Text(String(localized: "Laya chose \(answer.choice) · confidence \(String(format: "%.2f", answer.confidence))")
                            + (answer.latencyMilliseconds.map { String(format: " · %.0f ms", $0) } ?? "")
                            + (answer.model.map { " · \($0)" } ?? ""))
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textDim)
                        if decision.authority == .shadow, answer.choice != decision.action {
                            Text("Shadow: Laya would have selected \(answer.choice) · \(Int((answer.probabilities[answer.choice] ?? 0) * 100))%")
                                .font(Theme.ui(.small))
                                .foregroundStyle(Theme.textDim)
                        }
                    } else if let error = decision.engineError {
                        Text("Laya: \(error)").font(Theme.mono(.micro)).foregroundStyle(Theme.textFaint)
                    }
                    Text("Deterministic policy: \(decision.deterministic)")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textDim)
                    if let override = decision.override {
                        Text("Policy override: \(override)")
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.warn)
                    }
                    DisclosureGroup(String(localized: "State and question")) {
                        Text(decision.question + "\n\n" + decision.state)
                            .font(Theme.mono(.micro))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Theme.ui(.small))
                }
                .padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            }
        }
    }

    private func verifications(_ run: AutoRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verification").font(Theme.ui(.body, .semibold))
            ForEach(Array(run.verifications.enumerated()), id: \.offset) { _, record in
                DisclosureGroup("Attempt \(record.attempt): \(record.verdict.rawValue)") {
                    Text(record.summary + (record.workerCommands.isEmpty ? "" : "\n\nWorker ran:\n" + record.workerCommands.joined(separator: "\n"))
                         + (record.signature.map { "\n\nFailure signature: \($0)" } ?? ""))
                        .font(Theme.mono(.micro))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.ui(.small))
            }
        }
    }

    private func events(_ run: AutoRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(Theme.ui(.body, .semibold))
            ForEach(run.events) { event in
                if let detail = event.detail, !detail.isEmpty {
                    DisclosureGroup {
                        Text(detail)
                            .font(Theme.mono(.micro))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        eventLabel(event)
                    }
                } else {
                    // Where a disclosure's chevron would be, so every title lines up.
                    eventLabel(event).padding(.leading, 20)
                }
            }
        }
    }

    private func eventLabel(_ event: AutoRunEvent) -> some View {
        HStack(spacing: 8) {
            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
            Text(event.kind.rawValue)
                .font(Theme.mono(.micro))
                .foregroundStyle(event.kind == .error ? Theme.danger : event.kind == .warning ? Theme.warn : Theme.textDim)
                .frame(width: 80, alignment: .leading)
            Text(event.title).font(Theme.ui(.small))
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Theme.ui(.small))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Theme.ui(.small))
                .textSelection(.enabled)
        }
    }

    private func copy() {
        guard let run else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(run) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}
