//
//  SignDropShared.swift
//  SignDrop
//
//  Created by Daniel Radtke on 5/7/16.
//  Copyright © 2016 Daniel Radtke. All rights reserved.
//

import Cocoa
class SignDropShared {
    static let certificateAuthorityURL = URL(string: "https://www.apple.com/certificateauthority/")!

    static func openCertificateAuthority() {
        NSWorkspace.shared.open(certificateAuthorityURL)
    }

    static func showCertificateAlert(_ messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Open Apple Certificate Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openCertificateAuthority()
        }
    }
}
