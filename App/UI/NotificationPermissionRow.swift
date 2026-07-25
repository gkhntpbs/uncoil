import SwiftUI

/// Whether macOS will let Uncoil notify at all, and what to do about it.
///
/// Every toggle under this row is meaningless while the system permission is
/// missing, and macOS only ever offers its prompt once — so the state belongs on
/// screen, with the one action that can change it and a way to prove delivery
/// without waiting for an agent to finish.
struct NotificationPermissionRow: View {
    @ObservedObject private var authorization = NotificationAuthorization.shared
    @State private var isWorking = false

    private var statusLevel: StatusBadge.Level {
        switch authorization.status {
        case .granted: .success
        case .provisional: .warning
        case .denied: .danger
        case .notRequested, .unknown: .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TablerIcon(name: "bell", size: 13, color: Theme.textDim)
                Text("macOS bildirim izni")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                Spacer()
                StatusBadge(text: authorization.status.label, level: statusLevel)
                    .accessibilityIdentifier("settings.notifications.status")
            }

            Text(explanation)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            if let error = authorization.lastError {
                Text(error)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if authorization.status.canRequest {
                    Button("İzin iste") {
                        run { await authorization.request() }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("settings.notifications.request")
                } else if authorization.status == .denied {
                    Button("Sistem Ayarları'nı aç") {
                        authorization.openSystemSettings()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("settings.notifications.openSystemSettings")
                }

                Button("Test bildirimi gönder") {
                    run { await authorization.sendTestNotification() }
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("settings.notifications.sendTest")

                Button("Durumu yenile") {
                    run { await authorization.refresh() }
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("settings.notifications.refresh")

                Spacer()

                if authorization.lastTestSentAt != nil {
                    Text("Test gönderildi")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.ok)
                        .accessibilityIdentifier("settings.notifications.testSent")
                }
            }
            .disabled(isWorking)
        }
        .padding(12)
        .panel()
        .task {
            // The user can change this in System Settings while Uncoil is open,
            // so the row reads the system rather than remembering an answer.
            await authorization.refresh()
        }
    }

    private var explanation: String {
        switch authorization.status {
        case .granted:
            "Bir ajan girdi beklediğinde ya da turunu bitirdiğinde bildirim gelir."
        case .provisional:
            "Bildirimler sessizce Bildirim Merkezi'ne düşer, banner çıkmaz."
        case .denied:
            "macOS izni reddedildi ve tekrar sormaz; yalnızca Sistem Ayarları'ndan açılabilir."
        case .notRequested:
            "macOS henüz sormadı. İzin verilmeden hiçbir bildirim gösterilemez."
        case .unknown:
            "Durum okunuyor…"
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
