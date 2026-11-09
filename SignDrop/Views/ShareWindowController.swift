import Cocoa

@MainActor
final class ShareWindowController: NSWindowController, NSWindowDelegate {
    static let stopWarning =
        "Shares in progress will be canceled, and links served from this Mac will stop working."
    private static let minimumWidth: CGFloat = 640

    let file: URL
    let rows: [ShareRow]
    var onClose: ((ShareWindowController) -> Void)?
    private var isFittingWindow = false

    init(file: URL, services: [ShareService]) {
        self.file = file
        rows = services.map { ShareRow(job: ShareJob(service: $0, file: file)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ShareWindowController.minimumWidth, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Share \(file.lastPathComponent)"
        window.representedURL = file
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setUpContent(in: window)
        rows.forEach { row in
            row.onLayoutChange = { [weak self] in self?.fitWindowToContent() }
        }
        fitWindowToContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    var hasActiveWork: Bool {
        rows.contains { $0.job.isActive }
    }

    var isOpen: Bool {
        window?.isVisible == true || window?.isMiniaturized == true
    }

    private func setUpContent(in window: NSWindow) {
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.yPlacement = .center
        rows.forEach { grid.addRow(with: [$0.nameLabel, $0.detailView, $0.actionsView]) }
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
    }

    private func fitWindowToContent() {
        guard !isFittingWindow, let window, let content = window.contentView else { return }
        isFittingWindow = true
        defer { isFittingWindow = false }
        content.layoutSubtreeIfNeeded()
        rows.forEach { $0.noteLabel.preferredMaxLayoutWidth = $0.detailView.frame.width }
        let height = content.fittingSize.height
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.contentMinSize = NSSize(
            width: ShareWindowController.minimumWidth, height: height)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
        window.setContentSize(
            NSSize(
                width: max(content.frame.width, ShareWindowController.minimumWidth), height: height)
        )
        window.setFrameTopLeftPoint(topLeft)
    }

    static func makeCloseAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Stop sharing and close?"
        alert.informativeText = stopWarning
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func halt() {
        rows.forEach { $0.job.halt() }
    }

    func haltAndClose() {
        halt()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasActiveWork else { return true }
        ShareWindowController.makeCloseAlert().beginSheetModal(for: sender) {
            [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.haltAndClose()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        fitWindowToContent()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        rows.forEach { $0.render() }
    }
}
