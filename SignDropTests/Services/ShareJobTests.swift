import AppKit
import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    struct ShareJobTests {
        private let window = NSWindow()
        private let file = URL(fileURLWithPath: "/tmp/App.ipa")
        private let link = URL(string: "https://example.com/install")!
        private let service: ControlledShareService
        private let job: ShareJob

        init() {
            let service = ControlledShareService()
            self.service = service
            job = ShareJob(service: service, file: file)
        }

        private func begin() async {
            job.start(in: window)
            _ = await isEventuallyTrue(2) { service.shareCount > 0 }
        }

        private func finish(with result: ShareResult) async {
            await begin()
            service.complete(.success(result))
            _ = await isEventuallyTrue(2) { job.state == .finished(result) }
        }

        private func deletion(_ mock: BetaDropMockServer, _ scenario: String) -> [URLRequest] {
            ["a", "b"].map { name in
                var request = URLRequest(
                    url: URL(string: "\(mock.baseURL)/s/\(scenario)/delete/\(name)")!)
                request.httpMethod = "DELETE"
                return request
            }
        }

        @Test func reportsProgressUntilTheFileIsSent() async {
            defer { job.cancel() }
            await begin()
            #expect(job.state == .running(0) && job.isActive, "job.startsAtZero")
            service.progress?(0.25)
            #expect(await isEventuallyTrue(1) { job.state == .running(0.25) }, "job.progress")
            service.progress?(1)
            #expect(await isEventuallyTrue(1) { job.state == .running(nil) }, "job.fullIsBusy")
        }

        @Test func aLiveShareHasNoPercentWhileStarting() async {
            defer { job.cancel() }
            service.isLiveShare = true
            await begin()
            #expect(job.state == .running(nil), "job.liveIsBusy")
        }

        @Test func finishesWithTheResult() async {
            let result = ShareResult(link: link, warnings: ["Slow"])
            await finish(with: result)
            #expect(job.state == .finished(result), "job.finished")
            #expect(!job.isActive, "job.finishedIsIdle")
        }

        @Test func aFailureCanBeRetried() async {
            defer { job.cancel() }
            await begin()
            service.complete(.failure(ShareError.server("boom")))
            #expect(await isEventuallyTrue(2) { job.state == .failed("boom") }, "job.failed")
            #expect(!job.isActive, "job.failedIsIdle")
            job.start(in: window)
            #expect(await isEventuallyTrue(2) { service.shareCount == 2 }, "job.retries")
        }

        @Test func anExpiredSessionAsksToSignInAgain() async {
            await begin()
            service.complete(.failure(ShareError.sessionExpired))
            #expect(
                await isEventuallyTrue(2) {
                    job.state == .failed("Fake Service session expired. Sign in again.")
                }, "job.sessionExpired")
        }

        @Test func aServiceThatIsNotReadyPreparesFirst() async {
            defer { job.cancel() }
            service.isReadyToShare = false
            job.start(in: window)
            #expect(await isEventuallyTrue(2) { service.shareCount == 1 }, "job.sharesAfterPrepare")
            #expect(service.prepareWindows == [window], "job.preparesInTheWindow")
        }

        @Test func decliningToPrepareReturnsToReady() async {
            service.isReadyToShare = false
            service.isPrepareSuccessful = false
            job.start(in: window)
            #expect(
                await isEventuallyTrue(2) {
                    service.prepareWindows.count == 1 && job.state == .ready
                }, "job.declined")
            #expect(service.shareCount == 0, "job.declinedDoesNotShare")
        }

        @Test func startingTwiceSharesOnce() async {
            defer { job.cancel() }
            await begin()
            job.start(in: window)
            await pause(0.1)
            #expect(service.shareCount == 1, "job.startsOnce")
        }

        @Test func cancelReturnsToReadyAtOnce() async {
            await begin()
            job.cancel()
            #expect(job.state == .ready && !job.isActive, "job.cancelled")
            await pause(0.1)
            #expect(job.state == .ready, "job.stillReadyAfterCancellationArrives")
        }

        @Test func aResultThatArrivesAfterCancelIsUndone() async throws {
            let mock = try await BetaDropMockServer()
            service.isCancellationIgnored = true
            await begin()
            job.cancel()
            let stopped = Collector<Bool>()
            let share = LiveShare { stopped.append(true) }
            service.complete(
                .success(
                    ShareResult(
                        link: link, warnings: [], deletionRequests: deletion(mock, "ok~late"),
                        liveShare: share)))
            #expect(
                await isEventuallyTrue(3) {
                    !stopped.all.isEmpty && mock.stats["ok~late"]["delete"] as? Int == 2
                }, "job.lateResultUndone")
            #expect(job.state == .ready && !share.isActive, "job.staysReady")
        }

        @Test func lateProgressIsIgnored() async {
            let result = ShareResult(link: link, warnings: [])
            await begin()
            let report = service.progress
            service.complete(.success(result))
            _ = await isEventuallyTrue(2) { job.state == .finished(result) }
            report?(0.5)
            await pause(0.1)
            #expect(job.state == .finished(result), "job.lateProgressIgnored")
        }

        @Test func keepsTheMacAwakeWhileRunning() async {
            await begin()
            #expect(isSleepBlocked(), "job.blocksSleep")
            service.complete(.success(ShareResult(link: link, warnings: [])))
            #expect(await isEventuallyTrue(3) { !isSleepBlocked() }, "job.allowsSleepWhenDone")
        }

        @Test func cancellingLetsTheMacSleep() async {
            await begin()
            job.cancel()
            #expect(await isEventuallyTrue(3) { !isSleepBlocked() }, "job.allowsSleepWhenCancelled")
        }

        @Test func stopSharingEndsTheLiveShareAndResets() async {
            let stopped = Collector<Bool>()
            let share = LiveShare { stopped.append(true) }
            await finish(with: ShareResult(link: link, warnings: [], liveShare: share))
            #expect(job.isActive, "job.liveIsActive")
            job.stopSharing()
            #expect(
                job.state == .ready && !stopped.all.isEmpty && !share.isActive && !job.isActive,
                "job.stopSharing")
        }

        @Test func aDroppedShareFailsTheRow() async {
            let share = LiveShare {}
            await finish(with: ShareResult(link: link, warnings: [], liveShare: share))
            share.end("ERR lost")
            #expect(
                job.state == .failed("Sharing stopped: the tunnel closed unexpectedly."),
                "job.dropped")
            #expect(!job.isActive, "job.droppedIsIdle")
        }

        @Test func aShareThatEndedBeforeTheResultArrivesFails() async {
            let share = LiveShare {}
            share.stop()
            await begin()
            service.complete(.success(ShareResult(link: link, warnings: [], liveShare: share)))
            #expect(
                await isEventuallyTrue(2) {
                    job.state == .failed("Sharing stopped: the tunnel closed unexpectedly.")
                }, "job.endedEarly")
        }

        @Test func deleteSendsTheRequestsAndResets() async throws {
            let mock = try await BetaDropMockServer()
            let result = ShareResult(
                link: link, warnings: [], deletionRequests: deletion(mock, "ok~job"))
            await finish(with: result)
            job.delete()
            #expect(job.state == .deleting(result) && job.isActive, "job.deleting")
            #expect(await isEventuallyTrue(3) { job.state == .ready }, "job.deleted")
            #expect(mock.stats["ok~job"]["delete"] as? Int == 2, "job.deleteSent")
        }

        @Test func aFailedDeleteKeepsTheResultAndCanRetry() async throws {
            let mock = try await BetaDropMockServer()
            let result = ShareResult(
                link: link, warnings: [], deletionRequests: deletion(mock, "delete-fail~job"))
            await finish(with: result)
            job.delete()
            #expect(await isEventuallyTrue(3) { job.state == .finished(result) }, "job.keptResult")
            #expect(
                job.deletionError == "Could not delete: Fake Service returned an error (HTTP 500).",
                "job.deletionError")
            #expect(mock.stats["delete-fail~job"]["delete"] as? Int == 1, "job.deleteStopsEarly")
            job.delete()
            #expect(job.deletionError == nil, "job.deletionErrorClearedOnRetry")
        }

        @Test func deleteNeedsDeletionRequests() async {
            let result = ShareResult(link: link, warnings: [])
            await finish(with: result)
            job.delete()
            #expect(job.state == .finished(result), "job.nothingToDelete")
        }

        @Test func haltCancelsARunningJob() async {
            await begin()
            job.halt()
            #expect(job.state == .ready && !job.isActive, "job.haltCancels")
        }

        @Test func haltStopsALiveShare() async {
            let stopped = Collector<Bool>()
            await finish(
                with: ShareResult(
                    link: link, warnings: [], liveShare: LiveShare { stopped.append(true) }))
            job.halt()
            #expect(job.state == .ready && !stopped.all.isEmpty, "job.haltStops")
        }

        @Test func aFinishedJobIgnoresHalt() async {
            let result = ShareResult(link: link, warnings: [])
            await finish(with: result)
            job.halt()
            #expect(job.state == .finished(result), "job.haltKeepsResults")
        }

        @Test func oneJobFailingLeavesTheOtherRunning() async {
            let otherService = ControlledShareService(name: "Other")
            let other = ShareJob(service: otherService, file: file)
            await begin()
            other.start(in: window)
            _ = await isEventuallyTrue(2) { otherService.shareCount == 1 }
            service.complete(.failure(ShareError.server("boom")))
            _ = await isEventuallyTrue(2) { job.state == .failed("boom") }
            #expect(other.state == .running(0), "job.independent")
            let result = ShareResult(link: link, warnings: [])
            otherService.complete(.success(result))
            #expect(await isEventuallyTrue(2) { other.state == .finished(result) }, "job.otherDone")
        }

        @Test func sharesThroughTheTunnelServiceAndStops() async throws {
            let work = try WorkDirectory()
            let tunnel = FakeTunnel(.passthrough)
            let tunnelService = TunnelShareService(tunnel: tunnel)
            tunnelService.readyTimeout = 2
            tunnelService.log = { _ in }
            let job = ShareJob(service: tunnelService, file: work.ipa("Job.ipa", sampleAppInfo))
            job.start(in: window)
            _ = await isEventuallyTrue(5) {
                if case .finished = job.state { return true }
                return false
            }
            guard case .finished(let result) = job.state else {
                Issue.record("job.tunnelFinished: \(job.state)")
                return
            }
            #expect(result.link?.lastPathComponent == "install", "job.tunnelLink")
            #expect(job.isActive, "job.tunnelIsActive")
            job.stopSharing()
            #expect(tunnel.isClosed && !job.isActive, "job.tunnelStopped")
        }

        @Test func cancellingAHostedShareRemovesThePartlySentFile() async throws {
            let mock = try await StreamshareMockServer()
            let work = try WorkDirectory()
            let hosted = StreamshareService(
                api: mock.api("stall~job"), shorteners: mock.shorteners("stall~job"))
            let job = ShareJob(service: hosted, file: work.ipa("Job.ipa", sampleAppInfo))
            job.start(in: window)
            _ = await isEventuallyTrue(3) { mock.stats["stall~job"]["create"] != nil }
            await pause(0.2)
            job.cancel()
            #expect(job.state == .ready, "job.hostedCancelled")
            #expect(
                await isEventuallyTrue(3) { mock.stats["stall~job"]["deleted"] != nil },
                "job.partialFileRemoved")
        }

        @Test func deletesAFinishedHostedShare() async throws {
            let mock = try await StreamshareMockServer()
            let work = try WorkDirectory()
            let hosted = StreamshareService(
                api: mock.api("ok~job"), shorteners: mock.shorteners("ok~job"))
            let job = ShareJob(service: hosted, file: work.ipa("Job.ipa", sampleAppInfo))
            job.start(in: window)
            _ = await isEventuallyTrue(5) {
                if case .finished = job.state { return true }
                return false
            }
            job.delete()
            #expect(await isEventuallyTrue(3) { job.state == .ready }, "job.hostedDeleted")
            #expect(
                mock.stats["ok~job"]["deleted"] as? [String] == ["ok~job-1/tok1", "ok~job-2/tok2"],
                "job.bothFilesDeleted")
        }
    }
}
