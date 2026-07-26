import AppKit
import SwiftUI

/// Settings → Entegrasyonlar → Sürücüler.
///
/// Both drivers are optional external programs, and installing one always needs
/// the user's say-so — these sections probe, report and offer, they never fetch
/// anything on their own. The probing and install logic is unchanged; only the
/// presentation is the settings window's.

// MARK: - Agent Browser

struct AgentBrowserSetupSection: View {
    @State private var status: DependencyInfo?
    @State private var isWorking = false
    @State private var resultMessage: String?
    @AppStorage(AgentBrowserAdapter.executablePreferenceKey)
    private var executablePath = ""

    var body: some View {
        Picker(selection: Binding(
            get: { executablePath },
            set: { newValue in
                executablePath = newValue
                resultMessage = "Yeni tarayıcı bir sonraki browser oturumunda kullanılacak."
                refresh()
            }
        )) {
            ForEach(AgentBrowserAdapter.installedBrowserChoices()) { browser in
                Text(browser.name).tag(browser.executablePath ?? "")
            }
        } label: {
            SettingsLabel(
                title: "Tarayıcı",
                detail: "Yalnızca bu Mac'te kurulu Chromium tabanlı tarayıcılar gösterilir.",
                symbol: "globe"
            )
        }
        .settingsID("permissions.browser.choice")

        AdaptiveRow {
            SettingsLabel(title: statusTitle, detail: status?.detail)
        } control: {
            SettingsStatusLine(
                level: status?.installed == true ? .ok : .warning,
                text: status?.installed == true ? "hazır" : "eksik"
            )
        }

        SettingsActionRow(isWorking: isWorking, note: resultMessage) {
            if status?.installed == true {
                Button("Başlat ve Doğrula") { startAndVerify() }
                    .buttonStyle(.borderedProminent)
                    .settingsID("permissions.browser.start")
            } else if status?.path != nil {
                Button("Chromium'u Kur") { installRuntime() }
                    .buttonStyle(.borderedProminent)
                    .settingsID("permissions.browser.install")
            } else {
                Button("Kurulum Rehberini Aç") { openInstallGuide() }
                    .buttonStyle(.borderedProminent)
                    .settingsID("permissions.browser.installGuide")
            }

            Button("Yenile") { refresh() }
                .settingsID("permissions.browser.refresh")
        }
        .task { await refreshStatus() }
    }

    private var statusTitle: String {
        guard let status else { return "Agent Browser denetleniyor" }
        guard status.path != nil else { return "Agent Browser CLI kurulu değil" }
        guard status.installed else { return "Chromium runtime gerekli" }
        return status.version ?? "Agent Browser hazır"
    }

    private func refresh() {
        Task { await refreshStatus() }
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

// MARK: - Computer Use

struct CuaDriverSetupSection: View {
    @State private var status: DependencyInfo?
    @State private var isWorking = false
    @State private var resultMessage: String?

    var body: some View {
        AdaptiveRow {
            SettingsLabel(
                title: statusTitle,
                detail: status?.detail ?? "Cua Driver kurulumu, daemon ve macOS izinlerini hazırlar.",
                symbol: "display"
            )
        } control: {
            SettingsStatusLine(
                level: status?.installed == true ? .ok : .warning,
                text: status?.installed == true ? "hazır" : "eksik"
            )
        }

        SettingsActionRow(isWorking: isWorking, note: resultMessage) {
            if status?.installed == true {
                Button("Başlat ve Doğrula") { startAndVerify() }
                    .buttonStyle(.borderedProminent)
                    .settingsID("permissions.cua.start")

                Button("İzinleri Ayarla") { grantPermissions() }
                    .settingsID("permissions.cua.permissions")
            } else {
                Button("Kurulum Rehberini Aç") { openInstallGuide() }
                    .buttonStyle(.borderedProminent)
                    .settingsID("permissions.cua.installGuide")
            }

            Button("Yenile") { refresh() }
                .settingsID("permissions.cua.refresh")
        }
        .task { await refreshStatus() }
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
        Task { await refreshStatus() }
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
