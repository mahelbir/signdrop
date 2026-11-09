import Foundation
import Testing

struct MockHTTPServerTests {
    private let server = MockHTTPServer()

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    @Test func passesRequestPartsToTheHandler() async throws {
        let seen = Collector<MockHTTPServer.Request>()
        let bodies = Collector<String>()
        server.handleRequest = { request in
            seen.append(request)
            bodies.append(request.bodyText)
            return .text(201, "created", contentType: "text/x-test")
        }
        try await server.start()

        var request = URLRequest(url: url("/s/ok/api?a=1&b=2"))
        request.httpMethod = "POST"
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("payload".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        let received = try #require(seen.all.first)
        #expect(received.method == "POST")
        #expect(received.path == "/s/ok/api")
        #expect(received.pathParts == ["s", "ok", "api"])
        #expect(received.query == "a=1&b=2")
        #expect(received.header("authorization") == "Bearer t")
        #expect(bodies.all == ["payload"])
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        #expect(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                == "text/x-test")
        #expect(data == Data("created".utf8))
    }

    @Test func keepsServingAfterAResponse() async throws {
        let count = Collector<Int>()
        server.handleRequest = { _ in
            count.append(1)
            return .text(200, "\(count.all.count)")
        }
        try await server.start()

        let (first, _) = try await URLSession.shared.data(from: url("/one"))
        let (second, _) = try await URLSession.shared.data(from: url("/two"))

        #expect(first == Data("1".utf8))
        #expect(second == Data("2".utf8))
    }

    @Test func readsTheWholeBodyOfALargeRequest() async throws {
        let sizes = Collector<Int>()
        server.handleRequest = { request in
            sizes.append(request.body.count)
            return .text(200, "ok")
        }
        try await server.start()

        var request = URLRequest(url: url("/large"))
        request.httpMethod = "PUT"
        _ = try await URLSession.shared.upload(
            for: request, from: Data(repeating: 7, count: 5_000_000))

        #expect(sizes.all == [5_000_000])
    }

    @Test func staysSilentWhenTheHandlerReturnsNothing() async throws {
        server.handleRequest = { _ in nil }
        try await server.start()

        var request = URLRequest(url: url("/silent"))
        request.timeoutInterval = 0.5
        await #expect(throws: URLError.self) {
            _ = try await URLSession.shared.data(for: request)
        }
    }

    @Test func refusesConnectionsAfterStop() async throws {
        try await server.start()
        server.stop()

        await #expect(throws: URLError.self) {
            _ = try await URLSession.shared.data(from: url("/gone"))
        }
    }

    @Test func exchangesWebSocketMessagesAndReportsTheClose() async throws {
        let messages = Collector<MockWebSocket.Message>()
        let paths = Collector<String>()
        let closes = Collector<String>()
        server.handleSocket = { socket in
            paths.append(socket.path)
            socket.onMessage = { message in
                messages.append(message)
                socket.send("ACK")
            }
            socket.onClose = { code, reason in
                closes.append("\(code ?? -1) \(reason ?? "nil")")
            }
        }
        try await server.start()

        let socket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(server.port)/s/ok/api/upload/id1")!)
        socket.resume()
        let large = Data(repeating: 9, count: 1_048_576)
        try await socket.send(.data(large))
        let firstReply = try await socket.receive()
        try await socket.send(.string("hello"))
        let secondReply = try await socket.receive()
        socket.cancel(with: .normalClosure, reason: Data("DONE".utf8))

        #expect(await isEventuallyTrue(3) { !closes.all.isEmpty })
        #expect(paths.all == ["/s/ok/api/upload/id1"])
        #expect(messages.all == [.binary(large), .text("hello")])
        #expect(firstReply.textValue == "ACK")
        #expect(secondReply.textValue == "ACK")
        #expect(closes.all == ["1000 DONE"])
    }
}

private extension URLSessionWebSocketTask.Message {
    var textValue: String? {
        if case .string(let text) = self {
            return text
        }
        return nil
    }
}
