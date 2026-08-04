import Foundation
import XCTest
@testable import Uncoil

final class CuaDriverAdapterTests: XCTestCase {
    final class Runner: @unchecked Sendable {
        struct Invocation: Equatable {
            var executable: String
            var arguments: [String]
        }

        private let lock = NSLock()
        private(set) var invocations: [Invocation] = []
        var handler: @Sendable (String, [String]) -> ProcessRunner.Result

        init(handler: @escaping @Sendable (String, [String]) -> ProcessRunner.Result) {
            self.handler = handler
        }

        func call(_ executable: String, _ arguments: [String], _: TimeInterval) -> ProcessRunner.Result {
            lock.lock()
            invocations.append(Invocation(executable: executable, arguments: arguments))
            lock.unlock()
            return handler(executable, arguments)
        }
    }

    func testProbeUsesCurrentPermissionsCommand() {
        let runner = Runner { _, arguments in
            if arguments == ["--version"] {
                return self.result(stdout: "cua-driver 0.12.3 (aarch64-macos)\n")
            }
            return self.result(stdout: "Accessibility: ✅ granted\nScreen Recording: ✅ granted\n")
        }
        let adapter = adapter(runner)

        let info = adapter.probe()

        XCTAssertTrue(info.installed)
        XCTAssertEqual(info.version, "cua-driver 0.12.3 (aarch64-macos)")
        XCTAssertTrue(info.detail?.contains("Accessibility: ✅ granted") == true)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["--version"],
            ["permissions", "status"],
        ])
    }

    func testListAppsUsesCallToolJSONContract() throws {
        let runner = Runner { _, arguments in
            XCTAssertEqual(Array(arguments.prefix(2)), ["call", "list_apps"])
            return self.result(stdout: #"{"apps":[{"bundle_id":"com.gokhantopbas.uncoil","pid":42}]}"#)
        }
        let adapter = adapter(runner)

        let output = try adapter.perform(.listApps, session: "session-1").get()

        guard case .object(let object) = output.externalContent,
              case .array(let apps)? = object["apps"] else {
            return XCTFail("missing apps")
        }
        XCTAssertEqual(apps.count, 1)
    }

    func testInspectWindowResolvesBundlePIDAndWindow() throws {
        let runner = Runner { _, arguments in
            switch Array(arguments.prefix(2)) {
            case ["call", "list_apps"]:
                return self.result(stdout: #"{"apps":[{"bundle_id":"com.gokhantopbas.uncoil","pid":42,"running":true}]}"#)
            case ["call", "list_windows"]:
                return self.result(stdout: #"{"windows":[{"window_id":77,"pid":42,"title":"Uncoil"}]}"#)
            case ["call", "get_window_state"]:
                return self.result(stdout: #"{"pid":42,"window_id":77,"elements":[]}"#)
            default:
                return self.result(exitCode: 1, stderr: "unexpected command")
            }
        }
        let adapter = adapter(runner)

        let output = try adapter.perform(
            .inspectWindow(bundleID: "com.gokhantopbas.uncoil", windowID: 77),
            session: "session-1"
        ).get()

        guard case .object(let window) = output.externalContent else {
            return XCTFail("missing window")
        }
        XCTAssertEqual(window["bundle_id"]?.stringValue, "com.gokhantopbas.uncoil")
        XCTAssertEqual(window["pid"]?.intValue, 42)
        XCTAssertEqual(window["window_id"]?.intValue, 77)
        XCTAssertNotNil(window["state"])
    }

    func testInspectWindowPrefersVisibleLargestWindow() throws {
        let runner = Runner { _, arguments in
            switch Array(arguments.prefix(2)) {
            case ["call", "list_apps"]:
                return self.result(stdout: #"{"apps":[{"bundle_id":"com.gokhantopbas.uncoil","pid":42}]}"#)
            case ["call", "list_windows"]:
                return self.result(stdout: #"{"windows":[{"window_id":88,"pid":42,"title":"Settings","is_on_screen":false,"bounds":{"width":660,"height":652}},{"window_id":77,"pid":42,"title":"Uncoil","is_on_screen":true,"bounds":{"width":1100,"height":720}}]}"#)
            case ["call", "get_window_state"]:
                return self.result(stdout: #"{"pid":42,"window_id":77,"elements":[]}"#)
            default:
                return self.result(exitCode: 1, stderr: "unexpected command")
            }
        }
        let adapter = adapter(runner)

        let output = try adapter.perform(
            .inspectWindow(bundleID: "com.gokhantopbas.uncoil", windowID: nil),
            session: "session-1"
        ).get()

        guard case .object(let window) = output.externalContent else {
            return XCTFail("missing window")
        }
        XCTAssertEqual(window["window_id"]?.intValue, 77)
    }

    func testClickUsesElementIndex() throws {
        let runner = Runner { _, arguments in
            XCTAssertEqual(Array(arguments.prefix(2)), ["call", "click"])
            guard let data = arguments.last?.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let object) = value else {
                return self.result(exitCode: 1, stderr: "invalid arguments")
            }
            XCTAssertEqual(object["element_index"]?.intValue, 11)
            XCTAssertNil(object["x"])
            XCTAssertNil(object["y"])
            return self.result(stdout: #"{"effect":"clicked"}"#)
        }
        let adapter = adapter(runner)
        let window = WindowTarget(bundleID: "net.whatsapp.WhatsApp", pid: 42, windowID: 77, title: "WhatsApp")

        _ = try adapter.perform(
            .click(window: window, target: .element(index: 11)),
            session: "session-1"
        ).get()
    }

    func testTypeUsesElementIndex() throws {
        let runner = Runner { _, arguments in
            XCTAssertEqual(Array(arguments.prefix(2)), ["call", "type_text"])
            guard let data = arguments.last?.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let object) = value else {
                return self.result(exitCode: 1, stderr: "invalid arguments")
            }
            XCTAssertEqual(object["element_index"]?.intValue, 19)
            XCTAssertEqual(object["text"]?.stringValue, "deneme mesajı")
            return self.result(stdout: #"{"effect":"typed"}"#)
        }
        let adapter = adapter(runner)
        let window = WindowTarget(bundleID: "net.whatsapp.WhatsApp", pid: 42, windowID: 77, title: "WhatsApp")

        _ = try adapter.perform(
            .type(window: window, text: "deneme mesajı", target: .element(index: 19)),
            session: "session-1"
        ).get()
    }

    func testHotkeySplitsCurrentKeyArray() throws {
        let runner = Runner { _, arguments in
            XCTAssertEqual(Array(arguments.prefix(2)), ["call", "hotkey"])
            guard let data = arguments.last?.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let object) = value,
                  case .array(let keys)? = object["keys"] else {
                return self.result(exitCode: 1, stderr: "invalid arguments")
            }
            XCTAssertEqual(keys.compactMap(\.stringValue), ["cmd", "shift", "p"])
            return self.result(stdout: #"{"effect":"unverifiable"}"#)
        }
        let adapter = adapter(runner)
        let window = WindowTarget(bundleID: "com.gokhantopbas.uncoil", pid: 42, windowID: 77, title: "Uncoil")

        _ = try adapter.perform(
            .hotkey(window: window, keys: "cmd+shift+p"),
            session: "session-1"
        ).get()
    }

    func testToolCallStartsDaemonAndRetries() throws {
        final class State: @unchecked Sendable {
            var started = false
        }
        let state = State()
        let runner = Runner { executable, arguments in
            if executable == "/usr/bin/open" {
                state.started = true
                return self.result()
            }
            if arguments == ["permissions", "status"] {
                return self.result(stdout: state.started ? "Accessibility: ✅ granted" : "daemon is not running")
            }
            if Array(arguments.prefix(2)) == ["call", "list_apps"] {
                return state.started
                    ? self.result(stdout: #"{"apps":[]}"#)
                    : self.result(exitCode: 1, stderr: "Cua Driver daemon is not running")
            }
            return self.result()
        }
        let adapter = adapter(runner)

        _ = try adapter.perform(.listApps, session: "session-1").get()

        XCTAssertTrue(state.started)
        XCTAssertTrue(runner.invocations.contains {
            $0.executable == "/usr/bin/open"
                && $0.arguments == ["-n", "-g", "-a", "CuaDriver", "--args", "serve"]
        })
        XCTAssertEqual(runner.invocations.filter {
            Array($0.arguments.prefix(2)) == ["call", "list_apps"]
        }.count, 2)
    }

    private func adapter(_ runner: Runner) -> CuaDriverAdapter {
        CuaDriverAdapter(
            resolver: { "/fake/cua-driver" },
            run: { executable, arguments, timeout in
                runner.call(executable, arguments, timeout)
            }
        )
    }

    private func result(
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> ProcessRunner.Result {
        ProcessRunner.Result(
            exitCode: exitCode,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            timedOut: false,
            truncated: false,
            launchError: nil
        )
    }
}
