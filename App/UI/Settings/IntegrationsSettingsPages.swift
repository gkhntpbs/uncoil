import AppKit
import SwiftUI

// MARK: - GitHub

struct GitHubSettingsPage: View {
    @State private var loggedIn = KeychainStore.read(key: "github-token") != nil

    var body: some View {
        SettingsPage(
            title: "GitHub",
            subtitle: "Tarayıcıdan giriş yap; token yalnızca Keychain'de saklanır."
        ) {
            Section {
                GitHubLoginView(loggedIn: $loggedIn)
            }
        }
    }
}

/// Device-flow login: shows the one-time code, opens github.com in the
/// chosen browser, polls until authorized, stores the token in Keychain.
struct GitHubLoginView: View {
    @Binding var loggedIn: Bool
    @State private var phase: Phase = .idle
    @State private var username: String?
    @State private var pollTask: Task<Void, Never>?

    enum Phase: Equatable {
        case idle
        case requesting
        case waitingForBrowser(GitHubAuthService.DeviceCode)
        case failed(String)
    }

    var body: some View {
        Group {
            if loggedIn {
                loggedInRow
            } else {
                switch phase {
                case .idle, .failed:
                    startRow
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("GitHub'dan kod isteniyor…").foregroundStyle(Theme.textDim)
                    }
                case .waitingForBrowser(let code):
                    codeRow(code)
                }
                if case .failed(let message) = phase {
                    Text(message).font(.caption).foregroundStyle(Theme.danger)
                }
            }
        }
        .task {
            guard loggedIn, username == nil,
                  let token = KeychainStore.read(key: "github-token") else { return }
            username = await GitHubAuthService.fetchUsername(token: token)
        }
    }

    private var loggedInRow: some View {
        AdaptiveRow {
            SettingsStatusLine(level: .ok, text: username.map { "@\($0)" } ?? "Giriş yapıldı")
        } control: {
            Button("Çıkış Yap", role: .destructive) {
                KeychainStore.delete(key: "github-token")
                loggedIn = false
                username = nil
                phase = .idle
            }
        }
    }

    private var startRow: some View {
        AdaptiveRow {
            SettingsLabel(title: "GitHub hesabınla bağlan")
        } control: {
            Button("Tarayıcıdan Giriş Yap") { startLogin() }
                .buttonStyle(.borderedProminent)
                .settingsID("github.loginButton")
        }
    }

    private func codeRow(_ code: GitHubAuthService.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(code.userCode)
                    .font(.system(.title2, design: .monospaced).bold())
                    .kerning(2)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: {
                    Label("Kodu kopyala", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                Spacer()
                ProgressView().controlSize(.small)
            }

            Text("Kod panoya kopyalandı — aşağıdan bir tarayıcı seçip sayfaya yapıştır; onaylayınca otomatik bağlanır.")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Varsayılanda Aç") { NSWorkspace.shared.open(code.verificationURL) }
                    .buttonStyle(.borderedProminent)

                ForEach(BrowserApp.installed) { browser in
                    Button {
                        browser.open(code.verificationURL)
                    } label: {
                        if let icon = browser.appIcon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Text(browser.displayName)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("\(browser.displayName) ile aç")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        code.verificationURL.absoluteString, forType: .string
                    )
                } label: {
                    Label("Linki kopyala", systemImage: "link").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)

                Spacer()
                Button("Vazgeç") {
                    pollTask?.cancel()
                    phase = .idle
                }
            }
        }
    }

    private func startLogin() {
        phase = .requesting
        pollTask = Task {
            switch await GitHubAuthService.requestDeviceCode() {
            case .failure(let error):
                phase = .failed(error.errorDescription ?? "Bağlantı hatası")
            case .success(let code):
                // Copy the code and open the page right away.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                phase = .waitingForBrowser(code)

                switch await GitHubAuthService.pollForToken(code) {
                case .success(let token):
                    KeychainStore.save(key: "github-token", value: token)
                    username = await GitHubAuthService.fetchUsername(token: token)
                    loggedIn = true
                    phase = .idle
                case .failure(let error):
                    if !Task.isCancelled {
                        phase = .failed(error.errorDescription ?? "Giriş tamamlanamadı")
                    }
                }
            }
        }
    }
}

// MARK: - Drivers

struct DriversSettingsPage: View {
    var body: some View {
        SettingsPage(
            title: "Sürücüler",
            subtitle: "Agent Browser ve Computer Use bağlantılarını kur ve doğrula. Kurulum her zaman senin onayınla başlar."
        ) {
            Section("Agent Browser") {
                AgentBrowserSetupSection()
            }
            Section("Computer Use") {
                CuaDriverSetupSection()
            }
        }
        .settingsID("permissions.drivers")
    }
}
