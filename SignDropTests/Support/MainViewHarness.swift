import AppKit
import Foundation
import Testing
@testable import SignDrop

@MainActor
final class MainViewHarness {
    let work: WorkDirectory
    let mock: BetaDropMockServer
    let view = MainView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    private let savedPasteboard: [[NSPasteboard.PasteboardType: Data]] =
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { contents, type in
                contents[type] = item.data(forType: type)
            }
        }
    private let savedLogName = Log.logName

    init(isCertificateLoaded: Bool = false) async throws {
        try #require(isAccountFileIsolated)
        work = try WorkDirectory()
        mock = try await BetaDropMockServer()
        Log.logName = work.child("app.log").path
        BetaDropConfig.clear(at: BetaDropConfig.fileURL())
        prepare(view, isCertificateLoaded: isCertificateLoaded)
    }

    deinit {
        Log.logName = savedLogName
        BetaDropConfig.clear(at: BetaDropConfig.fileURL())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(
            savedPasteboard.map { contents in
                let item = NSPasteboardItem()
                contents.forEach { item.setData($0.value, forType: $0.key) }
                return item
            })
    }

    var loggedText: String {
        (try? String(contentsOf: work.child("app.log"), encoding: .utf8)) ?? ""
    }

    func prepare(_ target: MainView, isCertificateLoaded: Bool) {
        target.setUpLayout()
        target.populateProvisioningProfiles()
        if isCertificateLoaded {
            target.populateCodesigningCerts()
        }
    }

    func isBesideStatus(_ button: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        let labelFrame = view.statusLabel.convert(view.statusLabel.bounds, to: view)
        let buttonFrame = button.convert(button.bounds, to: view)
        return buttonFrame.minX >= labelFrame.maxX && buttonFrame.minX - labelFrame.maxX < 20
            && abs(buttonFrame.midY - labelFrame.midY) < 2
    }

    func signIn(_ scenario: String) throws {
        try BetaDropConfig(
            apiUrl: mock.api(scenario), token: "bd_live_harness",
            user: .init(id: "1", email: "dev@example.com", role: nil)
        ).write(to: BetaDropConfig.fileURL())
        view.refreshUploadAccount()
    }

    func sign(_ name: String, input: String, output: String? = nil, on other: MainView? = nil) async
    {
        let target = other ?? view
        target.inputFileField.stringValue = input
        target.inputAppInfo = target.readAppInfo(input)
        target.profilePopup.selectItem(at: 0)
        target.chooseProvisioningProfile(target.profilePopup)
        if let certificate = SigningFixtures.certificate {
            target.certificatePopup.selectItem(withTitle: certificate)
        }
        target.newEntitlementsPath = ""
        target.outputFile = output ?? work.child("\(name).ipa").path
        target.controlsEnabled(false)
        let finished = Collector<Bool>()
        Thread.detachNewThread {
            target.signingThread()
            finished.append(true)
        }
        _ = await isEventuallyTrue(120) { !finished.all.isEmpty && !target.isSigning }
    }
}

extension NSAttributedString {
    func attributes(ofText text: String) -> [NSAttributedString.Key: Any] {
        let range = (string as NSString).range(of: text)
        return range.location == NSNotFound
            ? [:] : attributes(at: range.location, effectiveRange: nil)
    }
}

func isLinkStyled(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
    attributes[.foregroundColor] as? NSColor == .linkColor
        && attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue
}
