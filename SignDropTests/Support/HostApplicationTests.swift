import AppKit
import Testing
@testable import SignDrop

@MainActor
struct HostApplicationTests {
    @Test func launchSkipsStartupWork() throws {
        let view = try #require(NSApp.windows.compactMap { $0.contentView as? MainView }.first)
        #expect(view.codesigningCerts.isEmpty)
    }

    @Test func accountFileIsNotTheRealOne() {
        #expect(isAccountFileIsolated)
    }
}
