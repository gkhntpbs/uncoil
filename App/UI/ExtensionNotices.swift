import SwiftUI

/// The Extensions window's messages.
///
/// One line of state was not enough: a bulk action produces several results, a
/// scan reports while an adoption is still going, and a message that has to be
/// dismissed by hand for something that went fine is noise. Notices stack, the
/// harmless ones fade on their own, and anything that failed stays until the user
/// has seen it.
@MainActor
final class ExtensionNoticeCenter: ObservableObject {
    enum Level: Equatable {
        case info
        case success
        case warning
        case failure

        var icon: String {
            switch self {
            case .info: "info-circle"
            case .success: "circle-check"
            case .warning: "alert-triangle"
            case .failure: "alert-circle"
            }
        }

        /// Only what went well disappears on its own; a warning or a failure is
        /// the user's to dismiss.
        var autoDismissAfter: TimeInterval? {
            switch self {
            case .info: 5
            case .success: 4
            case .warning, .failure: nil
            }
        }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var level: Level
        var text: String
        /// Long output (a scanner's stderr, a rejected plan) shown on demand.
        var detail: String?
        var isExpanded = false
    }

    /// Newest last, so the stack grows downwards like a log.
    @Published private(set) var notices: [Notice] = []
    /// Beyond this the oldest is dropped: a wall of toasts hides the newest one.
    private let limit = 4

    func post(_ text: String, level: Level = .info, detail: String? = nil) {
        // The same message twice in a row is one message.
        if let last = notices.last, last.text == text, last.level == level { return }
        let notice = Notice(level: level, text: text, detail: detail)
        notices.append(notice)
        if notices.count > limit { notices.removeFirst(notices.count - limit) }
        guard let delay = level.autoDismissAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.dismiss(notice.id)
        }
    }

    /// Classifies a plain message so existing call sites keep working: anything
    /// that reads like a failure is not quietly shown as good news.
    func post(message: String) {
        post(message, level: Self.level(of: message))
    }

    static func level(of message: String) -> Level {
        let lowered = message.lowercased()
        let failures = [
            "failed", "could not be done", "could not be read", "error", "blocks",
            "could not be removed", "not found", "invalid", "not done", "dropped",
            "could not be installed", "could not be restored",
        ]
        if failures.contains(where: lowered.contains) { return .failure }
        let warnings = [
            "warning", "skipped", "unchanged", "changed on disk", "requires", "needs",
        ]
        if warnings.contains(where: lowered.contains) { return .warning }
        let successes = [
            "applied", "sahiplenildi", "created", "updated", "eklendi",
            "kuruldu", "restored", "removed", "repaired", "bitti",
        ]
        if successes.contains(where: lowered.contains) { return .success }
        return .info
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func dismissAll() {
        notices.removeAll()
    }

    func toggleDetail(_ id: UUID) {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        notices[index].isExpanded.toggle()
    }

    /// A write-only binding for the screens that still assign a plain string.
    var messageBinding: Binding<String?> {
        Binding(
            get: { nil },
            set: { [weak self] value in
                guard let value, !value.isEmpty else { return }
                self?.post(message: value)
            }
        )
    }
}

/// The stack itself: newest at the bottom, each one dismissable.
struct ExtensionNoticeStack: View {
    @ObservedObject var center: ExtensionNoticeCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(center.notices) { notice in
                row(notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(uncoilAnimation(.easeOut(duration: 0.16)), value: center.notices)
        .accessibilityIdentifier("extensions.notices")
    }

    private func tint(_ level: ExtensionNoticeCenter.Level) -> Color {
        switch level {
        case .info: Theme.info
        case .success: Theme.ok
        case .warning: Theme.warn
        case .failure: Theme.danger
        }
    }

    private func row(_ notice: ExtensionNoticeCenter.Notice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TablerIcon(name: notice.level.icon, size: 12, color: tint(notice.level))
                    .padding(.top, 1)
                Text(notice.text)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if notice.detail != nil {
                    Button(notice.isExpanded ? "Hide" : "Detail") {
                        center.toggleDetail(notice.id)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(.micro, .medium))
                    .foregroundStyle(Theme.textDim)
                }
                Button {
                    center.dismiss(notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("extensions.notice.dismiss")
            }
            if notice.isExpanded, let detail = notice.detail {
                Text(detail)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint(notice.level).opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("extensions.notice")
    }
}
