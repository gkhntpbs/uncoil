import SwiftUI

/// Settings → Integrations → SSH Hosts: the machines Uncoil knows, where each
/// one is defined, and which projects tell their agents about it.
///
/// Two kinds of host, and the page keeps saying which is which. A *System* host
/// is defined in the user's own SSH config; Uncoil remembers it and may add a
/// note, but its connection is edited where it lives. An *Uncoil* host is
/// written by Uncoil into `~/.ssh/uncoil_config`, and reaching it with plain
/// `ssh <alias>` needs that file included from `~/.ssh/config` — one line, added
/// only when the user says so.
struct SSHHostsSettingsPage: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var service = SSHHostService.shared
    @Environment(\.openWindow) private var openWindow

    @State private var editing: SSHHostEditorSheet.Target?
    @State private var importing = false
    @State private var confirmingInclude = false
    @State private var message: String?
    @State private var messageLevel: SettingsStatusLine.Level = .neutral

    private var hasUncoilHosts: Bool {
        projectStore.sshHosts.contains { $0.origin == .uncoil }
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "SSH Hosts"),
            subtitle: String(localized: "The machines your projects use. Associate a host with a project and the agents started there are told about it — they connect with plain ssh <alias>, as you would.")
        ) {
            Section("Hosts") {
                if projectStore.sshHosts.isEmpty {
                    SettingsNote(String(localized: "None yet. Import the hosts already in your SSH config, or add one below."))
                } else {
                    ForEach(projectStore.sshHosts) { host in
                        row(host)
                    }
                }
            }

            Section("Add") {
                SettingsActionRow(note: message, noteLevel: messageLevel) {
                    Button(String(localized: "Import from SSH Config…")) { importing = true }
                        .disabled(service.importable(store: projectStore).isEmpty)
                        .settingsID("ssh.import")
                    Button(String(localized: "New Host…")) {
                        editing = .new
                    }
                    .settingsID("ssh.new")
                }
                SettingsNote(service.importable(store: projectStore).isEmpty && !service.discovered.isEmpty
                    ? String(localized: "Every host in your SSH config is already here.")
                    : String(localized: "Importing leaves your SSH config as it is: Uncoil only remembers the host and which projects use it."))
            }

            Section("SSH Config") {
                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Uncoil's hosts in ssh"),
                        detail: includeDetail,
                        symbol: "doc.text"
                    )
                } control: {
                    HStack(spacing: 8) {
                        SettingsStatusLine(level: includeLevel, text: includeStatusText)
                        if service.includeStatus != .installed {
                            Button(String(localized: "Add Include…")) { confirmingInclude = true }
                                .settingsID("ssh.include")
                        }
                    }
                }
                SettingsNote(String(localized: "Hosts you add here are written to ~/.ssh/uncoil_config. Your own ~/.ssh/config is never rewritten; the one Include line is added only when you confirm it, with a copy saved to config.bak first."))
            }
        }
        .onAppear { service.rescan(store: projectStore) }
        .sheet(item: $editing) { target in
            SSHHostEditorSheet(target: target) { message = $0; messageLevel = .ok }
        }
        .sheet(isPresented: $importing) {
            SSHImportSheet { count in
                message = String(localized: "Imported \(count) hosts. Associate them with a project to tell its agents.")
                messageLevel = .ok
            }
        }
        .confirmationDialog(
            String(localized: "Add one line to ~/.ssh/config?"),
            isPresented: $confirmingInclude
        ) {
            Button(String(localized: "Add Include Line")) { installInclude() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Uncoil puts “Include uncoil_config” at the top of your SSH config, so ssh can find the hosts you add here. Nothing else in the file changes, and the current file is copied to ~/.ssh/config.bak first.")
        }
    }

    private var includeStatusText: String {
        switch service.includeStatus {
        case .installed: String(localized: "included")
        case .misplaced: String(localized: "not at the top")
        case .missing: String(localized: "not included")
        }
    }

    private var includeLevel: SettingsStatusLine.Level {
        switch service.includeStatus {
        case .installed: .ok
        case .misplaced, .missing: hasUncoilHosts ? .warning : .neutral
        }
    }

    private var includeDetail: String {
        switch service.includeStatus {
        case .installed:
            String(localized: "~/.ssh/config includes uncoil_config, so ssh <alias> reaches the hosts you add here.")
        case .misplaced:
            String(localized: "The Include line comes after a Host block, so it only applies inside that block. Move it to the top of ~/.ssh/config.")
        case .missing:
            String(localized: "Not included yet. Hosts imported from your config work without it; hosts you add here need it.")
        }
    }

    // MARK: - Rows

    private func row(_ host: SSHHost) -> some View {
        let users = projectStore.projects(usingSSHHost: host.alias)
        let missing = host.origin == .system && service.entry(for: host.alias) == nil
        return AdaptiveRow {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.alias)
                        .font(.body.monospaced())
                    SSHOriginBadge(origin: host.origin)
                    if missing {
                        Text("not in SSH config")
                            .font(.caption2)
                            .foregroundStyle(Theme.warn)
                    }
                }
                if let detail = [host.trimmedNote, host.destinationSummary].compactMap({ $0 }).first {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                Text(users.isEmpty
                    ? String(localized: "Not used by any project")
                    : String(localized: "Used by \(users.map(\.name).joined(separator: ", "))"))
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
            }
        } control: {
            HStack(spacing: 8) {
                openTerminalButton(host, users: users)
                Button(String(localized: "Edit")) { editing = .existing(host) }
                    .settingsID("ssh.edit.\(host.alias)")
                Menu {
                    if let entry = service.entry(for: host.alias), host.origin == .system {
                        Button(String(localized: "Reveal in Config File")) { service.revealInConfig(entry) }
                        Divider()
                    }
                    Button(
                        host.origin == .system ? String(localized: "Forget") : String(localized: "Delete"),
                        role: .destructive
                    ) {
                        service.delete(alias: host.alias, store: projectStore)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
    }

    /// A terminal belongs to a project, so the button asks which one when the
    /// host has several, and uses the one-off workspace when it has none.
    @ViewBuilder
    private func openTerminalButton(_ host: SSHHost, users: [Project]) -> some View {
        if users.count > 1 {
            Menu(String(localized: "Open Terminal")) {
                ForEach(users) { project in
                    Button(project.name) { openTerminal(host, in: project) }
                }
            }
            .fixedSize()
        } else {
            Button(String(localized: "Open Terminal")) {
                openTerminal(host, in: users.first ?? projectStore.ensureScratchProject())
            }
            .settingsID("ssh.terminal.\(host.alias)")
        }
    }

    private func openTerminal(_ host: SSHHost, in project: Project) {
        service.openTerminal(alias: host.alias, in: project, store: projectStore, settings: settings)
        openWindow(.main)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installInclude() {
        do {
            try service.installInclude()
            message = String(localized: "Added. ssh now reads ~/.ssh/uncoil_config; the previous file is in ~/.ssh/config.bak.")
            messageLevel = .ok
        } catch {
            message = error.localizedDescription
            messageLevel = .error
        }
    }
}

/// Where a host is defined, as a small capsule beside its alias.
struct SSHOriginBadge: View {
    let origin: SSHHost.Origin

    var body: some View {
        Text(origin == .system ? String(localized: "System") : String(localized: "Uncoil"))
            .font(Theme.ui(.micro, .medium))
            .foregroundStyle(origin == .system ? Theme.textDim : Theme.highlight)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (origin == .system ? Theme.textDim : Theme.highlight).opacity(0.14),
                in: Capsule()
            )
            .help(origin == .system
                ? String(localized: "Defined in your SSH config. Edit its connection there.")
                : String(localized: "Written by Uncoil to ~/.ssh/uncoil_config."))
    }
}

// MARK: - Editor

/// Adds or edits one host.
///
/// For an Uncoil host every field is editable and saving rewrites
/// `~/.ssh/uncoil_config`. For a system host the connection is shown but not
/// editable — it is the user's config's to say — and only the note, and which
/// projects use the host, are Uncoil's.
struct SSHHostEditorSheet: View {
    enum Target: Identifiable {
        case new
        case existing(SSHHost)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let host): host.alias
            }
        }
    }

    let target: Target
    var onSaved: (String) -> Void = { _ in }

    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var service = SSHHostService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var alias = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var note = ""
    @State private var projectIDs: Set<UUID> = []
    @State private var error: String?

    private var original: SSHHost? {
        if case .existing(let host) = target { return host }
        return nil
    }

    private var isSystem: Bool { original?.origin == .system }

    private var draft: SSHHost {
        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return SSHHost(
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            hostName: clean(hostName),
            user: clean(user),
            port: Int(port.trimmingCharacters(in: .whitespaces)),
            identityFile: clean(identityFile),
            note: clean(note),
            origin: original?.origin ?? .uncoil
        )
    }

    /// Checked as the alias is typed, so a collision is said before Save.
    private var conflict: String? {
        guard !isSystem, !draft.alias.isEmpty else { return nil }
        return service.validate(draft, replacing: original?.alias, store: projectStore)?.errorDescription
    }

    private var portIsValid: Bool {
        let text = port.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || (Int(text).map { (1...65535).contains($0) } ?? false)
    }

    var body: some View {
        SheetScaffold(
            title: original.map { String(localized: "Edit \($0.alias)") } ?? String(localized: "New SSH Host"),
            subtitle: isSystem
                ? String(localized: "Defined in your SSH config. Its connection is edited there; the note and projects are Uncoil's.")
                : String(localized: "Written to ~/.ssh/uncoil_config. Agents connect with ssh <alias>."),
            width: 520
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                    SheetField(label: String(localized: "Alias"), hint: conflict) {
                        SheetTextField(placeholder: "staging-api", text: $alias)
                            .disabled(isSystem)
                            .accessibilityIdentifier("ssh.editor.alias")
                    }
                    HStack(spacing: Theme.Space.snug) {
                        SheetField(label: String(localized: "Host name")) {
                            SheetTextField(placeholder: "10.0.0.5", text: $hostName).disabled(isSystem)
                        }
                        SheetField(label: String(localized: "Port"), hint: portIsValid ? nil : String(localized: "1–65535")) {
                            SheetTextField(placeholder: "22", text: $port).disabled(isSystem)
                        }
                        .frame(width: 90)
                    }
                    HStack(spacing: Theme.Space.snug) {
                        SheetField(label: String(localized: "User")) {
                            SheetTextField(placeholder: "deploy", text: $user).disabled(isSystem)
                        }
                        SheetField(label: String(localized: "Identity file")) {
                            SheetTextField(placeholder: "~/.ssh/id_ed25519", text: $identityFile).disabled(isSystem)
                        }
                    }
                    SheetField(
                        label: String(localized: "Note"),
                        hint: String(localized: "What the machine is for. Agents see this next to the alias.")
                    ) {
                        SheetTextField(placeholder: String(localized: "Staging environment"), text: $note)
                            .accessibilityIdentifier("ssh.editor.note")
                    }
                    SheetField(
                        label: String(localized: "Projects"),
                        hint: String(localized: "Agents started in these projects are told about this host.")
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(projectStore.projects.filter { !$0.isScratchWorkspace }) { project in
                                Toggle(project.name, isOn: Binding(
                                    get: { projectIDs.contains(project.id) },
                                    set: { if $0 { projectIDs.insert(project.id) } else { projectIDs.remove(project.id) } }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    if let error {
                        Text(error)
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(height: 400)
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            Button(String(localized: "Save")) { save() }
                .buttonStyle(AccentButtonStyle())
                .disabled(draft.alias.isEmpty || conflict != nil || !portIsValid)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ssh.editor.save")
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let host = original else { return }
        alias = host.alias
        hostName = host.hostName ?? ""
        user = host.user ?? ""
        port = host.port.map(String.init) ?? ""
        identityFile = host.identityFile ?? ""
        note = host.note ?? ""
        projectIDs = Set(projectStore.projects(usingSSHHost: host.alias).map(\.id))
    }

    private func save() {
        let host = draft
        do {
            try service.save(host, replacing: original?.alias, store: projectStore)
        } catch {
            self.error = error.localizedDescription
            return
        }
        for project in projectStore.projects where !project.isScratchWorkspace {
            let wanted = projectIDs.contains(project.id)
            let has = project.sshHostAliases?.contains(host.alias) == true
            if wanted != has {
                projectStore.setSSHHost(host.alias, associated: wanted, with: project.id)
            }
        }
        let needsInclude = host.origin == .uncoil && service.includeStatus != .installed
        onSaved(needsInclude
            ? String(localized: "Saved \(host.alias). Add the Include line below so ssh can reach it.")
            : String(localized: "Saved \(host.alias)."))
        dismiss()
    }
}

// MARK: - Import

/// The hosts in the user's SSH config Uncoil does not remember yet, as a
/// checklist. Importing copies nothing out of the config — it only lets Uncoil
/// name the host and associate it with projects.
struct SSHImportSheet: View {
    var onImported: (Int) -> Void

    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var service = SSHHostService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var candidates: [SSHConfigEntry] { service.importable(store: projectStore) }

    var body: some View {
        SheetScaffold(
            title: String(localized: "Import from SSH Config"),
            subtitle: String(localized: "Hosts found in ~/.ssh/config and the files it includes. They stay defined there.")
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if candidates.isEmpty {
                        Text("Nothing new to import.")
                            .font(Theme.ui(.body))
                            .foregroundStyle(Theme.textDim)
                    }
                    ForEach(candidates, id: \.alias) { entry in
                        SheetOptionRow(
                            title: entry.alias,
                            detail: entry.asHost.destinationSummary,
                            isSelected: selected.contains(entry.alias),
                            leading: {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(Theme.textDim)
                            }
                        ) {
                            if selected.contains(entry.alias) {
                                selected.remove(entry.alias)
                            } else {
                                selected.insert(entry.alias)
                            }
                        }
                        .accessibilityIdentifier("ssh.import.\(entry.alias)")
                    }
                }
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(height: 320)
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Button(selected.count == candidates.count
                ? String(localized: "Select None")
                : String(localized: "Select All")) {
                selected = selected.count == candidates.count ? [] : Set(candidates.map(\.alias))
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(candidates.isEmpty)
            Spacer()
            Button(String(localized: "Import")) {
                let chosen = candidates.filter { selected.contains($0.alias) }
                service.importHosts(chosen, store: projectStore)
                onImported(chosen.count)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(selected.isEmpty)
            .accessibilityIdentifier("ssh.import.confirm")
        }
    }
}
