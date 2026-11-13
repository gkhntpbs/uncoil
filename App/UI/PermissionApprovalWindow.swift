import AppKit
import Combine
import SwiftUI

@MainActor
final class PermissionApprovalWindow: NSObject, NSWindowDelegate {
    static let contentSize = NSSize(width: 520, height: 420)

    private let permissions: PermissionService
    private let projects: ProjectStore
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var window: NSWindow?
    private var displayedID: String?

    init(permissions: PermissionService, projects: ProjectStore) {
        self.permissions = permissions
        self.projects = projects
        super.init()
        observation = permissions.$requests.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.permissions.pruneExpiredIfNeeded()
                self?.refresh()
            }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let request = permissions.pending().first else {
            displayedID = nil
            window?.orderOut(nil)
            return
        }
        guard request.id != displayedID else { return }
        displayedID = request.id
        let panel: NSWindow
        if let window {
            panel = window
        } else {
            panel = PermissionPanel(
                contentRect: NSRect(origin: .zero, size: Self.contentSize),
                styleMask: [.borderless, .closable], backing: .buffered, defer: false)
            panel.title = String(localized: "Permission request")
            panel.identifier = NSUserInterfaceItemIdentifier("permission.approvalWindow")
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.minSize = Self.contentSize
            panel.maxSize = Self.contentSize
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        let content = NSHostingView(rootView: PermissionApprovalView(
            request: request,
            caller: sessionName(request.fromSessionID),
            target: request.targetSessionID.map(sessionName),
            decide: { [weak self] scope in
                guard let self else { return }
                if let scope {
                    permissions.grant(id: request.id, scope: scope)
                } else {
                    permissions.deny(id: request.id)
                }
            }))
        panel.contentView = content
        panel.setContentSize(Self.contentSize)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let displayedID { permissions.deny(id: displayedID) }
        return false
    }

    private func sessionName(_ raw: String) -> String {
        guard let record = projects.sessions.first(where: { $0.id.uuidString == raw }) else {
            return PermissionNotificationPolicy.short(raw)
        }
        let project = projects.projects.first { $0.id == record.projectID }?.name ?? ""
        return "\(record.displayTitle) · \(project) · \(raw.prefix(8))"
    }
}

private struct PermissionApprovalView: View {
    let request: PermissionRequest
    let caller: String
    let target: String?
    let decide: (PermissionRequest.Scope?) -> Void

    private var detail: String {
        switch request.grantKey {
        case "computer.inspect":
            String(localized: "The agent can read app windows, including any sensitive information they show.")
        case "computer.background_control":
            String(localized: "The agent can click and type into your real apps in the background, including apps containing sensitive information.")
        case "computer.foreground_control":
            String(localized: "The agent can bring an app window to the front and change your keyboard focus.")
        case "sessions.control":
            String(localized: "The agent can send prompts, interrupt work and resume the target session.")
        case "sessions.close":
            String(localized: "The agent can stop the target session.")
        case "sessions.approve":
            String(localized: "The agent can answer the target session's approvals on your behalf, allowing commands and file changes.")
        default:
            request.grantKey
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            Text("Allow this agent to continue?")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 48)
            VStack(spacing: 3) {
                Text(caller)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(caller)
                    .accessibilityIdentifier("permission.caller")
                if let target {
                    Text("Target: \(target)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .help(target)
                        .accessibilityIdentifier("permission.target")
                }
            }
            .foregroundStyle(.white.opacity(0.65))
            .frame(height: 36)
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(height: 76)
                .accessibilityIdentifier("permission.detail")
                .padding(.top, 12)
            Text("Manage approvals in Settings → Permissions.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(height: 28)
                .padding(.top, 8)
            Spacer(minLength: 18)
            HStack(spacing: 8) {
                Button("Don't Allow") { decide(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PermissionButtonStyle())
                    .frame(width: 116)
                    .accessibilityIdentifier("permission.deny")
                Button("Allow Until Revoked") { decide(.persistent) }
                    .buttonStyle(PermissionButtonStyle())
                    .frame(width: 196)
                    .accessibilityIdentifier("permission.allowPersistent")
                Button("Allow Once") { decide(.once) }
                    .buttonStyle(PermissionButtonStyle(primary: true))
                    .frame(width: 128)
                    .accessibilityIdentifier("permission.allowOnce")
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(width: PermissionApprovalWindow.contentSize.width,
               height: PermissionApprovalWindow.contentSize.height)
        .background(Color(red: 0.13, green: 0.13, blue: 0.13),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }
}

private final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct PermissionButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.7 : 0.95))
            .background(primary ? Color.accentColor : .white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
