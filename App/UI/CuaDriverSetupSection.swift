import AppKit
import SwiftUI

struct CuaDriverSetupSection: View {
    @State private var status: DependencyInfo?
    @State private var isWorking = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Computer Use Setup")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.text)
                Text("Cua Driver kurulumu, daemon ve macOS izinlerini hazırlar.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TablerIcon(
                        name: status?.installed == true ? "circle-check" : "alert-circle",
                        size: 15,
                        color: status?.installed == true ? Theme.ok : Theme.warn
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(Theme.mono(11.5, .medium))
                            .foregroundStyle(Theme.text)
                        if let detail = status?.detail, !detail.isEmpty {
                            Text(detail)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(4)
                        }
                    }
                    Spacer()
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(12)

                Divider().overlay(Theme.border)

                HStack(spacing: 8) {
                    if status?.installed == true {
                        Button("Başlat ve Doğrula") {
                            startAndVerify()
                        }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("settings.permissions.cua.start")

                        Button("İzinleri Ayarla") {
                            grantPermissions()
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("settings.permissions.cua.permissions")
                    } else {
                        Button("Kurulum Rehberini Aç") {
                            openInstallGuide()
                        }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("settings.permissions.cua.installGuide")
                    }

                    Button("Yenile") {
                        refresh()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("settings.permissions.cua.refresh")
                    .disabled(isWorking)

                    Spacer()
                }
                .padding(10)
            }
            .panel()

            if let resultMessage {
                Text(resultMessage)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await refreshStatus()
        }
    }

    private var statusTitle: String {
        guard let status else { return "Cua Driver denetleniyor" }
        guard status.installed else { return "Cua Driver kurulu değil" }
        if let version = status.version, !version.isEmpty {
            return version
        }
        return "Cua Driver kurulu"
    }

    private func refresh() {
        Task {
            await refreshStatus()
        }
    }

    private func startAndVerify() {
        guard !isWorking else { return }
        isWorking = true
        resultMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let adapter = CuaDriverAdapter()
                let outcome = adapter.perform(.listApps, session: "uncoil-setup")
                let message: String
                switch outcome {
                case .success:
                    message = "Cua Driver hazır ve araç çağrısı başarılı."
                case .failure(let error):
                    message = error.remedy.map { "\(error.message)\n\($0)" } ?? error.message
                }
                return (adapter.probe(), message)
            }.value
            status = result.0
            resultMessage = result.1
            isWorking = false
        }
    }

    private func grantPermissions() {
        guard !isWorking, let binary = status?.path else { return }
        isWorking = true
        resultMessage = nil
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                ProcessRunner.run(
                    executable: binary,
                    arguments: ["permissions", "grant"],
                    timeout: 120
                )
            }.value
            let stdout = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            resultMessage = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            await refreshStatus()
            isWorking = false
        }
    }

    private func refreshStatus() async {
        guard !isWorking else { return }
        isWorking = true
        status = await Task.detached(priority: .utility) {
            CuaDriverAdapter().probe()
        }.value
        isWorking = false
    }

    private func openInstallGuide() {
        guard let url = URL(string: "https://cua.ai/docs/how-to-guides/driver/install") else { return }
        NSWorkspace.shared.open(url)
    }
}
