import XCTest
@testable import Uncoil

/// A Docker run's process state says almost nothing: `docker compose up` stays
/// alive and keeps printing while a container crash-loops, so the run reads as
/// healthy for as long as the failure lasts.
final class DockerStatusTests: XCTestCase {
    // MARK: - Parsing

    /// Compose v2 emits a JSON array; older builds and `docker ps` emit one
    /// object per line. Both are real, so both are read.
    func testAJSONArrayIsParsed() {
        let containers = DockerStatus.parse("""
        [{"Name":"web-1","Service":"web","State":"running","Health":"healthy"},
         {"Name":"db-1","Service":"db","State":"exited","Health":""}]
        """)
        XCTAssertEqual(containers.map(\.name), ["web-1", "db-1"])
        XCTAssertEqual(containers.first?.service, "web")
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertFalse(containers[1].isRunning)
    }

    func testOneObjectPerLineIsParsed() {
        let containers = DockerStatus.parse("""
        {"Name":"web-1","Service":"web","State":"running","Health":""}
        {"Name":"db-1","Service":"db","State":"running","Health":"healthy"}
        """)
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[1].health, "healthy")
    }

    /// `docker ps` calls the field `Names`, `docker compose ps` calls it `Name`.
    func testBothNameFieldsAreAccepted() {
        XCTAssertEqual(
            DockerStatus.parse(#"{"Names":"solo","State":"running"}"#).first?.name, "solo"
        )
        XCTAssertEqual(
            DockerStatus.parse(#"{"Name":"solo","State":"running"}"#).first?.name, "solo"
        )
    }

    /// Older Compose reports no separate state or health; both are folded into
    /// a human-readable `Status`.
    func testStateAndHealthAreRecoveredFromAStatusString() {
        let up = DockerStatus.parse(#"{"Name":"web","Status":"Up 2 minutes (unhealthy)"}"#)
        XCTAssertEqual(up.first?.state, "running")
        XCTAssertTrue(up.first?.isUnhealthy ?? false)

        let restarting = DockerStatus.parse(
            #"{"Name":"web","Status":"Restarting (1) 2 seconds ago"}"#
        )
        XCTAssertTrue(restarting.first?.isRestarting ?? false)

        let exited = DockerStatus.parse(#"{"Name":"web","Status":"Exited (1) 5 seconds ago"}"#)
        XCTAssertEqual(exited.first?.state, "exited")
    }

    /// One odd line must not hide every other container.
    func testAnUnparseableLineIsSkippedRatherThanFailingTheBatch() {
        let containers = DockerStatus.parse("""
        not json at all
        {"Name":"web-1","State":"running"}
        """)
        XCTAssertEqual(containers.map(\.name), ["web-1"])
    }

    func testEmptyOutputIsNoContainersNotAFailure() {
        XCTAssertTrue(DockerStatus.parse("").isEmpty)
        XCTAssertTrue(DockerStatus.parse("   \n  ").isEmpty)
    }

    // MARK: - Health

    /// The case this whole file exists for: the compose process is alive, so
    /// the run says "running", while a container loops.
    func testARestartingContainerIsReportedAsDegraded() {
        let health = DockerStatus.health(of: [
            DockerContainer(name: "web-1", service: "web", state: "running", health: ""),
            DockerContainer(name: "db-1", service: "db", state: "restarting", health: ""),
        ])
        XCTAssertTrue(health.isDegraded)
        XCTAssertTrue(health.label.contains("db-1"))
    }

    func testAnUnhealthyContainerIsReportedAsDegraded() {
        let health = DockerStatus.health(of: [
            DockerContainer(name: "web-1", service: "web", state: "running", health: "unhealthy"),
        ])
        XCTAssertTrue(health.isDegraded)
    }

    /// An image with no health check is not an unhealthy one.
    func testNoHealthCheckIsNotUnhealthy() {
        let health = DockerStatus.health(of: [
            DockerContainer(name: "web-1", service: "web", state: "running", health: ""),
        ])
        XCTAssertEqual(health, .allRunning)
    }

    func testSomeStoppedIsDegradedAndAllStoppedIsNot() {
        let partial = DockerStatus.health(of: [
            DockerContainer(name: "a", service: "", state: "running", health: ""),
            DockerContainer(name: "b", service: "", state: "exited", health: ""),
        ])
        XCTAssertTrue(partial.isDegraded)

        let none = DockerStatus.health(of: [
            DockerContainer(name: "a", service: "", state: "exited", health: ""),
        ])
        XCTAssertEqual(none, .allStopped)
    }

    func testNoContainersIsUnknownRatherThanStopped() {
        XCTAssertEqual(DockerStatus.health(of: []), .unknown)
    }

    // MARK: - Which runs are asked

    func testOnlyDockerCommandsAreProbed() {
        XCTAssertNotNil(DockerStatus.statusArguments(for: "docker compose up"))
        XCTAssertNotNil(DockerStatus.statusArguments(for: "docker-compose up"))
        XCTAssertNil(DockerStatus.statusArguments(for: "npm run dev"))
        XCTAssertNil(DockerStatus.statusArguments(for: "go run ."))
    }

    func testComposeIsAskedAboutItsWholeProject() throws {
        let arguments = try XCTUnwrap(DockerStatus.statusArguments(for: "docker compose up"))
        XCTAssertEqual(arguments.first, "compose")
        // --all, or a container that exited would simply vanish from the list
        // instead of being reported as stopped.
        XCTAssertTrue(arguments.contains("--all"))
    }

    func testAPlainRunIsLookedUpByTheNameItWasGiven() throws {
        let arguments = try XCTUnwrap(
            DockerStatus.statusArguments(for: "docker run --rm --name myapp -p 80:80 myapp")
        )
        XCTAssertTrue(arguments.contains("name=^myapp$"))
    }

    /// Without `--name` the container gets a random one, and guessing at the
    /// newest container would report someone else's.
    func testAnUnnamedRunIsNotProbedAtAll() {
        XCTAssertNil(DockerStatus.statusArguments(for: "docker run --rm myapp"))
    }
}

/// Opening a project on a particular area, for the session header's shortcut
/// to a run's logs.
@MainActor
final class ProjectAreaRouteTests: XCTestCase {
    func testARequestedAreaIsDelivered() {
        let route = ProjectAreaRoute()
        let project = UUID()
        route.request("run", for: project)
        XCTAssertEqual(route.take(for: project), "run")
    }

    /// Consumed once: otherwise every later visit to the project would be
    /// dragged back to Run instead of landing where the user left off.
    func testTheRequestIsConsumedRatherThanSticking() {
        let route = ProjectAreaRoute()
        let project = UUID()
        route.request("run", for: project)
        _ = route.take(for: project)
        XCTAssertNil(route.take(for: project))
    }

    func testOneProjectsRequestDoesNotMoveAnother() {
        let route = ProjectAreaRoute()
        let first = UUID()
        let second = UUID()
        route.request("run", for: first)
        XCTAssertNil(route.take(for: second))
        XCTAssertEqual(route.take(for: first), "run")
    }
}
