import Cocoa

@MainActor
enum AppMenus {
    static func install(in mainMenu: NSMenu, shareTarget: AnyObject) {
        mainMenu.insertItem(makeFileItem(shareTarget: shareTarget), at: 1)
        let helpIndex = mainMenu.items.firstIndex { $0.title == "Help" } ?? mainMenu.numberOfItems
        mainMenu.insertItem(makeWindowItem(), at: helpIndex)
    }

    private static func makeFileItem(shareTarget: AnyObject) -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(
            withTitle: "Share…", action: #selector(MainView.shareSignedFile(_:)), keyEquivalent: "E"
        ).target = shareTarget
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func makeWindowItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
