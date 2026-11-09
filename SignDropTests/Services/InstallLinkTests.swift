import Foundation
import Testing
@testable import SignDrop

struct InstallLinkTests {
    private let work: WorkDirectory
    private let package = URL(string: "https://streamshare.wireway.ch/download/abc123")!

    init() throws {
        work = try WorkDirectory()
    }

    @Test func buildsTheManifest() throws {
        let app = try #require(AppInfo(ipa: work.ipa("Manifest.ipa", sampleAppInfo).path))
        let data = try? InstallLink.manifest(for: app, package: package)
        let item = manifestItem(data)
        #expect(
            data.map { String(decoding: $0.prefix(5), as: UTF8.self) } == "<?xml", "manifest.xml")
        #expect(
            item.assets == [["kind": "software-package", "url": package.absoluteString]],
            "manifest.asset")
        #expect(
            item.metadata == [
                "bundle-identifier": "com.acme.sample", "bundle-version": "2.1", "kind": "software",
                "title": "Sample App",
            ], "manifest.metadata")
    }

    @Test func manifestFallsBackForBareApps() throws {
        let bare = try #require(
            AppInfo(
                ipa: work.ipa(
                    "BareNames.ipa",
                    ["CFBundleIdentifier": "com.acme.bare", "CFBundleVersion": "7"]
                ).path))
        let metadata = manifestItem(try? InstallLink.manifest(for: bare, package: package)).metadata
        #expect(
            metadata?["title"] == "com.acme.bare" && metadata?["bundle-version"] == "7",
            "manifest.fallbacks")
    }

    @Test func webLinkKeepsTheEncodingVerifiedOnADevice() throws {
        let manifest = try #require(URL(string: "https://streamshare.wireway.ch/download/abc123"))
        let expected =
            "https://axorax.github.io/urlmskr/aXRtcy1zZXJ2aWNlczovLz9hY3Rpb249ZG93bmxvYWQtbWFuaWZlc3QmdXJsPWh0dHBzJTNBJTJGJTJGc3RyZWFtc2hhcmUud2lyZXdheS5jaCUyRmRvd25sb2FkJTJGYWJjMTIz"
        #expect(
            (try? InstallLink.webLink(manifest: manifest))?.absoluteString == expected,
            "webLink.verifiedOnDevice")
    }

    @Test func webLinkRoundTripsAnyManifestWithoutSlashes() {
        let characters = Array("abcXYZ019-._~:/?#[]@!$&'()*+,;=%")
        var slashCount = 0
        var roundTripFailures: [String] = []
        for _ in 0..<3000 {
            let suffix = String(
                (0..<Int.random(in: 1...60)).map { _ in characters.randomElement()! })
            guard let manifest = URL(string: "https://host.example/" + suffix) else { continue }
            guard let link = try? InstallLink.webLink(manifest: manifest) else {
                roundTripFailures.append(suffix)
                continue
            }
            let code = String(link.absoluteString.dropFirst(InstallLink.maskerURL.count))
            slashCount += code.contains("/") ? 1 : 0
            let decoded =
                Data(base64Encoded: code).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let components = URLComponents(string: decoded)
            let isRoundTrip =
                link.absoluteString.hasPrefix(InstallLink.maskerURL)
                && decoded.hasPrefix("itms-services://?action=download-manifest&url=")
                && components?.queryItems?.count == 2
                && components?.queryItems?.last?.value == manifest.absoluteString
            if !isRoundTrip {
                roundTripFailures.append(suffix)
            }
        }
        #expect(slashCount == 0, "webLink.neverSlash")
        #expect(roundTripFailures.isEmpty, "webLink.roundTrip")
    }
}
