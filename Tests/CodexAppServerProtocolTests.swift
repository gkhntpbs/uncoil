import XCTest
@testable import Uncoil

final class CodexAppServerProtocolTests: XCTestCase {
    func testParsesResponseNotificationAndServerRequest() throws {
        let response = try CodexAppServerMessage(
            data: Data(#"{"id":1,"result":{"thread":{"id":"thread-1"}}}"#.utf8)
        )
        XCTAssertEqual(response.id, .int(1))
        XCTAssertEqual(
            response.result?.objectValue?["thread"]?.objectValue?["id"]?.stringValue,
            "thread-1"
        )

        let notification = try CodexAppServerMessage(
            data: Data(#"{"method":"turn/started","params":{"threadId":"thread-1"}}"#.utf8)
        )
        XCTAssertEqual(notification.method, "turn/started")
        XCTAssertNil(notification.id)

        let approval = try CodexAppServerMessage(
            data: Data(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":"git status"}}"#.utf8)
        )
        XCTAssertEqual(approval.id, .string("approval-1"))
        XCTAssertEqual(approval.method, "item/commandExecution/requestApproval")
    }

    func testWritesProtocolJSONLines() throws {
        let request = try CodexAppServerJSON.data(
            id: 7,
            method: "thread/start",
            params: .object(["cwd": .string("/workspace")])
        )
        XCTAssertEqual(request.last, 0x0A)
        let parsed = try CodexAppServerMessage(data: request.dropLast())
        XCTAssertEqual(parsed.id, .int(7))
        XCTAssertEqual(parsed.method, "thread/start")

        let response = try CodexAppServerJSON.response(
            id: .string("approval-1"),
            result: .object(["decision": .string("accept")])
        )
        let responseObject = try JSONDecoder().decode(JSONValue.self, from: response.dropLast())
        XCTAssertEqual(
            responseObject.objectValue?["result"]?.objectValue?["decision"]?.stringValue,
            "accept"
        )
    }

    func testSchemaCompatibilityIsExplicit() {
        XCTAssertEqual(
            CodexAppServerCompatibility.evaluate("codex-cli 0.145.0"),
            CodexAppServerCompatibility(version: "0.145.0", isSupported: true)
        )
        XCTAssertFalse(
            CodexAppServerCompatibility.evaluate("codex-cli 0.146.0").isSupported
        )
        XCTAssertFalse(
            CodexAppServerCompatibility.evaluate("unknown").isSupported
        )
    }

    func testFormatsStructuredHistoryAndToolEvents() {
        let result: JSONValue = .object([
            "thread": .object([
                "turns": .array([
                    .object([
                        "items": .array([
                            .object([
                                "id": .string("user-1"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .object([
                                        "type": .string("text"),
                                        "text": .string("Durumu kontrol et"),
                                    ]),
                                ]),
                            ]),
                            .object([
                                "id": .string("agent-1"),
                                "type": .string("agentMessage"),
                                "text": .string("Tamamlandı"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let history = CodexStructuredFormatter.history(from: result)
        XCTAssertTrue(history.contains("Durumu kontrol et"))
        XCTAssertTrue(history.contains("Tamamlandı"))

        let command: JSONValue = .object([
            "id": .string("command-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
        ])
        XCTAssertTrue(CodexStructuredFormatter.startedItem(command)?.contains("swift test") == true)

        let mcp: JSONValue = .object([
            "id": .string("mcp-1"),
            "type": .string("mcpToolCall"),
            "server": .string("uncoil"),
            "tool": .string("uncoil_sessions"),
        ])
        XCTAssertTrue(CodexStructuredFormatter.startedItem(mcp)?.contains("uncoil_sessions") == true)
    }

    func testFormatsInitialResumePage() {
        let result: JSONValue = .object([
            "initialTurnsPage": .object([
                "data": .array([
                    .object([
                        "items": .array([
                            .object([
                                "id": .string("agent-1"),
                                "type": .string("agentMessage"),
                                "text": .string("Önceki yanıt"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        XCTAssertTrue(CodexStructuredFormatter.history(from: result).contains("Önceki yanıt"))
    }

    func testWebSocketParserHandlesConsecutiveFramesAfterRemoveFirst() {
        var data = Data([0x81, 0x02])
        data.append(contentsOf: [0x6F, 0x6B])
        data.append(contentsOf: [0x81, 0x7E, 0x00, 0x82])
        data.append(Data(repeating: 0x61, count: 130))

        let first = CodexWebSocketFrameParser.parse(&data)
        XCTAssertEqual(first?.payload, Data("ok".utf8))

        let second = CodexWebSocketFrameParser.parse(&data)
        XCTAssertEqual(second?.payload.count, 130)
        XCTAssertTrue(data.isEmpty)
    }

    func testWebSocketParserWaitsForCompleteFrame() {
        var data = Data([0x81, 0x05, 0x68])
        XCTAssertNil(CodexWebSocketFrameParser.parse(&data))
        data.append(contentsOf: [0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(
            CodexWebSocketFrameParser.parse(&data)?.payload,
            Data("hello".utf8)
        )
    }
}
