import SwiftUI

/// Settings → İzinler: lists pending and granted control-plane permission
/// requests (directional caller→target grants) with approve/deny/revoke
/// controls. Minimal and consistent with the rest of Settings.
struct PermissionsSettingsSection: View {
    @ObservedObject var service: PermissionService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(
                title: "Bekleyen istekler",
                empty: "Bekleyen izin isteği yok.",
                records: service.pending()
            ) { record in
                HStack(spacing: 8) {
                    Button("Onayla") { service.grant(id: record.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ok)
                    Button("Reddet") { service.deny(id: record.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.warn)
                }
            }

            group(
                title: "Verilen izinler",
                empty: "Verilmiş izin yok.",
                records: service.granted()
            ) { record in
                Button("İptal") { service.revoke(id: record.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder
    private func group(
        title: String, empty: String, records: [PermissionRequest],
        @ViewBuilder actions: @escaping (PermissionRequest) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            if records.isEmpty {
                Text(empty)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.grantKey)
                                    .font(Theme.mono(11.5, .medium))
                                    .foregroundStyle(Theme.text)
                                Text("kaynak \(short(record.fromSessionID)) → hedef \(short(record.targetSessionID))")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textFaint)
                            }
                            Spacer()
                            actions(record)
                                .font(Theme.mono(11))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                }
                .panel()
            }
        }
    }

    private func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return String(id.prefix(8))
    }
}
