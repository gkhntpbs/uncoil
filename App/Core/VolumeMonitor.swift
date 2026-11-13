import AppKit
import Combine
import Foundation

/// Whether the folders projects live in can actually be reached.
///
/// Projects kept on an external disk vanish when the disk is not connected.
/// Opening a session there used to hang on an empty terminal with nothing to
/// say why; this answers the question up front, and again every time a disk is
/// connected or ejected.
enum FolderAvailability: Equatable {
    case available
    /// The folder sits on a disk under `/Volumes` that is not mounted.
    case volumeMissing(volumeName: String)
    /// The disk is there (or the path is not on one) but the folder is gone.
    case folderMissing

    /// Pure: the answer for `path`, given a way to ask whether a path exists.
    static func of(
        _ path: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> FolderAvailability {
        if exists(path) { return .available }
        if let volume = volumeName(of: path), !exists("/Volumes/\(volume)") {
            return .volumeMissing(volumeName: volume)
        }
        return .folderMissing
    }

    /// `"SN770 1TB"` for `/Volumes/SN770 1TB/Developer/x`, nil off `/Volumes`.
    static func volumeName(of path: String) -> String? {
        let components = (path as NSString).standardizingPath
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return String(components[1])
    }
}

/// Re-checks project folders whenever a disk is mounted or unmounted, and
/// says which disks the projects need but cannot find.
@MainActor
final class VolumeMonitor: ObservableObject {
    static let shared = VolumeMonitor()

    /// Bumped on every mount/unmount, so views holding a "folder missing"
    /// answer ask again.
    @Published private(set) var revision = 0

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VolumeMonitor.shared.revision += 1 }
            })
        }
    }

    /// Disks that hold at least one project and are not connected, each with
    /// the names of the projects that live on it. Sorted for a stable message.
    func missingVolumes(for projects: [Project]) -> [(volume: String, projects: [String])] {
        var byVolume: [String: [String]] = [:]
        for project in projects {
            if case .volumeMissing(let volume) = FolderAvailability.of(project.rootPath) {
                byVolume[volume, default: []].append(project.name)
            }
        }
        return byVolume.keys.sorted().map { ($0, byVolume[$0] ?? []) }
    }

    /// Disks already announced, so several windows (and repeated checks) say
    /// it once. A disk that comes back is forgotten, so ejecting it again is
    /// announced again.
    private var announced: Set<String> = []

    /// The message to show now, or nil when there is nothing new to say.
    func takeAnnouncement(for projects: [Project]) -> String? {
        let missing = missingVolumes(for: projects)
        announced.formIntersection(Set(missing.map(\.volume)))
        let fresh = missing.filter { !announced.contains($0.volume) }
        guard !fresh.isEmpty else { return nil }
        announced.formUnion(fresh.map(\.volume))
        return fresh.map { entry in
            let names = entry.projects.sorted().joined(separator: ", ")
            return String(localized: "“\(entry.volume)” is not connected. Sessions in \(names) can't start until it is.")
        }.joined(separator: "\n\n")
    }
}
