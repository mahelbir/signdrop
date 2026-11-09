import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    struct BetaDropAPITests {
        private static let validIPA =
            Data([0x50, 0x4B, 0x03, 0x04])
            + Data((0..<3_000_000).map { _ in UInt8.random(in: .min ... .max) })
        private let mock: BetaDropMockServer
        private let work: WorkDirectory

        init() async throws {
            mock = try await BetaDropMockServer()
            work = try WorkDirectory()
        }

        private func api(_ scenario: String) -> BetaDropAPI {
            var api = BetaDropAPI(baseURL: "\(mock.api(scenario))/")
            api.stallTimeout = 2
            return api
        }

        private func ipa() -> URL {
            work.file("My \"App\"\n-İ.ipa", Self.validIPA)
        }

        @Test func whoamiSendsTheToken() async {
            let user = try? await api("ok").whoami(token: "bd_live_abc")
            #expect(
                user == BetaDropConfig.User(id: "7", email: "dev@example.com", role: "user"),
                "api.whoami.user")
            #expect(
                mock.stats["ok"]["authorization"] as? String == "Bearer bd_live_abc",
                "api.whoami.bearer")
            await #expect(throws: ShareError.sessionExpired, "api.whoami.unauthorized") {
                try await api("unauthorized").whoami(token: "bd_live_bad")
            }
        }

        @Test func logoutReachesTheServer() async {
            await api("logout").logout(token: "bd_live_abc")
            #expect(mock.stats["logout"]["logout"] as? Int == 1, "api.logout.sent")
        }

        @Test func deviceCodeIsRequestedAndDecoded() async {
            let code = try? await api("approve").requestDeviceCode(
                clientName: "SignDrop/0.1.0 (macOS/arm64)")
            #expect(
                code?.userCode == "ABCD-1234"
                    && code?.verificationURIComplete == "https://betadrop.app/device?code=ABCD-1234"
                    && code?.interval == 1, "api.deviceCode.decoded")
            let codeStats = mock.stats["approve"]
            #expect(
                codeStats["clientName"] as? String == "SignDrop/0.1.0 (macOS/arm64)",
                "api.deviceCode.body")
            #expect(codeStats["scope"] as? String == "publish read", "api.deviceCode.body")
            #expect(codeStats["hasProviderHint"] as? Bool == false, "api.deviceCode.body")
            await #expect(
                throws: ShareError.server(
                    "BetaDrop returned an error (HTTP 500). Try again, or use an API token."),
                "api.deviceCode.httpError"
            ) {
                try await api("code-error").requestDeviceCode(clientName: "x")
            }
        }

        @Test func deviceTokenPollingFollowsTheServer() async {
            let poller = api("approve")
            let first = try? await poller.pollDeviceToken(deviceCode: "dc")
            let second = try? await poller.pollDeviceToken(deviceCode: "dc")
            let third = try? await poller.pollDeviceToken(deviceCode: "dc")
            #expect(first == .pending, "api.deviceToken.pending")
            #expect(second == .slowDown(interval: 1), "api.deviceToken.slowDown")
            #expect(
                third
                    == .approved(
                        token: "bd_live_device",
                        user: .init(id: "u1", email: "dev@example.com", role: "user")),
                "api.deviceToken.approved")
            let garbage = try? await api("garbage").pollDeviceToken(deviceCode: "dc")
            #expect(garbage == .expired, "api.deviceToken.garbageMeansExpired")
        }

        @Test func reportsUnusableServers() async {
            await #expect(
                throws: ShareError.network("Could not reach BetaDrop. Check your connection."),
                "api.unreachable"
            ) {
                try await BetaDropAPI(baseURL: "http://127.0.0.1:1").whoami(token: "x")
            }
            await #expect(
                throws: ShareError.server("Invalid BetaDrop API URL: http://exa mple.com"),
                "api.invalidBaseURL"
            ) {
                try await BetaDropAPI(baseURL: "http://exa mple.com").whoami(token: "x")
            }
        }

        @Test func validatesBuildsBeforeUploading() throws {
            let folder = try work.directory("folder.ipa")
            #expect(
                throws: ShareError.invalidFile("Unsupported file type \".txt\". Expected .ipa."),
                "publish.validate.extension"
            ) {
                try BetaDropAPI.validateBuild(work.file("notes.txt", Self.validIPA))
            }
            #expect(
                throws: ShareError.invalidFile("File not found: \(work.path)/absent.ipa"),
                "publish.validate.missing"
            ) { try BetaDropAPI.validateBuild(work.child("absent.ipa")) }
            #expect(
                throws: ShareError.invalidFile("Not a file: \(work.path)/folder.ipa"),
                "publish.validate.directory"
            ) { try BetaDropAPI.validateBuild(folder) }
            #expect(throws: ShareError.invalidFile("The file is empty."), "publish.validate.empty")
            { try BetaDropAPI.validateBuild(work.file("empty.ipa", Data())) }
            #expect(
                throws: ShareError.invalidFile(
                    "This file does not appear to be a valid iOS build. Please upload a valid IPA file."
                ),
                "publish.validate.magic"
            ) {
                try BetaDropAPI.validateBuild(work.file("fake.ipa", Data("hello world".utf8)))
            }
        }

        @Test func publishesTheBuild() async throws {
            let file = ipa()
            var uploader = api("ok")
            let bodyDirectory = try work.directory("bodies")
            uploader.temporaryDirectory = bodyDirectory
            let fractions = Collector<Double>()
            let result = try? await uploader.publish(file: file, token: "bd_live_abc") {
                fractions.append($0)
            }
            _ = await isEventuallyTrue(1) { (fractions.all.last ?? 0) >= 0.99 }
            #expect(
                result?.link.absoluteString == "https://betadrop.app/install/?i=abc123",
                "publish.ok.link")
            #expect(result?.warnings == [], "publish.ok.noWarnings")
            let received = mock.stats["ok"]
            #expect(received["sha256"] as? String == sha256Hex(ofFile: file), "publish.ok.sha256")
            #expect(
                received["filename"] as? String == "My _App__-İ.ipa", "publish.ok.sanitizedFilename"
            )
            #expect(
                received["authorization"] as? String == "Bearer bd_live_abc", "publish.ok.headers")
            #expect(received["accept"] as? String == "application/json", "publish.ok.headers")
            #expect(
                (received["boundary"] as? String)?.hasPrefix("----signdrop") == true,
                "publish.ok.headers")
            #expect(
                (received["head"] as? String)?.contains("Content-Type: application/octet-stream")
                    == true && received["hasClosingBoundary"] as? Bool == true,
                "publish.ok.multipartShape")
            #expect(
                (fractions.all.last ?? 0) >= 0.99 && fractions.all == fractions.all.sorted(),
                "publish.ok.progress")
            #expect(
                (try? FileManager.default.contentsOfDirectory(atPath: bodyDirectory.path)) == [],
                "publish.ok.bodyRemoved")
        }

        @Test func warnsAboutDuplicates() async {
            let duplicate = try? await api("duplicate").publish(file: ipa(), token: "t") { _ in }
            #expect(
                duplicate?.warnings == [
                    "You already published this exact build. (https://betadrop.app/install/?i=old1)"
                ], "publish.duplicate.warning")
        }

        @Test func retriesGatewayErrors() async {
            let file = ipa()
            let start = Date()
            let retried = try? await api("html5xx-then-ok").publish(file: file, token: "t") { _ in }
            #expect(
                retried?.link.absoluteString == "https://betadrop.app/install/?i=abc123",
                "publish.retry.succeeds")
            #expect(Date().timeIntervalSince(start) >= 3, "publish.retry.backoff")
            #expect(mock.stats["html5xx-then-ok"]["publish"] as? Int == 3, "publish.retry.count")
            await #expect(
                throws: ShareError.server("Unexpected response from BetaDrop (HTTP 502)."),
                "publish.retry.exhausted"
            ) {
                try await api("html5xx-always").publish(file: file, token: "t") { _ in }
            }
            #expect(
                mock.stats["html5xx-always"]["publish"] as? Int == 3, "publish.retry.exhaustedCount"
            )
        }

        @Test func doesNotRetryServerAnswers() async {
            let file = ipa()
            await #expect(throws: ShareError.server("Storage is down"), "publish.json5xx.noRetry")
            { try await api("json5xx").publish(file: file, token: "t") { _ in } }
            #expect(mock.stats["json5xx"]["publish"] as? Int == 1, "publish.json5xx.count")
            await #expect(
                throws: ShareError.server("Upload failed (HTTP 500)."),
                "publish.json5xxObject.message"
            ) { try await api("json5xx-object").publish(file: file, token: "t") { _ in } }
            #expect(
                mock.stats["json5xx-object"]["publish"] as? Int == 1,
                "publish.json5xxObject.noRetry")
            await #expect(throws: ShareError.sessionExpired, "publish.unauthorized") {
                try await api("unauthorized").publish(file: file, token: "t") { _ in }
            }
            #expect(
                mock.stats["unauthorized"]["publish"] as? Int == 1, "publish.unauthorized.noRetry")
        }

        @Test func explainsRejectedUploads() async {
            let file = ipa()
            await #expect(
                throws: ShareError.server("Unexpected response from BetaDrop (HTTP 200)."),
                "publish.notJSON"
            ) { try await api("not-json").publish(file: file, token: "t") { _ in } }
            await #expect(throws: ShareError.server("Plan limit reached"), "publish.successFalse")
            { try await api("success-false").publish(file: file, token: "t") { _ in } }
            await #expect(
                throws: ShareError.server("Upload failed (HTTP 422)."), "publish.errorNoMessage"
            ) { try await api("error-no-message").publish(file: file, token: "t") { _ in } }
            await #expect(
                throws: ShareError.server("Upload failed (HTTP 422)."), "publish.errorObject"
            ) { try await api("error-object").publish(file: file, token: "t") { _ in } }
            await #expect(throws: ShareError.server("Too many uploads"), "publish.rateLimit") {
                try await api("rate-limit").publish(file: file, token: "t") { _ in }
            }
            await #expect(
                throws: ShareError.server("Unexpected response from BetaDrop (HTTP 200)."),
                "publish.missingShortID"
            ) {
                try await api("missing-short-id").publish(file: file, token: "t") { _ in }
            }
        }

        @Test func reportsAStalledUpload() async {
            await #expect(
                throws: ShareError.network(
                    "Upload stalled — no data for 2s. Check your connection."), "publish.stall"
            ) {
                try await api("stall").publish(file: ipa(), token: "t") { _ in }
            }
        }

        @Test func removesOnlyAbandonedBodies() async throws {
            var cleaner = api("ok~cleanup")
            let cleanupDirectory = try work.directory("cleanup")
            cleaner.temporaryDirectory = cleanupDirectory
            for name in ["signdrop-upload-STALE", "signdrop-upload-BUSY", "other-file"] {
                FileManager.default.createFile(
                    atPath: cleanupDirectory.appendingPathComponent(name).path,
                    contents: Data("body".utf8))
            }
            let busyDescriptor = open(
                cleanupDirectory.appendingPathComponent("signdrop-upload-BUSY").path, O_RDONLY)
            flock(busyDescriptor, LOCK_EX)
            let cleanedResult = try? await cleaner.publish(file: ipa(), token: "t") { _ in }
            close(busyDescriptor)
            let remaining = try FileManager.default.contentsOfDirectory(
                atPath: cleanupDirectory.path
            ).sorted()
            #expect(
                cleanedResult != nil && remaining == ["other-file", "signdrop-upload-BUSY"],
                "publish.staleBodiesRemoved")
        }

        @Test func reportsAnUnwritableBodyDirectory() async {
            var noDisk = api("ok")
            noDisk.temporaryDirectory = URL(fileURLWithPath: "/nonexistent-signdrop-dir")
            let file = ipa()
            await #expect(
                throws: ShareError.invalidFile(
                    "Could not prepare the upload in /nonexistent-signdrop-dir."),
                "publish.bodyDirectoryUnwritable"
            ) {
                try await noDisk.publish(file: file, token: "t") { _ in }
            }
        }

        @Test func uploadsLargeFilesWithBoundedMemory() async throws {
            let large = work.file("Large.ipa", Data([0x50, 0x4B, 0x03, 0x04]))
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: 256 << 20)
            try handle.close()
            let api = api("ok~large")
            var link: String?
            let growth = await peakResidentGrowth {
                link =
                    (try? await api.publish(file: large, token: "t") { _ in })?.link.absoluteString
            }
            #expect(link == "https://betadrop.app/install/?i=abc123", "publish.largeFile.uploaded")
            #expect(growth < 64, "publish.largeFile.boundedMemory")
        }
    }
}
