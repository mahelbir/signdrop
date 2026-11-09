import AppKit
import Foundation
import Testing

extension SerialTests {
    @MainActor
    @Suite(.requiresIsolatedAccountFile)
    struct MainViewHarnessTests {
        @Test func restoresPasteboardContentThatIsNotText() async throws {
            let outer = try await MainViewHarness()
            let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(image, forType: .png)

            do {
                let inner = try await MainViewHarness()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("copied during a test", forType: .string)
                withExtendedLifetime(inner) {}
            }

            #expect(NSPasteboard.general.data(forType: .png) == image)
            #expect(NSPasteboard.general.string(forType: .string) == nil)
            withExtendedLifetime(outer) {}
        }
    }
}
