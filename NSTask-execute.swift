//
//  NSTask-execute.swift
//  SignDrop
//
//  Created by Daniel Radtke on 11/3/15.
//  Copyright © 2015 Daniel Radtke. All rights reserved.
//

import Foundation
struct SignDropTaskOutput {
    var output: String
    var status: Int32
    init(status: Int32, output: String){
        self.status = status
        self.output = output
    }
}
extension Process {
    func launchSynchronous() -> SignDropTaskOutput {
        self.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        self.standardOutput = pipe
        self.standardError = pipe
        let pipeFile = pipe.fileHandleForReading
        do {
            try self.run()
        } catch {
            try? pipeFile.close()
            return SignDropTaskOutput(status: -1, output: error.localizedDescription)
        }

        let data = NSMutableData()
        while self.isRunning {
            data.append(pipeFile.availableData)
        }
        
        try? pipeFile.close()
        self.terminate();
        
        if let output = String.init(data: data as Data, encoding: String.Encoding.utf8) {
            return SignDropTaskOutput(status: self.terminationStatus, output: output)
        } else {
            return SignDropTaskOutput(status: self.terminationStatus, output: "")
        }
        
    }
    
    func execute(_ launchPath: String, workingDirectory: String?, arguments: [String]?)->SignDropTaskOutput{
        self.executableURL = URL(fileURLWithPath: launchPath)
        if arguments != nil {
            self.arguments = arguments
        }
        if workingDirectory != nil {
            self.currentDirectoryURL = URL(fileURLWithPath: workingDirectory!)
        }
        return self.launchSynchronous()
    }
    
}
