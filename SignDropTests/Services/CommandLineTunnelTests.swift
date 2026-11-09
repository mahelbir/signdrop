import AppKit
import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct CommandLineTunnelTests {
        private let work: WorkDirectory

        init() throws {
            work = try WorkDirectory()
            try work.installFakeTunnelTools()
        }

        private func mockTunnel(
            _ behaviour: String, marker: String, timeout: TimeInterval = 5,
            hasFreshHostname: Bool = false
        ) -> CommandLineTunnel {
            let tunnel = CommandLineTunnel(
                name: "Mock Tunnel",
                executable: "mock-tunnel",
                brewPackage: "mock-tunnel",
                installPage: URL(string: "https://example.com/install")!,
                arguments: { port in [behaviour, marker, "\(port)"] },
                publicURLPattern: CommandLineTunnel.cloudflareQuickTunnel().publicURLPattern,
                hasFreshHostname: hasFreshHostname
            )
            tunnel.searchPaths = [work.path]
            tunnel.loginShell = nil
            tunnel.startTimeout = timeout
            tunnel.log = { _ in }
            return tunnel
        }

        private func openError(_ tunnel: CommandLineTunnel) async -> String? {
            do {
                _ = try await tunnel.open(port: 1)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        private func hasStopped(_ marker: String) async -> Bool {
            await isEventuallyTrue(2) { !isAlive(marker) }
        }

        @Test func quickTunnelUsesTheVerifiedSetup() {
            let quickTunnel = CommandLineTunnel.cloudflareQuickTunnel()
            #expect(
                quickTunnel.name == "Cloudflare Quick Tunnel"
                    && quickTunnel.executable == "cloudflared",
                "quickTunnel.name")
            #expect(quickTunnel.installCommand == "brew install cloudflared", "quickTunnel.install")
            #expect(
                quickTunnel.installPage.absoluteString
                    == "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/#macos",
                "quickTunnel.install"
            )
            #expect(
                quickTunnel.arguments(8080) == [
                    "tunnel", "--no-autoupdate", "--config", "/dev/null", "--grace-period", "1s",
                    "--url", "http://127.0.0.1:8080",
                ], "quickTunnel.arguments")
            #expect(
                quickTunnel.searchPaths == ["/opt/homebrew/bin", "/usr/local/bin"]
                    && quickTunnel.loginShell == "/bin/zsh" && quickTunnel.startTimeout == 30,
                "quickTunnel.searchPaths")
            #expect(
                quickTunnel.hasFreshHostname
                    && !mockTunnel("url", marker: "unused").hasFreshHostname,
                "quickTunnel.freshHostname")
            #expect(quickTunnel.unreachableDNSDelay == 8, "quickTunnel.dnsFallbackDelay")
            #expect(quickTunnel.unreachableDNSAttempts == 3, "quickTunnel.dnsFallbackAttempts")
        }

        @Test func parsesDNSAnswers() {
            #expect(
                AuthoritativeDNS.addresses(in: ["edge.example.net.", "104.16.1.1"]) == [
                    "104.16.1.1"
                ], "dns.addressesSkipNonIPv4")
            #expect(
                AuthoritativeDNS.records(in: ";; Warning, ignoring\n104.16.1.1\n\n") == [
                    "104.16.1.1"
                ], "dns.recordsSkipComments")
        }

        @Test func findsThePublicURLInToolOutput() {
            let quickTunnel = CommandLineTunnel.cloudflareQuickTunnel()
            let banner =
                "2026-09-28T10:00:00Z INF |  https://quiet-river-sample-words.trycloudflare.com                                   |"
            #expect(
                quickTunnel.publicURL(in: banner)?.absoluteString
                    == "https://quiet-river-sample-words.trycloudflare.com",
                "quickTunnel.urlFromBanner")
            let apiError =
                "2026-09-28T10:00:00Z ERR failed to request quick Tunnel: Post \"https://api.trycloudflare.com/tunnel\": dial tcp: lookup api.trycloudflare.com: no such host"
            #expect(quickTunnel.publicURL(in: apiError) == nil, "quickTunnel.ignoresAPIHost")
        }

        @Test func opensAndClosesATunnel() async {
            let marker = newMarker()
            let happy = mockTunnel("url", marker: marker)
            let output = Collector<String>()
            happy.log = { output.append($0) }
            #expect(
                happy.isReady && happy.executablePath == work.child("mock-tunnel").path,
                "tunnel.ready")
            let open = try? await happy.open(port: 8080)
            #expect(
                open?.publicURL.absoluteString == "https://abc-def.trycloudflare.com", "tunnel.url")
            #expect(
                output.all.contains(
                    "Mock Tunnel: 2026-09-28T10:00:00Z INF |  https://abc-def.trycloudflare.com  |"),
                "tunnel.logsOutput")
            #expect(isAlive("url \(marker)"), "tunnel.running")
            #expect(isAlive("\(marker) 8080"), "tunnel.portPassed")
            open?.close()
            open?.close()
            let isStopped = await hasStopped(marker)
            #expect(isStopped && open?.isClosed == true, "tunnel.closeStops")
        }

        @Test func reportsAToolThatExitsEarly() async {
            #expect(
                await openError(mockTunnel("fail", marker: newMarker()))
                    == "ERR failed to request quick Tunnel: 429", "tunnel.earlyExitLastLine")
        }

        @Test func stopsASilentToolAtTheDeadline() async {
            let marker = newMarker()
            let started = Date()
            let message = await openError(mockTunnel("silent", marker: marker, timeout: 1))
            #expect(message == "The tunnel did not start in time.", "tunnel.timeoutMessage")
            #expect(Date().timeIntervalSince(started) < 10, "tunnel.timeoutMessage")
            #expect(await hasStopped(marker), "tunnel.timeoutStops")
        }

        @Test func cancellingAStartingTunnelStopsTheTool() async {
            let marker = newMarker()
            let tunnel = mockTunnel("silent", marker: marker, timeout: 20)
            let opening = Task { try await tunnel.open(port: 1) }
            #expect(await isEventuallyTrue(3) { isAlive(marker) }, "tunnel.cancelStarted")
            opening.cancel()
            let outcome = await opening.result
            #expect(throws: CancellationError.self, "tunnel.cancelThrows") { try outcome.get() }
            #expect(await hasStopped(marker), "tunnel.cancelStops")
        }

        @Test func keepsTheLastLineOnTimeout() async {
            let message = await openError(
                mockTunnel("chatty-silent", marker: newMarker(), timeout: 1))
            #expect(
                message == "The tunnel did not start in time. Last output: INF still connecting",
                "tunnel.timeoutKeepsLastLine")
        }

        @Test func reportsAnUnexpectedClose() async {
            let dropping = try? await mockTunnel("url-then-exit", marker: newMarker()).open(port: 1)
            let reasons = Collector<String>()
            dropping?.onUnexpectedClose = { reasons.append($0) }
            let isDropped = await isEventuallyTrue(3) { dropping?.isClosed == true }
            #expect(isDropped && reasons.all == ["ERR connection lost"], "tunnel.unexpectedClose")
        }

        @Test func explainsAMissingTool() async {
            let missing = mockTunnel("url", marker: "unused")
            missing.searchPaths = ["/nonexistent"]
            #expect(!missing.isReady && missing.executablePath == nil, "tunnel.missingNotReady")
            #expect(
                await openError(missing)
                    == "Mock Tunnel needs mock-tunnel. Install it and try again.",
                "tunnel.missingOpenThrows")
            let noBrew = missing.makeInstallAlert()
            #expect(noBrew.messageText == "Mock Tunnel needs mock-tunnel", "installAlert.noBrew")
            #expect(
                noBrew.informativeText
                    == "Download it from the install page, put it in /usr/local/bin, then try again.",
                "installAlert.noBrew")
            #expect(
                noBrew.buttons.map(\.title) == ["Open Install Page", "Cancel"],
                "installAlert.noBrew")
            missing.searchPaths = ["/nonexistent", work.child("fakebrew").path]
            let withBrew = missing.makeInstallAlert()
            #expect(
                withBrew.informativeText
                    == "Install it with Homebrew by running “brew install mock-tunnel” in Terminal, then try again.",
                "installAlert.withBrew")
            #expect(
                withBrew.buttons.map(\.title) == ["Copy Command", "Open Install Page", "Cancel"],
                "installAlert.withBrew")
        }

        @Test func findsTheToolThroughTheLoginShell() async {
            let shellOnly = mockTunnel("url", marker: "unused")
            shellOnly.searchPaths = ["/nonexistent"]
            shellOnly.loginShell = work.child("fake-shell").path
            #expect(!shellOnly.isReady, "loginShell.notReadyBefore")
            let isPrepared = await shellOnly.prepare(in: NSWindow())
            #expect(
                isPrepared && shellOnly.isReady
                    && shellOnly.executablePath == work.child("mock-tunnel").path,
                "loginShell.found")
        }

        @Test func waitsUntilTheHostnameIsPublished() async throws {
            let marker = newMarker()
            let lookups = Collector<String>()
            let publishing = mockTunnel("url", marker: marker, hasFreshHostname: true)
            let dnsLog = Collector<String>()
            publishing.log = { dnsLog.append($0) }
            publishing.hostnameAnswer = { host in
                lookups.append(host)
                return lookups.all.count >= 3 ? .published(["104.16.1.1"]) : .missing
            }
            let published = try? await publishing.open(port: 1)
            #expect(
                published != nil
                    && lookups.all == Array(repeating: "abc-def.trycloudflare.com", count: 3),
                "dns.waitsUntilPublished")
            #expect(published?.onUnexpectedClose == nil, "dns.handlerFreeAfterWait")
            #expect(published?.resolvedAddresses == ["104.16.1.1"], "dns.keepsAddresses")
            let dnsLines = dnsLog.all.filter { $0.hasPrefix("Mock Tunnel: DNS ") }
            try #require(dnsLines.count == 2, "dns.logsProgress")
            #expect(
                dnsLines[0].hasPrefix(
                    "Mock Tunnel: DNS missing for abc-def.trycloudflare.com after "),
                "dns.logsProgress")
            #expect(
                dnsLines[1].hasPrefix(
                    "Mock Tunnel: DNS published([\"104.16.1.1\"]) for abc-def.trycloudflare.com after "
                ), "dns.logsProgress")
            published?.close()
            #expect(await hasStopped(marker), "dns.closeAfterWaitStops")
        }

        @Test func failsWhenTheHostnameIsNeverPublished() async {
            let marker = newMarker()
            let unpublished = mockTunnel("url", marker: marker, timeout: 1, hasFreshHostname: true)
            unpublished.hostnameAnswer = { _ in .missing }
            let started = Date()
            let message = await openError(unpublished)
            #expect(
                message == "The tunnel address was not published in time.",
                "dns.unpublishedTimesOut")
            #expect(Date().timeIntervalSince(started) < 10, "dns.unpublishedTimesOut")
            #expect(await hasStopped(marker), "dns.unpublishedStops")
        }

        @Test func reportsAToolThatDiesWhileWaitingForDNS() async {
            let dropping = mockTunnel("url-then-exit", marker: newMarker(), hasFreshHostname: true)
            dropping.hostnameAnswer = { _ in .missing }
            #expect(await openError(dropping) == "ERR connection lost", "dns.closeWhileWaiting")
        }

        @Test func fallsBackWhenDNSIsUnreachable() async {
            let marker = newMarker()
            let lookups = Collector<String>()
            let blocked = mockTunnel("url", marker: marker, hasFreshHostname: true)
            blocked.unreachableDNSDelay = 0.5
            blocked.hostnameAnswer = { host in
                lookups.append(host)
                return .unreachable
            }
            let started = Date()
            let open = try? await blocked.open(port: 1)
            let wait = Date().timeIntervalSince(started)
            #expect(open != nil && lookups.all.count == 3, "dns.unreachableFallsBack")
            #expect(wait >= 1.5 && wait < 10, "dns.unreachableFallsBack")
            #expect(open?.resolvedAddresses == [], "dns.unreachableHasNoAddresses")
            open?.close()
            #expect(await hasStopped(marker), "dns.unreachableCloseStops")
        }

        @Test func retriesAfterAnUnreachableAnswer() async {
            let lookups = Collector<String>()
            let recovering = mockTunnel(
                "url", marker: newMarker(), timeout: 30, hasFreshHostname: true)
            recovering.unreachableDNSDelay = 30
            recovering.hostnameAnswer = { host in
                lookups.append(host)
                return lookups.all.count == 1 ? .unreachable : .published(["104.16.1.1"])
            }
            let started = Date()
            let recovered = try? await recovering.open(port: 1)
            #expect(
                recovered?.resolvedAddresses == ["104.16.1.1"] && lookups.all.count == 2,
                "dns.retriesAfterUnreachable")
            #expect(Date().timeIntervalSince(started) < 15, "dns.retriesAfterUnreachable")
            recovered?.close()
        }

        @Test func fallsBackAtTheDeadlineWhenDNSStaysUnreachable() async {
            let stubborn = mockTunnel(
                "url", marker: newMarker(), timeout: 1, hasFreshHostname: true)
            stubborn.unreachableDNSAttempts = 100
            stubborn.hostnameAnswer = { _ in .unreachable }
            let open = try? await stubborn.open(port: 1)
            #expect(
                open != nil && open?.resolvedAddresses == [], "dns.unreachableAtDeadlineFallsBack")
            open?.close()
        }

        @Test func doesNotWaitOnceThePublishedAnswerArrives() async {
            let lookups = Collector<String>()
            let instant = mockTunnel("url", marker: newMarker(), hasFreshHostname: true)
            instant.hostnameAnswer = { host in
                lookups.append(host)
                return .published(["104.16.1.1"])
            }
            let started = Date()
            let open = try? await instant.open(port: 1)
            #expect(open != nil && lookups.all.count == 1, "dns.noWaitAfterPublished")
            #expect(Date().timeIntervalSince(started) < 10, "dns.noWaitAfterPublished")
            open?.close()
        }

        @Test func wrapperKillsTheToolWhenItsParentIsKilled() async throws {
            let marker = newMarker()
            let parent = Process()
            parent.executableURL = URL(fileURLWithPath: "/bin/sh")
            parent.arguments = [
                "-c",
                """
                mkfifo "$1"
                exec 3<>"$1"
                /bin/sh -c "$SIGNDROP_WRAPPER" "$2" url "$3" 1 <"$1" 3>&- >/dev/null 2>&1 &
                echo READY
                while :; do sleep 1; done
                """, "parent", work.child("stdin.fifo").path, work.child("mock-tunnel").path,
                marker,
            ]
            parent.environment = ProcessInfo.processInfo.environment.merging([
                "SIGNDROP_WRAPPER": CommandLineTunnel.wrapperScript
            ]) { $1 }
            let output = Pipe()
            parent.standardOutput = output
            try parent.run()
            let ready = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            let wasRunning = await isEventuallyTrue(3) { isAlive("url \(marker)") }
            kill(parent.processIdentifier, SIGKILL)
            let isGone = await isEventuallyTrue(2) { !isAlive("url \(marker)") }
            #expect(ready.hasPrefix("READY") && wasRunning && isGone, "orphan.killedWithParent")
        }
    }
}
