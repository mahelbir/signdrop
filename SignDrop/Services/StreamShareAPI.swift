import Foundation

struct StreamShareFile: Decodable, Equatable {
    let id: String
    let deletionToken: String

    enum CodingKeys: String, CodingKey {
        case id = "fileIdentifier"
        case deletionToken
    }
}

struct StreamShareAPI {
    static let serviceName = "StreamShare"
    static let chunkSize = 1024 * 1024
    static let doneReason = Data("FILE_UPLOAD_DONE".utf8)

    var baseURL = URL(string: "https://streamshare.wireway.ch")!
    var socketURL = URL(string: "wss://streamshare.wireway.ch")!
    var session = UploadServices.session
    var stallTimeout: TimeInterval = 60

    func downloadURL(for file: StreamShareFile) -> URL {
        baseURL.appendingPathComponent("download/\(file.id)")
    }

    func deletionRequest(for file: StreamShareFile) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete/\(file.id)/\(file.deletionToken)"), timeoutInterval: 30)
        request.httpMethod = "DELETE"
        return request
    }

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> StreamShareFile {
        guard let stream = InputStream(url: file), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw UploadError.invalidFile("Could not read file: \(file.path)")
        }
        return try await upload(stream, name: file.lastPathComponent, size: size, progress: progress)
    }

    func upload(_ data: Data, name: String) async throws -> StreamShareFile {
        try await upload(InputStream(data: data), name: name, size: data.count) { _ in }
    }

    func delete(_ file: StreamShareFile) async throws {
        try await UploadServices.delete([deletionRequest(for: file)], service: StreamShareAPI.serviceName, session: session)
    }

    private func upload(_ stream: InputStream, name: String, size: Int, progress: @escaping (Double) -> Void) async throws -> StreamShareFile {
        let file = try await create(name: name)
        let socket = session.webSocketTask(with: URLRequest(url: socketURL.appendingPathComponent("api/upload/\(file.id)"), timeoutInterval: stallTimeout))
        socket.resume()
        stream.open()
        defer { stream.close() }
        do {
            var buffer = [UInt8](repeating: 0, count: StreamShareAPI.chunkSize)
            var sentCount = 0
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    throw UploadError.invalidFile("Could not read \(name).")
                }
                guard count > 0 else { break }
                guard case .string("ACK") = try await exchange(Data(buffer[..<count]), on: socket) else {
                    throw UploadError.server("Unexpected response from StreamShare.")
                }
                sentCount += count
                let fraction = min(Double(sentCount) / Double(max(size, 1)), 1)
                DispatchQueue.main.async { progress(fraction) }
            }
            socket.cancel(with: .normalClosure, reason: StreamShareAPI.doneReason)
            return file
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            try? await delete(file)
            throw UploadError.from(error, service: StreamShareAPI.serviceName, stallTimeout: stallTimeout)
        }
    }

    private func exchange(_ chunk: Data, on socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let timeout = UInt64(stallTimeout * 1_000_000_000)
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask {
                try await socket.send(.data(chunk))
                return try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() ?? nil else {
                socket.cancel(with: .goingAway, reason: nil)
                throw URLError(.timedOut)
            }
            return reply
        }
    }

    private func create(name: String) async throws -> StreamShareFile {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/create"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let (data, status) = try await session.response(for: request, service: StreamShareAPI.serviceName)
        guard (200..<300).contains(status), let file = try? JSONDecoder().decode(StreamShareFile.self, from: data) else {
            throw UploadError.server("StreamShare could not start the upload (HTTP \(status)).")
        }
        return file
    }
}
