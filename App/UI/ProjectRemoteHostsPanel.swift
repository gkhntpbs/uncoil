import SwiftUI

/// The project's remote hosts, on its overview: which machines its agents are
/// told about, a terminal on each, and a menu to change the list.
///
/// The hosts themselves are managed once, globally, in Settings → SSH Hosts;
/// here a project only says which of them it uses. That is the whole of the
/// project side — a host is never configured twice.
struct ProjectRemoteHostsPanel: View {
    let project: Project
    @Binding var selection: MainSelection?
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    /// Read live, not from the `project` value the view was built with, so a
    /// toggle shows at once.
    private var current: Project {
        projectStore.projects.first { $0.id == project.id } ?? project
    }

    private var hosts: [SSHHost] { projectStore.sshHosts(for: current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                PanelHeading(title: String(localized: "Remote Hosts"), count: hosts.count)
                manageMenu
                    .padding(.trailing, 10)
                    .padding(.top, 4)
            }

            if hosts.isEmpty {
                Text(projectStore.sshHosts.isEmpty
                    ? String(localized: "No SSH hosts yet. Add or import them in Settings, then pick the ones this project's agents should know about.")
                    : String(localized: "None. Pick the hosts this project's agents should know about."))
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 1) {
                    ForEach(hosts) { host in
                        RemoteHostRow(host: host) { openTerminal(host) }
                    }
                }
                .padding(6)
                Text("Agents started here are told these hosts and connect with ssh <alias>.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .panel()
        .accessibilityIdentifier("dashboard.remoteHosts")
    }

    private var manageMenu: some View {
        Menu {
            ForEach(projectStore.sshHosts) { host in
                let isOn = current.sshHostAliases?.contains(host.alias) == true
                Button {
                    projectStore.setSSHHost(host.alias, associated: !isOn, with: project.id)
                } label: {
                    if isOn {
                        Label(host.alias, systemImage: "checkmark")
                    } else {
                        Text(host.alias)
                    }
                }
            }
            if !projectStore.sshHosts.isEmpty { Divider() }
            Button(String(localized: "Manage SSH Hosts…")) {
                Router.shared.go(to: .settings(pane: SettingsView.Pane.sshHosts.id))
                openWindow(.settings)
            }
        } label: {
            Text("Choose")
                .font(Theme.ui(.small, .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("dashboard.remoteHosts.manage")
    }

    private func openTerminal(_ host: SSHHost) {
        let record = SSHHostService.shared.openTerminal(
            alias: host.alias, in: current, store: projectStore, settings: settings)
        selection = .session(record.id)
    }
}

private struct RemoteHostRow: View {
    let host: SSHHost
    let openTerminal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(host.alias)
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(Theme.text)
                    SSHOriginBadge(origin: host.origin)
                }
                if let detail = [host.trimmedNote, host.destinationSummary].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(String(localized: "Open Terminal"), action: openTerminal)
                .buttonStyle(GhostButtonStyle())
                .opacity(hovering ? 1 : 0.6)
                .accessibilityIdentifier("dashboard.remoteHosts.terminal.\(host.alias)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .onHover { value in
            withAnimation(Theme.Motion.quick) { hovering = value }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The project settings tab: every known host with a switch for this project,
/// and the way to the global list where hosts are added and edited.
///
/// Works on a draft of the aliases, so the sheet's Cancel and Save mean the
/// same here as on its other tabs.
struct ProjectRemoteHostsSettings: View {
    @Binding var aliases: [String]
    let manageHosts: () -> Void
    @EnvironmentObject private var projectStore: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if projectStore.sshHosts.isEmpty {
                Text("No SSH hosts yet. Add or import them in Settings, then pick the ones this project's agents should know about.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 1) {
                    ForEach(projectStore.sshHosts) { host in
                        row(host)
                    }
                }
                Text(aliases.isEmpty
                    ? String(localized: "None selected: agents in this project are told nothing about remote hosts.")
                    : String(localized: "Agents started here are told these hosts and connect with ssh <alias>."))
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Manage SSH Hosts…"), action: manageHosts)
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("project.settings.remoteHosts.manage")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(host.alias)
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(Theme.text)
                    SSHOriginBadge(origin: host.origin)
                }
                if let detail = [host.trimmedNote, host.destinationSummary].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Space.tight)
            Toggle("", isOn: Binding(
                get: { aliases.contains(host.alias) },
                set: { on in
                    if on {
                        if !aliases.contains(host.alias) { aliases.append(host.alias) }
                    } else {
                        aliases.removeAll { $0 == host.alias }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, 8)
        .accessibilityIdentifier("project.settings.remoteHosts.\(host.alias)")
    }
}
