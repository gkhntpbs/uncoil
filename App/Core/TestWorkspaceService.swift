import Foundation

enum TestWorkspaceError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

struct TestWorkspaceService {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func create() throws -> URL {
        let root = temporaryDirectory
            .appendingPathComponent("UncoilAcceptance-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try write("# Uncoil Acceptance Workspace\n", to: root.appendingPathComponent("README.md"))
        try write(
            ".build-cache/\n.uncoil-worktrees/\n.DS_Store\n",
            to: root.appendingPathComponent(".gitignore")
        )
        try createSwiftProject(at: root.appendingPathComponent("swift-sample", isDirectory: true))
        try createJavaScriptProject(at: root.appendingPathComponent("javascript-sample", isDirectory: true))
        try createScripts(at: root.appendingPathComponent("scripts", isDirectory: true))
        try createFakeMCP(at: root.appendingPathComponent("fake-mcp", isDirectory: true))
        try createManifest(at: root)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["add", "."], at: root)
        try runGit([
            "-c", "user.name=Uncoil Acceptance",
            "-c", "user.email=acceptance@uncoil.local",
            "commit", "-m", "chore: initialize acceptance workspace",
        ], at: root)
        return root
    }

    private func createSwiftProject(at root: URL) throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent("Sources/AcceptanceApp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(
            """
            // swift-tools-version: 5.10
            import PackageDescription

            let package = Package(
                name: "AcceptanceApp",
                platforms: [.macOS(.v14)],
                products: [.executable(name: "acceptance-app", targets: ["AcceptanceApp"])],
                targets: [.executableTarget(name: "AcceptanceApp")]
            )
            """,
            to: root.appendingPathComponent("Package.swift")
        )
        try write(
            "import Foundation\n\nprint(\"uncoil-swift-ok\")\n",
            to: root.appendingPathComponent("Sources/AcceptanceApp/main.swift")
        )
    }

    private func createJavaScriptProject(at root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try write(
            """
            {
              "name": "uncoil-acceptance-js",
              "private": true,
              "type": "module",
              "scripts": {
                "test": "node --test",
                "start": "node index.js"
              }
            }
            """,
            to: root.appendingPathComponent("package.json")
        )
        try write(
            "export const status = () => \"uncoil-js-ok\";\n\nconsole.log(status());\n",
            to: root.appendingPathComponent("index.js")
        )
        try write(
            """
            import test from "node:test";
            import assert from "node:assert/strict";
            import { status } from "./index.js";

            test("status", () => assert.equal(status(), "uncoil-js-ok"));
            """,
            to: root.appendingPathComponent("index.test.js")
        )
    }

    private func createScripts(at root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let scripts = [
            "test-pass.sh": "#!/bin/zsh\nprint 'acceptance-pass'\nexit 0\n",
            "test-fail.sh": "#!/bin/zsh\nprint -u2 'acceptance-fail'\nexit 1\n",
            "long-running.sh": "#!/bin/zsh\nwhile true; do print 'acceptance-heartbeat'; sleep 5; done\n",
            "large-output.sh": "#!/bin/zsh\nfor i in {1..10000}; do print \"acceptance-line-$i\"; done\n",
            "crash.sh": "#!/bin/zsh\nkill -SEGV $$\n",
        ]
        for (name, contents) in scripts {
            let url = root.appendingPathComponent(name)
            try write(contents, to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func createFakeMCP(at root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let server = root.appendingPathComponent("server.js")
        try write(
            """
            #!/usr/bin/env node
            import readline from "node:readline";

            const tools = [
              {
                name: "fixture_read",
                description: "Returns deterministic read-only fixture data.",
                inputSchema: { type: "object", additionalProperties: false },
                annotations: { readOnlyHint: true, destructiveHint: false }
              },
              {
                name: "fixture_write",
                description: "Simulates a permission-gated mutation.",
                inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"], additionalProperties: false },
                annotations: { readOnlyHint: false, destructiveHint: false }
              },
              {
                name: "fixture_delete",
                description: "Simulates a permission-gated destructive action.",
                inputSchema: { type: "object", properties: { target: { type: "string" } }, required: ["target"], additionalProperties: false },
                annotations: { readOnlyHint: false, destructiveHint: true }
              }
            ];

            const reply = (id, result) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\\n`);
            const input = readline.createInterface({ input: process.stdin });

            input.on("line", line => {
              let request;
              try {
                request = JSON.parse(line);
              } catch {
                return;
              }
              if (request.method === "initialize") {
                reply(request.id, {
                  protocolVersion: request.params?.protocolVersion ?? "2025-06-18",
                  capabilities: { tools: {} },
                  serverInfo: { name: "uncoil-acceptance-mcp", version: "1.0.0" }
                });
              } else if (request.method === "tools/list") {
                reply(request.id, { tools });
              } else if (request.method === "tools/call") {
                reply(request.id, {
                  content: [{ type: "text", text: JSON.stringify({ tool: request.params?.name, arguments: request.params?.arguments ?? {} }) }]
                });
              } else if (request.id !== undefined) {
                reply(request.id, {});
              }
            });
            """,
            to: server
        )
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        try write(
            """
            {
              "mcpServers": {
                "uncoil-acceptance": {
                  "command": "node",
                  "args": ["./fake-mcp/server.js"]
                }
              }
            }
            """,
            to: root.appendingPathComponent("config.example.json")
        )
    }

    private func createManifest(at root: URL) throws {
        try write(
            """
            {
              "commands": {
                "swift": "swift run --package-path swift-sample",
                "javascript": "npm --prefix javascript-sample test",
                "pass": "./scripts/test-pass.sh",
                "fail": "./scripts/test-fail.sh",
                "longRunning": "./scripts/long-running.sh",
                "largeOutput": "./scripts/large-output.sh",
                "crash": "./scripts/crash.sh"
              },
              "mcp": {
                "server": "./fake-mcp/server.js",
                "config": "./fake-mcp/config.example.json",
                "readOnlyTools": ["fixture_read"],
                "mutationTools": ["fixture_write"],
                "destructiveTools": ["fixture_delete"]
              }
            }
            """,
            to: root.appendingPathComponent("acceptance.json")
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TestWorkspaceError.commandFailed(
                message.isEmpty ? "The git command failed." : message
            )
        }
    }
}
