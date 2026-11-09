import AppKit
import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewStatusTests {
        private let harness: MainViewHarness

        init() async throws {
            harness = try await MainViewHarness()
        }

        private var view: MainView {
            harness.view
        }

        private func edge(_ indicator: NSView) -> CGFloat {
            view.layoutSubtreeIfNeeded()
            return indicator.convert(indicator.bounds, to: view).maxX
        }

        @Test func progressKeepsItsSlotAndPercent() {
            view.showProgress(nil)
            let isIndeterminateShown =
                !view.busyIndicator.isHidden && view.busyIndicator.isIndeterminate
                && view.progressBar.isHidden
            let indeterminatePercent = view.progressLabel.stringValue
            view.setStatus("Short")
            let shortStatusEdge = edge(view.busyIndicator)
            view.setStatus("A much longer status message that changes the width of the status text")
            let longStatusEdge = edge(view.busyIndicator)
            view.showProgress(0.25)
            let determinateEdge = edge(view.progressBar)
            let isDeterminateShown =
                view.busyIndicator.isHidden && !view.progressBar.isHidden
                && view.progressBar.doubleValue == 25
            let determinatePercent = view.progressLabel.stringValue
            let percentFrame = view.progressLabel.convert(view.progressLabel.bounds, to: view)
            let barFrame = view.progressBar.convert(view.progressBar.bounds, to: view)
            #expect(
                percentFrame.maxX <= barFrame.minX && barFrame.maxX == view.bounds.maxX - 8,
                "progress.percentLeftOfBar")
            view.showProgress(0.999)
            let almostDonePercent = view.progressLabel.stringValue
            view.controlsEnabled(true)
            #expect(
                shortStatusEdge == longStatusEdge && longStatusEdge == determinateEdge
                    && determinateEdge == view.bounds.maxX - 8, "progress.fixedPosition")
            #expect(
                isIndeterminateShown && isDeterminateShown && view.progressBar.isHidden
                    && view.busyIndicator.isHidden, "progress.showAndHide")
            #expect(
                determinatePercent == "25%" && almostDonePercent == "99%", "progress.percentShown")
            #expect(
                indeterminatePercent == "" && view.progressLabel.stringValue == "",
                "progress.percentEmptyWhenIndeterminateOrHidden")
        }

        @Test func uploadPopupListsTheProviders() {
            #expect(
                view.uploadPopup.itemTitles == [
                    "None", "", "BetaDrop", "StreamShare", "Cloudflare Tunnel",
                ] && view.uploadPopup.item(at: 1)?.isSeparatorItem == true, "upload.items")
            #expect(
                (view.uploadPopup.accessibilityTitleUIElement() as? NSTextField)?.stringValue
                    == "Upload:", "upload.label")
            #expect(
                view.uploadPopup.indexOfSelectedItem == 0 && view.uploadService == nil,
                "upload.defaultNone")
            #expect(
                view.uploadPopup.toolTip == "Uploads the signed IPA and copies its install link",
                "upload.noneTooltip")
            #expect(view.inputControls.contains(view.uploadPopup), "upload.inputControl")
        }

        @Test func signedOutProviderIsUnchecked() {
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            view.refreshUploadAccount()
            #expect(
                view.uploadPopup.indexOfSelectedItem == 0 && view.uploadService == nil,
                "upload.signedOutUnchecks")
        }

        @Test func providerWithoutSignInStaysSelected() {
            view.uploadPopup.selectItem(withTitle: "StreamShare")
            view.chooseUploadService(view.uploadPopup)
            view.refreshUploadAccount()
            #expect(view.uploadService?.name == "StreamShare", "upload.noSignInKept")
        }

        @Test func signedInProviderStaysSelected() throws {
            try harness.signIn("ok~harness")
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            view.refreshUploadAccount()
            #expect(view.uploadPopup.toolTip == "Signed in as dev@example.com", "upload.tooltip")
            #expect(view.uploadService?.name == "BetaDrop", "upload.signedInKept")
        }
    }

    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct UploadAccountMenuTests {
        @Test func addsASignOutItemWhileSignedIn() async throws {
            let harness = try await MainViewHarness()
            let view = harness.view
            let menu = NSMenu()
            menu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "")
            try harness.signIn("ok~menu")
            let accountMenu = UploadAccountMenu(services: UploadServices.all, in: menu)
            let item = menu.items[3]
            #expect(menu.items.count == 6 && menu.delegate === accountMenu, "menu.position")
            #expect(
                menu.items[1].title == "Check for Updates…" && menu.items[5].title == "Quit",
                "menu.position")
            #expect(menu.items[2].isSeparatorItem && menu.items[4].isSeparatorItem, "menu.position")
            #expect(
                item.title == "Sign Out of BetaDrop (dev@example.com)" && !item.isHidden
                    && !menu.items[4].isHidden, "menu.signedInTitle")

            try FileManager.default.removeItem(at: BetaDropConfig.fileURL())
            accountMenu.menuNeedsUpdate(menu)
            #expect(item.isHidden && menu.items[4].isHidden, "menu.signedOutHidden")

            try harness.signIn("ok~menu")
            view.uploadPopup.selectItem(withTitle: "BetaDrop")
            accountMenu.menuNeedsUpdate(menu)
            if let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            _ = await isEventuallyTrue(5) {
                !FileManager.default.fileExists(atPath: BetaDropConfig.fileURL().path)
                    && harness.mock.stats["ok~menu"]["logout"] != nil
            }
            #expect(
                !FileManager.default.fileExists(atPath: BetaDropConfig.fileURL().path)
                    && harness.mock.stats["ok~menu"]["logout"] as? Int == 1, "menu.signOutClears")
            #expect(view.uploadPopup.indexOfSelectedItem == 0, "menu.signOutUnchecks")
        }
    }
}
