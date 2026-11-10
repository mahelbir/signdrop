import Cocoa

@MainActor
final class ShareRow: NSObject {
    let job: ShareJob
    let nameLabel: NSTextField
    let linkLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let progress = ProgressSlot()
    let shareButton = NSButton(title: "Share", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let copyLinkButton = NSButton(title: "Copy Link", target: nil, action: nil)
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop Sharing", target: nil, action: nil)
    let detailView = NSStackView()
    let actionsView = NSStackView()
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var onLayoutChange: (() -> Void)?
    private let progressRow = NSStackView()
    private let rawLinkMenu = NSMenu()

    private var buttons: [NSButton] {
        [
            shareButton, cancelButton, retryButton, copyLinkButton, openButton, deleteButton,
            stopButton,
        ]
    }

    private var finishedResult: ShareResult? {
        if case .finished(let result) = job.state {
            return result
        }
        return nil
    }

    init(job: ShareJob) {
        self.job = job
        nameLabel = NSTextField(labelWithString: job.service.name)
        super.init()
        configureControls()
        job.onChange = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(accountDidChange(_:)), name: .shareAccountDidChange,
            object: nil)
        render()
    }

    private func configureControls() {
        for (button, action) in [
            (shareButton, #selector(share(_:))), (cancelButton, #selector(cancel(_:))),
            (retryButton, #selector(share(_:))), (copyLinkButton, #selector(copyLink(_:))),
            (openButton, #selector(openLink(_:))), (deleteButton, #selector(confirmDelete(_:))),
            (stopButton, #selector(stopSharing(_:))),
        ] {
            button.target = self
            button.action = action
        }
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        linkLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.isSelectable = true
        linkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .systemOrange
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rawLinkMenu.addItem(
            withTitle: "Copy itms-services Link", action: #selector(copyRawLink(_:)),
            keyEquivalent: ""
        ).target = self
        deleteButton.toolTip = "Right-click to copy a Terminal command that deletes this share"
        deleteButton.menu = NSMenu()
        deleteButton.menu?.addItem(
            withTitle: "Copy Delete Command", action: #selector(copyDeletionCommand(_:)),
            keyEquivalent: ""
        ).target = self
        progress.bar.setAccessibilityLabel("\(job.service.name) progress")
        progress.busyIndicator.setAccessibilityLabel("\(job.service.name) progress")
        progress.label.alignment = .left
        [progress.busyIndicator, progress.bar, progress.label].forEach {
            progressRow.addArrangedSubview($0)
        }
        NSLayoutConstraint.activate([
            progress.label.widthAnchor.constraint(equalToConstant: 34),
            progress.bar.widthAnchor.constraint(equalToConstant: 140),
            progress.busyIndicator.widthAnchor.constraint(equalTo: progress.bar.widthAnchor),
        ])
        detailView.orientation = .vertical
        detailView.alignment = .leading
        detailView.spacing = 2
        [progressRow, linkLabel, noteLabel].forEach { detailView.addArrangedSubview($0) }
        detailView.setHuggingPriority(.defaultLow, for: .horizontal)
        actionsView.spacing = 6
        buttons.forEach { actionsView.addArrangedSubview($0) }
    }

    @objc private func accountDidChange(_ notification: Notification) {
        render()
    }

    func render() {
        var visibleButtons: [NSButton] = []
        var fraction: Double??
        var link: URL?
        var notes: [String] = []
        switch job.state {
        case .ready:
            visibleButtons = [shareButton]
        case .preparing:
            fraction = .some(nil)
        case .running(let progress):
            fraction = .some(progress)
            visibleButtons = [cancelButton]
        case .finished(let result):
            link = result.link
            notes = result.warnings + [job.deletionError].compactMap { $0 }
            visibleButtons = buttons(for: result)
            copyLinkButton.menu = result.itmsLink == nil ? nil : rawLinkMenu
            copyLinkButton.toolTip =
                result.itmsLink == nil ? nil : "Right-click to copy the itms-services link"
        case .deleting(let result):
            fraction = .some(nil)
            link = result.link
        case .failed(let message):
            notes = [message]
            visibleButtons = [retryButton]
        }
        let suffix = job.service.isReadyToShare ? "" : "…"
        shareButton.title = "Share" + suffix
        retryButton.title = "Retry" + suffix
        let window = nameLabel.window
        let isLosingFocus = buttons.contains {
            $0 === window?.firstResponder && !visibleButtons.contains($0)
        }
        buttons.forEach { $0.isHidden = !visibleButtons.contains($0) }
        if isLosingFocus {
            window?.makeFirstResponder(nil)
        }
        if let fraction {
            progress.show(fraction)
        } else {
            progress.hide()
        }
        progressRow.isHidden = fraction == nil
        linkLabel.stringValue = link?.absoluteString ?? ""
        linkLabel.toolTip = link?.absoluteString
        linkLabel.isHidden = link == nil
        noteLabel.stringValue = notes.joined(separator: ". ")
        noteLabel.isHidden = notes.isEmpty
        nameLabel.toolTip = job.service.accountName.map { "Signed in as \($0)" }
        onLayoutChange?()
    }

    private func buttons(for result: ShareResult) -> [NSButton] {
        var visible = result.link == nil ? [] : [copyLinkButton, openButton]
        if !result.deletionRequests.isEmpty {
            visible.append(deleteButton)
        }
        if result.liveShare != nil {
            visible.append(stopButton)
        }
        return visible
    }

    func makeDeleteAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete this share from \(job.service.name)?"
        alert.informativeText = "The install link will stop working. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func share(_ sender: NSButton) {
        guard let window = sender.window else { return }
        job.start(in: window)
    }

    @objc private func cancel(_ sender: Any) {
        job.cancel()
    }

    @objc private func copyLink(_ sender: Any) {
        if let link = finishedResult?.link {
            copy(link.absoluteString)
        }
    }

    @objc private func copyRawLink(_ sender: Any) {
        if let itmsLink = finishedResult?.itmsLink {
            copy(itmsLink)
        }
    }

    @objc private func openLink(_ sender: Any) {
        if let link = finishedResult?.link {
            openURL(link)
        }
    }

    @objc private func confirmDelete(_ sender: NSButton) {
        guard let window = sender.window else { return }
        makeDeleteAlert().beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.job.delete()
            }
        }
    }

    @objc private func copyDeletionCommand(_ sender: Any) {
        if let requests = finishedResult?.deletionRequests {
            copy(ShareServices.deletionCommand(requests))
        }
    }

    @objc private func stopSharing(_ sender: Any) {
        job.stopSharing()
    }
}
