import AppKit
import Foundation
import Testing
@testable import SignDrop

struct SavedProfileTests {
    private let saved = SavedProfile(name: "Acme", appID: "com.acme.app", teamID: "ABCDE12345")
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    @Test func picksTheNewestProfileWithTheSameIdentity() {
        let other = SavedProfile(name: "Other", appID: "com.acme.app", teamID: "ABCDE12345")
        let candidates = [
            (identity: other, created: newer), (identity: saved, created: older),
            (identity: saved, created: newer), (identity: saved, created: older),
        ]
        #expect(saved.newestIndex(in: candidates) == 2, "savedProfile.newest")
    }

    @Test func needsTheNameAppIDAndTeamToMatch() {
        let differing = [
            SavedProfile(name: "Other", appID: "com.acme.app", teamID: "ABCDE12345"),
            SavedProfile(name: "Acme", appID: "com.acme.other", teamID: "ABCDE12345"),
            SavedProfile(name: "Acme", appID: "com.acme.app", teamID: "ZZZZZ99999"),
        ]
        for profile in differing {
            #expect(
                saved.newestIndex(in: [(identity: profile, created: newer)]) == nil,
                "savedProfile.differs")
        }
    }
}

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewSavedChoicesTests {
        private let harness: MainViewHarness

        init() async throws {
            harness = try await MainViewHarness()
        }

        private var view: MainView {
            harness.view
        }

        private func profileCopy() throws -> String {
            let copy = harness.work.child("custom-\(UUID().uuidString).mobileprovision").path
            try FileManager.default.copyItem(
                atPath: try #require(SigningFixtures.fixedProfile), toPath: copy)
            return copy
        }

        private func choose(_ popup: NSPopUpButton, at index: Int) {
            popup.selectItem(at: index)
            if let action = popup.action {
                NSApp.sendAction(action, to: popup.target, from: popup)
            }
        }

        @Test func firstLaunchKeepsTheDefaults() {
            let next = harness.relaunchedView()
            #expect(next.noGetTaskAllowCheckbox.state == .on, "saved.defaultGetTaskAllow")
            #expect(next.ignorePluginsCheckbox.state == .off, "saved.defaultPlugins")
            #expect(next.profilePopup.indexOfSelectedItem == 0, "saved.defaultProfile")
        }

        @Test func optionsComeBackAfterARelaunch() {
            view.noGetTaskAllowCheckbox.performClick(nil)
            view.ignorePluginsCheckbox.performClick(nil)
            let next = harness.relaunchedView()
            #expect(next.noGetTaskAllowCheckbox.state == .off, "saved.getTaskAllow")
            #expect(next.ignorePluginsCheckbox.state == .on, "saved.plugins")
        }

        @Test func aDroppedProfileFileComesBack() throws {
            let path = try profileCopy()
            view.fileDropped(path)
            #expect(harness.relaunchedView().profileFilename == path, "saved.droppedProfile")
        }

        @Test func aDeletedProfileFileFallsBackToReSignOnly() throws {
            let path = try profileCopy()
            view.fileDropped(path)
            try FileManager.default.removeItem(atPath: path)
            let next = harness.relaunchedView()
            #expect(
                next.profilePopup.indexOfSelectedItem == 0 && next.profileFilename == nil,
                "saved.deletedProfile")
        }

        @Test func aProfileFileThatExpiredLeavesTheAppIDEditable() throws {
            let path = try profileCopy()
            view.fileDropped(path)
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.copyItem(
                atPath: try #require(SigningFixtures.expiredProfile), toPath: path)
            let next = harness.relaunchedView()
            #expect(
                next.profilePopup.indexOfSelectedItem == 0 && next.profileFilename == nil,
                "saved.expiredProfile")
            #expect(next.appIDField.isEnabled, "saved.expiredKeepsAppIDEditable")
            #expect(next.appIDField.stringValue.isEmpty, "saved.expiredLeavesAppIDEmpty")
        }

        @Test func droppingAnExpiredProfileLeavesTheAppIDEditable() throws {
            view.fileDropped(try #require(SigningFixtures.expiredProfile))
            #expect(view.profilePopup.indexOfSelectedItem == 0, "expired.reSignOnly")
            #expect(view.appIDField.isEnabled, "expired.keepsAppIDEditable")
            #expect(view.appIDField.stringValue.isEmpty, "expired.leavesAppIDEmpty")
            #expect(
                view.statusLabel.stringValue == "Provisioning profile expired", "expired.status")
        }

        @Test func anInstalledProfileIsFoundAgainAfterItIsRenewed() throws {
            let original = try #require(ProvisioningProfile(filename: try profileCopy()))
            view.customProfiles = [original]
            view.populateProvisioningProfiles()
            view.customProfiles = []
            let index = try #require(
                view.provisioningProfiles.firstIndex { $0.filename == original.filename })
            choose(view.profilePopup, at: index + 3)

            let renewedPath = try profileCopy()
            let renewed = try #require(ProvisioningProfile(filename: renewedPath))
            #expect(
                harness.relaunchedView(profiles: [renewed]).profileFilename == renewedPath,
                "saved.renewedProfile")
        }

        @Test func anUnavailableProfileFallsBackToReSignOnly() throws {
            let original = try #require(ProvisioningProfile(filename: try profileCopy()))
            view.customProfiles = [original]
            view.populateProvisioningProfiles()
            view.customProfiles = []
            let index = try #require(
                view.provisioningProfiles.firstIndex { $0.filename == original.filename })
            choose(view.profilePopup, at: index + 3)
            let next = harness.relaunchedView()
            #expect(
                next.profilePopup.indexOfSelectedItem == 0 && next.profileFilename == nil,
                "saved.unavailableProfile")
        }

        @Test func choosingReSignOnlyForgetsTheProfile() throws {
            view.fileDropped(try profileCopy())
            choose(view.profilePopup, at: 0)
            let next = harness.relaunchedView()
            #expect(
                next.profilePopup.indexOfSelectedItem == 0 && next.profileFilename == nil,
                "saved.forgotProfile")
        }

        @Test func aRestoredProfileIsNotSavedOverByTheLaunch() throws {
            let path = try profileCopy()
            view.fileDropped(path)
            _ = harness.relaunchedView()
            #expect(harness.relaunchedView().profileFilename == path, "saved.survivesLaunches")
        }
    }
}
