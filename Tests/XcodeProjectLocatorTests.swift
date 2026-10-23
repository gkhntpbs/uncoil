import XCTest
@testable import Uncoil

final class XcodeProjectLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-xcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ name: String, directory: Bool) throws {
        let url = root.appendingPathComponent(name)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data().write(to: url)
        }
    }

    func testPlainFolderHasNoXcodeTarget() throws {
        try make("index.js", directory: false)
        XCTAssertNil(XcodeProjectLocator.target(in: root))
        XCTAssertNil(PreferredEditor.xcode.openTarget(forDirectory: root))
        XCTAssertEqual(PreferredEditor.vscode.openTarget(forDirectory: root), root)
    }

    func testWorkspaceWinsOverProjectAndPackage() throws {
        try make("App.xcodeproj", directory: true)
        try make("App.xcworkspace", directory: true)
        try make("Package.swift", directory: false)
        XCTAssertEqual(XcodeProjectLocator.target(in: root)?.lastPathComponent, "App.xcworkspace")
    }

    func testProjectWinsOverPackage() throws {
        try make("App.xcodeproj", directory: true)
        try make("Package.swift", directory: false)
        XCTAssertEqual(XcodeProjectLocator.target(in: root)?.lastPathComponent, "App.xcodeproj")
    }

    func testPackageAlone() throws {
        try make("Package.swift", directory: false)
        XCTAssertEqual(XcodeProjectLocator.target(in: root)?.lastPathComponent, "Package.swift")
    }

    func testNestedProjectIsIgnored() throws {
        try make("vendor/Lib.xcodeproj", directory: true)
        XCTAssertNil(XcodeProjectLocator.target(in: root))
    }
}
