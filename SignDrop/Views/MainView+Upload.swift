import Cocoa

extension MainView {

    var uploadService: UploadService? {
        uploadPopup.selectedItem?.representedObject as? UploadService
    }

    func configureUploadPopup() {
        uploadPopup.removeAllItems()
        uploadPopup.addItem(withTitle: "None")
        uploadPopup.menu?.addItem(.separator())
        for service in UploadServices.all {
            uploadPopup.addItem(withTitle: service.name)
            uploadPopup.lastItem?.representedObject = service
        }
        uploadPopup.target = self
        uploadPopup.action = #selector(chooseUploadService(_:))
        refreshUploadAccount()
        NotificationCenter.default.addObserver(self, selector: #selector(uploadAccountDidChange(_:)), name: .uploadAccountDidChange, object: nil)
    }

    @objc func uploadAccountDidChange(_ notification: Notification) {
        refreshUploadAccount()
    }

    func refreshUploadAccount() {
        if let service = uploadService, service.isSignInRequired, service.accountName == nil {
            uploadPopup.selectItem(at: 0)
        }
        uploadPopup.toolTip = uploadService?.accountName.map { "Signed in as \($0)" } ?? "Uploads the signed IPA and copies its install link"
    }

    @objc func chooseUploadService(_ sender: NSPopUpButton) {
        guard let service = uploadService, !service.isReadyToUpload else {
            refreshUploadAccount()
            return
        }
        Task {
            if !(await prepareUpload(for: service)) {
                sender.selectItem(at: 0)
            }
            refreshUploadAccount()
        }
    }

    func prepareUpload(for service: UploadService) async -> Bool {
        guard let window = window else { return false }
        return await service.prepareToUpload(in: window)
    }

    func startSigningWhenUploadReady() {
        guard let service = uploadService, !service.isReadyToUpload else {
            startSigning()
            return
        }
        Task {
            if await prepareUpload(for: service) {
                startSigning()
            } else {
                uploadPopup.selectItem(at: 0)
                refreshUploadAccount()
            }
        }
    }

    func finishSigning(_ output: String, isUploadRequested: Bool) {
        let outputURL = URL(fileURLWithPath: output)
        guard isUploadRequested, let service = uploadService else {
            setStatus("Done, output at \(output)", link: outputURL)
            controlsEnabled(true)
            return
        }
        guard output.pathExtension.lowercased() == "ipa" else {
            setStatus("Done, output at \(output) (only .ipa files can be uploaded)", link: outputURL)
            controlsEnabled(true)
            return
        }
        Task {
            await uploadSignedFile(outputURL, to: service)
        }
    }

    func uploadSignedFile(_ file: URL, to service: UploadService) async {
        setStatus(service.isLiveShare ? "Starting \(service.name)…" : "Uploading to \(service.name)…")
        showProgress(service.isLiveShare ? nil : 0)
        do {
            let result = try await service.upload(file) { [weak self] fraction in
                self?.showProgress(fraction < 1 ? fraction : nil)
            }
            reportUpload(result, from: service)
            if let share = result.liveShare, share.isActive {
                watchSharing(share, file: file)
                return
            }
        } catch UploadError.sessionExpired {
            setStatus("\(service.name) session expired. Sign in again.", isWarning: true, link: file)
        } catch {
            setStatus("\(service.isLiveShare ? "Sharing" : "Upload") failed: \(error.localizedDescription)", isWarning: true, link: file)
        }
        controlsEnabled(true)
    }

    func appendStatusLinkTitle() {
        let status = statusLabel.attributedStringValue
        let attributes = status.length > 0 ? status.attributes(at: 0, effectiveRange: nil) : [:]
        let text = NSMutableAttributedString(attributedString: status)
        text.append(NSAttributedString(string: " · ", attributes: attributes))
        text.append(NSAttributedString(string: statusLink?.isFileURL == true ? "Show in Finder" : "Open Install Page", attributes: linkAttributes(attributes)))
        statusLabel.attributedStringValue = text
    }

    func linkAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        attributes.merging([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }
    }

    func reportUpload(_ result: UploadResult, from service: UploadService) {
        var headline = result.liveShare == nil ? "Uploaded to \(service.name)" : "Sharing from this Mac"
        if let link = result.link {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            Log.write("Install link: \(link.absoluteString)")
            headline += " — link copied"
        }
        setStatus(([headline] + result.warnings).joined(separator: ". "), isWarning: !result.warnings.isEmpty, link: result.link)
        if !result.deletionRequests.isEmpty {
            showUploadDeletion((service.name, result.deletionRequests))
        }
    }

    func showUploadDeletion(_ upload: (serviceName: String, requests: [URLRequest])) {
        deletableUpload = upload
        deleteUploadButton.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    func makeDeleteUploadAlert() -> NSAlert? {
        guard let upload = deletableUpload else { return nil }
        let alert = NSAlert()
        alert.messageText = "Delete this upload from \(upload.serviceName)?"
        alert.informativeText = "The install link will stop working. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @objc func confirmUploadDeletion(_ sender: Any) {
        guard let alert = makeDeleteUploadAlert(), let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.deleteUpload()
            }
        }
    }

    @objc func copyDeletionCommand(_ sender: Any) {
        guard let upload = deletableUpload else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UploadServices.deletionCommand(upload.requests), forType: .string)
    }

    func deleteUpload() {
        guard let upload = deletableUpload else { return }
        controlsEnabled(false)
        setStatus("Deleting the upload from \(upload.serviceName)…")
        showProgress(nil)
        Task {
            do {
                try await UploadServices.delete(upload.requests, service: upload.serviceName)
                setStatus("Deleted the upload from \(upload.serviceName)")
            } catch {
                setStatus("Could not delete the upload: \(error.localizedDescription)", isWarning: true)
                showUploadDeletion(upload)
            }
            controlsEnabled(true)
        }
    }

    func watchSharing(_ share: LiveShare, file: URL) {
        hideProgress()
        stopSharingButton.isHidden = false
        window?.invalidateCursorRects(for: self)
        share.onEnd = { [weak self] reason in
            Log.write(reason)
            self?.finishSharing("Sharing stopped: the tunnel closed unexpectedly.", isWarning: true, link: file)
        }
    }

    @objc func stopSharing(_ sender: Any) {
        LiveShare.current?.stop()
        finishSharing("Stopped sharing")
    }

    func finishSharing(_ status: String, isWarning: Bool = false, link: URL? = nil) {
        stopSharingButton.isHidden = true
        setStatus(status, isWarning: isWarning, link: link)
        controlsEnabled(true)
    }

    static func makeQuitWhileSharingAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Stop sharing and quit?"
        alert.informativeText = "The install link will stop working."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

extension MainView: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard LiveShare.current != nil else { return true }
        NSApp.terminate(sender)
        return false
    }
}
