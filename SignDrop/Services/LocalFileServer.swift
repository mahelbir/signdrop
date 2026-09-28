import Foundation
import Network

final class LocalFileServer {
    enum Content {
        case data(Data)
        case file(FileHandle, size: UInt64)
        case redirect(String)
    }

    struct Route {
        let content: Content
        let contentType: String
    }

    static let chunkSize = 256 * 1024
    private static let headerLimit = 16 * 1024

    var onRequest: ((String, String, Int) -> Void)?
    private let queue = DispatchQueue(label: "LocalFileServer")
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func setRoute(_ path: String, _ route: Route) {
        queue.sync { routes[path] = route }
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
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
            for route in routes.values {
                if case .file(let handle, _) = route.content {
                    try? handle.close()
                }
            }
            routes = [:]
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
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > Self.headerLimit {
                connection.cancel()
            } else {
                self.readHeader(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let parts = header.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        guard ["GET", "HEAD"].contains(method), let route = routes[path] else {
            onRequest?(method, path, 404)
            send(connection, head: Self.head(status: "404 Not Found", contentType: "text/plain", length: 0), body: nil)
            return
        }
        let body = method == "GET" ? route.content : nil
        switch route.content {
        case .redirect(let location):
            onRequest?(method, path, 302)
            send(connection, head: Self.head(status: "302 Found", contentType: route.contentType, length: 0, location: location), body: nil)
        case .data(let data):
            onRequest?(method, path, 200)
            send(connection, head: Self.head(status: "200 OK", contentType: route.contentType, length: UInt64(data.count)), body: body)
        case .file(_, let size):
            onRequest?(method, path, 200)
            send(connection, head: Self.head(status: "200 OK", contentType: route.contentType, length: size), body: body)
        }
    }

    private func send(_ connection: NWConnection, head: Data, body: Content?) {
        switch body {
        case .data(let data)?:
            connection.send(content: head + data, completion: .contentProcessed { _ in connection.cancel() })
        case .file(let handle, let size)?:
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard error == nil else { return connection.cancel() }
                self?.sendChunk(connection, handle: handle, offset: 0, size: size)
            })
        case .redirect?, nil:
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func sendChunk(_ connection: NWConnection, handle: FileHandle, offset: UInt64, size: UInt64) {
        guard connections[ObjectIdentifier(connection)] != nil, offset < size else {
            connection.cancel()
            return
        }
        let count = Int(min(UInt64(Self.chunkSize), size - offset))
        var chunk = Data(count: count)
        let read = chunk.withUnsafeMutableBytes { pread(handle.fileDescriptor, $0.baseAddress, count, off_t(offset)) }
        guard read > 0 else {
            connection.cancel()
            return
        }
        connection.send(content: chunk.prefix(read), completion: .contentProcessed { [weak self] error in
            guard error == nil else { return connection.cancel() }
            self?.sendChunk(connection, handle: handle, offset: offset + UInt64(read), size: size)
        })
    }

    private static func head(status: String, contentType: String, length: UInt64, location: String? = nil) -> Data {
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        return Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n\(redirect)Connection: close\r\n\r\n".utf8)
    }
}
