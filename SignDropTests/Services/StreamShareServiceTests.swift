import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct StreamShareServiceTests {
        private let mock: StreamShareMockServer
        private let work: WorkDirectory

        init() async throws {
            mock = try await StreamShareMockServer()
            work = try WorkDirectory()
        }

        private func service(_ scenario: String, shortener: String? = nil) -> StreamShareService {
            StreamShareService(
                api: mock.api(scenario), shorteners: mock.shorteners(shortener ?? scenario))
        }

        private func ipa() -> URL {
            work.ipa("Service.ipa", sampleAppInfo)
        }

        @Test func needsNoAccount() {
            let happy = service("ok~service")
            #expect(happy.name == "StreamShare", "service.name")
            #expect(happy.accountName == nil, "service.noAccount")
            #expect(!happy.isSignInRequired, "service.noSignIn")
        }

        @Test func isRegisteredAfterBetaDrop() {
            #expect(UploadServices.all.first?.isSignInRequired == true, "service.betaDropSignIn")
            #expect(
                UploadServices.all.map(\.name) == ["BetaDrop", "StreamShare", "Cloudflare Tunnel"],
                "service.registered")
        }

        @Test func uploadsTheIPAAndItsManifest() async {
            let ipa = ipa()
            let fractions = Collector<Double>()
            let result = try? await service("ok~service").upload(ipa) { fractions.append($0) }
            _ = await isEventuallyTrue(3) { mock.uploads("ok~service").count == 2 }
            let api = mock.api("ok~service")
            let ipaFile = StreamShareFile(id: "ok~service-1", deletionToken: "tok1")
            let manifestFile = StreamShareFile(id: "ok~service-2", deletionToken: "tok2")
            let expected = UploadResult(
                link: URL(string: "https://ulvis.net/mock-ok~service"),
                warnings: [],
                deletionRequests: [
                    api.deletionRequest(for: ipaFile), api.deletionRequest(for: manifestFile),
                ]
            )
            #expect(result == expected, "service.upload.result")
            let stats = mock.stats["ok~service"]
            #expect(
                stats["names"] as? [String] == ["Service.ipa", "manifest.plist"],
                "service.upload.names")
            #expect(
                mock.uploads("ok~service").first?["sha256"] as? String == sha256Hex(ofFile: ipa),
                "service.upload.ipaBytes")
            let manifest = manifestItem(await download(api.downloadURL(for: manifestFile)))
            #expect(
                manifest.assets?.first?["url"] == api.downloadURL(for: ipaFile).absoluteString,
                "service.upload.manifestPointsToIPA")
            #expect(
                manifest.metadata?["bundle-identifier"] == "com.acme.sample"
                    && manifest.metadata?["title"] == "Sample App",
                "service.upload.manifestMetadata")
            #expect(
                stats["ulvisUrl"] as? String
                    == (try? InstallLink.webLink(manifest: api.downloadURL(for: manifestFile)))?
                    .absoluteString, "service.upload.shortensWebLink")
            #expect(fractions.all.last == 1, "service.upload.progress")
            #expect(stats["deleted"] == nil, "service.upload.keepsFiles")
        }

        @Test func keepsTheWebLinkWhenShorteningFails() async {
            let fallbackAPI = mock.api("ok~fallback")
            let fallback = try? await service("ok~fallback", shortener: "fail-all~service").upload(
                ipa()
            ) { _ in }
            let fallbackManifest = StreamShareFile(id: "ok~fallback-2", deletionToken: "tok2")
            #expect(
                fallback?.link
                    == (try? InstallLink.webLink(
                        manifest: fallbackAPI.downloadURL(for: fallbackManifest))),
                "service.shortenFails.webLink")
            #expect(
                fallback?.warnings == [
                    "Could not shorten the link (Ulvis, Spoo.me, CleanURI, TinyURL)."
                ], "service.shortenFails.warning")
            #expect(
                fallback?.deletionRequests.count == 2
                    && mock.stats["ok~fallback"]["deleted"] == nil,
                "service.shortenFails.keepsFiles")
        }

        @Test func deletesTheIPAWhenTheManifestFails() async {
            let ipa = ipa()
            await #expect(
                throws: UploadError.server("StreamShare could not start the upload (HTTP 500)."),
                "service.manifestFails"
            ) { try await service("manifest-fail").upload(ipa) { _ in } }
            _ = await isEventuallyTrue(3) { mock.stats["manifest-fail"]["deleted"] != nil }
            #expect(
                mock.stats["manifest-fail"]["deleted"] as? [String] == ["manifest-fail-1/tok1"],
                "service.manifestFails.deletesIPA")
        }

        @Test func rejectsAnInvalidIPABeforeUploading() async {
            let fake = work.file("NotAnApp.ipa", Data("hello world".utf8))
            await #expect(
                throws: UploadError.invalidFile(
                    "This file does not appear to be a valid iOS build. Please upload a valid IPA file."
                ),
                "service.invalidIPA"
            ) {
                try await service("ok~invalid").upload(fake) { _ in }
            }
            #expect(mock.stats["ok~invalid"]["create"] == nil, "service.invalidIPA.skipsUpload")
        }
    }
}
