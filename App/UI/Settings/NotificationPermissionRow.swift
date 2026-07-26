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

    private var level: SettingsStatusLine.Level {
        switch authorization.status {
        case .granted: .ok
        case .provisional: .warning
        case .denied: .error
        case .notRequested, .unknown: .neutral
        }
    }

    var body: some View {
        AdaptiveRow {
            SettingsLabel(
                title: "macOS bildirim izni",
                detail: explanation,
                symbol: "bell.badge"
            )
        } control: {
            SettingsStatusLine(level: level, text: authorization.status.label)
                .settingsID("notifications.status")
        }

        if let error = authorization.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsActionRow(
            isWorking: isWorking,
            note: authorization.lastTestSentAt != nil ? "Test bildirimi gönderildi." : nil,
            noteLevel: .ok
        ) {
            if authorization.status.canRequest {
                Button("İzin İste") {
                    run { await authorization.request() }
                }
                .buttonStyle(.borderedProminent)
                .settingsID("notifications.request")
            } else if authorization.status == .denied {
                Button("Sistem Ayarları’nı Aç") {
                    authorization.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                .settingsID("notifications.openSystemSettings")
            }

            Button("Test Bildirimi Gönder") {
                run { await authorization.sendTestNotification() }
            }
            .settingsID("notifications.sendTest")

            Button("Durumu Yenile") {
                run { await authorization.refresh() }
            }
            .settingsID("notifications.refresh")
        }
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
