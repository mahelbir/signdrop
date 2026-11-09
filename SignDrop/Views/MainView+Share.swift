import Cocoa

extension MainView {

    func refreshShareButton() {
        shareButton.isEnabled = !isSigning && signedFile != nil
    }

    @objc func shareSignedFile(_ sender: Any) {
        guard !isSigning, let signedFile else { return }
        shareWindows.show(file: signedFile)
    }

    func finishSigning(_ output: String) {
        let outputURL = URL(fileURLWithPath: output)
        signedFile = output.pathExtension.lowercased() == "ipa" ? outputURL : nil
        setStatus("Done, output at \(output)", link: outputURL)
        controlsEnabled(true)
    }

    func askForOutputFile(for inputFile: String) -> String? {
        while true {
            let saveDialog = NSSavePanel()
            saveDialog.identifier = .signedOutputPanel
            saveDialog.allowedContentTypes = contentTypes(["ipa"])
            saveDialog.nameFieldStringValue =
                "\(inputFile.lastPathComponent.stringByDeletingPathExtension)-signed"
            guard saveDialog.runModal() == .OK, let path = saveDialog.url?.path else { return nil }
            guard isOutputBeingShared(path) else { return path }
            MainView.makeFileBeingSharedAlert().runModal()
        }
    }

    func isOutputBeingShared(_ path: String) -> Bool {
        shareWindows.isSharing(file: URL(fileURLWithPath: path))
    }

    static func makeFileBeingSharedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "This file is being shared."
        alert.informativeText = "Stop sharing it first, or choose a different name."
        alert.addButton(withTitle: "OK")
        return alert
    }

    func appendStatusLinkTitle() {
        let status = statusLabel.attributedStringValue
        let attributes = status.length > 0 ? status.attributes(at: 0, effectiveRange: nil) : [:]
        let text = NSMutableAttributedString(attributedString: status)
        text.append(NSAttributedString(string: " · ", attributes: attributes))
        text.append(
            NSAttributedString(
                string: "Show in Finder", attributes: linkAttributes(attributes)))
        statusLabel.attributedStringValue = text
    }

    func linkAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key:
        Any]
    {
        attributes.merging([
            .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]) { $1 }
    }
}

extension MainView: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shareWindows.hasActiveWork || shareWindows.hasOpenWindows else { return true }
        terminateApp(sender)
        return false
    }
}

extension MainView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(shareSignedFile(_:)) ? shareButton.isEnabled : true
    }
}
