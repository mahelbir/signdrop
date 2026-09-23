import Cocoa

extension MainView {

    enum FormRow {
        case section(String)
        case field(String, NSView)
        case pair(String, NSView, String, NSView)
        case content(NSView)
    }

    func setUpLayout() {
        configureControls()
        let form = makeForm([
            .field("Input File:", NSStackView(views: [inputFileField, inputFileButton])),
            .section("Signing"),
            .field("Certificate:", certificatePopup),
            .field("Profile:", profilePopup),
            .field("Entitlements:", NSStackView(views: [entitlementsField, entitlementsButton])),
            .section("App Info"),
            .pair("App ID:", appIDField, "Name:", displayNameField),
            .pair("Version:", versionField, "Build:", buildField),
            .section("Options"),
            .content(makeOptionsStack()),
            .content(uploadCheckbox)
        ])
        let statusBar = NSStackView(views: [statusLabel, progressLabel, busyIndicator, progressBar])
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        statusBar.distribution = .fill
        statusBar.setHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        [form, signButton, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            form.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            appIDField.widthAnchor.constraint(equalTo: displayNameField.widthAnchor),
            signButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20),
            signButton.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: signButton.bottomAnchor, constant: 20),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 25),
            progressBar.widthAnchor.constraint(equalToConstant: 160),
            busyIndicator.widthAnchor.constraint(equalTo: progressBar.widthAnchor),
            progressLabel.widthAnchor.constraint(equalToConstant: 34)
        ])
        fitWindowToContent()
    }

    func configureControls() {
        inputFileField.placeholderString = "Path or URL of an .ipa, .app, .appex, .xcarchive or .deb"
        inputFileField.delegate = self
        inputFileButton.target = self
        inputFileButton.action = #selector(chooseInputFile(_:))
        entitlementsButton.target = self
        entitlementsButton.action = #selector(chooseEntitlementsFile(_:))
        [inputFileButton, entitlementsButton].forEach { $0.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        appIDField.delegate = self
        certificatePopup.target = self
        certificatePopup.action = #selector(chooseSigningCertificate(_:))
        profilePopup.target = self
        profilePopup.action = #selector(chooseProvisioningProfile(_:))
        entitlementsField.placeholderString = "Optional, overrides the profile's entitlements"
        [appIDField, displayNameField, versionField, buildField].forEach { $0.placeholderString = "Unchanged" }
        noGetTaskAllowCheckbox.state = .on
        noGetTaskAllowCheckbox.toolTip = "Don't add the get-task-allow entitlement, as it might break some apps"
        ignorePluginsCheckbox.toolTip = "Don't re-sign extension bundles, as they might have their own code signature"
        configureUploadCheckbox()
        signButton.keyEquivalent = "\r"
        signButton.target = self
        signButton.action = #selector(doSign(_:))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(statusLabelClick(_:))))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.maxValue = 100
        progressBar.isHidden = true
        busyIndicator.style = .bar
        busyIndicator.isIndeterminate = true
        busyIndicator.isHidden = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        progressLabel.alignment = .right
        [statusLabel, certificatePopup, profilePopup].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    func makeForm(_ rows: [FormRow]) -> NSGridView {
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.xPlacement = .fill
        for row in rows {
            switch row {
            case .section(let title):
                let gridRow = grid.addRow(with: [makeSectionHeader(title), empty, empty, empty])
                gridRow.mergeCells(in: NSRange(location: 0, length: 4))
                gridRow.topPadding = 12
            case .field(let title, let control):
                grid.addRow(with: [makeFormLabel(title, for: control), makeStretchable(control), empty, empty]).mergeCells(in: NSRange(location: 1, length: 3))
            case .pair(let title, let control, let secondTitle, let secondControl):
                grid.addRow(with: [makeFormLabel(title, for: control), makeStretchable(control), makeFormLabel(secondTitle, for: secondControl), makeStretchable(secondControl)])
            case .content(let view):
                let gridRow = grid.addRow(with: [empty, view, empty, empty])
                gridRow.mergeCells(in: NSRange(location: 1, length: 3))
                gridRow.cell(at: 1).xPlacement = .leading
            }
        }
        return grid
    }

    func makeStretchable(_ view: NSView) -> NSView {
        if let stack = view as? NSStackView {
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return view
    }

    func makeFormLabel(_ title: String, for control: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1), for: .horizontal)
        (control as? NSControl)?.setAccessibilityTitleUIElement(label)
        return label
    }

    func makeSectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .headline)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let separator = NSBox()
        separator.boxType = .separator
        let header = NSStackView(views: [label, separator])
        header.distribution = .fill
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        return header
    }

    func makeOptionsStack() -> NSStackView {
        let stack = NSStackView(views: [noGetTaskAllowCheckbox, ignorePluginsCheckbox])
        stack.spacing = 20
        return stack
    }

    func fitWindowToContent() {
        guard let window = window else { return }
        let width = frame.width
        layoutSubtreeIfNeeded()
        let size = fittingSize
        window.setContentSize(NSSize(width: max(width, size.width), height: size.height))
        window.contentMinSize = size
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: size.height)
        window.center()
    }
}
