import Foundation

/// A line-per-event journal the app writes only under UI testing, so a test
/// can assert on the things no accessibility query reaches — text submitted
/// into a PTY, files written beside a project.
///
/// The path comes from the test itself (`UNCOIL_TEST_JOURNAL` in the launch
/// environment) because the two processes do not share a temporary directory:
/// the XCUITest runner is sandboxed into its own container and cannot read the
/// app's temp at all — a journal written there is real, present, and invisible
/// to every assertion. The unsandboxed app writing into the runner's container
/// is the one direction that works. With no path set, the state directory is
/// the fallback so a person can still read the journal after a manual run.
enum UITestJournal {
    static var url: URL? {
        if let path = ProcessInfo.processInfo.environment["UNCOIL_TEST_JOURNAL"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return LaunchConfig.shared.dataDirectoryOverride?
            .appendingPathComponent("submitted-text.log")
    }

    /// Appends one event. Newlines inside the payload are flattened so the
    /// journal stays one event per line.
    static func append(_ event: String, _ payload: String) {
        guard let url else { return }
        let line = "\(event)\t\(payload.replacingOccurrences(of: "\n", with: "⏎"))\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
