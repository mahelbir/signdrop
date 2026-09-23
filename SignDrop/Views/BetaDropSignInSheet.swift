import Cocoa

@MainActor
final class BetaDropSignInSheet: NSObject {
    static let createTokenURL = URL(string: "https://betadrop.app/settings/?tab=developer")!

    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let codeLabel = NSTextField(labelWithString: "")
    let linkButton = NSButton(title: "", target: nil, action: nil)
    let waitingLabel = NSTextField(labelWithString: "Waiting for approval…")
    let spinner = NSProgressIndicator()
    let tokenField = NSSecureTextField()
    let createTokenButton = NSButton(title: "Create a token", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let tokenButton = NSButton(title: "Use API Token…", target: nil, action: nil)
    let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    let signInButton = NSButton(title: "Sign In", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var isTokenMode = false
    private let service: BetaDropService
    private var verificationURL: URL?
    private var signInTask: Task<Void, Never>?
    private weak var parentWindow: NSWindow?

    init(service: BetaDropService) {
        self.service = service
        super.init()
        setUpLayout()
    }

    func present(in window: NSWindow) async -> Bool {
        parentWindow = window
        startBrowserSignIn()
        let response = await withCheckedContinuation { continuation in
            window.beginSheet(panel) { continuation.resume(returning: $0) }
        }
        signInTask?.cancel()
        return response == .OK
    }

    func showCode(_ code: BetaDropDeviceCode) {
        codeLabel.stringValue = code.userCode
        linkButton.title = code.verificationURI
        verificationURL = URL(string: code.verificationURIComplete) ?? URL(string: code.verificationURI)
        linkButton.isHidden = verificationURL == nil
        openVerificationPage()
    }

    func showError(_ error: Error) {
        spinner.stopAnimation(nil)
        waitingLabel.isHidden = true
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
        retryButton.isHidden = isTokenMode
        signInButton.isEnabled = true
        tokenField.isEnabled = true
    }

    @objc func showTokenMode() {
        signInTask?.cancel()
        isTokenMode = true
        messageLabel.stringValue = "Paste an API token from BetaDrop Settings → Developer → API tokens."
        [codeLabel, linkButton, waitingLabel, spinner, tokenButton, retryButton, errorLabel].forEach { $0.isHidden = true }
        [tokenField, createTokenButton, signInButton].forEach { $0.isHidden = false }
        signInButton.keyEquivalent = "\r"
        panel.makeFirstResponder(tokenField)
    }

    private func setUpLayout() {
        let titleLabel = NSTextField(labelWithString: "Sign In to BetaDrop")
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        codeLabel.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        codeLabel.isSelectable = true
        [linkButton, createTokenButton].forEach {
            $0.isBordered = false
            $0.contentTintColor = .linkColor
            $0.target = self
        }
        linkButton.action = #selector(openVerificationPage)
        createTokenButton.action = #selector(openCreateTokenPage)
        spinner.style = .spinning
        spinner.controlSize = .small
        errorLabel.textColor = .systemRed
        tokenField.placeholderString = "bd_live_…"
        tokenButton.target = self
        tokenButton.action = #selector(showTokenMode)
        retryButton.target = self
        retryButton.action = #selector(startBrowserSignIn)
        signInButton.target = self
        signInButton.action = #selector(signInWithToken)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let waitingRow = NSStackView(views: [spinner, waitingLabel])
        let buttonRow = NSStackView(views: [tokenButton, NSView(), retryButton, cancelButton, signInButton])
        buttonRow.distribution = .fill
        let stack = NSStackView(views: [titleLabel, messageLabel, codeLabel, linkButton, waitingRow, tokenField, createTokenButton, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                stack.widthAnchor.constraint(equalToConstant: 420),
                messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                tokenField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
            ])
        }
    }

    @objc func startBrowserSignIn() {
        signInTask?.cancel()
        isTokenMode = false
        messageLabel.stringValue = "Approve SignDrop in your browser, then come back here."
        codeLabel.stringValue = "…"
        [tokenField, createTokenButton, signInButton, retryButton, errorLabel, linkButton].forEach { $0.isHidden = true }
        [codeLabel, waitingLabel, spinner, tokenButton].forEach { $0.isHidden = false }
        spinner.startAnimation(nil)
        signInTask = Task {
            do {
                try await service.signInWithBrowser { code in
                    showCode(code)
                }
                finish(.OK)
            } catch is CancellationError {
            } catch {
                showError(error)
            }
        }
    }

    @objc private func signInWithToken() {
        signInTask?.cancel()
        errorLabel.isHidden = true
        signInButton.isEnabled = false
        tokenField.isEnabled = false
        let token = tokenField.stringValue
        signInTask = Task {
            do {
                try await service.signIn(token: token)
                finish(.OK)
            } catch is CancellationError {
            } catch {
                showError(error)
            }
        }
    }

    @objc private func openVerificationPage() {
        if let verificationURL {
            NSWorkspace.shared.open(verificationURL)
        }
    }

    @objc private func openCreateTokenPage() {
        NSWorkspace.shared.open(BetaDropSignInSheet.createTokenURL)
    }

    @objc private func cancel() {
        finish(.cancel)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        signInTask?.cancel()
        parentWindow?.endSheet(panel, returnCode: response)
    }
}
