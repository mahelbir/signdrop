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

        @Test func shareWaitsForASignedIPA() {
            #expect(!view.shareButton.isEnabled, "share.offUntilSigned")
            view.finishSigning(harness.work.child("Signed.ipa").path)
            #expect(view.shareButton.isEnabled, "share.onAfterSigning")
            view.controlsEnabled(false)
            #expect(!view.shareButton.isEnabled, "share.offWhileSigning")
            view.controlsEnabled(true)
            #expect(view.shareButton.isEnabled, "share.onAgain")
        }

        @Test func shareStaysOffForAnAppex() {
            let output = harness.work.child("Plugin.appex").path
            view.finishSigning(output)
            #expect(!view.shareButton.isEnabled, "share.offForAppex")
            #expect(
                view.statusLabel.stringValue == "Done, output at \(output) · Show in Finder",
                "share.appexStatus")
        }

        @Test func aFailedSigningTurnsShareOff() async {
            view.finishSigning(harness.work.child("Signed.ipa").path)
            view.inputFileField.stringValue = harness.work.child("Plugin.appex").path
            view.startSigning()
            _ = await isEventuallyTrue(5) { !view.isSigning }
            #expect(!view.shareButton.isEnabled, "share.offAfterFailure")
        }

        @Test func shareSitsToTheLeftOfSign() {
            view.layoutSubtreeIfNeeded()
            let share = view.shareButton.convert(view.shareButton.bounds, to: view)
            let sign = view.signButton.convert(view.signButton.bounds, to: view)
            #expect(
                share.maxX <= sign.minX && sign.minX - share.maxX < 20
                    && abs(share.midY - sign.midY) < 2, "share.besideSign")
        }

        @Test func shareOpensTheSignedFile() {
            let output = harness.work.child("Signed.ipa")
            view.finishSigning(output.path)
            view.shareSignedFile(view.shareButton)
            let controller = view.shareWindows.current
            defer { controller?.window?.close() }
            #expect(
                controller?.file.standardizedFileURL == output.standardizedFileURL,
                "share.opensFile")
            #expect(controller?.window?.isVisible == true, "share.windowShown")
        }

        @Test func finishingLeavesThePasteboardAlone() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            view.finishSigning(harness.work.child("Signed.ipa").path)
            #expect(
                NSPasteboard.general.string(forType: .string) == "unchanged", "share.noAutoCopy")
        }

        @Test func theSignButtonAsksForInputOnlyWhenItOpensAPanel() {
            view.inputFileField.stringValue = "/tmp/Plugin.appex"
            view.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: view.inputFileField)
            )
            #expect(view.signButton.title == "Sign", "sign.inPlaceHasNoEllipsis")
            view.inputFileField.stringValue = "/tmp/App.ipa"
            view.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: view.inputFileField)
            )
            #expect(view.signButton.title == "Sign…", "sign.panelHasEllipsis")
        }

        @Test func theFormStaysUnlockedWhileSharing() async throws {
            let service = ControlledShareService()
            let windows = ShareWindows(services: { [service] })
            view.shareWindows = windows
            let controller = windows.show(file: harness.work.child("Signed.ipa"))
            defer {
                controller.rows[0].job.cancel()
                controller.window?.close()
            }
            controller.rows[0].shareButton.performClick(nil)
            _ = await isEventuallyTrue(2) { service.shareCount == 1 }
            #expect(
                !view.isSigning && view.signButton.isEnabled && view.inputFileField.isEnabled,
                "share.formUnlocked")
        }

        @Test func aFileBeingSharedCannotBeOverwritten() async throws {
            let service = ControlledShareService()
            let windows = ShareWindows(services: { [service] })
            view.shareWindows = windows
            let signed = harness.work.child("Signed.ipa")
            let controller = windows.show(file: signed)
            defer {
                controller.rows[0].job.cancel()
                controller.window?.close()
            }
            #expect(!view.isOutputBeingShared(signed.path), "share.idleFileCanBeOverwritten")
            controller.rows[0].shareButton.performClick(nil)
            _ = await isEventuallyTrue(2) { service.shareCount == 1 }
            #expect(view.isOutputBeingShared(signed.path), "share.busyFileIsProtected")
            #expect(
                !view.isOutputBeingShared(harness.work.child("Other.ipa").path),
                "share.otherFileCanBeWritten")
            let alert = MainView.makeFileBeingSharedAlert()
            #expect(alert.messageText == "This file is being shared.", "share.overwriteAlert")
            #expect(
                alert.informativeText == "Stop sharing it first, or choose a different name.",
                "share.overwriteAlert")
        }

        @Test func closingTheWindowQuitsOnlyWhenShareWindowsAreOpen() {
            let terminated = Collector<Bool>()
            view.terminateApp = { _ in terminated.append(true) }
            #expect(view.windowShouldClose(NSWindow()), "close.noShareWindows")
            #expect(terminated.all.isEmpty, "close.lastWindowQuitsOnItsOwn")
            let controller = view.shareWindows.show(file: harness.work.child("Signed.ipa"))
            defer { controller.window?.close() }
            #expect(!view.windowShouldClose(NSWindow()), "close.keepsWindowUntilQuit")
            #expect(terminated.all == [true], "close.quitsTheApp")
        }

        @Test func theMenuCommandFollowsTheButton() {
            let item = NSMenuItem(
                title: "Share…", action: #selector(MainView.shareSignedFile(_:)), keyEquivalent: "")
            #expect(!view.validateMenuItem(item), "share.menuOff")
            view.finishSigning(harness.work.child("Signed.ipa").path)
            #expect(view.validateMenuItem(item), "share.menuOn")
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

        private func showDone() {
            let output = harness.work.child("new-done.ipa").path
            view.setStatus("Done, output at \(output)", link: URL(fileURLWithPath: output))
        }

        private var isReset: Bool {
            view.statusLabel.stringValue == "Ready"
                && !view.isStatusWarning
                && view.statusLink == nil
                && view.statusLabel.toolTip == nil
        }

        private func waitForAppInfo() async {
            _ = await isEventuallyTrue(5) { view.inputAppInfo != nil }
        }

        @Test func aDroppedFileClearsTheDoneStatus() async {
            showDone()
            view.fileDropped(ipa)
            #expect(isReset, "inputReset.dropped")
            await waitForAppInfo()
            #expect(isReset, "inputReset.droppedAfterRead")
        }

        @Test func aDroppedURLClearsTheStatus() throws {
            showDone()
            view.urlDropped(try #require(NSURL(string: "https://example.com/App.ipa")))
            #expect(isReset, "inputReset.urlDropped")
        }

        @Test func typingClearsTheStatus() async {
            showDone()
            view.inputFileField.stringValue = ipa
            view.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: view.inputFileField)
            )
            #expect(isReset, "inputReset.typed")
            await waitForAppInfo()
        }

        @Test func aProfileMismatchWarningSurvivesTheReset() async throws {
            view.selectCustomProfile(try #require(SigningFixtures.fixedProfile))
            showDone()
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

    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct ShareAccountMenuTests {
        @Test func addsASignOutItemWhileSignedIn() async throws {
            let harness = try await MainViewHarness()
            let menu = NSMenu()
            menu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "")
            try harness.signIn("ok~menu")
            let accountMenu = ShareAccountMenu(services: ShareServices.all, in: menu)
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
        }
    }

    @MainActor
    struct DockReopenTests {
        private func minimizedWindows() async -> [NSWindow] {
            let windows = (0..<2).map { _ in
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.orderFront(nil)
                window.miniaturize(nil)
                return window
            }
            _ = await isEventuallyTrue(5) { windows.allSatisfy(\.isMiniaturized) }
            return windows
        }

        @Test func clickingTheDockIconRestoresEveryMinimizedWindow() async throws {
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let windows = await minimizedWindows()
            defer { windows.forEach { $0.close() } }
            #expect(windows.allSatisfy { $0.isMiniaturized }, "reopen.setUp")
            #expect(
                !delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false),
                "reopen.handled")
            #expect(
                await isEventuallyTrue(5) { windows.allSatisfy { !$0.isMiniaturized } },
                "reopen.restored")
        }

        @Test func aVisibleWindowLeavesMinimizedOnesAlone() async throws {
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let windows = await minimizedWindows()
            defer { windows.forEach { $0.close() } }
            #expect(
                delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true),
                "reopen.default")
            await pause(0.3)
            #expect(windows.allSatisfy { $0.isMiniaturized }, "reopen.leftAlone")
        }
    }

    @MainActor
    struct AppMenusTests {
        private func titles(_ menu: NSMenu) -> [String] {
            menu.items.map(\.title)
        }

        private func installed() -> (menu: NSMenu, target: NSObject) {
            let menu = NSMenu()
            for title in ["SignDrop", "Edit", "View", "Help"] {
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            }
            let target = NSObject()
            AppMenus.install(in: menu, shareTarget: target)
            return (menu, target)
        }

        @Test func addsFileAndWindowInTheStandardOrder() {
            #expect(
                titles(installed().menu) == ["SignDrop", "File", "Edit", "View", "Window", "Help"],
                "menus.order")
        }

        @Test func theFileMenuSharesAndCloses() throws {
            let (menu, target) = installed()
            let file = try #require(menu.item(withTitle: "File")?.submenu)
            let share = try #require(file.item(withTitle: "Share…"))
            #expect(share.keyEquivalent == "E" && share.target === target, "menus.share")
            #expect(share.action == #selector(MainView.shareSignedFile(_:)), "menus.shareAction")
            let close = try #require(file.item(withTitle: "Close"))
            #expect(close.keyEquivalent == "w", "menus.close")
            #expect(close.action == #selector(NSWindow.performClose(_:)), "menus.closeAction")
        }

        @Test func theLaunchedAppListsItsWindowsInTheWindowMenu() throws {
            let window = try #require(NSApp.mainMenu?.item(withTitle: "Window")?.submenu)
            #expect(NSApp.windowsMenu === window, "menus.windowsMenu")
        }

        @Test func theMainWindowIsListedInTheWindowMenu() throws {
            let menu = try #require(NSApp.windowsMenu)
            let mainWindow = try #require(NSApp.windows.first { $0.contentView is MainView })
            #expect(
                menu.items.contains { $0.title == mainWindow.title }, "menus.mainWindowListed")
        }

        @Test func theWindowMenuHasTheStandardCommands() throws {
            let window = try #require(installed().menu.item(withTitle: "Window")?.submenu)
            #expect(
                window.item(withTitle: "Minimize")?.keyEquivalent == "m"
                    && window.item(withTitle: "Zoom") != nil
                    && window.item(withTitle: "Bring All to Front") != nil, "menus.windowItems")
        }
    }
}
