import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct TunnelShareServiceTests {
        private let work: WorkDirectory
        private let ipa: URL

        init() throws {
            work = try WorkDirectory()
            ipa = work.ipa("OTA.ipa", sampleAppInfo)
        }

        private func shareService(_ mode: FakeTunnel.Mode) -> (
            service: TunnelShareService, tunnel: FakeTunnel, logged: Collector<String>
        ) {
            let tunnel = FakeTunnel(mode)
            let service = TunnelShareService(tunnel: tunnel)
            service.readyTimeout = 2
            let logged = Collector<String>()
            service.log = { logged.append($0) }
            return (service, tunnel, logged)
        }

        @Test func buildsTheItmsLink() {
            let manifest = URL(string: "https://host.example/tok/manifest.plist")!
            let expected =
                "itms-services://?action=download-manifest&url=https%3A%2F%2Fhost.example%2Ftok%2Fmanifest.plist"
            #expect(InstallLink.itmsLink(manifest: manifest) == expected, "link.itmsLink")
        }

        @Test func keepsALinkThatCannotBeShortened() async {
            let keptLink = URL(string: "https://example.com/page")!
            let kept = try? await InstallLink.shortenOrKeep(
                keptLink, with: [], session: ShareServices.session)
            #expect(
                kept?.link == keptLink && kept?.warnings == ["Could not shorten the link ()."],
                "link.shortenOrKeep")
        }

        @Test func sharesTheInstallPageAndTheRawLink() async {
            let (direct, _, _) = shareService(.passthrough)
            let result = try? await direct.share(ipa) { _ in }
            let installURL = result?.link
            #expect(installURL?.lastPathComponent == "install", "share.installLink")
            #expect(
                installURL?.absoluteString.hasPrefix("http://127.0.0.1:") == true,
                "share.installLink")
            #expect(result?.warnings == [], "share.noThirdPartyWarnings")
            let installHead = installURL.map { responseHead($0) }
            let expectedManifest = installURL?.deletingLastPathComponent().appendingPathComponent(
                "manifest.plist")
            #expect(
                installHead?.status == "HTTP/1.1 302 Found"
                    && installHead?.location
                        == expectedManifest.map { InstallLink.itmsLink(manifest: $0) },
                "share.installRedirects")
            #expect(
                result?.itmsLink != nil && result?.itmsLink == installHead?.location,
                "share.rawLink")
            #expect(
                await httpRequest(
                    manifestURL(fromItmsLink: installHead?.location) ?? URL(fileURLWithPath: "/")
                ).status == 200, "share.redirectManifestServed")
            result?.liveShare?.stop()
        }

        @Test func followsTheTunnelReadiness() {
            let (service, tunnel, _) = shareService(.passthrough)
            #expect(
                service.name == "Fake Tunnel" && service.isLiveShare && !service.isSignInRequired
                    && service.accountName == nil, "share.identity")
            tunnel.isReady = false
            #expect(!service.isReadyToShare, "share.notReadyFollowsTunnel")
            tunnel.isReady = true
            #expect(service.isReadyToShare, "share.readyFollowsTunnel")
        }

        @Test func sharesAndStops() async throws {
            let app = try #require(AppInfo(ipa: ipa.path))
            let ipaData = try Data(contentsOf: ipa)
            let (service, tunnel, logged) = shareService(.passthrough)
            let result = try await service.share(ipa) { _ in }
            let share = result.liveShare
            #expect(share?.isActive == true, "share.live")
            let manifest = manifestURL(fromItmsLink: result.itmsLink)
            #expect(
                manifest?.lastPathComponent == "manifest.plist"
                    && manifest?.absoluteString.hasPrefix(
                        "http://127.0.0.1:\(tunnel.openedPort ?? 0)/") == true,
                "share.manifestPath")
            let item = manifestItem(await httpRequest(manifest ?? URL(fileURLWithPath: "/")).data)
            let package = item.assets?.first?["url"].flatMap(URL.init(string:))
            #expect(item.metadata?["bundle-identifier"] == app.bundleID, "share.manifestContent")
            #expect(package?.lastPathComponent == "app.ipa", "share.manifestContent")
            #expect(
                package?.deletingLastPathComponent() == manifest?.deletingLastPathComponent(),
                "share.manifestContent")
            #expect(
                await httpRequest(package ?? URL(fileURLWithPath: "/")).data == ipaData,
                "share.packageBytes")
            #expect(
                logged.all.contains { $0.hasPrefix("GET /") && $0.hasSuffix("/app.ipa 200") },
                "share.logsRequests")
            #expect(
                logged.all.contains { $0.hasPrefix("Fake Tunnel: link check passed after ") },
                "share.logsCheckPassed")
            #expect(isSleepBlocked(), "share.blocksSleep")

            share?.stop()
            share?.stop()
            #expect(
                tunnel.isClosed && share?.isActive == false, "share.stopClosesTunnel")
            #expect(
                await httpRequest(manifest ?? URL(fileURLWithPath: "/")).status == 0,
                "share.stopClosesServer")
            let isSleepAllowed = await isEventuallyTrue(2) { !isSleepBlocked() }
            #expect(isSleepAllowed, "share.stopAllowsSleep")
        }

        @Test func endsWhenTheTunnelDrops() async {
            let (service, tunnel, _) = shareService(.passthrough)
            let result = try? await service.share(ipa) { _ in }
            let reasons = Collector<String>()
            result?.liveShare?.onEnd = { reasons.append($0) }
            tunnel.tunnel?.reportUnexpectedClose("ERR lost")
            #expect(
                reasons.all == ["ERR lost"] && result?.liveShare?.isActive == false,
                "share.unexpectedEnd")
            #expect(
                await httpRequest(
                    manifestURL(fromItmsLink: result?.itmsLink) ?? URL(fileURLWithPath: "/")
                ).status == 0, "share.unexpectedEndClosesServer")
        }

        @Test func twoSharesRunSideBySide() async {
            let first = try? await shareService(.passthrough).service.share(ipa) { _ in }
            let second = try? await shareService(.passthrough).service.share(ipa) { _ in }
            #expect(
                first?.liveShare?.isActive == true && second?.liveShare?.isActive == true,
                "share.sideBySide")
            first?.liveShare?.stop()
            #expect(
                first?.liveShare?.isActive == false && second?.liveShare?.isActive == true,
                "share.stopsOnlyItself")
            second?.liveShare?.stop()
        }

        @Test func failsWhenTheTunnelDropsAfterTheLinkCheck() async {
            let (service, tunnel, _) = shareService(.passthrough)
            service.log = { line in
                if line.hasPrefix("HEAD ") && line.hasSuffix("/manifest.plist 200") {
                    Task { @MainActor in tunnel.tunnel?.reportUnexpectedClose("ERR lost") }
                }
            }
            var message: String?
            do {
                _ = try await service.share(ipa) { _ in }
            } catch {
                message = error.localizedDescription
            }
            let isServerClosed =
                await httpRequest(URL(string: "http://127.0.0.1:\(tunnel.openedPort ?? 0)/")!)
                .status == 0
            #expect(
                message == "ERR lost" && isServerClosed, "share.dropsAfterReady")
        }

        @Test func logsWhyTheLinkCheckFailed() async {
            let (service, _, logged) = shareService(.unreachable)
            _ = try? await service.share(ipa) { _ in }
            let lines = logged.all.filter { $0.hasPrefix("Fake Tunnel: link check ") }
            #expect(
                lines.count == 1 && lines[0].contains("NSURLErrorDomain -1004"),
                "share.logsCheckFailures")
        }

        @Test func checksAFreshHostnameWithoutTheSystemResolver() async {
            let (service, _, logged) = shareService(.pinned)
            let result = try? await service.share(ipa) { _ in }
            #expect(result?.link?.host == "fresh-host.invalid", "share.pinnedCheckSkipsResolver")
            #expect(
                logged.all.contains { $0.hasPrefix("Fake Tunnel: link check passed after ") },
                "share.pinnedCheckSkipsResolver")
            #expect(
                logged.all.contains {
                    $0.hasPrefix("HEAD /") && $0.hasSuffix("/manifest.plist 200")
                }, "share.pinnedCheckSkipsResolver")
            result?.liveShare?.stop()
        }

        @Test func logsTheCurlExitOfAPinnedCheck() async {
            let (service, _, logged) = shareService(.pinnedUnreachable)
            _ = try? await service.share(ipa) { _ in }
            let lines = logged.all.filter { $0.hasPrefix("Fake Tunnel: link check ") }
            #expect(
                lines.count == 1 && lines[0].contains("curl exit 7"), "share.pinnedLogsCurlExit")
        }

        @Test func failedSharesCleanUp() async throws {
            let notIPA = work.file("not.ipa", Data("nope".utf8))
            let cases: [(name: String, mode: FakeTunnel.Mode, file: URL, expected: ShareError)] = [
                ("share.invalidBuild", .passthrough, notIPA, .invalidBuild),
                ("share.tunnelFails", .fail, ipa, .server("ERR boom")),
                (
                    "share.unreachable", .unreachable, ipa,
                    .server("The link did not become reachable.")
                ),
                (
                    "share.pinnedUnreachable", .pinnedUnreachable, ipa,
                    .server("The link did not become reachable.")
                ),
                ("share.dropsWhileStarting", .dropsWhileStarting, ipa, .server("ERR lost")),
            ]
            for item in cases {
                let (service, tunnel, _) = shareService(item.mode)
                let started = Date()
                await #expect(throws: item.expected, "\(item.name)") {
                    try await service.share(item.file) { _ in }
                }
                var isServerClosed = true
                if let port = tunnel.openedPort {
                    isServerClosed =
                        await httpRequest(URL(string: "http://127.0.0.1:\(port)/")!).status == 0
                }
                #expect(
                    isServerClosed && (tunnel.tunnel == nil || tunnel.isClosed)
                        && Date().timeIntervalSince(started) < 5,
                    "\(item.name).cleanup")
            }
        }

        @Test func resultsCompareTheirLiveShare() {
            let equalShare = LiveShare {}
            let sharing = ShareResult(link: nil, warnings: [], liveShare: equalShare)
            #expect(
                sharing == ShareResult(link: nil, warnings: [], liveShare: equalShare),
                "share.resultEquatable")
            #expect(ShareResult(link: nil, warnings: []) != sharing, "share.resultEquatable")
            equalShare.stop()
        }

        @Test func otherServicesAreNotLiveShares() {
            #expect(
                StreamshareService().isReadyToShare && !StreamshareService().isLiveShare,
                "share.defaultsForOthers")
            #expect(
                ShareServices.all.map(\.name) == [
                    "BetaDrop", "Streamshare", "Cloudflare Quick Tunnel",
                ]
                    && ShareServices.all.last?.isLiveShare == true, "share.registered")
        }
    }
}
