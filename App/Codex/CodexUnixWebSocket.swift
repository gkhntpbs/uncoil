import CryptoKit
import Darwin
import Foundation

struct CodexWebSocketFrame: Equatable {
    let final: Bool
    let opcode: UInt8
    let payload: Data
}

enum CodexWebSocketFrameParser {
    static func parse(_ source: inout Data) -> CodexWebSocketFrame? {
        if source.startIndex != 0 {
            source = Data(source)
        }
        guard source.count >= 2 else { return nil }
        let first = source[0]
        let second = source[1]
        let final = first & 0x80 != 0
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard source.count >= 4 else { return nil }
            length = Int(source[2]) << 8 | Int(source[3])
            offset += 2
        } else if length == 127 {
            guard source.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 0..<8 {
                value = value << 8 | UInt64(source[2 + index])
            }
            guard value <= 16_777_216 else {
                source.removeAll()
                return nil
            }
            length = Int(value)
            offset += 8
        }
        let maskLength = masked ? 4 : 0
        guard source.count >= offset + maskLength + length else { return nil }
        var mask = [UInt8]()
        if masked {
            mask = Array(source[offset..<(offset + 4)])
            offset += 4
        }
        var payload = Data(source[offset..<(offset + length)])
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[(index - payload.startIndex) % 4]
            }
        }
        source.removeFirst(offset + length)
        return CodexWebSocketFrame(final: final, opcode: opcode, payload: payload)
    }
}

@MainActor
final class CodexUnixWebSocket {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let handle: FileHandle
    private var buffer = Data()
    private var fragmented = Data()
    private var closed = false

    static func connect(path: String) async throws -> CodexUnixWebSocket {
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try connectDescriptor(path: path)
        }.value
        return CodexUnixWebSocket(descriptor: descriptor)
    }

    private init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self else { return }
                if data.isEmpty {
                    self.finish()
                } else {
                    self.receive(data)
                }
            }
        }
    }

    func send(_ data: Data) throws {
        try sendFrame(opcode: 0x1, payload: data)
    }

    func close() {
        guard !closed else { return }
        try? sendFrame(opcode: 0x8, payload: Data())
        finish()
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while parseFrame() {}
    }

    private func parseFrame() -> Bool {
        guard let frame = CodexWebSocketFrameParser.parse(&buffer) else { return false }
        switch frame.opcode {
        case 0x0:
            fragmented.append(frame.payload)
            if frame.final {
                onMessage?(fragmented)
                fragmented.removeAll(keepingCapacity: true)
            }
        case 0x1:
            if frame.final {
                onMessage?(frame.payload)
            } else {
                fragmented = frame.payload
            }
        case 0x8:
            finish()
        case 0x9:
            try? sendFrame(opcode: 0xA, payload: frame.payload)
        default:
            break
        }
        return !closed
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        guard !closed else {
            throw CodexAppServerProtocolError.processLaunch("Codex app-server socket kapalı.")
        }
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let value = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        try handle.write(contentsOf: frame)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        handle.readabilityHandler = nil
        try? handle.close()
        onClose?()
    }

    nonisolated private static func connectDescriptor(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CodexAppServerProtocolError.processLaunch(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw CodexAppServerProtocolError.processLaunch("Codex app-server socket yolu çok uzun.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw CodexAppServerProtocolError.processLaunch(message)
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        let keyData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = keyData.base64EncodedString()
        let request = """
        GET /rpc HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r
        """ + "\n"
        try request.withCString { pointer in
            var remaining = strlen(pointer)
            var cursor = UnsafeRawPointer(pointer)
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                guard written > 0 else {
                    throw CodexAppServerProtocolError.processLaunch(String(cString: strerror(errno)))
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while response.range(of: Data("\r\n\r\n".utf8)) == nil, response.count < 16_384 {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else {
                Darwin.close(descriptor)
                throw CodexAppServerProtocolError.processLaunch("Codex app-server WebSocket handshake başarısız.")
            }
            response.append(contentsOf: chunk.prefix(count))
        }
        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: response[..<headerEnd.upperBound], encoding: .utf8),
              header.contains(" 101 ") else {
            Darwin.close(descriptor)
            throw CodexAppServerProtocolError.processLaunch("Codex app-server WebSocket upgrade reddedildi.")
        }
        let expected = Data(
            Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        guard header.lowercased().contains("sec-websocket-accept: \(expected.lowercased())") else {
            Darwin.close(descriptor)
            throw CodexAppServerProtocolError.processLaunch("Codex app-server WebSocket imzası geçersiz.")
        }
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return descriptor
    }
}
