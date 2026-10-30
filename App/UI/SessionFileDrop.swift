import SwiftUI

struct SessionFileDrop: ViewModifier {
    let record: SessionRecord
    let project: Project
    @State private var targeted = false
    @ObservedObject private var reporter = SessionDropReporter.shared

    func body(content: Content) -> some View {
        content
            .onDrop(of: SessionImageDropService.acceptedTypes, isTargeted: $targeted) { providers in
                SessionImageDropService.handle(providers, record: record, project: project) {
                    reporter.report($0, for: record.id)
                }
            }
            .overlay(alignment: .bottom) {
                if targeted || reporter.progress(for: record.id).message != nil {
                    HStack(spacing: 8) {
                        if reporter.progress(for: record.id).isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            TablerIcon(name: "paperclip", size: 14, color: Theme.highlight)
                        }
                        Text(targeted
                             ? String(localized: "Drop to attach files to this session's message")
                             : reporter.progress(for: record.id).message ?? "")
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.highlight.opacity(0.5)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 64)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(targeted ? "session.dropTarget" : "session.dropProgress")
                    .task(id: reporter.progress(for: record.id)) {
                        guard !reporter.progress(for: record.id).isWorking else { return }
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        reporter.clear(record.id)
                    }
                }
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .strokeBorder(Theme.highlight.opacity(0.6), lineWidth: 2)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }
}
