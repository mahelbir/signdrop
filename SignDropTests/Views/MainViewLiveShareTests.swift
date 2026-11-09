import AppKit
import Foundation
import Testing
@testable import SignDrop

@MainActor
private final class FakeShareService: UploadService {
    let name = "Fake Tunnel"
    let accountName: String? = nil
    let isSignInRequired = false
    let isLiveShare = true
    var isReadyToUpload = true
    var isPrepared = false
    var result: Result<UploadResult, Error> = .failure(UploadError.server("unset"))
    var statusDuringUpload = ""
    var isBusyDuringUpload = false
    private let view: MainView

    init(view: MainView) {
        self.view = view
    }

    func signIn(in window: NSWindow) async -> Bool {
        true
    }

    func prepareToUpload(in window: NSWindow) async -> Bool {
        isPrepared
    }

    func signOut() async {}

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult {
        statusDuringUpload = view.statusLabel.stringValue
        isBusyDuringUpload = !view.busyIndicator.isHidden && view.progressBar.isHidden
        return try result.get()
    }
}

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewLiveShareTests {
        private let harness: MainViewHarness
        private let service: FakeShareService
        private let file: URL
        private let link = URL(string: "https://tinyurl.com/example")!
        private let stopped = Collector<Bool>()

        init() async throws {
            harness = try await MainViewHarness()
            service = FakeShareService(view: harness.view)
            file = harness.work.child("new-done.ipa")
        }

        private var view: MainView {
            harness.view
        }

        private func makeShare() -> LiveShare {
            let stopped = stopped
            return LiveShare { stopped.append(true) }
        }

        private func upload() async {
            view.controlsEnabled(false)
            await view.uploadSignedFile(file, to: service)
        }

        @Test func sharingLocksTheFormUntilStopped() async {
            let share = makeShare()
            service.result = .success(UploadResult(link: link, warnings: [], liveShare: share))
            await upload()
            #expect(service.statusDuringUpload == "Starting Fake Tunnel…" && service.isBusyDuringUpload, "liveShare.startingStatus")
            #expect(view.statusLabel.stringValue == "Sharing from this Mac — link copied · Open Install Page", "liveShare.status")
            #expect(!view.stopSharingButton.isHidden && view.stopSharingButton.title == "Stop Sharing" && view.deleteUploadButton.isHidden, "liveShare.stopShown")
            let title = view.stopSharingButton.attributedTitle
            #expect(isLinkStyled(title.length > 0 ? title.attributes(at: 0, effectiveRange: nil) : [:]), "liveShare.stopLinkStyled")
            #expect(harness.isBesideStatus(view.stopSharingButton), "liveShare.stopBesideStatus")
            #expect(view.isSigning && !view.signButton.isEnabled && !view.uploadPopup.isEnabled, "liveShare.locked")
            #expect(view.busyIndicator.isHidden && view.progressBar.isHidden, "liveShare.progressHidden")
            #expect(LiveShare.current === share, "liveShare.current")

            view.stopSharing(view.stopSharingButton)
            #expect(!stopped.all.isEmpty && LiveShare.current == nil, "liveShare.stopStops")
            #expect(view.statusLabel.stringValue == "Stopped sharing" && !view.isStatusWarning, "liveShare.stoppedStatus")
            #expect(!view.isSigning && view.signButton.isEnabled && view.stopSharingButton.isHidden, "liveShare.unlockedAfterStop")
            #expect(view.windowShouldClose(NSWindow()), "liveShare.windowClosesWithoutShare")
        }

        @Test func anUnexpectedEndWarnsAndUnlocks() async {
            let share = makeShare()
            service.result = .success(UploadResult(link: link, warnings: [], liveShare: share))
            await upload()
            share.end("ERR connection lost")
            #expect(view.statusLabel.stringValue == "Sharing stopped: the tunnel closed unexpectedly. · Show in Finder", "liveShare.unexpectedStatus")
            #expect(view.isStatusWarning && view.statusLink == file, "liveShare.unexpectedStatus")
            #expect(!stopped.all.isEmpty && !view.isSigning && view.stopSharingButton.isHidden && LiveShare.current == nil, "liveShare.unexpectedUnlocks")
        }

        @Test func aFailedShareWarnsAndUnlocks() async {
            service.result = .failure(UploadError.server("boom"))
            await upload()
            #expect(view.statusLabel.stringValue == "Sharing failed: boom · Show in Finder" && view.isStatusWarning, "liveShare.failedStatus")
            #expect(!view.isSigning && view.stopSharingButton.isHidden, "liveShare.failedUnlocks")
        }

        @Test func quittingAsksFirst() {
            let alert = MainView.makeQuitWhileSharingAlert()
            #expect(alert.messageText == "Stop sharing and quit?", "liveShare.quitAlert")
            #expect(alert.informativeText == "The install link will stop working.", "liveShare.quitAlert")
            #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"], "liveShare.quitAlert")
        }

        @Test func anUnreadyProviderIsUnselected() async {
            view.uploadPopup.addItem(withTitle: "Fake Tunnel")
            view.uploadPopup.lastItem?.representedObject = service
            view.uploadPopup.selectItem(withTitle: "Fake Tunnel")
            view.chooseUploadService(view.uploadPopup)
            #expect(view.uploadPopup.titleOfSelectedItem == "Fake Tunnel", "liveShare.readyKept")
            service.isReadyToUpload = false
            view.chooseUploadService(view.uploadPopup)
            _ = await isEventuallyTrue(3) { view.uploadPopup.indexOfSelectedItem == 0 }
            #expect(view.uploadPopup.indexOfSelectedItem == 0, "liveShare.notReadyResets")
        }
    }
}
