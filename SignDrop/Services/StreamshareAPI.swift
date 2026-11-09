import Foundation

struct StreamshareFile: Decodable, Equatable {
    let id: String
    let deletionToken: String

    enum CodingKeys: String, CodingKey {
        case id = "fileIdentifier"
        case deletionToken
    }
}

struct StreamshareAPI {
    static let serviceName = "Streamshare"
    static let chunkSize = 1024 * 1024
    static let doneReason = Data("FILE_UPLOAD_DONE".utf8)

    var baseURL = URL(string: "https://streamshare.wireway.ch")!
    var socketURL = URL(string: "wss://streamshare.wireway.ch")!
    var session = ShareServices.session
    var stallTimeout: TimeInterval = 60

    func downloadURL(for file: StreamshareFile) -> URL {
        baseURL.appendingPathComponent("download/\(file.id)")
    }

    func deletionRequest(for file: StreamshareFile) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/delete/\(file.id)/\(file.deletionToken)"),
            timeoutInterval: 30)
        request.httpMethod = "DELETE"
        return request
    }

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> StreamshareFile {
        guard let stream = InputStream(url: file),
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else {
            throw ShareError.invalidFile("Could not read file: \(file.path)")
        }
        return try await upload(
            stream, name: file.lastPathComponent, size: size, progress: progress)
    }

    func upload(_ data: Data, name: String) async throws -> StreamshareFile {
        try await upload(InputStream(data: data), name: name, size: data.count) { _ in }
    }

    func delete(_ file: StreamshareFile) async throws {
        try await ShareServices.delete(
            [deletionRequest(for: file)], service: StreamshareAPI.serviceName, session: session)
    }

    func deleteIgnoringCancellation(_ file: StreamshareFile) async {
        let api = self
        await Task.detached { try? await api.delete(file) }.value
    }

    private func upload(
        _ stream: InputStream, name: String, size: Int, progress: @escaping (Double) -> Void
    ) async throws -> StreamshareFile {
        let file = try await create(name: name)
        let socket = session.webSocketTask(
            with: URLRequest(
                url: socketURL.appendingPathComponent("api/upload/\(file.id)"),
                timeoutInterval: stallTimeout))
        socket.resume()
        stream.open()
        defer { stream.close() }
        do {
            var buffer = [UInt8](repeating: 0, count: StreamshareAPI.chunkSize)
            var sentCount = 0
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    throw ShareError.invalidFile("Could not read \(name).")
                }
                guard count > 0 else { break }
                guard case .string("ACK") = try await exchange(Data(buffer[..<count]), on: socket)
                else {
                    throw ShareError.server("Unexpected response from Streamshare.")
                }
                sentCount += count
                let fraction = min(Double(sentCount) / Double(max(size, 1)), 1)
                DispatchQueue.main.async { progress(fraction) }
            }
            socket.cancel(with: .normalClosure, reason: StreamshareAPI.doneReason)
            return file
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            await deleteIgnoringCancellation(file)
            throw ShareError.from(
                error, service: StreamshareAPI.serviceName, stallTimeout: stallTimeout)
        }
    }

    private func exchange(_ chunk: Data, on socket: URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message
    {
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
            do {
                guard let reply = try await group.next() ?? nil else {
                    throw URLError(.timedOut)
                }
                return reply
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
    }

    private func create(name: String) async throws -> StreamshareFile {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/create"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let (data, status) = try await session.response(
            for: request, service: StreamshareAPI.serviceName)
        guard (200..<300).contains(status),
            let file = try? JSONDecoder().decode(StreamshareFile.self, from: data)
        else {
            throw ShareError.server("Streamshare could not start the upload (HTTP \(status)).")
        }
        return file
    }
}
