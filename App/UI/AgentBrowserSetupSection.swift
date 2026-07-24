import AppKit
import SwiftUI

struct AgentBrowserSetupSection: View {
    @State private var status: DependencyInfo?
    @State private var isWorking = false
    @State private var resultMessage: String?
    @AppStorage(AgentBrowserAdapter.executablePreferenceKey)
    private var executablePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Browser Setup")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.text)
                Text("CLI ve uyumlu Chromium runtime kurulumunu hazırlar.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TablerIcon(name: "world", size: 15, color: Theme.textDim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tarayıcı")
                            .font(Theme.mono(11.5, .medium))
                            .foregroundStyle(Theme.text)
                        Text("Yalnızca bu Mac'te kurulu Chromium tabanlı tarayıcılar gösterilir.")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Menu {
                        ForEach(AgentBrowserAdapter.installedBrowserChoices()) { browser in
                            Button(browser.name) {
                                executablePath = browser.executablePath ?? ""
                                resultMessage = "Yeni tarayıcı bir sonraki browser oturumunda kullanılacak."
                                refresh()
                            }
                        }
                    } label: {
                        Text(selectedBrowserName)
                            .font(Theme.mono(10.5, .medium))
                            .foregroundStyle(Theme.text)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("settings.permissions.browser.choice")
                }
                .padding(12)

                Divider().overlay(Theme.border)

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
                        .accessibilityIdentifier("settings.permissions.browser.start")
                    } else if status?.path != nil {
                        Button("Chromium'u Kur") {
                            installRuntime()
                        }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("settings.permissions.browser.install")
                    } else {
                        Button("Kurulum Rehberini Aç") {
                            openInstallGuide()
                        }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("settings.permissions.browser.installGuide")
                    }

                    Button("Yenile") {
                        refresh()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("settings.permissions.browser.refresh")
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
        guard let status else { return "Agent Browser denetleniyor" }
        guard status.path != nil else { return "Agent Browser CLI kurulu değil" }
        guard status.installed else { return "Chromium runtime gerekli" }
        return status.version ?? "Agent Browser hazır"
    }

    private var selectedBrowserName: String {
        AgentBrowserAdapter.installedBrowserChoices()
            .first { ($0.executablePath ?? "") == executablePath }?.name
            ?? "Uncoil Chromium"
    }

    private func refresh() {
        Task {
            await refreshStatus()
        }
    }

    private func installRuntime() {
        guard !isWorking, let binary = status?.path,
              let invocation = AgentBrowserAdapter.installInvocation(binary: binary)
        else {
            resultMessage = "Node veya agent-browser Playwright CLI bulunamadı."
            return
        }
        isWorking = true
        resultMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(
                    at: AgentBrowserAdapter.defaultBrowserDirectory,
                    withIntermediateDirectories: true
                )
                return ProcessRunner.run(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    extraEnv: AgentBrowserAdapter.runtimeEnvironment(
                        nodePath: AgentBrowserAdapter.nodePath(binary: binary)
                    ),
                    timeout: 900
                )
            }.value
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            resultMessage = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            await refreshStatus()
            isWorking = false
        }
    }

    private func startAndVerify() {
        guard !isWorking else { return }
        isWorking = true
        resultMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let adapter = AgentBrowserAdapter()
                let opened = adapter.perform(
                    .open(url: "https://example.com"),
                    session: "uncoil-setup",
                    profileDir: nil
                )
                let message: String
                switch opened {
                case .success:
                    _ = adapter.perform(.stop, session: "uncoil-setup", profileDir: nil)
                    message = "Agent Browser hazır; Example Domain başarıyla açıldı."
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

    private func refreshStatus() async {
        guard !isWorking else { return }
        isWorking = true
        status = await Task.detached(priority: .utility) {
            AgentBrowserAdapter().probe()
        }.value
        isWorking = false
    }

    private func openInstallGuide() {
        guard let url = URL(string: "https://github.com/vercel-labs/agent-browser") else { return }
        NSWorkspace.shared.open(url)
    }
}
