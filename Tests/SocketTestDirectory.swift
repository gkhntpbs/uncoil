import Foundation

/// A directory for a test's Unix socket that the kernel will accept.
///
/// `sun_path` holds 104 bytes on macOS, and the repository's `.build-cache`
/// is not always short enough: a checkout under `.uncoil-worktrees/<name>` on a
/// volume with a long name pushes `<dir>/runtime.sock` past it, `bind` fails
/// with `ENAMETOOLONG`, and every socket test waits out its timeout. The
/// preferred directory is kept whenever it fits; only an over-long one falls
/// back to a short one under `/tmp`, which the caller removes as before.
enum SocketTestDirectory {
    static let maxSocketPathBytes = 103

    static func make(preferred: URL, socketName: String) throws -> URL {
        let directory: URL
        if preferred.appendingPathComponent(socketName).path.utf8.count <= maxSocketPathBytes {
            directory = preferred
        } else {
            directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("uncoil-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
