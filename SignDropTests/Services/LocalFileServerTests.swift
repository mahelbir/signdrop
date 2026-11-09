import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct LocalFileServerTests {
        private let work: WorkDirectory
        private let server = LocalFileServer()
        private let manifest = Data("<plist>hello</plist>".utf8)

        init() throws {
            work = try WorkDirectory()
        }

        private func url(_ port: UInt16, _ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
        }

        private func makeFile(_ name: String, megabytes: Int) -> URL {
            let file = work.file(name, Data())
            var block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            if let writer = try? FileHandle(forWritingTo: file) {
                for index in 0..<megabytes {
                    block.replaceSubrange(0..<8, with: withUnsafeBytes(of: index) { Data($0) })
                    try? writer.write(contentsOf: block)
                }
                try? writer.close()
            }
            return file
        }

        private func start(serving file: URL) async throws -> UInt16 {
            server.setRoute(
                "/tok/manifest.plist", .init(content: .data(manifest), contentType: "text/xml"))
            let port = try await server.start()
            server.setRoute(
                "/tok/app.ipa",
                .init(
                    content: .file(try FileHandle(forReadingFrom: file), size: fileSize(file)),
                    contentType: "application/octet-stream"))
            return port
        }

        @Test func servesKnownRoutesOnly() async throws {
            let requests = Collector<String>()
            server.onRequest = { method, path, status in
                requests.append("\(method) \(path) \(status)")
            }
            let file = makeFile("small.ipa", megabytes: 1)
            let port = try await start(serving: file)
            defer { server.stop() }
            #expect(port > 0, "server.start")

            let get = await httpRequest(url(port, "/tok/manifest.plist"))
            #expect(
                get.status == 200 && get.data == manifest && get.length == "\(manifest.count)",
                "server.getData")
            let head = await httpRequest(url(port, "/tok/manifest.plist"), method: "HEAD")
            #expect(
                head.status == 200 && head.data.isEmpty && head.length == "\(manifest.count)",
                "server.headData")
            let headFile = await httpRequest(url(port, "/tok/app.ipa"), method: "HEAD")
            #expect(
                headFile.status == 200 && headFile.length == "\(fileSize(file))", "server.headFile")
            #expect(
                await httpRequest(url(port, "/tok/other")).status == 404, "server.unknownPath404")
            #expect(
                await httpRequest(url(port, "/bad/manifest.plist")).status == 404,
                "server.wrongToken404")
            #expect(
                await httpRequest(url(port, "/tok/manifest.plist"), method: "POST").status == 404,
                "server.post404")
            let ranged = await httpRequest(
                url(port, "/tok/manifest.plist"), headers: ["Range": "bytes=0-3"])
            #expect(ranged.status == 200 && ranged.data == manifest, "server.rangeIgnored")

            let itmsLink =
                "itms-services://?action=download-manifest&url=https%3A%2F%2Fexample.com%2Fm.plist"
            server.setRoute(
                "/tok/install", .init(content: .redirect(itmsLink), contentType: "text/plain"))
            let redirect = responseHead(url(port, "/tok/install"))
            #expect(
                redirect.status == "HTTP/1.1 302 Found" && redirect.location == itmsLink,
                "server.redirect")
            let headRedirect = responseHead(url(port, "/tok/install"), isHead: true)
            #expect(
                headRedirect.status == "HTTP/1.1 302 Found" && headRedirect.location == itmsLink,
                "server.headRedirect")
            #expect(
                requests.all.contains("GET /tok/manifest.plist 200")
                    && requests.all.contains("GET /tok/other 404")
                    && requests.all.contains("GET /tok/install 302"), "server.logsRequests")
        }

        @Test func servesLargeFilesConcurrentlyWithFlatMemory() async throws {
            let big = makeFile("big.ipa", megabytes: 200)
            let bigSHA = sha256Hex(ofFile: big)
            let port = try await start(serving: big)
            defer { server.stop() }
            try FileManager.default.moveItem(at: big, to: work.child("moved.ipa"))

            let outputs = (0..<3).map { work.child("download-\($0).ipa") }
            var curls: [Process] = []
            var isFinished = false
            let growth = await peakResidentGrowth {
                curls = outputs.map {
                    startCurl([
                        "-sf", "--limit-rate", "100M", "-o", $0.path,
                        url(port, "/tok/app.ipa").absoluteString,
                    ])
                }
                isFinished = await isEventuallyTrue(60) { !curls.contains(where: \.isRunning) }
            }
            try #require(isFinished)
            let hashes = zip(curls, outputs).map { curl, output in
                curl.terminationStatus == 0 ? sha256Hex(ofFile: output) : "failed"
            }
            #expect(hashes.allSatisfy { $0 == bigSHA }, "server.concurrentAfterMove")
            #expect(growth < 50, "server.memoryFlat")
        }

        @Test func listensOnLoopbackOnly() async throws {
            let port = try await start(serving: makeFile("small.ipa", megabytes: 1))
            defer { server.stop() }
            let lanIP = Process().execute(
                "/usr/sbin/ipconfig", workingDirectory: nil, arguments: ["getifaddr", "en0"]
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lanIP.isEmpty {
                #expect(
                    await httpRequest(URL(string: "http://\(lanIP):\(port)/tok/manifest.plist")!)
                        .status == 0, "server.loopbackOnly")
            }
        }

        @Test func stopCutsDownloadsAndClosesThePort() async throws {
            let file = makeFile("big.ipa", megabytes: 64)
            let port = try await start(serving: file)
            let partial = work.child("partial.ipa")
            let slow = startCurl([
                "-sf", "--limit-rate", "5M", "-o", partial.path,
                url(port, "/tok/app.ipa").absoluteString,
            ])
            await pause(0.5)
            server.stop()
            let isCut = await isEventuallyTrue(5) { !slow.isRunning }
            #expect(
                isCut && slow.terminationStatus != 0 && fileSize(partial) < fileSize(file),
                "server.stopCutsDownload")
            #expect(
                await httpRequest(url(port, "/tok/manifest.plist")).status == 0,
                "server.stopClosesPort")
            server.stop()
            #expect(Bool(true), "server.stopTwice")
        }
    }
}
