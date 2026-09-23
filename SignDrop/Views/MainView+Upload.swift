import Cocoa

extension MainView {

    var uploadService: UploadService {
        UploadServices.all[0]
    }

    func configureUploadCheckbox() {
        uploadCheckbox.title = "Upload to \(uploadService.name)"
        uploadCheckbox.target = self
        uploadCheckbox.action = #selector(toggleUpload(_:))
        refreshUploadAccount()
        NotificationCenter.default.addObserver(self, selector: #selector(uploadAccountDidChange(_:)), name: .uploadAccountDidChange, object: nil)
    }

    @objc func uploadAccountDidChange(_ notification: Notification) {
        refreshUploadAccount()
    }

    func refreshUploadAccount() {
        if let account = uploadService.accountName {
            uploadCheckbox.toolTip = "Signed in as \(account)"
        } else {
            uploadCheckbox.toolTip = "Uploads the signed IPA and copies its install link"
            uploadCheckbox.state = .off
        }
    }

    @objc func toggleUpload(_ sender: NSButton) {
        guard sender.state == .on else { return }
        Task {
            sender.state = await ensureUploadSignIn() ? .on : .off
        }
    }

    func ensureUploadSignIn() async -> Bool {
        if uploadService.accountName != nil {
            return true
        }
        guard let window = window else { return false }
        return await uploadService.signIn(in: window)
    }

    func startSigningWhenUploadReady() {
        guard uploadCheckbox.state == .on, uploadService.accountName == nil else {
            startSigning()
            return
        }
        Task {
            if await ensureUploadSignIn() {
                startSigning()
            } else {
                uploadCheckbox.state = .off
            }
        }
    }

    func finishSigning(_ output: String, isUploadRequested: Bool) {
        guard isUploadRequested else {
            setStatus("Done, output at \(output)")
            controlsEnabled(true)
            return
        }
        guard output.pathExtension.lowercased() == "ipa" else {
            setStatus("Done, output at \(output) (only .ipa files can be uploaded)")
            controlsEnabled(true)
            return
        }
        Task {
            await uploadSignedFile(URL(fileURLWithPath: output))
        }
    }

    func uploadSignedFile(_ file: URL) async {
        setStatus("Uploading to \(uploadService.name)…")
        downloadProgress.doubleValue = 0
        downloadProgress.isHidden = false
        do {
            let result = try await uploadService.upload(file) { [weak self] fraction in
                self?.downloadProgress.doubleValue = fraction * 100
            }
            reportUpload(result)
        } catch UploadError.sessionExpired {
            setStatus("\(uploadService.name) session expired. Sign in again.", isWarning: true)
        } catch {
            setStatus("Upload failed: \(error.localizedDescription)", isWarning: true)
        }
        downloadProgress.isHidden = true
        controlsEnabled(true)
    }

    func reportUpload(_ result: UploadResult) {
        let isWarning = !result.warnings.isEmpty
        guard let link = result.link else {
            setStatus((["Uploaded to \(uploadService.name)"] + result.warnings).joined(separator: ". "), isWarning: isWarning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        Log.write("Install link: \(link.absoluteString)")
        setStatus((["Uploaded to \(uploadService.name) — link copied"] + result.warnings).joined(separator: ". "), isWarning: isWarning, link: link)
    }
}
