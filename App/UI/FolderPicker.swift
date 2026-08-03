import AppKit
import SwiftUI

/// Choosing a folder, through the panel macOS already gives everyone.
///
/// Uncoil used to draw its own browser in a sheet. It looked like the rest of
/// the app and behaved like nothing else on the machine: no favourites, no
/// recents, no iCloud or network volumes, no ⌘⇧G to type a path, no search, and
/// none of the keyboard habits people already have. A file chooser is not a
/// place to have a house style.
@MainActor
enum FolderPicker {
    /// Runs the standard open panel as a sheet on `window`, or as a free
    /// standing modal when there is no window to hang it on.
    ///
    /// `startingAt` is where the panel opens; nil lets macOS restore wherever
    /// the user was last, which is almost always the better answer.
    static func choose(
        in window: NSWindow? = nil,
        startingAt directory: URL? = nil,
        prompt: String? = nil,
        onPick: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        if let directory { panel.directoryURL = directory }
        if let prompt { panel.prompt = prompt }

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }

        if let window = window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}

extension View {
    /// Opens the folder panel when `isPresented` becomes true, and clears the
    /// flag again immediately — the panel owns the interaction from there.
    ///
    /// Shaped like `.sheet(isPresented:)` so the call sites that used to raise
    /// Uncoil's own picker keep the state they already had.
    func folderPicker(
        isPresented: Binding<Bool>,
        startingAt directory: URL? = nil,
        prompt: String? = nil,
        onPick: @escaping (URL) -> Void
    ) -> some View {
        onChange(of: isPresented.wrappedValue) { _, presenting in
            guard presenting else { return }
            isPresented.wrappedValue = false
            FolderPicker.choose(startingAt: directory, prompt: prompt, onPick: onPick)
        }
    }
}
