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
            "BetaDrop", "Streamshare", "Cloudflare Quick Tunnel", "Urlmskr", "Spoo.me", "TinyURL",
            "GNU General Public License v3.0", "no warranty", "modified version",
            "changed since 2026", "iOS App Signer © 2015-2025 Daniel Radtke", "GPL-3.0",
            "NimbusKit", "Memory Mapping", "Apache License 2.0", "BetaDrop CLI", "MIT License",
            "license texts", "not affiliated", "public",
        ]
        #expect(mentions.filter { !text.contains($0) } == [], "about.credits.mentions")
    }

    @Test func shipsTheLicenseTexts() throws {
        let licenses: [(name: String, folder: String?, marker: String)] = [
            ("LICENSE", nil, "GNU GENERAL PUBLIC LICENSE"),
            ("Apache-2.0", "Licenses", "Version 2.0, January 2004"),
            ("NimbusKit-NOTICE", "Licenses", "Copyright 2011-2012 Jeff Verkoeyen"),
        ]
        for license in licenses {
            let url = try #require(
                Bundle.main.url(
                    forResource: license.name, withExtension: "txt", subdirectory: license.folder),
                "about.license.\(license.name)")
            #expect(
                try String(contentsOf: url, encoding: .utf8).contains(license.marker),
                "about.license.\(license.name)")
        }
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
                "https://axorax.github.io/urlmskr/", "https://spoo.me",
                "https://tinyurl.com", "https://github.com/DanTheMan827/ios-app-signer",
                "https://github.com/NimbusKit/markdown",
                "https://github.com/NimbusKit/memorymapping",
                "https://github.com/betadrop-app/betadrop-cli",
                "https://github.com/mahelbir/signdrop/blob/master/LICENSE.txt",
                "https://github.com/mahelbir/signdrop/tree/master/SignDrop/Resources/Licenses",
            ],
            "about.credits.links"
        )
        #expect(fixedColors == [], "about.credits.adaptiveColor")
    }
}
