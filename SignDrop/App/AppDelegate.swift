//
//  AppDelegate.swift
//  SignDrop
//
//  Created by Daniel Radtke on 11/2/15.
//  Copyright © 2015 Daniel Radtke. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @objc let fileManager = FileManager.default
    var shareAccountMenu: ShareAccountMenu?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        shareAccountMenu = ShareAccountMenu(
            services: ShareServices.all, in: NSApp.mainMenu?.items.first?.submenu)
        if let mainMenu = NSApp.mainMenu,
            let mainView = NSApp.windows.compactMap({ $0.contentView as? MainView }).first
        {
            AppMenus.install(in: mainMenu, shareTarget: mainView)
            NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
            if let window = mainView.window {
                NSApp.addWindowsItem(window, title: window.title, filename: false)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        try? fileManager.removeItem(atPath: Log.logName)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = ShareWindows.shared
        guard windows.hasActiveWork else { return .terminateNow }
        guard ShareWindows.makeQuitAlert().runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        windows.stopAll()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        sender.windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    @IBAction func openCertificateAuthority(_ sender: NSMenuItem) {
        SignDropShared.openCertificateAuthority()
    }

    @IBAction func nsMenuLinkClick(_ sender: NSMenuLink) {
        NSWorkspace.shared.open(URL(string: sender.url!)!)
    }
    @IBAction func viewLog(_ sender: AnyObject) {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.logName))
    }
    @IBAction func checkForUpdates(_ sender: NSMenuItem) {
        func updateCheckStatus(_ status: Bool, data: Data?, response: URLResponse?, error: Error?) {
            if status == false {
                DispatchQueue.main.async {
                    let alert = NSAlert()

                    if error != nil {
                        alert.messageText = "There was a problem checking for a new version."
                        alert.informativeText =
                            "More information is available in the application log."
                        Log.write(error!.localizedDescription)
                    } else {
                        alert.messageText = "You are currently running the latest version."
                    }
                    alert.runModal()
                }
            }
        }
        UpdatesController.checkForUpdate(forceShow: true, callbackFunc: updateCheckStatus)
    }
}
