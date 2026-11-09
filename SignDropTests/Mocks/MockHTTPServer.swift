import CryptoKit
import Foundation
import Network

final class MockHTTPServer {
    struct Request {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let bodyFile: URL?

        var pathParts: [String] {
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")
        }

        var body: Data {
            bodyFile.flatMap { try? Data(contentsOf: $0) } ?? Data()
        }

        var bodyText: String {
            String(decoding: body, as: UTF8.self)
        }

        var bodyJSON: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    struct Response {
        let status: Int
        let body: Data
        let contentType: String

        static func text(_ status: Int, _ text: String, contentType: String = "text/plain") -> Response {
            Response(status: status, body: Data(text.utf8), contentType: contentType)
        }

        static func json(_ status: Int, _ object: Any) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, body: body, contentType: "application/json")
        }

        static func data(_ status: Int, _ body: Data) -> Response {
            Response(status: status, body: body, contentType: "application/octet-stream")
        }
    }

    private struct Head {
        let method: String
        let target: String
        let headers: [String: String]

        var contentLength: Int {
            Int(headers["content-length"] ?? "") ?? 0
        }

        var isWebSocketUpgrade: Bool {
            headers["upgrade"]?.lowercased() == "websocket"
        }

        func request(bodyFile: URL?) -> Request {
            let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            return Request(method: method, path: String(parts.first ?? ""), query: parts.count > 1 ? String(parts[1]) : "", headers: headers, bodyFile: bodyFile)
        }
    }

    var handleRequest: (Request) -> Response? = { _ in .text(404, "Not found") }
    var shouldIgnoreBody: (Request) -> Bool = { _ in false }
    var handleSocket: (MockWebSocket) -> Void = { _ in }
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "MockHTTPServer")
    private let spoolDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MockHTTPServer-\(UUID().uuidString)")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: spoolDirectory)
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            begin(connection, head: Self.parse(text), rest: Data(buffer[end.upperBound...]))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readHead(connection, buffer: buffer)
                }
                return
            }
            readHead(connection, buffer: buffer + data)
        }
    }

    private static func parse(_ text: String) -> Head {
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(method: requestLine.first.map(String.init) ?? "", target: requestLine.count > 1 ? String(requestLine[1]) : "", headers: headers)
    }

    private func begin(_ connection: NWConnection, head: Head, rest: Data) {
        if head.isWebSocketUpgrade {
            upgrade(connection, head: head, rest: rest)
        } else if head.contentLength == 0 || shouldIgnoreBody(head.request(bodyFile: nil)) {
            respond(connection, head: head, bodyFile: nil, rest: rest)
        } else {
            let file = spoolDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: file) else {
                connection.cancel()
                return
            }
            spool(connection, head: head, file: file, writer: writer, remaining: head.contentLength, pending: rest)
        }
    }

    private func spool(_ connection: NWConnection, head: Head, file: URL, writer: FileHandle, remaining: Int, pending: Data) {
        let used = pending.prefix(remaining)
        try? writer.write(contentsOf: used)
        let left = remaining - used.count
        guard left > 0 else {
            try? writer.close()
            respond(connection, head: head, bodyFile: file, rest: Data(pending.dropFirst(used.count)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if isComplete || error != nil {
                    try? writer.close()
                    try? FileManager.default.removeItem(at: file)
                    connection.cancel()
                } else {
                    spool(connection, head: head, file: file, writer: writer, remaining: left, pending: Data())
                }
                return
            }
            spool(connection, head: head, file: file, writer: writer, remaining: left, pending: data)
        }
    }

    private func respond(_ connection: NWConnection, head: Head, bodyFile: URL?, rest: Data) {
        let response = handleRequest(head.request(bodyFile: bodyFile))
        if let bodyFile {
            try? FileManager.default.removeItem(at: bodyFile)
        }
        guard let response else { return }
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            self?.readHead(connection, buffer: rest)
        })
    }

    private func upgrade(_ connection: NWConnection, head: Head, rest: Data) {
        let key = (head.headers["sec-websocket-key"] ?? "") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(key.utf8))).base64EncodedString()
        let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let socket = MockWebSocket(path: head.request(bodyFile: nil).path, connection: connection, buffer: rest)
        handleSocket(socket)
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in socket.start() })
    }
}

final class MockWebSocket {
    enum Message: Equatable {
        case text(String)
        case binary(Data)
    }

    private struct Frame {
        let opcode: UInt8
        let isFinal: Bool
        let payload: Data
    }

    let path: String
    var onMessage: (Message) -> Void = { _ in }
    var onClose: (Int?, String?) -> Void = { _, _ in }
    private let connection: NWConnection
    private var buffer: Data
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var isFinished = false

    fileprivate init(path: String, connection: NWConnection, buffer: Data) {
        self.path = path
        self.connection = connection
        self.buffer = buffer
    }

    func send(_ text: String) {
        sendFrame(opcode: 1, payload: Data(text.utf8))
    }

    fileprivate func start() {
        parseFrames()
        receive()
    }

    private func receive() {
        guard !isFinished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 21) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
                parseFrames()
            }
            if isComplete || error != nil {
                finish(code: nil, reason: nil)
            } else {
                receive()
            }
        }
    }

    private func parseFrames() {
        while !isFinished, let frame = nextFrame() {
            handle(frame)
        }
    }

    private func nextFrame() -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let first = buffer[start]
        let second = buffer[start + 1]
        var length = Int(second & 0x7f)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = (2...9).reduce(0) { $0 << 8 | Int(buffer[start + $1]) }
            offset = 10
        }
        let isMasked = second & 0x80 != 0
        let maskLength = isMasked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        var payload = Data(buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
        if isMasked {
            let mask = Array(buffer[(start + offset)..<(start + offset + 4)])
            payload.withUnsafeMutableBytes { bytes in
                for index in bytes.indices {
                    bytes[index] ^= mask[index & 3]
                }
            }
        }
        buffer = Data(buffer.dropFirst(offset + maskLength + length))
        return Frame(opcode: first & 0x0f, isFinal: first & 0x80 != 0, payload: payload)
    }

    private func handle(_ frame: Frame) {
        switch frame.opcode {
        case 0, 1, 2:
            if frame.opcode != 0 {
                fragmentOpcode = frame.opcode
                fragments = Data()
            }
            fragments.append(frame.payload)
            if frame.isFinal {
                onMessage(fragmentOpcode == 1 ? .text(String(decoding: fragments, as: UTF8.self)) : .binary(fragments))
            }
        case 8:
            let code = frame.payload.count >= 2 ? Int(frame.payload[frame.payload.startIndex]) << 8 | Int(frame.payload[frame.payload.startIndex + 1]) : nil
            let reason = frame.payload.count > 2 ? String(decoding: frame.payload.dropFirst(2), as: UTF8.self) : nil
            sendFrame(opcode: 8, payload: frame.payload)
            finish(code: code, reason: reason)
        case 9:
            sendFrame(opcode: 10, payload: frame.payload)
        default:
            break
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) })
        }
        connection.send(content: frame + payload, completion: .contentProcessed { _ in })
    }

    private func finish(code: Int?, reason: String?) {
        guard !isFinished else { return }
        isFinished = true
        onClose(code, reason)
        connection.cancel()
    }
}
