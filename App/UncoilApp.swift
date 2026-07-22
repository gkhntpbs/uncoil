import SwiftUI
import AppKit

@main
struct UncoilApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(projectStore)
                .environmentObject(sessionStore)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Project…") {
                    NotificationCenter.default.post(name: .uncoilAddProject, object: nil)
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
            }
            CommandMenu("Claude") {
                Button("Hook'ları Kur") { runInstaller(install: true) }
                Button("Hook'ları Kaldır") { runInstaller(install: false) }
            }
        }
    }

    private func runInstaller(install: Bool) {
        let alert = NSAlert()
        do {
            if install {
                try HookInstaller.install()
                alert.messageText = "Claude hook'ları kuruldu"
                alert.informativeText = """
                ~/.claude/settings.json güncellendi (önce yedeği alındı). \
                Açık Claude oturumlarını yeniden başlattığında durum takibi başlar.
                """
            } else {
                try HookInstaller.uninstall()
                alert.messageText = "Claude hook'ları kaldırıldı"
                alert.informativeText = "Uncoil'e ait girdiler silindi; diğer hook'lara dokunulmadı."
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = install ? "Hook kurulamadı" : "Hook kaldırılamadı"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

extension Notification.Name {
    static let uncoilAddProject = Notification.Name("uncoil.addProject")
}
