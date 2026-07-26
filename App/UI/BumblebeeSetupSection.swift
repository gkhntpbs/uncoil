import AppKit
import SwiftUI

/// What the Security screen shows when Bumblebee is not there.
///
/// One button does the whole thing: Uncoil fetches the newest release from the
/// project's own GitHub, checks it against the `checksums.txt` published with it,
/// and unpacks it into its tools directory. What it never does is run an install
/// script — only the release archive is downloaded, and nothing in it is executed
/// to install it. A binary the user already has can still be picked by hand.
struct BumblebeeSetupSection: View {
    /// Called after the binary set changes, so the screen re-reads its state.
    var onChange: () -> Void
    /// Asks the binary for its version and runs its self-test.
    var onVerify: (() async -> String)?

    @State private var locator = BumblebeeLocator.default()
    @State private var found: [BumblebeeBinary] = []
    @State private var detail: String?
    @State private var isInstalling = false
    @State private var phase: BumblebeeInstaller.Phase?
    @State private var isVerifying = false

    private var isInstalled: Bool { !found.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bumblebee install")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Text(
                    isInstalled
                        ? "Binary found; scans are run from the Security screen."
                        : "Bumblebee not found. Uncoil keeps running its own scan;"
                            + " Installing Bumblebee is your call."
                )
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TablerIcon(
                        name: isInstalled ? "circle-check" : "alert-circle",
                        size: 15,
                        color: isInstalled ? Theme.ok : Theme.warn
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isInstalled ? "Installed" : "Not installed")
                            .font(Theme.mono(.body, .medium))
                            .foregroundStyle(Theme.text)
                        Text(
                            found.first.map { "\($0.source.label): \($0.path)" }
                                ?? "Looked in: the app bundle, \(locator.managedPath), PATH"
                        )
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    }
                    Spacer()
                }
                .padding(12)

                if !isInstalled {
                    Divider().overlay(Theme.border)
                    VStack(alignment: .leading, spacing: 5) {
                        step(1, "Uncoil downloads the latest release of the \(BumblebeeInstaller.repository) repo.")
                        step(2, "Verified against the checksums.txt published with the same release; discarded on a mismatch.")
                        step(3, "The binary is unpacked under \(locator.managedPath) and asked for its version.")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                Divider().overlay(Theme.border)
                FlowRow(spacing: 9) {
                    Button(isInstalling ? "Downloading…" : (isInstalled ? "Download again" : "Download and install")) {
                        install()
                    }
                    .buttonStyle(isInstalled ? AnyButtonStyle(GhostButtonStyle()) : AnyButtonStyle(AccentButtonStyle()))
                    .disabled(isInstalling)
                    .accessibilityIdentifier("extensions.security.bumblebee.install")

                    Button("Choose the Binary…") { chooseBinary() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(isInstalling)
                        .accessibilityIdentifier("extensions.security.bumblebee.choose")

                    Button("Open the Folder") { revealManagedDirectory() }
                        .buttonStyle(GhostButtonStyle())

                    Button("Open the Repo") {
                        NSWorkspace.shared.open(BumblebeeInstaller.homepage)
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button("Re-audit") { refresh() }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.security.bumblebee.recheck")

                    if isInstalled, let onVerify {
                        Button(isVerifying ? "Verifying…" : "Verify the version") {
                            isVerifying = true
                            Task {
                                detail = await onVerify()
                                isVerifying = false
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(isVerifying)
                        .accessibilityIdentifier("extensions.security.bumblebee.verify")
                    }

                    if isInstalling {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                if let phase {
                    Divider().overlay(Theme.border)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(phase.label)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            if let fraction = phase.fraction {
                                Text("%\(Int(fraction * 100))")
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        // Determinate while the size is known, indeterminate for
                        // the steps that have no size to report.
                        if let fraction = phase.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(Theme.highlight)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(Theme.highlight)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("extensions.security.bumblebee.progress")
                }

                if let detail {
                    Divider().overlay(Theme.border)
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .panel()
        }
        .onAppear(perform: refresh)
        .accessibilityIdentifier("extensions.security.bumblebeeSetup")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.bg)
                .frame(width: 15, height: 15)
                .background(Theme.textDim, in: Circle())
            Text(text)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func refresh() {
        found = locator.available()
    }

    /// Downloads the newest release from the project's own GitHub, checks it
    /// against the checksums published with it, and puts it in place.
    private func install() {
        isInstalling = true
        detail = nil
        phase = .askingGitHub
        let installer = BumblebeeInstaller(destinationDirectory: locator.managedDirectory)
        Task {
            do {
                let installed = try await installer.install { step in
                    Task { @MainActor in phase = step }
                }
                detail = String(localized: "\(installed.releaseTag) installed: \(installed.path)")
                refresh()
                onChange()
            } catch {
                phase = nil
                detail = String(localized: "Could not install: \(error.localizedDescription)")
            }
            isInstalling = false
            // The finished bar stays for a moment, then the state row speaks.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !isInstalling { phase = nil }
        }
    }

    /// Copies a binary the user picked into Uncoil's tools directory. Nothing is
    /// downloaded and nothing is executed here.
    private func chooseBinary() {
        let picker = NSOpenPanel()
        picker.title = String(localized: "Choose the Bumblebee binary")
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            detail = String(localized: "The chosen file is not executable: \(url.lastPathComponent)")
            return
        }
        let destination = URL(fileURLWithPath: locator.managedPath)
        do {
            try FileManager.default.createDirectory(
                at: locator.managedDirectory, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path
            )
            detail = String(localized: "Copied: \(destination.path)")
            refresh()
            onChange()
        } catch {
            detail = String(localized: "Could not be copied: \(error.localizedDescription)")
        }
    }

    private func revealManagedDirectory() {
        try? FileManager.default.createDirectory(
            at: locator.managedDirectory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([locator.managedDirectory])
    }
}
