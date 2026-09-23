import Cocoa

extension MainView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === inputFileField {
            refreshInputAppID()
        }
    }

    func refreshInputAppID() {
        let inputFile = inputFileField.stringValue
        inputAppID = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let appID = self.readAppID(inputFile)
            DispatchQueue.main.async {
                if self.inputFileField.stringValue == inputFile {
                    self.inputAppID = appID
                }
            }
        }
    }

    func readAppID(_ inputFile: String) -> String? {
        switch inputFile.pathExtension.lowercased() {
        case "ipa":
            guard fileManager.fileExists(atPath: inputFile), let tempFolder = makeTempFolder() else { return nil }
            defer { try? fileManager.removeItem(atPath: tempFolder) }
            _ = Process().execute(unzipPath, workingDirectory: nil, arguments: ["-q", inputFile, "Payload/*.app/Info.plist", "-d", tempFolder])
            return readAppID(inPayload: tempFolder.stringByAppendingPathComponent("Payload"))
        case "xcarchive":
            return readAppID(inPayload: inputFile.stringByAppendingPathComponent("Products/Applications"))
        case "app", "appex":
            return getPlistKey(inputFile.stringByAppendingPathComponent("Info.plist"), keyName: "CFBundleIdentifier")
        default:
            return nil
        }
    }

    func readAppID(inPayload payloadDirectory: String) -> String? {
        let appBundle = (try? fileManager.contentsOfDirectory(atPath: payloadDirectory))?.first { $0.pathExtension == "app" }
        return appBundle.flatMap { readAppID(payloadDirectory.stringByAppendingPathComponent($0)) }
    }

    func updateAppIDLabels() {
        inputAppIDLabel.stringValue = inputAppID ?? "—"
        guard let inputAppID = inputAppID, let profileAppID = selectedProfileAppID else {
            profileMatchLabel.stringValue = ""
            return
        }
        let isWildcard = profileAppID.hasSuffix("*")
        let isCovered = isWildcard ? inputAppID.hasPrefix(String(profileAppID.dropLast())) : inputAppID == profileAppID
        profileMatchLabel.textColor = isCovered ? .systemGreen : .systemOrange
        if isCovered {
            profileMatchLabel.stringValue = "✓ Matches the selected provisioning profile"
        } else if isWildcard {
            profileMatchLabel.stringValue = "⚠︎ Not covered by \(profileAppID), set a New Application ID"
        } else {
            profileMatchLabel.stringValue = "⚠︎ Will be changed to \(profileAppID) when signing"
        }
    }
}
