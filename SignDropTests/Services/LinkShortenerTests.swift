import Foundation
import Testing
@testable import SignDrop

extension StreamShareMockServer {
    func shorteners(_ scenario: String) -> [LinkShortener] {
        [.ulvis("\(baseURL)/s/\(scenario)/ulvis"), .spoo("\(baseURL)/s/\(scenario)/spoo"), .cleanURI("\(baseURL)/s/\(scenario)/cleanuri"), .tinyURL("\(baseURL)/s/\(scenario)/tinyurl")]
    }
}

extension SerialTests {
    struct LinkShortenerTests {
        private let mock: StreamShareMockServer
        private let link = URL(string: "https://axorax.github.io/urlmskr/ab+c/d=?e=f&g")!
        private let encodedLink = "https%3A%2F%2Faxorax.github.io%2Furlmskr%2Fab%2Bc%2Fd%3D%3Fe%3Df%26g"

        init() async throws {
            mock = try await StreamShareMockServer()
        }

        @Test func triesServicesInTheVerifiedOrder() {
            #expect(LinkShortener.all.map(\.name) == ["Ulvis", "Spoo.me", "CleanURI", "TinyURL"], "shorten.order")
            let endpoints = LinkShortener.all.map { $0.makeRequest("https://example.com")?.url?.absoluteString ?? "nil" }
            #expect(endpoints == [
                "https://ulvis.net/API/write/get?type=json&url=https%3A%2F%2Fexample.com",
                "https://spoo.me/api/v1/shorten",
                "https://cleanuri.com/api/v1/shorten",
                "https://tinyurl.com/api-create.php?url=https%3A%2F%2Fexample.com",
            ], "shorten.defaultEndpoints")
        }

        @Test func stopsAtTheFirstThatAnswers() async {
            let first = try? await InstallLink.shorten(link, with: mock.shorteners("ok~short"))
            let stats = mock.stats["ok~short"]
            #expect(first?.absoluteString == "https://ulvis.net/mock-ok~short" && stats["spoo"] == nil && stats["cleanuri"] == nil && stats["tinyurl"] == nil, "shorten.firstWins")
            #expect(stats["ulvisUrl"] as? String == link.absoluteString, "shorten.ulvis.request")
            #expect(stats["ulvisType"] as? String == "json", "shorten.ulvis.request")
            #expect((stats["ulvisQuery"] as? String)?.hasSuffix("url=\(encodedLink)") == true, "shorten.ulvis.request")
        }

        @Test func fallsBackToSpoo() async {
            let second = try? await InstallLink.shorten(link, with: mock.shorteners("fail-ulvis~short"))
            let stats = mock.stats["fail-ulvis~short"]
            #expect(second?.absoluteString == "https://spoo.me/mock-fail-ulvis~short" && stats["ulvis"] as? Int == 1 && stats["cleanuri"] == nil, "shorten.spooAfterUlvis")
            #expect(stats["spooUrl"] as? String == link.absoluteString && stats["spooContentType"] as? String == "application/json", "shorten.spoo.request")
        }

        @Test func fallsBackToCleanURI() async {
            let third = try? await InstallLink.shorten(link, with: mock.shorteners("fail-ulvis-spoo~short"))
            let stats = mock.stats["fail-ulvis-spoo~short"]
            #expect(third?.absoluteString == "https://cleanuri.com/mock-fail-ulvis-spoo~short" && stats["spoo"] as? Int == 1 && stats["tinyurl"] == nil, "shorten.cleanuriAfterSpoo")
            #expect(stats["cleanuriUrl"] as? String == link.absoluteString, "shorten.cleanuri.request")
            #expect(stats["cleanuriBody"] as? String == "url=\(encodedLink)", "shorten.cleanuri.request")
            #expect(stats["cleanuriContentType"] as? String == "application/x-www-form-urlencoded", "shorten.cleanuri.request")
        }

        @Test func usesTinyURLLast() async {
            let fourth = try? await InstallLink.shorten(link, with: mock.shorteners("fail-ulvis-spoo-cleanuri~short"))
            let stats = mock.stats["fail-ulvis-spoo-cleanuri~short"]
            #expect(fourth?.absoluteString == "https://tinyurl.com/mock-fail-ulvis-spoo-cleanuri~short" && stats["cleanuri"] as? Int == 1, "shorten.tinyurlLast")
            #expect(stats["tinyurlUrl"] as? String == link.absoluteString && stats["tinyurlQuery"] as? String == "url=\(encodedLink)", "shorten.tinyurl.request")
        }

        @Test func skipsAnUnreachableService() async {
            var offline = mock.shorteners("ok~offline")
            offline[0] = .ulvis("http://127.0.0.1:1/ulvis")
            let skipped = try? await InstallLink.shorten(link, with: offline)
            #expect(skipped?.absoluteString == "https://spoo.me/mock-ok~offline", "shorten.unreachableSkipped")
        }

        @Test func reportsWhenAllFail() async {
            await #expect(throws: UploadError.server("Could not shorten the link (Ulvis, Spoo.me, CleanURI, TinyURL)."), "shorten.allFail") {
                try await InstallLink.shorten(link, with: mock.shorteners("fail-all~short"))
            }
        }
    }
}
