// uncoil-extension — the fixed command agent configs point at.
//
// Usage: uncoil-extension run <extension-id>
//
// Resolves the extension's active revision and entrypoint from Uncoil's
// launcher manifest, fetches its secrets from the running app (never from
// disk), and runs the real MCP server with stdin/stdout passed straight
// through so the agent's stdio transport is untouched. stderr is teed to a log
// file, and the exit code — or the signal that killed it — is recorded.

import Darwin
import Foundation

// MARK: - Paths

let environment = ProcessInfo.processInfo.environment
let storeRoot = environment["UNCOIL_EXTENSION_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".uncoil/extensions", isDirectory: true)
let manifestURL = storeRoot
    .appendingPathComponent("locks", isDirectory: true)
    .appendingPathComponent(ExtensionLaunchManifest.fileName)
let logDirectory = storeRoot.appendingPathComponent("logs", isDirectory: true)
let runsDirectory = storeRoot.appendingPathComponent("runs", isDirectory: true)

func fail(_ message: String, code: Int32 = 78) -> Never {
    FileHandle.standardError.write(Data("uncoil-extension: \(message)\n".utf8))
    exit(code)
}

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, arguments[0] == "run" else {
    fail("kullanım: uncoil-extension run <extension-id>", code: 64)
}
let extensionID = arguments[1]
let extraArguments = Array(arguments.dropFirst(2))

// MARK: - Manifest

guard let manifestData = FileManager.default.contents(atPath: manifestURL.path) else {
    fail("launcher manifest bulunamadı: \(manifestURL.path)")
}
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
guard let manifest = try? decoder.decode(ExtensionLaunchManifest.self, from: manifestData) else {
    fail("launcher manifest okunamadı")
}
guard manifest.version <= ExtensionLaunchManifest.currentVersion else {
    fail("launcher manifest sürümü \(manifest.version) bu launcher'dan yeni")
}
guard let entry = manifest.entry(id: extensionID) else {
    fail("bilinmeyen extension: \(extensionID)")
}
guard !entry.isQuarantined else {
    fail("\(extensionID) karantinada; Uncoil'de geri yükleyene kadar başlatılmaz", code: 77)
}

// The revision path is normally a symlink; resolving it now means a process
// started after an update runs the new revision, and one started before keeps
// the old files it already opened.
let revisionPath = URL(fileURLWithPath: entry.revisionPath).resolvingSymlinksInPath()
guard FileManager.default.fileExists(atPath: revisionPath.path) else {
    fail("aktif revision yok: \(entry.revisionPath)")
}
let entrypoint = revisionPath.appendingPathComponent(entry.entrypoint)
guard FileManager.default.fileExists(atPath: entrypoint.path) else {
    fail("entrypoint yok: \(entry.entrypoint)")
}

// MARK: - Runtime

func locate(_ name: String) -> String? {
    if name.hasPrefix("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let directories = (environment["PATH"]?.split(separator: ":").map(String.init) ?? []) + [
        "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]
    for directory in directories {
        let path = "\(directory)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

let executable: String
var childArguments: [String] = entry.arguments
if let interpreter = entry.runtime.interpreter {
    guard let resolved = locate(interpreter) else {
        fail("\(entry.runtime.rawValue) çalıştırıcısı bulunamadı: \(interpreter)")
    }
    executable = resolved
    childArguments.append(entrypoint.path)
} else {
    guard FileManager.default.isExecutableFile(atPath: entrypoint.path) else {
        fail("entrypoint çalıştırılabilir değil: \(entry.entrypoint)")
    }
    executable = entrypoint.path
}
childArguments.append(contentsOf: extraArguments)

// MARK: - Secrets

/// Asks the running app for this extension's secret environment. Values are
/// never read from disk; if Uncoil is not running the launcher says so rather
/// than starting a server that would fail confusingly later.
func fetchSecrets() -> [String: String] {
    guard !entry.secretKeys.isEmpty else { return [:] }
    let socketPath = environment["UNCOIL_EXTENSION_SECRET_SOCKET"]
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Uncoil/\(ExtensionSecretProtocol.socketName)"
            ).path

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("secret socket açılamadı") }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        fail("secret socket yolu çok uzun")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        fail("\(extensionID) secret gerektiriyor; Uncoil çalışmıyor")
    }

    guard var payload = try? JSONEncoder()
        .encode(ExtensionSecretProtocol.Request(extension_id: extensionID)) else {
        fail("secret isteği kodlanamadı")
    }
    payload.append(0x0A)
    payload.withUnsafeBytes { raw in
        _ = write(fd, raw.baseAddress, raw.count)
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !response.contains(0x0A) {
        let read = Darwin.read(fd, &buffer, buffer.count)
        guard read > 0 else { break }
        response.append(contentsOf: buffer[0..<read])
    }
    guard let newline = response.firstIndex(of: 0x0A),
          let decoded = try? JSONDecoder().decode(
            ExtensionSecretProtocol.Response.self,
            from: response.prefix(upTo: newline)
          ) else {
        fail("secret yanıtı okunamadı")
    }
    guard decoded.ok, let environment = decoded.environment else {
        fail("secret alınamadı: \(decoded.error ?? "bilinmeyen hata")")
    }
    return environment
}

var childEnvironment = environment
for (key, value) in entry.environment { childEnvironment[key] = value }
for (key, value) in fetchSecrets() { childEnvironment[key] = value }
childEnvironment["UNCOIL_EXTENSION_ID"] = extensionID
if let revisionID = entry.revisionID {
    childEnvironment["UNCOIL_EXTENSION_REVISION"] = revisionID
}

// MARK: - Logging

try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
let logURL = logDirectory.appendingPathComponent("\(entry.name).log")
if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
}
let logHandle = try? FileHandle(forWritingTo: logURL)
try? logHandle?.seekToEnd()

/// Secret values must never reach a log line, so anything that looks like one
/// is replaced before writing.
let secretValues = Set(
    entry.secretKeys.compactMap { childEnvironment[$0] }.filter { $0.count >= 4 }
)
func masked(_ text: String) -> String {
    var result = text
    for value in secretValues {
        result = result.replacingOccurrences(of: value, with: "«gizli»")
    }
    return result
}

func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    logHandle?.write(Data("\(stamp) \(masked(line))\n".utf8))
}

log("başlatılıyor: \(([executable] + childArguments).joined(separator: " "))")

// MARK: - Run

let process = Process()
process.executableURL = URL(fileURLWithPath: executable)
process.arguments = childArguments
process.currentDirectoryURL = revisionPath
process.environment = childEnvironment
// stdin/stdout pass straight through: the agent talks MCP over them.
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput

// stderr is teed so a failing server leaves a trace without hiding it from the
// agent that started it.
let errorPipe = Pipe()
process.standardError = errorPipe
errorPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    let text = String(decoding: data, as: UTF8.self)
    FileHandle.standardError.write(Data(masked(text).utf8))
    logHandle?.write(Data(masked(text).utf8))
}

do {
    try process.run()
} catch {
    log("başlatılamadı: \(error.localizedDescription)")
    fail("başlatılamadı: \(error.localizedDescription)", code: 126)
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let runURL = runsDirectory.appendingPathComponent("\(entry.name)-\(process.processIdentifier).json")

func writeRun(_ record: ExtensionRunRecord) {
    guard let data = try? encoder.encode(record) else { return }
    try? data.write(to: runURL, options: .atomic)
}

var record = ExtensionRunRecord(
    extensionID: extensionID,
    revisionID: entry.revisionID,
    pid: process.processIdentifier,
    startedAt: Date(),
    agent: environment["UNCOIL_EXTENSION_AGENT"]
)
writeRun(record)

// Forward a shutdown request so the child gets a chance to exit cleanly.
for forwarded in [SIGTERM, SIGINT] {
    signal(forwarded, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: forwarded, queue: .global())
    source.setEventHandler {
        kill(process.processIdentifier, forwarded)
    }
    source.resume()
    // Sources must outlive this loop; leaking them is intentional for a
    // process whose whole life is this one child.
    _ = Unmanaged.passRetained(source as AnyObject)
}

process.waitUntilExit()
errorPipe.fileHandleForReading.readabilityHandler = nil

record.endedAt = Date()
if process.terminationReason == .uncaughtSignal {
    record.signal = process.terminationStatus
    log("sinyalle sonlandı: \(process.terminationStatus)")
} else {
    record.exitCode = process.terminationStatus
    log("çıkış kodu: \(process.terminationStatus)")
}
writeRun(record)
try? logHandle?.close()
exit(process.terminationStatus)
