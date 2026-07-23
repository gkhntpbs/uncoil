import SwiftUI
import SwiftTerm

/// Runs the provider's own browser-login flow (claude /login, codex login)
/// in a small embedded terminal, scoped to the selected account profile's
/// isolated config root. Credentials never touch Uncoil — the provider CLI
/// stores them itself.
struct LoginTerminalSheet: View {
    let profile: AccountProfile
    let onFinished: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProviderMark(provider: profile.provider, size: 13)
                Text("\(profile.provider.displayName) · \(profile.name) — Giriş")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("Akış tarayıcıyı açar; bitince bu pencereyi kapat.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.border)

            LoginTerminalHost(profile: profile, settings: settings)
                .frame(minHeight: 340)

            Divider().overlay(Theme.border)

            HStack {
                Spacer()
                Button("Kapat") {
                    onFinished()
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(10)
        }
        .frame(width: 640, height: 460)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login.sheet")
    }
}

private struct LoginTerminalHost: NSViewRepresentable {
    let profile: AccountProfile
    let settings: SettingsStore

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.nativeBackgroundColor = NSColor(Theme.bg)
        view.nativeForegroundColor = NSColor(Theme.text)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        let processEnv = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR"] {
            if let value = processEnv[key] {
                env.append("\(key)=\(value)")
            }
        }
        if let key = profile.isolationEnvironmentKey,
           let dir = profile.configDirectory(profilesRoot: settings.profilesRootURL) {
            env.append("\(key)=\(dir.path)")
        }

        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        var command = profile.provider.loginCommand ?? ""
        if let binary = settings.binaryPath(for: profile.provider),
           let commandName = profile.provider.launchCommand {
            command = command.replacingOccurrences(
                of: commandName,
                with: "\"\(binary)\"",
                options: .anchored
            )
        }
        view.startProcess(
            executable: shell,
            args: ["-l", "-i", "-c", "exec \(command)"],
            environment: env,
            execName: nil,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
