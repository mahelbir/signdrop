import AppKit
import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct ShareWindowTests {
        private let harness: MainViewHarness
        private let link = URL(string: "https://example.com/install")!
        private let rawLink = "itms-services://?action=download-manifest&url=x"
        private let file = URL(fileURLWithPath: "/tmp/Signed App.ipa")
        private let hosted = ControlledShareService(name: "Hosted Service")
        private let live = ControlledShareService(name: "Live Service")
        private let controller: ShareWindowController

        init() async throws {
            harness = try await MainViewHarness()
            live.isLiveShare = true
            controller = ShareWindowController(file: file, services: [hosted, live])
        }

        private var hostedRow: ShareRow {
            controller.rows[0]
        }

        private var liveRow: ShareRow {
            controller.rows[1]
        }

        private func shownButtons(_ row: ShareRow) -> [String] {
            [
                row.shareButton, row.cancelButton, row.retryButton, row.copyLinkButton,
                row.openButton, row.deleteButton, row.stopButton,
            ].filter { !$0.isHidden }.map(\.title)
        }

        private func start(_ row: ShareRow, _ service: ControlledShareService) async {
            let count = service.shareCount
            row.shareButton.performClick(nil)
            _ = await isEventuallyTrue(2) { service.shareCount > count }
        }

        private func finish(
            _ row: ShareRow, _ service: ControlledShareService, with result: ShareResult
        ) async {
            await start(row, service)
            service.complete(.success(result))
            _ = await isEventuallyTrue(2) { row.job.state == .finished(result) }
        }

        private func deletion(_ scenario: String) -> [URLRequest] {
            ["a", "b"].map { name in
                var request = URLRequest(
                    url: URL(string: "\(harness.mock.baseURL)/s/\(scenario)/delete/\(name)")!)
                request.httpMethod = "DELETE"
                return request
            }
        }

        private func click(_ item: NSMenuItem?) {
            if let item, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }

        private var pasteboardText: String? {
            NSPasteboard.general.string(forType: .string)
        }

        @Test func listsEveryServiceUnderTheFileName() {
            #expect(controller.window?.title == "Share Signed App.ipa", "window.title")
            #expect(
                controller.rows.map(\.nameLabel.stringValue) == ["Hosted Service", "Live Service"],
                "window.rows")
            #expect(
                ShareWindowController(file: file, services: ShareServices.all).rows.map(
                    \.nameLabel.stringValue) == [
                        "BetaDrop", "Streamshare", "Cloudflare Quick Tunnel",
                    ], "window.registeredServices")
        }

        @Test func aReadyRowOffersShare() {
            #expect(shownButtons(hostedRow) == ["Share"], "row.ready")
            #expect(hostedRow.linkLabel.isHidden && hostedRow.noteLabel.isHidden, "row.readyEmpty")
            #expect(
                hostedRow.progress.bar.isHidden && hostedRow.progress.busyIndicator.isHidden,
                "row.readyNoProgress")
        }

        @Test func aServiceThatNeedsSetupAsksForMoreInput() async {
            hosted.isReadyToShare = false
            hosted.isPrepareSuccessful = false
            let row = ShareWindowController(file: file, services: [hosted]).rows[0]
            #expect(shownButtons(row) == ["Share…"], "row.shareEllipsis")
            hosted.isReadyToShare = true
            row.render()
            #expect(shownButtons(row) == ["Share"], "row.shareNoEllipsis")
        }

        @Test func aHostedShareShowsItsPercentAndCanBeCancelled() async {
            await start(hostedRow, hosted)
            #expect(shownButtons(hostedRow) == ["Cancel"], "row.runningButtons")
            #expect(
                !hostedRow.progress.bar.isHidden && hostedRow.progress.busyIndicator.isHidden,
                "row.determinateBar")
            hosted.progress?(0.25)
            _ = await isEventuallyTrue(1) { hostedRow.progress.label.stringValue == "25%" }
            #expect(hostedRow.progress.bar.doubleValue == 25, "row.percent")
            hostedRow.cancelButton.performClick(nil)
            #expect(shownButtons(hostedRow) == ["Share"], "row.cancelled")
            #expect(hostedRow.progress.bar.isHidden, "row.cancelHidesProgress")
        }

        @Test func aLiveShareUsesTheBusyBarWithoutAPercent() async {
            await start(liveRow, live)
            defer { liveRow.job.cancel() }
            #expect(
                !liveRow.progress.busyIndicator.isHidden && liveRow.progress.bar.isHidden
                    && liveRow.progress.label.stringValue == "", "row.liveBusy")
            #expect(shownButtons(liveRow) == ["Cancel"], "row.liveCanCancel")
        }

        @Test func oneIndicatorNeverChangesMode() async {
            await start(hostedRow, hosted)
            defer { hostedRow.job.cancel() }
            hosted.progress?(1)
            _ = await isEventuallyTrue(1) { !hostedRow.progress.busyIndicator.isHidden }
            #expect(
                hostedRow.progress.bar.isHidden && !hostedRow.progress.bar.isIndeterminate
                    && hostedRow.progress.busyIndicator.isIndeterminate, "row.neverSwitchesMode")
        }

        @Test func rowsKeepTheirOwnProgress() async {
            await start(hostedRow, hosted)
            let other = ControlledShareService(name: "Other")
            let pair = ShareWindowController(file: file, services: [hosted, other])
            defer {
                hostedRow.job.cancel()
                pair.rows[1].job.cancel()
            }
            await start(pair.rows[1], other)
            hosted.progress?(0.25)
            other.progress?(0.5)
            _ = await isEventuallyTrue(1) {
                hostedRow.progress.label.stringValue == "25%"
                    && pair.rows[1].progress.label.stringValue == "50%"
            }
            #expect(hostedRow.progress.label.stringValue == "25%", "row.ownPercent")
            #expect(pair.rows[1].progress.label.stringValue == "50%", "row.otherPercent")
        }

        @Test func aFinishedHostedShareOffersItsLinkAndDelete() async {
            await finish(
                hostedRow, hosted,
                with: ShareResult(link: link, warnings: [], deletionRequests: deletion("ok~row")))
            #expect(
                shownButtons(hostedRow) == ["Copy Link", "Open", "Delete…"], "row.finishedButtons")
            #expect(
                hostedRow.linkLabel.stringValue == link.absoluteString
                    && !hostedRow.linkLabel.isHidden, "row.linkShown")
            #expect(hostedRow.linkLabel.toolTip == link.absoluteString, "row.linkTooltip")
        }

        @Test func aServiceWithoutDeletionOffersOnlyTheLink() async {
            await finish(hostedRow, hosted, with: ShareResult(link: link, warnings: []))
            #expect(shownButtons(hostedRow) == ["Copy Link", "Open"], "row.noDelete")
            #expect(hostedRow.copyLinkButton.menu == nil, "row.noRawLinkMenu")
        }

        @Test func aLiveShareOffersStopSharing() async {
            let stopped = Collector<Bool>()
            await finish(
                liveRow, live,
                with: ShareResult(
                    link: link, warnings: [], itmsLink: rawLink,
                    liveShare: LiveShare { stopped.append(true) }))
            #expect(shownButtons(liveRow) == ["Copy Link", "Open", "Stop Sharing"], "row.liveDone")
            liveRow.stopButton.performClick(nil)
            #expect(!stopped.all.isEmpty, "row.stopStops")
            #expect(shownButtons(liveRow) == ["Share"], "row.stopResets")
            #expect(liveRow.linkLabel.isHidden, "row.stopHidesLink")
        }

        @Test func copyingNeedsAClick() async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            await finish(hostedRow, hosted, with: ShareResult(link: link, warnings: []))
            #expect(pasteboardText == "unchanged", "row.noAutoCopy")
            hostedRow.copyLinkButton.performClick(nil)
            #expect(pasteboardText == link.absoluteString, "row.copied")
        }

        @Test func rightClickCopiesTheRawLink() async {
            await finish(
                hostedRow, hosted, with: ShareResult(link: link, warnings: [], itmsLink: rawLink))
            let menu = hostedRow.copyLinkButton.menu
            #expect(menu?.items.map(\.title) == ["Copy itms-services Link"], "row.rawLinkMenu")
            #expect(
                hostedRow.copyLinkButton.toolTip == "Right-click to copy the itms-services link",
                "row.rawLinkHint")
            click(menu?.items.first)
            #expect(pasteboardText == rawLink, "row.rawLinkCopied")
        }

        @Test func openUsesTheNormalLink() async {
            let opened = Collector<URL>()
            hostedRow.openURL = { opened.append($0) }
            await finish(
                hostedRow, hosted, with: ShareResult(link: link, warnings: [], itmsLink: rawLink))
            hostedRow.openButton.performClick(nil)
            #expect(opened.all == [link], "row.openNormalLink")
        }

        @Test func warningsShowUnderTheLink() async {
            await finish(
                hostedRow, hosted, with: ShareResult(link: link, warnings: ["Slow", "Busy"]))
            #expect(
                hostedRow.noteLabel.stringValue == "Slow. Busy" && !hostedRow.noteLabel.isHidden,
                "row.warnings")
            #expect(hostedRow.noteLabel.textColor == .systemOrange, "row.warningColor")
        }

        @Test func aFailureStaysInItsRowAndCanBeRetried() async {
            await start(hostedRow, hosted)
            await start(liveRow, live)
            defer { liveRow.job.cancel() }
            hosted.complete(.failure(ShareError.server("boom")))
            _ = await isEventuallyTrue(2) { hostedRow.job.state == .failed("boom") }
            #expect(shownButtons(hostedRow) == ["Retry"], "row.failedButtons")
            #expect(hostedRow.noteLabel.stringValue == "boom", "row.failedText")
            #expect(shownButtons(liveRow) == ["Cancel"], "row.otherKeepsRunning")
            hostedRow.retryButton.performClick(nil)
            #expect(await isEventuallyTrue(2) { hosted.shareCount == 2 }, "row.retried")
            hostedRow.job.cancel()
        }

        @Test func focusStaysInTheRowWhenItsButtonDisappears() async throws {
            guard NSApp.isFullKeyboardAccessEnabled else { return }
            let window = try #require(controller.window)
            await finish(hostedRow, hosted, with: ShareResult(link: link, warnings: []))
            #expect(window.makeFirstResponder(liveRow.shareButton), "focus.setUp")
            await start(liveRow, live)
            defer { liveRow.job.cancel() }
            #expect(window.firstResponder === liveRow.cancelButton, "focus.staysInRow")
        }

        @Test func aRowThatWasNotFocusedLeavesTheFocusAlone() async throws {
            guard NSApp.isFullKeyboardAccessEnabled else { return }
            let window = try #require(controller.window)
            #expect(window.makeFirstResponder(hostedRow.shareButton), "focus.setUp")
            await start(liveRow, live)
            defer { liveRow.job.cancel() }
            #expect(window.firstResponder === hostedRow.shareButton, "focus.leftAlone")
        }

        private func isNoteFullyShown(_ row: ShareRow, in window: NSWindow) -> Bool {
            window.contentView?.layoutSubtreeIfNeeded()
            let label = row.noteLabel
            let needed =
                label.cell?.cellSize(
                    forBounds: NSRect(
                        x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)
                ).height ?? 0
            return label.frame.width > 0 && label.frame.height + 1 >= needed
        }

        @Test func aLongErrorIsNotCutOff() async throws {
            let message = "Streamshare returned an error (HTTP 500)."
            let longName = ControlledShareService(name: "Cloudflare Quick Tunnel")
            let narrow = ShareWindowController(file: file, services: [hosted, longName])
            let window = try #require(narrow.window)
            await finish(
                narrow.rows[1], longName,
                with: ShareResult(
                    link: link, warnings: [], deletionRequests: deletion("ok~wide"),
                    liveShare: LiveShare {}))
            defer { narrow.rows[1].job.stopSharing() }
            await start(narrow.rows[0], hosted)
            hosted.complete(.failure(ShareError.server(message)))
            _ = await isEventuallyTrue(2) { narrow.rows[0].job.state == .failed(message) }
            #expect(isNoteFullyShown(narrow.rows[0], in: window), "row.noteNotCutOff")
            window.setContentSize(NSSize(width: 900, height: window.contentLayoutRect.height))
            #expect(isNoteFullyShown(narrow.rows[0], in: window), "row.noteNotCutOffWhenWider")
        }

        @Test func anExpiredSessionShowsInTheRow() async throws {
            try harness.signIn("unauthorized~row")
            let ipa = harness.work.ipa("Row.ipa", sampleAppInfo)
            let row = ShareWindowController(file: ipa, services: [ShareServices.all[0]]).rows[0]
            row.shareButton.performClick(nil)
            _ = await isEventuallyTrue(10) {
                if case .failed = row.job.state { return true }
                return false
            }
            #expect(
                row.noteLabel.stringValue == "BetaDrop session expired. Sign in again.",
                "row.expiredText")
            #expect(
                !FileManager.default.fileExists(atPath: BetaDropConfig.fileURL().path),
                "row.expiredClearsSession")
            #expect(shownButtons(row) == ["Retry…"], "row.retryNeedsSignIn")
        }

        @Test func deleteAsksFirst() async {
            await finish(
                hostedRow, hosted,
                with: ShareResult(link: link, warnings: [], deletionRequests: deletion("ok~row")))
            let alert = hostedRow.makeDeleteAlert()
            #expect(alert.messageText == "Delete this share from Hosted Service?", "delete.alert")
            #expect(
                alert.informativeText
                    == "The install link will stop working. This can't be undone.",
                "delete.alert")
            #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"], "delete.alert")
        }

        @Test func aDeletedShareReturnsToReady() async {
            await finish(
                hostedRow, hosted,
                with: ShareResult(link: link, warnings: [], deletionRequests: deletion("ok~del")))
            hostedRow.job.delete()
            #expect(
                !hostedRow.progress.busyIndicator.isHidden && shownButtons(hostedRow) == [],
                "delete.busy")
            _ = await isEventuallyTrue(3) { hostedRow.job.state == .ready }
            #expect(shownButtons(hostedRow) == ["Share"], "delete.ready")
            #expect(harness.mock.stats["ok~del"]["delete"] as? Int == 2, "delete.sent")
        }

        @Test func aFailedDeleteShowsWhyAndKeepsTheButton() async {
            let result = ShareResult(
                link: link, warnings: [], deletionRequests: deletion("delete-fail~row"))
            await finish(hostedRow, hosted, with: result)
            hostedRow.job.delete()
            _ = await isEventuallyTrue(3) { hostedRow.job.deletionError != nil }
            #expect(
                hostedRow.noteLabel.stringValue
                    == "Could not delete: Hosted Service returned an error (HTTP 500).",
                "delete.failureText")
            #expect(
                shownButtons(hostedRow) == ["Copy Link", "Open", "Delete…"], "delete.failureRetry")
        }

        @Test func rightClickCopiesADeleteCommandThatWorks() async throws {
            await finish(
                hostedRow, hosted,
                with: ShareResult(link: link, warnings: [], deletionRequests: deletion("ok~copy")))
            let menu = hostedRow.deleteButton.menu
            #expect(menu?.items.map(\.title) == ["Copy Delete Command"], "delete.copyMenu")
            #expect(
                hostedRow.deleteButton.toolTip
                    == "Right-click to copy a Terminal command that deletes this share",
                "delete.copyHint")
            click(menu?.items.first)
            let server = harness.mock.baseURL
            #expect(
                pasteboardText
                    == "curl -X DELETE '\(server)/s/ok~copy/delete/a' && curl -X DELETE '\(server)/s/ok~copy/delete/b'",
                "delete.copyCommand")
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-c", pasteboardText ?? "false"]
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            shell.waitUntilExit()
            #expect(
                shell.terminationStatus == 0
                    && harness.mock.stats["ok~copy"]["delete"] as? Int == 2,
                "delete.commandWorks")
        }

        @Test func copiedCommandQuotesHeadersAndURLs() throws {
            var request = URLRequest(url: try #require(URL(string: "https://example.com/it's")))
            request.httpMethod = "DELETE"
            request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
            #expect(
                ShareServices.deletionCommand([request])
                    == "curl -X DELETE -H 'Authorization: Bearer t' 'https://example.com/it'\\''s'",
                "delete.commandQuoted")
        }

        @Test func theAccountNameIsAHint() async {
            hosted.accountName = "dev@example.com"
            hostedRow.render()
            #expect(hostedRow.nameLabel.toolTip == "Signed in as dev@example.com", "row.account")
            hosted.accountName = nil
            NotificationCenter.default.post(name: .shareAccountDidChange, object: nil)
            #expect(hostedRow.nameLabel.toolTip == nil, "row.accountCleared")
        }

        @Test func closingAnIdleWindowNeedsNoAnswer() throws {
            #expect(!controller.hasActiveWork, "close.idle")
            #expect(
                controller.windowShouldClose(try #require(controller.window)), "close.allowed")
        }

        @Test func closingAsksWhileSomethingRuns() {
            let alert = ShareWindowController.makeCloseAlert()
            #expect(alert.messageText == "Stop sharing and close?", "close.alert")
            #expect(
                alert.informativeText
                    == "Shares in progress will be canceled, and links served from this Mac will stop working.",
                "close.alert")
            #expect(alert.buttons.map(\.title) == ["Stop and Close", "Cancel"], "close.alert")
        }

        @Test func stoppingAndClosingHaltsEveryRow() async {
            await start(hostedRow, hosted)
            let stopped = Collector<Bool>()
            await finish(
                liveRow, live,
                with: ShareResult(
                    link: link, warnings: [], liveShare: LiveShare { stopped.append(true) }))
            #expect(controller.hasActiveWork, "close.active")
            controller.haltAndClose()
            #expect(!controller.hasActiveWork && !stopped.all.isEmpty, "close.halted")
            #expect(hostedRow.job.state == .ready, "close.cancelled")
        }

        @Test func finishedResultsDoNotAskBeforeClosing() async {
            await finish(hostedRow, hosted, with: ShareResult(link: link, warnings: []))
            #expect(!controller.hasActiveWork, "close.finishedIsIdle")
        }
    }

    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct ShareWindowsTests {
        private let harness: MainViewHarness
        private let service = ControlledShareService()
        private let windows: ShareWindows
        private let signed: URL
        private let link = URL(string: "https://example.com/install")!

        init() async throws {
            harness = try await MainViewHarness()
            let service = service
            windows = ShareWindows(services: { [service] })
            signed = harness.work.child("Signed.ipa")
        }

        private func close(_ controller: ShareWindowController) {
            controller.window?.close()
        }

        private func start(_ controller: ShareWindowController) async {
            let count = service.shareCount
            controller.rows[0].shareButton.performClick(nil)
            _ = await isEventuallyTrue(2) { service.shareCount > count }
        }

        @Test func showingTheSameFileReusesItsWindow() {
            let first = windows.show(file: signed)
            defer { close(first) }
            #expect(windows.show(file: signed) === first, "windows.reused")
            #expect(first.window?.isVisible == true, "windows.visible")
        }

        @Test func eachFileGetsItsOwnWindow() {
            let first = windows.show(file: signed)
            let second = windows.show(file: harness.work.child("Other.ipa"))
            defer {
                close(first)
                close(second)
            }
            #expect(first !== second, "windows.ownWindow")
            #expect(windows.controllers.count == 2, "windows.bothKept")
        }

        @Test func aNewSigningStartsFreshButLeavesOpenWindows() {
            let first = windows.show(file: signed)
            windows.beginNewSigning()
            let second = windows.show(file: signed)
            defer {
                close(first)
                close(second)
            }
            #expect(first !== second, "windows.newSigningIsFresh")
            #expect(first.window?.isVisible == true, "windows.oldStaysOpen")
            #expect(windows.controllers.contains { $0 === first }, "windows.oldStillTracked")
        }

        @Test func aClosedWindowComesBackWithItsResults() async {
            let controller = windows.show(file: signed)
            await start(controller)
            let result = ShareResult(link: link, warnings: [])
            service.complete(.success(result))
            _ = await isEventuallyTrue(2) { controller.rows[0].job.state == .finished(result) }
            close(controller)
            #expect(controller.window?.isVisible == false, "windows.closed")
            let reopened = windows.show(file: signed)
            defer { close(reopened) }
            #expect(reopened === controller, "windows.reopened")
            #expect(reopened.rows[0].job.state == .finished(result), "windows.keepsResults")
        }

        @Test func aMinimizedWindowCountsAsOpen() async {
            let controller = windows.show(file: signed)
            defer { close(controller) }
            controller.window?.miniaturize(nil)
            _ = await isEventuallyTrue(5) { controller.window?.isMiniaturized == true }
            #expect(controller.window?.isMiniaturized == true, "windows.minimized")
            #expect(windows.hasOpenWindows, "windows.minimizedIsOpen")
            windows.beginNewSigning()
            #expect(windows.controllers.contains { $0 === controller }, "windows.minimizedKept")
        }

        @Test func aNewSigningForgetsAClosedWindow() {
            let controller = windows.show(file: signed)
            close(controller)
            windows.beginNewSigning()
            #expect(windows.controllers.isEmpty, "windows.forgotten")
        }

        @Test func closingAnOlderWindowForgetsIt() {
            let first = windows.show(file: signed)
            windows.beginNewSigning()
            let second = windows.show(file: harness.work.child("Other.ipa"))
            defer { close(second) }
            close(first)
            #expect(windows.controllers.map(\.file) == [second.file], "windows.olderForgotten")
        }

        @Test func tracksWhatIsBeingShared() async {
            let controller = windows.show(file: signed)
            defer { close(controller) }
            #expect(!windows.hasActiveWork && windows.hasOpenWindows, "windows.idle")
            #expect(!windows.isSharing(file: signed), "windows.notSharing")
            await start(controller)
            #expect(windows.hasActiveWork, "windows.active")
            #expect(windows.isSharing(file: signed), "windows.sharing")
            let same = URL(
                fileURLWithPath: signed.deletingLastPathComponent().path + "/./Signed.ipa")
            #expect(windows.isSharing(file: same), "windows.standardizesPaths")
            windows.stopAll()
            #expect(!windows.hasActiveWork, "windows.stopAll")
        }

        @Test func quittingAsksFirst() {
            let alert = ShareWindows.makeQuitAlert()
            #expect(alert.messageText == "Stop sharing and quit?", "windows.quitAlert")
            #expect(
                alert.informativeText
                    == "Shares in progress will be canceled, and links served from this Mac will stop working.",
                "windows.quitAlert")
            #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"], "windows.quitAlert")
        }
    }
}
