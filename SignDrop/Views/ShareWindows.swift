import Cocoa

@MainActor
final class ShareWindows {
    static let shared = ShareWindows()

    private(set) var controllers: [ShareWindowController] = []
    private(set) var current: ShareWindowController?
    private let services: @MainActor () -> [ShareService]
    private var cascadePoint = NSPoint.zero

    init(services: @escaping @MainActor () -> [ShareService] = { ShareServices.all }) {
        self.services = services
    }

    var hasActiveWork: Bool {
        controllers.contains { $0.hasActiveWork }
    }

    var hasOpenWindows: Bool {
        controllers.contains { $0.isOpen }
    }

    func isSharing(file: URL) -> Bool {
        controllers.contains {
            $0.hasActiveWork && $0.file.standardizedFileURL == file.standardizedFileURL
        }
    }

    @discardableResult
    func show(file: URL) -> ShareWindowController {
        if let current, current.file == file {
            current.showWindow(nil)
            return current
        }
        let controller = ShareWindowController(file: file, services: services())
        controller.onClose = { [weak self] in self?.windowDidClose($0) }
        controllers.append(controller)
        current = controller
        controller.window?.center()
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        return controller
    }

    func beginNewSigning() {
        current = nil
        controllers.removeAll { !$0.isOpen && !$0.hasActiveWork }
    }

    func stopAll() {
        controllers.forEach { $0.halt() }
    }

    static func makeQuitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Stop sharing and quit?"
        alert.informativeText = ShareWindowController.stopWarning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func windowDidClose(_ controller: ShareWindowController) {
        if controller !== current {
            controllers.removeAll { $0 === controller }
        }
    }
}
