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

    func testCompatibilityErrorRoundtrip() throws {
        let event = RuntimeEventMessage(
            ev: "error",
            version: RuntimeProtocol.version,
            minor: RuntimeProtocol.minor,
            errorCode: "incompatible_protocol",
            message: "Runtime protokolü uyumsuz."
        )
        let line = try XCTUnwrap(Data.runtimeLine(event))
        let decoded = try JSONDecoder().decode(RuntimeEventMessage.self, from: line.dropLast())
        XCTAssertEqual(decoded.errorCode, "incompatible_protocol")
        XCTAssertEqual(decoded.version, RuntimeProtocol.version)
    }

    func testHelloCarriesVersion() {
        XCTAssertEqual(RuntimeCommand.hello().version, RuntimeProtocol.version)
        XCTAssertEqual(RuntimeCommand.hello().minor, RuntimeProtocol.minor)
    }

    func testNegotiatesLowestCompatibleMinor() {
        XCTAssertEqual(
            RuntimeProtocol.negotiate(
                peerVersion: RuntimeProtocol.version,
                peerMinor: RuntimeProtocol.minor + 2
            ),
            .compatible(minor: RuntimeProtocol.minor)
        )
        XCTAssertEqual(
            RuntimeProtocol.negotiate(
                peerVersion: RuntimeProtocol.version,
                peerMinor: 0
            ),
            .compatible(minor: 0)
        )
    }

    func testRuntimeStorageLimitsAreBounded() {
        XCTAssertLessThanOrEqual(
            RuntimeProtocol.replayBufferLimit,
            RuntimeProtocol.replayDiskLimit
        )
        XCTAssertGreaterThan(RuntimeProtocol.logFileLimit, 0)
        XCTAssertGreaterThan(RuntimeProtocol.logGenerations, 0)
        XCTAssertGreaterThan(RuntimeProtocol.sessionIdleThreshold, 0)
    }

    func testRejectsMissingAndMismatchedMajorVersion() {
        guard case .incompatible(let missing) = RuntimeProtocol.negotiate(
            peerVersion: nil,
            peerMinor: nil
        ) else {
            return XCTFail("Eksik sürüm reddedilmeliydi.")
        }
        XCTAssertTrue(missing.contains("no version information"))

        guard case .incompatible(let mismatch) = RuntimeProtocol.negotiate(
            peerVersion: RuntimeProtocol.version + 1,
            peerMinor: 0
        ) else {
            return XCTFail("Major sürüm uyuşmazlığı reddedilmeliydi.")
        }
        XCTAssertTrue(mismatch.contains("mismatch"))
    }
}
