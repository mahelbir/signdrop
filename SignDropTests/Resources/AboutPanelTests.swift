import AppKit
import Foundation
import Testing

struct AboutPanelTests {
    private func credits() throws -> NSAttributedString {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
        return try NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
    }

    @Test func showsTheCopyright() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
                == "Copyright © 2026 Mahmuthan Elbir.", "about.copyright")
    }

    @Test func creditsEveryServiceAndProject() throws {
        let text = try credits().string
        let mentions = [
            "BetaDrop", "StreamShare", "Cloudflare Tunnel", "Urlmskr", "Ulvis", "Spoo.me",
            "CleanURI", "TinyURL",
            "iOS App Signer © 2015-2025 Daniel Radtke", "GPL-3.0", "NimbusKit",
            "Apache License 2.0",
            "not affiliated", "public",
        ]
        #expect(mentions.filter { !text.contains($0) } == [], "about.credits.mentions")
    }

    @Test func linksAdaptToDarkMode() throws {
        let credits = try credits()
        var links: Set<String> = []
        var fixedColors: [String] = []
        credits.enumerateAttributes(in: NSRange(location: 0, length: credits.length)) {
            attributes, range, _ in
            if let link = attributes[.link] {
                links.insert("\(link)")
            }
            if let color = attributes[.foregroundColor] as? NSColor, attributes[.link] == nil {
                fixedColors.append(
                    "\((credits.string as NSString).substring(with: range).prefix(20)): \(color)")
            }
        }
        #expect(
            links == [
                "https://betadrop.app", "https://streamshare.wireway.ch",
                "https://try.cloudflare.com",
                "https://axorax.github.io/urlmskr/", "https://ulvis.net", "https://spoo.me",
                "https://cleanuri.com",
                "https://tinyurl.com", "https://github.com/DanTheMan827/ios-app-signer",
                "https://github.com/NimbusKit/markdown",
            ],
            "about.credits.links"
        )
        #expect(fixedColors == [], "about.credits.adaptiveColor")
    }
}
