import AppKit
import Foundation
import Testing
@testable import SignDrop

private final class PartialZipView: MainView {
    override func zip(_ inputPath: String, outputFile: String) -> SignDropTaskOutput {
        guard outputFile.hasSuffix("new-partial-zip.ipa") else {
            return super.zip(inputPath, outputFile: outputFile)
        }
        FileManager.default.createFile(atPath: outputFile, contents: Data("partial".utf8))
        return SignDropTaskOutput(status: 18, output: "zip warning: could not open for reading")
    }
}

private final class NoTempFolderView: MainView {
    override func makeTempFolder() -> String? {
        nil
    }
}

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile, .requiresSigningCertificate)
    struct MainViewSigningTests {
        private let harness: MainViewHarness
        private let sampleIPA: String
        private let sampleAppex: String

        init() async throws {
            harness = try await MainViewHarness(isCertificateLoaded: true)
            let sample = try #require(SigningFixtures.sampleApp)
            sampleIPA = sample.ipa
            sampleAppex = sample.appex
        }

        private var view: MainView {
            harness.view
        }

        @Test func aPackagingFailureUnlocksTheForm() async {
            await harness.sign(
                "new-zip-failure", input: sampleIPA,
                output: "/nonexistent-signdrop-dir/zip-failure.ipa")
            #expect(view.statusLabel.stringValue == "Error packaging IPA", "zipFailure.status")
            #expect(!view.isSigning, "zipFailure.unlocked")
            #expect(
                view.statusLink == nil && view.statusLabel.toolTip == nil
                    && !view.statusLabel.stringValue.contains("·"), "zipFailure.noLink")
        }

        @Test func aPackagingFailureRemovesThePartialOutput() async {
            let partial = PartialZipView(frame: view.frame)
            harness.prepare(partial, isCertificateLoaded: true)
            await harness.sign("new-partial-zip", input: sampleIPA, on: partial)
            #expect(partial.statusLabel.stringValue == "Error packaging IPA", "partialZip.status")
            #expect(
                !FileManager.default.fileExists(
                    atPath: harness.work.child("new-partial-zip.ipa").path),
                "partialZip.outputRemoved")
        }

        @Test func aMissingTempFolderUnlocksTheForm() async {
            let noTempFolder = NoTempFolderView(frame: view.frame)
            harness.prepare(noTempFolder, isCertificateLoaded: true)
            await harness.sign("new-no-temp-folder", input: sampleIPA, on: noTempFolder)
            #expect(
                noTempFolder.statusLabel.stringValue == "Error creating temp folder",
                "noTempFolder.status")
            #expect(
                !noTempFolder.isSigning && noTempFolder.signButton.isEnabled,
                "noTempFolder.unlocked")
        }

        @Test func reportsTheFinishedFile() async {
            await harness.sign("new-done", input: sampleIPA)
            let doneFile = URL(fileURLWithPath: harness.work.child("new-done.ipa").path)
            #expect(
                view.statusLabel.stringValue == "Done, output at \(doneFile.path) · Show in Finder",
                "done.showInFinder")
            #expect(
                view.statusLink == doneFile && view.statusLabel.toolTip == doneFile.path,
                "done.link")
            #expect(
                isLinkStyled(
                    view.statusLabel.attributedStringValue.attributes(ofText: "Show in Finder")),
                "done.linkStyled")
        }

        @Test func showsTheBusyIndicatorWhileSigning() async {
            let shown = Collector<String>()
            let busy = view.busyIndicator.observe(\.isHidden) { indicator, _ in
                if !indicator.isHidden { shown.append("busy") }
            }
            let bar = view.progressBar.observe(\.isHidden) { bar, _ in
                if !bar.isHidden { shown.append("bar") }
            }
            await harness.sign("new-progress", input: sampleIPA)
            busy.invalidate()
            bar.invalidate()
            #expect(
                shown.all.contains("busy") && !shown.all.contains("bar"),
                "progress.busyWhileSigning")
            #expect(
                view.progressBar.isHidden && view.busyIndicator.isHidden && !view.isSigning,
                "progress.hiddenWhenDone")
        }

        @Test func uploadsTheSignedIPA() async throws {
            let link = "https://betadrop.app/install/?i=abc123"
            let modes = Collector<Bool>()
            let shown = Collector<String>()
            let modeObservation = view.progressBar.observe(\.isIndeterminate) { bar, _ in
                modes.append(bar.isIndeterminate)
            }
            let busy = view.busyIndicator.observe(\.isHidden) { indicator, _ in
                if !indicator.isHidden { shown.append("busy") }
            }
            let bar = view.progressBar.observe(\.isHidden) { bar, _ in
                if !bar.isHidden { shown.append("bar") }
            }
            try harness.signIn("ok~harness")
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            view.refreshUploadAccount()
            await harness.sign("new-upload", input: sampleIPA)
            modeObservation.invalidate()
            busy.invalidate()
            bar.invalidate()

            #expect(
                shown.all.contains("bar") && shown.all.last == "busy", "upload.progressSwitchesBars"
            )
            #expect(
                !view.progressBar.isIndeterminate && !modes.all.contains(true),
                "progress.determinateBarNeverIndeterminate")
            #expect(
                view.statusLabel.stringValue
                    == "Uploaded to BetaDrop — link copied · Open Install Page", "upload.status")
            #expect(view.statusLink?.absoluteString == link, "upload.link")
            #expect(
                isLinkStyled(
                    view.statusLabel.attributedStringValue.attributes(ofText: "Open Install Page")),
                "upload.linkStyled")
            #expect(view.statusLabel.toolTip == link, "upload.linkTooltip")
            #expect(NSPasteboard.general.string(forType: .string) == link, "upload.pasteboard")
            #expect(
                !view.isSigning && view.uploadPopup.isEnabled && view.signButton.isEnabled,
                "upload.unlocked")
            #expect(view.progressBar.isHidden, "upload.progressHidden")
            #expect(
                harness.mock.stats["ok~harness"]["sha256"] as? String
                    == sha256Hex(ofFile: harness.work.child("new-upload.ipa")), "upload.sameBytes")
            #expect(!harness.loggedText.contains("bd_live_harness"), "tokenNotLogged")
        }

        @Test func doesNotUploadAnAppex() async throws {
            let appex = harness.work.child("Standalone2.appex")
            try FileManager.default.copyItem(atPath: sampleAppex, toPath: appex.path)
            try harness.signIn("ok~harness")
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            view.refreshUploadAccount()
            await harness.sign("new-upload-appex", input: appex.path, output: appex.path)
            #expect(
                view.statusLabel.stringValue.hasSuffix(
                    "Standalone2.appex (only .ipa files can be uploaded) · Show in Finder"),
                "uploadAppex.skipped")
            #expect(harness.mock.stats["ok~harness"]["publish"] == nil, "uploadAppex.noUpload")
            let appexFile = URL(fileURLWithPath: appex.path)
            #expect(
                !view.statusLabel.stringValue.contains("Open Install Page")
                    && view.statusLink == appexFile && view.statusLabel.toolTip == appexFile.path,
                "uploadAppex.linkReplaced")
        }

        @Test func anExpiredSessionKeepsTheSignedFile() async throws {
            try harness.signIn("unauthorized~harness")
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            await harness.sign("new-upload-expired", input: sampleIPA)
            #expect(
                view.statusLabel.stringValue
                    == "BetaDrop session expired. Sign in again. · Show in Finder"
                    && view.isStatusWarning, "uploadExpired.status")
            #expect(
                !FileManager.default.fileExists(atPath: BetaDropConfig.fileURL().path),
                "uploadExpired.configCleared")
            #expect(view.uploadPopup.indexOfSelectedItem == 0, "uploadExpired.unchecked")
            #expect(
                view.statusLink
                    == URL(fileURLWithPath: harness.work.child("new-upload-expired.ipa").path),
                "uploadExpired.showInFinder")
        }
    }

    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewUnsignedTests {
        @Test func signingWithoutACertificateUnlocksTheForm() async throws {
            let harness = try await MainViewHarness()
            let view = harness.view
            await harness.sign(
                "new-no-certificate", input: harness.work.ipa("Sample.ipa", sampleAppInfo).path)
            #expect(
                view.statusLabel.stringValue == "No signing certificate selected",
                "noCertificate.status")
            #expect(!view.isSigning && view.signButton.isEnabled, "noCertificate.unlocked")
        }
    }
}
