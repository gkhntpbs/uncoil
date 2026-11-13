import SwiftUI

/// What a session shows instead of a terminal when its folder cannot be reached.
///
/// Launching an agent in a folder that is not there leaves an empty terminal
/// that never answers. This names the cause — usually an external disk that is
/// not connected — and the session starts on its own once the disk is back.
struct MissingFolderView: View {
    let availability: FolderAvailability
    let path: String
    let onRetry: () -> Void

    private var headline: String {
        switch availability {
        case .volumeMissing(let volume):
            String(localized: "The disk “\(volume)” is not connected")
        default:
            String(localized: "The project folder could not be found")
        }
    }

    private var detail: String {
        switch availability {
        case .volumeMissing:
            String(localized: "This session lives on an external disk. Connect the disk and the session will start on its own.")
        default:
            String(localized: "The folder may have been moved, renamed or deleted. Restore it, or change the project's folder in its settings.")
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            TablerIcon(name: "folder-off", size: 26, color: Theme.textDim)
            VStack(spacing: 6) {
                Text(headline)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text(path)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            Button("Try Again", action: onRetry)
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("session.missingFolder.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.missingFolder")
    }
}
