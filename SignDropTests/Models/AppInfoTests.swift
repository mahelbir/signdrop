import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    struct AppInfoTests {
        private let work: WorkDirectory

        init() throws {
            work = try WorkDirectory()
        }

        @Test func readsAnIPA() {
            let app = AppInfo(ipa: work.ipa("Sample.ipa", sampleAppInfo).path)
            #expect(app?.bundleID == "com.acme.sample" && app?.displayName == "Sample App" && app?.version == "2.1" && app?.build == "42", "appInfo.ipa.fields")
            #expect(AppInfo(ipa: work.ipa("Plain.ipa", ["CFBundleIdentifier": "com.acme.plain", "CFBundleName": "Plain"]).path)?.displayName == "Plain", "appInfo.ipa.nameFallback")
        }

        @Test func rejectsUnreadableIPAs() {
            #expect(AppInfo(ipa: work.child("absent.ipa").path) == nil, "appInfo.ipa.missing")
            #expect(AppInfo(ipa: work.file("fake.ipa", Data("hello world".utf8)).path) == nil, "appInfo.ipa.notZip")
            #expect(AppInfo(ipa: work.ipa("Bare.ipa", nil).path) == nil, "appInfo.ipa.noInfoPlist")
        }

        @Test func readsAPayloadFolder() {
            #expect(AppInfo(payload: work.payload(sampleAppInfo).path)?.bundleID == "com.acme.sample", "appInfo.payload.fields")
            #expect(AppInfo(payload: work.child("nothing").path) == nil, "appInfo.payload.empty")
        }
    }
}
