//
//  SignDropShared.swift
//  SignDrop
//
//  Created by Daniel Radtke on 5/7/16.
//  Copyright © 2016 Daniel Radtke. All rights reserved.
//

import Foundation
class SignDropShared {
    static func fixSigning(_ tempFolder: String){
        let script = "do shell script \"/bin/bash \\\"\(Bundle.main.path(forResource: "fix-wwdr", ofType: "sh")!)\\\"\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        //https://developer.apple.com/certificationauthority/AppleWWDRCA.cer
        return
    }
}
