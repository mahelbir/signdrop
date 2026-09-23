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
    
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        try? fileManager.removeItem(atPath: Log.logName)
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
        func updateCheckStatus(_ status: Bool, data: Data?, response: URLResponse?, error: Error?){
            if status == false {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    
                    
                    if error != nil {
                        alert.messageText = "There was a problem checking for a new version."
                        alert.informativeText = "More information is available in the application log."
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

