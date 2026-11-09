import Foundation

final class StreamShareMockServer {
    typealias Request = MockHTTPServer.Request
    typealias Response = MockHTTPServer.Response

    private final class Upload {
        var received = Data()
        var sizes: [Int] = []
    }

    let stats = MockStats()
    private let server = MockHTTPServer()
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    var baseURL: String {
        "http://127.0.0.1:\(server.port)"
    }

    var socketURL: String {
        "ws://127.0.0.1:\(server.port)"
    }

    init() async throws {
        server.handleRequest = { [weak self] request in
            self?.route(request)
        }
        server.handleSocket = { [weak self] socket in
            self?.accept(socket)
        }
        try await server.start()
    }

    func uploads(_ scenario: String) -> [[String: Any]] {
        stats[scenario]["uploads"] as? [[String: Any]] ?? []
    }

    private func route(_ request: Request) -> Response? {
        switch request.method {
        case "GET":
            return get(request)
        case "POST":
            return post(request)
        case "DELETE":
            return delete(request)
        default:
            return .text(404, "Not found")
        }
    }

    private static func isFailing(_ scenario: String, _ shortener: String) -> Bool {
        let words = scenarioKind(scenario).components(separatedBy: "-")
        return words[0] == "fail" && (words.dropFirst().contains(shortener) || words.dropFirst().contains("all"))
    }

    private static func formValue(_ form: String, _ name: String) -> String? {
        for pair in form.components(separatedBy: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == name {
                return String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
        }
        return nil
    }

    private func get(_ request: Request) -> Response {
        let parts = request.pathParts
        if parts.count == 4, parts[0] == "s", parts[2] == "download" {
            lock.lock()
            defer { lock.unlock() }
            return files[parts[3]].map { .data(200, $0) } ?? .text(404, "Not found")
        }
        if parts.count == 3, parts[0] == "s", parts[2] == "ulvis" {
            let scenario = parts[1]
            stats.bump(scenario, "ulvis", ["ulvisQuery": request.query, "ulvisType": Self.formValue(request.query, "type"), "ulvisUrl": Self.formValue(request.query, "url")])
            if Self.isFailing(scenario, "ulvis") {
                return .json(200, ["success": false, "error": ["code": 1, "msg": "invalid url"]])
            }
            return .json(200, ["success": true, "data": ["url": "https://ulvis.net/mock-\(scenario)"]])
        }
        if parts.count == 3, parts[0] == "s", parts[2] == "tinyurl" {
            let scenario = parts[1]
            stats.bump(scenario, "tinyurl", ["tinyurlQuery": request.query, "tinyurlUrl": Self.formValue(request.query, "url")])
            return Self.isFailing(scenario, "tinyurl") ? .text(400, "Error") : .text(200, "https://tinyurl.com/mock-\(scenario)")
        }
        return .text(404, "Not found")
    }

    private func post(_ request: Request) -> Response {
        let parts = request.pathParts
        if parts.count == 4, parts[0] == "s", parts[2] == "api", parts[3] == "create" {
            let scenario = parts[1]
            let count = stats.bump(scenario, "create", ["contentType": request.header("Content-Type")])
            stats.append(scenario, "names", request.bodyJSON["name"] as? String ?? "")
            if scenarioKind(scenario) == "create-500" || (scenarioKind(scenario) == "manifest-fail" && count == 2) {
                return .text(500, "<html>Internal Server Error</html>", contentType: "text/html")
            }
            return .json(200, ["fileIdentifier": "\(scenario)-\(count)", "deletionToken": "tok\(count)"])
        }
        if parts.count == 3, parts[0] == "s", parts[2] == "spoo" {
            let scenario = parts[1]
            let longURL = request.bodyJSON["long_url"] as? String
            stats.bump(scenario, "spoo", ["spooContentType": request.header("Content-Type"), "spooUrl": longURL])
            if Self.isFailing(scenario, "spoo") {
                return .json(400, ["error": "URL is not allowed or invalid", "code": "validation_error"])
            }
            return .json(201, ["alias": "mock", "short_url": "https://spoo.me/mock-\(scenario)", "long_url": longURL ?? ""])
        }
        if parts.count == 3, parts[0] == "s", parts[2] == "cleanuri" {
            let scenario = parts[1]
            let body = request.bodyText
            stats.bump(scenario, "cleanuri", ["cleanuriContentType": request.header("Content-Type"), "cleanuriBody": body, "cleanuriUrl": Self.formValue(body, "url")])
            let scheme = Self.isFailing(scenario, "cleanuri") ? "http" : "https"
            return .json(200, ["result_url": "\(scheme)://cleanuri.com/mock-\(scenario)"])
        }
        return .text(404, "Not found")
    }

    private func delete(_ request: Request) -> Response {
        let parts = request.pathParts
        guard parts.count == 6, parts[0] == "s", parts[2] == "api", parts[3] == "delete" else { return .text(404, "Not found") }
        let scenario = parts[1]
        stats.bump(scenario, "delete")
        stats.append(scenario, "deleted", "\(parts[4])/\(parts[5])")
        if scenarioKind(scenario) == "delete-404" {
            return .text(404, "Not found")
        }
        lock.lock()
        files[parts[4]] = nil
        lock.unlock()
        return .text(200, "OK")
    }

    private func accept(_ socket: MockWebSocket) {
        let parts = socket.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")
        guard parts.count > 1, let identifier = parts.last else { return }
        let scenario = parts[1]
        let upload = Upload()
        socket.onMessage = { [weak self, weak socket] message in
            switch message {
            case .text(let text):
                self?.stats.append(scenario, "texts", text)
            case .binary(let data):
                upload.sizes.append(data.count)
                upload.received.append(data)
                if scenarioKind(scenario) != "stall" {
                    socket?.send(scenarioKind(scenario) == "bad-reply" ? "NOPE" : "ACK")
                }
            }
        }
        socket.onClose = { [weak self] code, reason in
            guard let self else { return }
            lock.lock()
            files[identifier] = upload.received
            lock.unlock()
            var record: [String: Any] = ["id": identifier, "sha256": sha256Hex(upload.received), "size": upload.received.count, "chunks": upload.sizes]
            record["closeCode"] = code
            record["closeReason"] = reason
            stats.append(scenario, "uploads", record)
        }
    }
}
