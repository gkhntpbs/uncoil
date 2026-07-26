import XCTest
@testable import Uncoil

/// The indicator has to tell "the control plane is down" apart from "it is up
/// and this session never reached it" — that second state is exactly what a
/// helper killed at exec looks like, and the whole point of showing it.
@MainActor
final class McpStatusTests: XCTestCase {
    private let session = UUID()

    override func tearDown() async throws {
        McpStatusStore.shared.forget(sessionID: session)
        McpStatusStore.shared.setServing(false)
    }

    func testNotServingMeansOffForEverySession() {
        McpStatusStore.shared.setServing(false)
        XCTAssertEqual(McpStatusStore.shared.state(for: session), .off)
    }

    func testServingWithoutContactIsWaiting() {
        McpStatusStore.shared.setServing(true)
        XCTAssertEqual(McpStatusStore.shared.state(for: session), .waiting)
    }

    func testContactMakesTheLinkConnected() {
        McpStatusStore.shared.setServing(true)
        let when = Date(timeIntervalSince1970: 1_000)
        McpStatusStore.shared.recordContact(sessionID: session, at: when)
        XCTAssertEqual(McpStatusStore.shared.state(for: session), .connected(since: when))
    }

    func testAnotherSessionsContactDoesNotCountAsThisOnes() {
        McpStatusStore.shared.setServing(true)
        McpStatusStore.shared.recordContact(sessionID: UUID())
        XCTAssertEqual(McpStatusStore.shared.state(for: session), .waiting)
    }
}
