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

        @Test func sharesTheSignedIPAFromItsWindow() async throws {
            try harness.signIn("ok~harness")
            await harness.sign("new-share", input: sampleIPA)
            view.shareSignedFile(view.shareButton)
            let controller = try #require(view.shareWindows.current)
            defer { controller.window?.close() }
            let row = controller.rows[0]
            row.shareButton.performClick(nil)
            _ = await isEventuallyTrue(20) { !row.copyLinkButton.isHidden }
            #expect(
                row.linkLabel.stringValue == "https://betadrop.app/install/?i=abc123",
                "share.link")
            #expect(
                harness.mock.stats["ok~harness"]["sha256"] as? String
                    == sha256Hex(ofFile: harness.work.child("new-share.ipa")), "share.sameBytes")
            #expect(!harness.loggedText.contains("bd_live_harness"), "tokenNotLogged")
        }

        @Test func doesNotOfferAnAppexForSharing() async throws {
            let appex = harness.work.child("Standalone2.appex")
            try FileManager.default.copyItem(atPath: sampleAppex, toPath: appex.path)
            await harness.sign("new-share-appex", input: appex.path, output: appex.path)
            #expect(!view.shareButton.isEnabled, "shareAppex.off")
            let appexFile = URL(fileURLWithPath: appex.path)
            #expect(
                view.statusLink == appexFile && view.statusLabel.toolTip == appexFile.path,
                "shareAppex.finderLink")
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
