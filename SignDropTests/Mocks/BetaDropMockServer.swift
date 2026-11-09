import Foundation

final class BetaDropMockServer {
    typealias Request = MockHTTPServer.Request
    typealias Response = MockHTTPServer.Response

    private struct Call {
        let request: Request
        let scenario: String

        var kind: String {
            scenarioKind(scenario)
        }

        var authorization: String? {
            request.header("Authorization")
        }
    }

    private static let user: [String: Any] = ["id": 7, "email": "dev@example.com", "role": "user"]
    private static let published: [String: Any] = [
        "id": "b1",
        "shortId": "abc123",
        "url": "https://betadrop.app/i/abc123",
        "platform": "ios",
        "fileSize": 1,
        "meta": [
            "name": "Sample", "version": "1.0", "package": "com.acme.sample", "icon": NSNull(),
            "dominantColor": NSNull(),
        ] as [String: Any],
    ]
    private static let duplicate: [String: Any] = [
        "id": "b0",
        "shortId": "old1",
        "url": "https://betadrop.app/install/?i=old1",
        "name": "Sample",
        "version": "1.0",
        "buildNumber": "1",
        "label": "Sample 1.0 (1)",
        "message": "You already published this exact build.",
        "createdAt": NSNull(),
        "downloadCount": 0,
    ]
    private static let approved: [String: Any] = [
        "access_token": "bd_live_device",
        "token_type": "Bearer",
        "user": ["id": "u1", "email": "dev@example.com", "role": "user"],
    ]
    private static let publishReplies: [String: (status: Int, body: [String: Any])] = [
        "ok": (200, ["success": true, "data": published]),
        "duplicate": (
            200, ["success": true, "data": published.merging(["duplicateOf": duplicate]) { $1 }]
        ),
        "json5xx": (500, ["success": false, "error": "Storage is down"]),
        "json5xx-object": (500, ["success": false, "error": ["code": "storage"]]),
        "unauthorized": (401, ["success": false, "error": "Unauthenticated."]),
        "success-false": (200, ["success": false, "message": "Plan limit reached"]),
        "error-no-message": (422, ["success": false]),
        "error-object": (422, ["success": false, "error": ["file": ["The file is invalid."]]]),
        "rate-limit": (429, ["success": false, "error": "Too many uploads"]),
        "missing-short-id": (200, ["success": true, "data": ["id": "b1"]]),
    ]
    private static let notFound = Response.json(404, ["success": false, "error": "Not found"])

    let stats = MockStats()
    private let server = MockHTTPServer()

    var baseURL: String {
        "http://127.0.0.1:\(server.port)"
    }

    init() async throws {
        server.handleRequest = { [weak self] request in
            self?.route(request)
        }
        server.shouldIgnoreBody = { request in
            request.pathParts.count > 1 && scenarioKind(request.pathParts[1]) == "stall"
        }
        try await server.start()
    }

    func api(_ scenario: String) -> String {
        "\(baseURL)/s/\(scenario)"
    }

    private func route(_ request: Request) -> Response? {
        let parts = request.pathParts
        if request.method == "DELETE" {
            guard parts.count == 4, parts[0] == "s", parts[2] == "delete" else {
                return Self.notFound
            }
            stats.bump(parts[1], "delete")
            return .json(parts[1].hasPrefix("delete-fail") ? 500 : 200, ["success": true])
        }
        guard parts.count >= 5, parts[0] == "s", parts[2] == "api", parts[3] == "cli" else {
            return Self.notFound
        }
        let call = Call(request: request, scenario: parts[1])
        switch parts[4...].joined(separator: "/") {
        case "whoami":
            return whoami(call)
        case "logout":
            stats.bump(call.scenario, "logout", ["authorization": call.authorization])
            return .json(200, ["success": true])
        case "device/code":
            return deviceCode(call)
        case "device/token":
            return deviceToken(call)
        case "publish":
            return publish(call)
        default:
            return Self.notFound
        }
    }

    private func whoami(_ call: Call) -> Response {
        stats.bump(call.scenario, "whoami", ["authorization": call.authorization])
        if call.kind == "unauthorized" {
            return .json(401, ["success": false, "error": "Unauthenticated."])
        }
        return .json(
            200,
            ["success": true, "data": ["user": Self.user, "token": NSNull()] as [String: Any]])
    }

    private func html(_ status: Int) -> Response {
        .text(status, "<html><body>Bad gateway</body></html>", contentType: "text/html")
    }

    private func deviceCode(_ call: Call) -> Response {
        let body = call.request.bodyJSON
        stats.bump(
            call.scenario, "deviceCode",
            [
                "clientName": body["client_name"], "scope": body["scope"],
                "hasProviderHint": body["provider_hint"] != nil,
            ])
        if call.kind == "code-error" {
            return html(500)
        }
        return .json(
            200,
            [
                "device_code": "dc-" + call.scenario,
                "user_code": "ABCD-1234",
                "verification_uri": "https://betadrop.app/device",
                "verification_uri_complete": "https://betadrop.app/device?code=ABCD-1234",
                "expires_in": call.kind == "expire" ? 2 : 30,
                "interval": call.kind == "bad-interval" ? -1 : 1,
            ])
    }

    private func deviceToken(_ call: Call) -> Response {
        let body = call.request.bodyJSON
        let count = stats.bump(
            call.scenario, "deviceToken", ["lastDeviceCode": body["device_code"]])
        switch call.kind {
        case "approve":
            let steps: [(Int, [String: Any])] = [
                (400, ["error": "authorization_pending"]),
                (400, ["error": "slow_down", "interval": 1]), (200, Self.approved),
            ]
            let step = steps[min(count, steps.count) - 1]
            return .json(step.0, step.1)
        case "bad-interval":
            return .json(200, Self.approved)
        case "approve-no-user":
            return .json(200, ["access_token": "bd_live_device", "token_type": "Bearer"])
        case "deny":
            return .json(400, ["error": count == 1 ? "authorization_pending" : "access_denied"])
        case "garbage":
            return html(500)
        default:
            return .json(400, ["error": "authorization_pending"])
        }
    }

    private func publish(_ call: Call) -> Response? {
        let count = stats.bump(call.scenario, "publish")
        if call.kind == "stall" {
            return nil
        }
        recordUpload(call)
        if call.kind == "not-json" {
            return .text(200, "<html>oops</html>", contentType: "text/html")
        }
        if call.kind == "html5xx-always" || (call.kind == "html5xx-then-ok" && count <= 2) {
            return html(502)
        }
        let reply = Self.publishReplies[call.kind] ?? Self.publishReplies["ok"]!
        return .json(reply.status, reply.body)
    }

    private func recordUpload(_ call: Call) {
        guard let file = call.request.bodyFile, let handle = try? FileHandle(forReadingFrom: file)
        else { return }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let boundary =
            (call.request.header("Content-Type") ?? "").components(separatedBy: "boundary=").last
            ?? ""
        let closing = Data("\r\n--\(boundary)--\r\n".utf8)
        try? handle.seek(toOffset: 0)
        let start = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let separator = start.range(of: Data("\r\n\r\n".utf8))
        let headEnd = separator.map { $0.lowerBound - start.startIndex } ?? start.count
        let disposition = String(decoding: start.prefix(headEnd), as: UTF8.self)
        let bodyStart = headEnd + 4
        try? handle.seek(toOffset: UInt64(bodyStart))
        let sha256 = sha256Hex(reading: handle, byteCount: max(size - closing.count - bodyStart, 0))
        try? handle.seek(toOffset: UInt64(max(size - closing.count, 0)))
        let tail = (try? handle.read(upToCount: closing.count)) ?? Data()
        let afterName = disposition.components(separatedBy: "filename=\"").last ?? ""
        stats.bump(
            call.scenario, "received",
            [
                "sha256": sha256,
                "filename": afterName.components(separatedBy: "\"\r\n").first,
                "authorization": call.authorization,
                "accept": call.request.header("Accept"),
                "boundary": boundary,
                "head": disposition,
                "hasClosingBoundary": tail == closing,
            ])
    }
}
