import AppKit
import Foundation
import UserNotifications

/// Whether a permission may be answered straight from a notification banner.
/// Elevated-risk grants never can: the user has to see the request in Uncoil
/// first, so a single click on a banner can never widen an agent's reach.
enum PermissionNotificationPolicy {
    static let decidableCategory = "uncoil.permission.decidable"
    static let sensitiveCategory = "uncoil.permission.sensitive"
    static let allowOnceAction = "uncoil.permission.allowOnce"
    static let denyAction = "uncoil.permission.deny"
    static let openAction = "uncoil.permission.open"

    /// Unknown keys count as sensitive — fail safe, never fail open.
    static func isSensitive(grantKey: String) -> Bool {
        guard let entry = CapabilityCatalog.entry(for: grantKey) else { return true }
        return entry.risky
    }

    static func category(grantKey: String) -> String {
        isSensitive(grantKey: grantKey) ? sensitiveCategory : decidableCategory
    }

    static func body(grantKey: String, from: String, target: String?) -> String {
        let label = CapabilityCatalog.entry(for: grantKey)?.label ?? grantKey
        let caller = short(from)
        guard let target else { return "\(caller) → \(label)" }
        return "\(caller) → \(short(target)): \(label)"
    }

    static func short(_ id: String) -> String {
        String(id.prefix(8))
    }
}

/// Posts permission banners and routes what the user does with them: tapping
/// opens the session, and non-sensitive requests can be answered inline.
@MainActor
final class PermissionNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PermissionNotificationCenter()

    /// Injected when the control plane starts; nil in tests.
    weak var permissions: PermissionService?
    /// Resolves a session id string to the record the banner should open.
    var sessionResolver: ((String) -> SessionRecord?)?
    var notificationPrefs: () -> NotificationPrefs = { NotificationPrefs() }

    private var registered = false

    /// Registers the two categories and installs the delegate. Safe to call
    /// more than once.
    func activate() {
        guard !registered else { return }
        registered = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allowOnce = UNNotificationAction(
            identifier: PermissionNotificationPolicy.allowOnceAction,
            title: String(localized: "Allow Once"),
            options: []
        )
        let deny = UNNotificationAction(
            identifier: PermissionNotificationPolicy.denyAction,
            title: "Deny",
            options: []
        )
        let open = UNNotificationAction(
            identifier: PermissionNotificationPolicy.openAction,
            title: String(localized: "Open in Uncoil"),
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PermissionNotificationPolicy.decidableCategory,
                actions: [allowOnce, deny, open],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: PermissionNotificationPolicy.sensitiveCategory,
                actions: [open],
                intentIdentifiers: []
            ),
        ])
    }

    /// Banner for a control-plane permission request.
    func post(_ request: PermissionRequest, projectID: UUID?) {
        let prefs = notificationPrefs()
        guard prefs.enabled, prefs.notifyPermission else { return }
        let sensitive = PermissionNotificationPolicy.isSensitive(grantKey: request.grantKey)
        post(
            title: sensitive ? String(localized: "Permission request (sensitive)") : String(localized: "Permission request"),
            body: PermissionNotificationPolicy.body(
                grantKey: request.grantKey,
                from: request.fromSessionID,
                target: request.targetSessionID
            ),
            category: PermissionNotificationPolicy.category(grantKey: request.grantKey),
            userInfo: [
                "request_id": request.id,
                "session_id": request.targetSessionID ?? request.fromSessionID,
            ],
            projectID: projectID,
            prefs: prefs
        )
    }

    /// Banner for a Codex structured approval. Command, file and permission
    /// approvals are always answered in the session, never from the banner.
    func post(_ approval: CodexApprovalRequest, projectID: UUID?) {
        let prefs = notificationPrefs()
        guard prefs.enabled, prefs.notifyPermission else { return }
        post(
            title: String(localized: "Codex is waiting for approval"),
            body: approval.title,
            category: PermissionNotificationPolicy.sensitiveCategory,
            userInfo: ["session_id": approval.sessionID.uuidString],
            projectID: projectID,
            prefs: prefs
        )
    }

    private func post(
        title: String,
        body: String,
        category: String,
        userInfo: [String: String],
        projectID: UUID?,
        prefs: NotificationPrefs
    ) {
        if let projectID, !prefs.isEnabled(project: projectID) { return }
        // Not in tests: see AttentionNotifier.isRunningTests.
        guard !AttentionNotifier.isRunningTests else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = userInfo
            let priority = projectID.map { prefs.priority(project: $0) } ?? prefs.priority
            content.interruptionLevel = priority.interruptionLevel
            switch projectID.map({ prefs.sound(project: $0) }) ?? prefs.sound {
            case "none":
                break
            case "default":
                content.sound = .default
            case let name:
                content.sound = UNNotificationSound(
                    named: UNNotificationSoundName("\(name).aiff")
                )
            }
            center.add(UNNotificationRequest(
                identifier: userInfo["request_id"] ?? UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let requestID = userInfo["request_id"] as? String
        let sessionID = userInfo["session_id"] as? String
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            self.handle(
                action: action, category: category,
                requestID: requestID, sessionID: sessionID
            )
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func handle(action: String, category: String, requestID: String?, sessionID: String?) {
        let decidable = category == PermissionNotificationPolicy.decidableCategory
        switch action {
        case PermissionNotificationPolicy.allowOnceAction where decidable:
            if let requestID { permissions?.grant(id: requestID, scope: .once) }
        case PermissionNotificationPolicy.denyAction where decidable:
            if let requestID { permissions?.deny(id: requestID) }
        default:
            // Tapping the banner (or a sensitive request's only action) opens
            // the session so the decision is made with full context.
            open(sessionID: sessionID)
        }
    }

    private func open(sessionID: String?) {
        if let sessionID, let record = sessionResolver?(sessionID) {
            MainRoute.shared.request(.session(record.id))
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
