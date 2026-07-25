import SwiftUI

/// What to do when an edit could not be applied because the file moved on inside
/// the very block being edited.
///
/// Uncoil does not choose for the user here. Recomputing an edit against changed
/// content is safe when the change was elsewhere; when it landed in the same
/// block, guessing would quietly overwrite someone's work.
struct TaskStaleEditSheet: View {
    enum Choice {
        /// Throw the pending edit away and show what is on disk.
        case reload
        /// Show both sides before deciding.
        case compare
        /// Leave the file alone and keep the screen as it is.
        case cancel
    }

    let taskText: String
    let detail: String
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    TablerIcon(name: "alert-triangle", size: 13, color: Theme.warn)
                    Text("Düzenleme uygulanamadı")
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.text)
                }
                Text(taskText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }
            Text(detail)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Dosya bu görevin bloğunda değişti. Ne yapılacağına sen karar ver.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Spacer()
                Button("İptal") { onChoose(.cancel) }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("staleEdit.cancel")
                Button("Karşılaştır") { onChoose(.compare) }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("staleEdit.compare")
                Button("Yeniden yükle") { onChoose(.reload) }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("staleEdit.reload")
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.bg)
        .accessibilityIdentifier("staleEdit.sheet")
    }
}

/// Builds the "mine vs theirs" text the compare option shows. Pure, so the
/// wording is testable without a window.
enum StaleEditComparison {
    static func text(
        taskText: String,
        attempted: String,
        onDisk: String?
    ) -> String {
        var sections = ["# Senin düzenlemen — \(taskText)", attempted]
        if let onDisk, !onDisk.isEmpty {
            sections.append("# Dosyadaki hâli")
            sections.append(onDisk)
        } else {
            sections.append("# Dosyadaki hâli")
            sections.append("Bu görev dosyada bulunamadı; başkası silmiş ya da taşımış olabilir.")
        }
        return sections.joined(separator: "\n\n")
    }
}
