import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct BetaDropServiceTests {
        private let mock: BetaDropMockServer
        private let work: WorkDirectory
        private let configURL: URL

        init() async throws {
            mock = try await BetaDropMockServer()
            work = try WorkDirectory()
            configURL = work.child("service/config.json")
        }

        private func service(_ scenario: String) -> BetaDropService {
            BetaDropService(configURL: configURL, defaultAPIURL: mock.api(scenario))
        }

        private var isConfigSaved: Bool {
            FileManager.default.fileExists(atPath: configURL.path)
        }

        private func storeConfig(scenario: String, token: String, user: BetaDropConfig.User? = nil)
            throws
        {
            try BetaDropConfig(apiUrl: mock.api(scenario), token: token, user: user).write(
                to: configURL)
        }

        private func ipa() -> URL {
            work.file(
                "Service.ipa", Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 1, count: 1000))
        }

        @Test func describesASignedOutService() {
            let service = service("ok~service")
            #expect(service.name == "BetaDrop", "service.name")
            #expect(
                service.clientName.hasPrefix("SignDrop/") && service.clientName.contains("(macOS/"),
                "service.clientName")
            #expect(service.accountName == nil, "service.signedOut")
        }

        @Test func browserSignInSavesTheAccount() async throws {
            let notifications = Collector<Int>()
            let observer = NotificationCenter.default.addObserver(
                forName: .shareAccountDidChange, object: nil, queue: nil
            ) { _ in notifications.append(1) }
            defer { NotificationCenter.default.removeObserver(observer) }
            let service = service("approve~service")
            let shownCodes = Collector<String>()
            try await service.signInWithBrowser { shownCodes.append($0.userCode) }
            let saved = BetaDropConfig.read(from: configURL)
            #expect(shownCodes.all == ["ABCD-1234"], "service.browser.code")
            #expect(
                saved?.token == "bd_live_device" && saved?.apiUrl == mock.api("approve~service")
                    && service.accountName == "dev@example.com", "service.browser.saved")
            #expect(notifications.all.count == 1, "service.browser.notified")
        }

        @Test func browserSignInAsksWhoamiWithoutAUser() async throws {
            try await service("approve-no-user").signInWithBrowser { _ in }
            #expect(
                BetaDropConfig.read(from: configURL)?.user?.email == "dev@example.com",
                "service.browser.whoamiFallback")
        }

        @Test func browserSignInReportsFailures() async {
            await #expect(
                throws: ShareError.server("Sign-in was denied in the browser."),
                "service.browser.denied"
            ) { try await service("deny").signInWithBrowser { _ in } }
            await #expect(
                throws: ShareError.server("The code expired. Try again."),
                "service.browser.expired"
            ) { try await service("expire").signInWithBrowser { _ in } }
        }

        @Test func browserSignInCanBeCancelled() async {
            let slow = service("slow")
            let task = Task { try await slow.signInWithBrowser { _ in } }
            await pause(1.5)
            task.cancel()
            let result = await task.result
            var isCancelled = false
            if case .failure(let error) = result {
                isCancelled = error is CancellationError
            }
            #expect(isCancelled, "service.browser.cancel")
            await pause(1.5)
            #expect(!isConfigSaved, "service.browser.cancelSavesNothing")
        }

        @Test func browserSignInSurvivesANegativeInterval() async throws {
            try await service("bad-interval").signInWithBrowser { _ in }
            #expect(
                BetaDropConfig.read(from: configURL)?.token == "bd_live_device",
                "service.browser.negativeIntervalSurvives")
        }

        @Test func tokenSignInChecksThePrefixAndSaves() async throws {
            let tokenService = service("ok~service")
            await #expect(
                throws: ShareError.server(
                    "That doesn't look like a BetaDrop token (expected to start with bd_live_)."),
                "service.token.prefix"
            ) {
                try await tokenService.signIn(token: "nope")
            }
            try await tokenService.signIn(token: "  bd_live_pasted \n")
            #expect(
                BetaDropConfig.read(from: configURL)?.token == "bd_live_pasted"
                    && tokenService.accountName == "dev@example.com", "service.token.saved")
        }

        @Test func rejectedTokenSavesNothing() async {
            await #expect(throws: ShareError.sessionExpired, "service.token.rejected") {
                try await service("unauthorized").signIn(token: "bd_live_bad")
            }
            #expect(!isConfigSaved, "service.token.rejectedSavesNothing")
        }

        @Test(arguments: [("apiUrlOnly", "ok~keep1", ""), ("emptyToken", "ok~keep2", "/")])
        func tokenSignInKeepsTheStoredServer(label: String, scenario: String, suffix: String)
            async throws
        {
            let token = label == "emptyToken" ? ",\"token\":\"\"" : ""
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\"apiUrl\":\"\(mock.api(scenario))\(suffix)\"\(token)}".write(
                to: configURL, atomically: true, encoding: .utf8)
            try? await service("ok~default").signIn(token: "bd_live_keep")
            #expect(
                BetaDropConfig.read(from: configURL)?.apiUrl == mock.api(scenario)
                    && mock.stats[scenario]["whoami"] as? Int == 1,
                "service.token.keepsStoredAPIURL.\(label)")
        }

        @Test func uploadNeedsASession() async throws {
            let file = ipa()
            let tokenService = service("ok~service")
            await #expect(throws: ShareError.sessionExpired, "service.upload.signedOut") {
                try await tokenService.share(file) { _ in }
            }
            try storeConfig(
                scenario: "ok", token: "bd_live_abc",
                user: .init(id: "1", email: "dev@example.com", role: nil))
            let uploaded = try? await tokenService.share(file) { _ in }
            #expect(
                uploaded
                    == ShareResult(
                        link: URL(string: "https://betadrop.app/install/?i=abc123"), warnings: []),
                "service.upload.link")
        }

        @Test func expiredSessionClearsTheAccount() async throws {
            let notifications = Collector<Int>()
            let observer = NotificationCenter.default.addObserver(
                forName: .shareAccountDidChange, object: nil, queue: nil
            ) { _ in notifications.append(1) }
            defer { NotificationCenter.default.removeObserver(observer) }
            let file = ipa()
            let tokenService = service("ok~service")
            try storeConfig(scenario: "unauthorized", token: "bd_live_revoked")
            #expect(tokenService.accountName == "unknown account", "service.account.unknownEmail")
            await #expect(throws: ShareError.sessionExpired, "service.upload.expired") {
                try await tokenService.share(file) { _ in }
            }
            #expect(
                !isConfigSaved && notifications.all.count == 1, "service.upload.expiredClearsConfig"
            )
        }

        @Test func followsAnExternalLogout() throws {
            let tokenService = service("ok~service")
            try storeConfig(scenario: "signout", token: "bd_live_abc")
            try FileManager.default.removeItem(at: configURL)
            #expect(tokenService.accountName == nil, "service.account.externalLogout")
        }

        @Test func signOutRevokesAndClears() async throws {
            let tokenService = service("ok~service")
            try storeConfig(scenario: "signout", token: "bd_live_abc")
            await tokenService.signOut()
            let signOutStats = mock.stats["signout"]
            #expect(
                signOutStats["logout"] as? Int == 1
                    && signOutStats["authorization"] as? String == "Bearer bd_live_abc",
                "service.signOut.revoked")
            #expect(!isConfigSaved && tokenService.accountName == nil, "service.signOut.cleared")
        }
    }
}
