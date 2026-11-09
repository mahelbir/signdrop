import AppKit
import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewDeleteUploadTests {
        private let harness: MainViewHarness
        private let link = URL(string: "https://tinyurl.com/example")!

        init() async throws {
            harness = try await MainViewHarness()
        }

        private var view: MainView {
            harness.view
        }

        private var server: String {
            harness.mock.baseURL
        }

        private var betaDrop: ShareService {
            ShareServices.all[0]
        }

        private var streamShare: ShareService {
            ShareServices.all[1]
        }

        private func deletion(_ scenario: String) -> [URLRequest] {
            ["a", "b"].map { name in
                var request = URLRequest(
                    url: URL(string: "\(server)/s/\(scenario)/delete/\(name)")!)
                request.httpMethod = "DELETE"
                return request
            }
        }

        private func report(_ scenario: String) {
            view.reportUpload(
                ShareResult(link: link, warnings: [], deletionRequests: deletion(scenario)),
                from: streamShare)
        }

        private func waitUntilUnlocked() async {
            _ = await isEventuallyTrue(10) { !view.isSigning }
        }

        private func copyDeletionCommand() -> String? {
            if let item = view.deleteUploadButton.menu?.items.first, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            return NSPasteboard.general.string(forType: .string)
        }

        @Test func buttonNeedsDeletionRequests() {
            view.reportUpload(ShareResult(link: link, warnings: []), from: betaDrop)
            #expect(view.deleteUploadButton.isHidden, "deleteUpload.hiddenWithoutRequests")
        }

        @Test func buttonSitsBesideTheStatusAsALink() {
            report("ok~delete")
            #expect(
                !view.deleteUploadButton.isHidden
                    && view.deleteUploadButton.title == "Delete Upload", "deleteUpload.shown")
            #expect(
                view.statusLabel.stringValue
                    == "Uploaded to StreamShare — link copied · Open Install Page",
                "deleteUpload.status")
            let title = view.deleteUploadButton.attributedTitle
            #expect(
                isLinkStyled(title.length > 0 ? title.attributes(at: 0, effectiveRange: nil) : [:]),
                "deleteUpload.linkStyled")
            #expect(harness.isBesideStatus(view.deleteUploadButton), "deleteUpload.besideStatus")
        }

        @Test func asksBeforeDeleting() {
            report("ok~delete")
            let alert = view.makeDeleteUploadAlert()
            #expect(
                alert?.messageText == "Delete this upload from StreamShare?", "deleteUpload.alert")
            #expect(
                alert?.informativeText
                    == "The install link will stop working. This can't be undone.",
                "deleteUpload.alert")
            #expect(alert?.buttons.map(\.title) == ["Delete", "Cancel"], "deleteUpload.alert")
        }

        @Test func rightClickCopiesADeleteCommand() throws {
            report("ok~delete")
            let copyMenu = view.deleteUploadButton.menu
            #expect(
                copyMenu?.items.map(\.title) == ["Copy Delete Command"], "deleteUpload.copyMenu")
            let rightClick = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )
            )
            #expect(
                copyMenu != nil && view.deleteUploadButton.menu(for: rightClick) === copyMenu,
                "deleteUpload.copyMenuOnRightClick")
            #expect(
                view.deleteUploadButton.toolTip
                    == "Right-click to copy a Terminal command that deletes this upload",
                "deleteUpload.copyHint")
            #expect(
                copyDeletionCommand()
                    == "curl -X DELETE '\(server)/s/ok~delete/delete/a' && curl -X DELETE '\(server)/s/ok~delete/delete/b'",
                "deleteUpload.copyCommand")
            #expect(
                !view.deleteUploadButton.isHidden
                    && view.statusLabel.stringValue.hasPrefix("Uploaded to StreamShare"),
                "deleteUpload.copyKeepsStatus")
        }

        @Test func copiedCommandWorksInAShell() throws {
            report("ok~copy")
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-c", copyDeletionCommand() ?? "false"]
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            shell.waitUntilExit()
            #expect(
                shell.terminationStatus == 0
                    && harness.mock.stats["ok~copy"]["delete"] as? Int == 2,
                "deleteUpload.copyCommandWorks")
        }

        @Test func copiedCommandQuotesHeadersAndURLs() throws {
            var request = URLRequest(url: try #require(URL(string: "https://example.com/it's")))
            request.httpMethod = "DELETE"
            request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
            #expect(
                ShareServices.deletionCommand([request])
                    == "curl -X DELETE -H 'Authorization: Bearer t' 'https://example.com/it'\\''s'",
                "deleteUpload.copyCommandQuoted")
        }

        @Test func aNewStatusHidesTheButton() {
            report("ok~delete")
            view.setStatus("Ready")
            #expect(
                view.deleteUploadButton.isHidden && view.makeDeleteUploadAlert() == nil,
                "deleteUpload.hiddenOnNewStatus")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            #expect(copyDeletionCommand() == "unchanged", "deleteUpload.copyNothingWithoutUpload")
        }

        @Test func deletesTheUpload() async {
            report("ok~delete")
            view.deleteUpload()
            await waitUntilUnlocked()
            #expect(harness.mock.stats["ok~delete"]["delete"] as? Int == 2, "deleteUpload.sent")
            #expect(
                view.statusLabel.stringValue == "Deleted the upload from StreamShare"
                    && !view.isStatusWarning && view.statusLink == nil, "deleteUpload.doneStatus")
            #expect(view.deleteUploadButton.isHidden, "deleteUpload.hiddenAfterDelete")
            #expect(
                !view.isSigning && view.signButton.isEnabled && view.progressBar.isHidden
                    && view.busyIndicator.isHidden, "deleteUpload.unlocked")
        }

        @Test func aFailedDeleteCanBeRetried() async {
            report("delete-fail~ui")
            view.deleteUpload()
            await waitUntilUnlocked()
            #expect(
                view.statusLabel.stringValue
                    == "Could not delete the upload: StreamShare returned an error (HTTP 500)."
                    && view.isStatusWarning, "deleteUpload.failureStatus")
            #expect(
                !view.deleteUploadButton.isHidden && view.makeDeleteUploadAlert() != nil,
                "deleteUpload.retryShown")
            #expect(
                harness.mock.stats["delete-fail~ui"]["delete"] as? Int == 1,
                "deleteUpload.failureStopsEarly")
        }
    }

    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewInputResetTests {
        private let harness: MainViewHarness
        private let ipa: String

        init() async throws {
            harness = try await MainViewHarness()
            ipa = harness.work.ipa("Sample.ipa", sampleAppInfo).path
        }

        private var view: MainView {
            harness.view
        }

        private func showUploaded() {
            let deletion = URLRequest(url: URL(string: "https://example.com/delete")!)
            view.reportUpload(
                ShareResult(
                    link: URL(string: "https://tinyurl.com/example")!, warnings: [],
                    deletionRequests: [deletion]), from: ShareServices.all[1])
        }

        private var isReset: Bool {
            view.statusLabel.stringValue == "Ready"
                && !view.isStatusWarning
                && view.statusLink == nil
                && view.statusLabel.toolTip == nil
                && view.deleteUploadButton.isHidden
                && view.makeDeleteUploadAlert() == nil
        }

        private func waitForAppInfo() async {
            _ = await isEventuallyTrue(5) { view.inputAppInfo != nil }
        }

        @Test func aDroppedFileClearsTheUploadStatus() async {
            showUploaded()
            view.fileDropped(ipa)
            #expect(isReset, "inputReset.dropped")
            await waitForAppInfo()
            #expect(isReset, "inputReset.droppedAfterRead")
        }

        @Test func aDroppedFileClearsTheDoneStatus() {
            let output = harness.work.child("new-done.ipa").path
            view.setStatus("Done, output at \(output)", link: URL(fileURLWithPath: output))
            view.fileDropped(ipa)
            #expect(isReset, "inputReset.droppedAfterDone")
        }

        @Test func aDroppedURLClearsTheStatus() throws {
            showUploaded()
            view.urlDropped(try #require(NSURL(string: "https://example.com/App.ipa")))
            #expect(isReset, "inputReset.urlDropped")
        }

        @Test func typingClearsTheStatus() async {
            showUploaded()
            view.inputFileField.stringValue = ipa
            view.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: view.inputFileField)
            )
            #expect(isReset, "inputReset.typed")
            await waitForAppInfo()
        }

        @Test func aProfileMismatchWarningSurvivesTheReset() async throws {
            view.selectCustomProfile(try #require(SigningFixtures.fixedProfile))
            showUploaded()
            view.fileDropped(ipa)
            #expect(isReset, "inputReset.beforeProfileWarning")
            await waitForAppInfo()
            #expect(
                view.isStatusWarning
                    && view.statusLabel.stringValue.hasPrefix(
                        "⚠︎ App ID com.acme.sample doesn't match"),
                "inputReset.profileWarningKept")
        }
    }
}
