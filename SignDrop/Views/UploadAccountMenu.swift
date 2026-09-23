import Cocoa

@MainActor
final class UploadAccountMenu: NSObject, NSMenuDelegate {
    private let separator = NSMenuItem.separator()
    private var accountItems: [NSMenuItem] = []

    init(services: [UploadService], in menu: NSMenu?) {
        super.init()
        guard let menu else { return }
        accountItems = services.filter(\.isSignInRequired).map { service in
            let item = NSMenuItem(title: "", action: #selector(signOut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service
            return item
        }
        let insertionIndex = min(2, menu.numberOfItems)
        (accountItems + [separator]).reversed().forEach { menu.insertItem($0, at: insertionIndex) }
        menu.delegate = self
        menuNeedsUpdate(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in accountItems {
            guard let service = item.representedObject as? UploadService else { continue }
            let account = service.accountName
            item.title = "Sign Out of \(service.name)" + (account.map { " (\($0))" } ?? "")
            item.isHidden = account == nil
        }
        separator.isHidden = accountItems.allSatisfy { $0.isHidden }
    }

    @objc private func signOut(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? UploadService else { return }
        Task {
            await service.signOut()
        }
    }
}
