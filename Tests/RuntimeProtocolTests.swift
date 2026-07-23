import XCTest
@testable import Uncoil

final class RuntimeProtocolTests: XCTestCase {
    func testCommandRoundtrip() throws {
        let command = RuntimeCommand(
            cmd: "launch", sid: "ABC", shell: "/bin/zsh",
            args: ["-l", "-i", "-c", "exec claude"],
            env: ["HOME=/Users/x"], cwd: "/tmp", cols: 120, rows: 40
        )
        let line = try XCTUnwrap(Data.runtimeLine(command))
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let decoded = try JSONDecoder().decode(RuntimeCommand.self, from: line.dropLast())
        XCTAssertEqual(decoded.cmd, "launch")
        XCTAssertEqual(decoded.sid, "ABC")
        XCTAssertEqual(decoded.args, ["-l", "-i", "-c", "exec claude"])
        XCTAssertEqual(decoded.cols, 120)
    }

    func testEventRoundtrip() throws {
        let event = RuntimeEventMessage(ev: "exited", sid: "ABC", code: 0)
        let line = try XCTUnwrap(Data.runtimeLine(event))
        let decoded = try JSONDecoder().decode(RuntimeEventMessage.self, from: line.dropLast())
        XCTAssertEqual(decoded.ev, "exited")
        XCTAssertEqual(decoded.code, 0)
    }

    func testHelloCarriesVersion() {
        XCTAssertEqual(RuntimeCommand.hello().version, RuntimeProtocol.version)
    }
}
