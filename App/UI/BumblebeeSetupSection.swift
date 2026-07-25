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
                Text("Bumblebee kurulumu")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text(
                    isInstalled
                        ? "Binary bulundu; taramalar Security ekranından çalıştırılır."
                        : "Bumblebee bulunamadı. Uncoil kendi taramasını yapmaya devam eder;"
                            + " Bumblebee'yi kurmak senin kararın."
                )
                .font(Theme.mono(10.5))
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
                        Text(isInstalled ? "Kurulu" : "Kurulu değil")
                            .font(Theme.mono(11.5, .medium))
                            .foregroundStyle(Theme.text)
                        Text(
                            found.first.map { "\($0.source.label): \($0.path)" }
                                ?? "Aranan yerler: uygulama paketi, \(locator.managedPath), PATH"
                        )
                        .font(Theme.mono(9.5))
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
                        step(1, "Uncoil, \(BumblebeeInstaller.repository) deposunun son sürümünü indirir.")
                        step(2, "Arşiv, aynı sürümle yayınlanan checksums.txt ile doğrulanır; eşleşmezse atılır.")
                        step(3, "Binary \(locator.managedPath) altına açılır ve sürümü sorulur.")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                Divider().overlay(Theme.border)
                FlowRow(spacing: 9) {
                    Button(isInstalling ? "İndiriliyor…" : (isInstalled ? "Yeniden indir" : "İndir ve kur")) {
                        install()
                    }
                    .buttonStyle(isInstalled ? AnyButtonStyle(GhostButtonStyle()) : AnyButtonStyle(AccentButtonStyle()))
                    .disabled(isInstalling)
                    .accessibilityIdentifier("extensions.security.bumblebee.install")

                    Button("Binary'yi seç…") { chooseBinary() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(isInstalling)
                        .accessibilityIdentifier("extensions.security.bumblebee.choose")

                    Button("Klasörü aç") { revealManagedDirectory() }
                        .buttonStyle(GhostButtonStyle())

                    Button("Depoyu aç") {
                        NSWorkspace.shared.open(BumblebeeInstaller.homepage)
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button("Yeniden denetle") { refresh() }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.security.bumblebee.recheck")

                    if isInstalled, let onVerify {
                        Button(isVerifying ? "Doğrulanıyor…" : "Sürümü doğrula") {
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
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            if let fraction = phase.fraction {
                                Text("%\(Int(fraction * 100))")
                                    .font(Theme.mono(9.5))
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
                        .font(Theme.mono(10))
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
                .font(Theme.mono(9.5, .semibold))
                .foregroundStyle(Theme.bg)
                .frame(width: 15, height: 15)
                .background(Theme.textDim, in: Circle())
            Text(text)
                .font(Theme.mono(10.5))
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
                detail = "\(installed.releaseTag) kuruldu: \(installed.path)"
                refresh()
                onChange()
            } catch {
                phase = nil
                detail = "Kurulamadı: \(error.localizedDescription)"
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
        picker.title = "Bumblebee binary'sini seç"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            detail = "Seçilen dosya çalıştırılabilir değil: \(url.lastPathComponent)"
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
            detail = "Kopyalandı: \(destination.path)"
            refresh()
            onChange()
        } catch {
            detail = "Kopyalanamadı: \(error.localizedDescription)"
        }
    }

    private func revealManagedDirectory() {
        try? FileManager.default.createDirectory(
            at: locator.managedDirectory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([locator.managedDirectory])
    }
}
