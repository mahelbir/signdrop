import Foundation
import Testing
@testable import SignDrop

extension StreamshareMockServer {
    func shorteners(_ scenario: String) -> [LinkShortener] {
        [.spoo("\(baseURL)/s/\(scenario)/spoo"), .tinyURL("\(baseURL)/s/\(scenario)/tinyurl")]
    }
}

extension SerialTests {
    struct LinkShortenerTests {
        private let mock: StreamshareMockServer
        private let link = URL(string: "https://axorax.github.io/urlmskr/ab+c/d=?e=f&g")!
        private let encodedLink =
            "https%3A%2F%2Faxorax.github.io%2Furlmskr%2Fab%2Bc%2Fd%3D%3Fe%3Df%26g"

        init() async throws {
            mock = try await StreamshareMockServer()
        }

        @Test func triesServicesInTheVerifiedOrder() {
            #expect(LinkShortener.all.map(\.name) == ["Spoo.me", "TinyURL"], "shorten.order")
            let endpoints = LinkShortener.all.map {
                $0.makeRequest("https://example.com")?.url?.absoluteString ?? "nil"
            }
            #expect(
                endpoints == [
                    "https://spoo.me/api/v1/shorten",
                    "https://tinyurl.com/api-create.php?url=https%3A%2F%2Fexample.com",
                ], "shorten.defaultEndpoints")
        }

        @Test func stopsAtTheFirstThatAnswers() async {
            let first = try? await InstallLink.shorten(link, with: mock.shorteners("ok~short"))
            let stats = mock.stats["ok~short"]
            #expect(
                first?.absoluteString == "https://spoo.me/mock-ok~short" && stats["tinyurl"] == nil,
                "shorten.firstWins")
            #expect(
                stats["spooUrl"] as? String == link.absoluteString
                    && stats["spooContentType"] as? String == "application/json",
                "shorten.spoo.request")
        }

        @Test func usesTinyURLLast() async {
            let last = try? await InstallLink.shorten(
                link, with: mock.shorteners("fail-spoo~short"))
            let stats = mock.stats["fail-spoo~short"]
            #expect(
                last?.absoluteString == "https://tinyurl.com/mock-fail-spoo~short"
                    && stats["spoo"] as? Int == 1, "shorten.tinyurlLast")
            #expect(
                stats["tinyurlUrl"] as? String == link.absoluteString
                    && stats["tinyurlQuery"] as? String == "url=\(encodedLink)",
                "shorten.tinyurl.request")
        }

        @Test func skipsAnUnreachableService() async {
            var offline = mock.shorteners("ok~offline")
            offline[0] = .spoo("http://127.0.0.1:1/spoo")
            let skipped = try? await InstallLink.shorten(link, with: offline)
            #expect(
                skipped?.absoluteString == "https://tinyurl.com/mock-ok~offline",
                "shorten.unreachableSkipped")
        }

        @Test func reportsWhenAllFail() async {
            await #expect(
                throws: ShareError.server("Could not shorten the link (Spoo.me, TinyURL)."),
                "shorten.allFail"
            ) {
                try await InstallLink.shorten(link, with: mock.shorteners("fail-all~short"))
            }
        }
    }
}
