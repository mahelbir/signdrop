import Cocoa

struct AppInfo: Equatable {
    let bundleID: String
    let displayName: String
    let version: String
    let build: String

    init?(infoPlist path: String) {
        guard let info = NSDictionary(contentsOfFile: path), let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        self.bundleID = bundleID
        displayName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ""
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
    }
}

extension MainView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === inputFileField {
            refreshInputAppID()
        } else if obj.object as? NSTextField === appIDField {
            updateProfileWarning()
        }
    }

    func refreshInputAppID() {
        let inputFile = inputFileField.stringValue
        inputAppInfo = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let appInfo = self.readAppInfo(inputFile)
            DispatchQueue.main.async {
                if self.inputFileField.stringValue == inputFile {
                    self.inputAppInfo = appInfo
                }
            }
        }
    }

    func readAppInfo(_ inputFile: String) -> AppInfo? {
        switch inputFile.pathExtension.lowercased() {
        case "ipa":
            guard fileManager.fileExists(atPath: inputFile), let tempFolder = makeTempFolder() else { return nil }
            defer { try? fileManager.removeItem(atPath: tempFolder) }
            _ = Process().execute(unzipPath, workingDirectory: nil, arguments: ["-q", inputFile, "Payload/*.app/Info.plist", "-d", tempFolder])
            return readAppInfo(inPayload: tempFolder.stringByAppendingPathComponent("Payload"))
        case "xcarchive":
            return readAppInfo(inPayload: inputFile.stringByAppendingPathComponent("Products/Applications"))
        case "app", "appex":
            return AppInfo(infoPlist: inputFile.stringByAppendingPathComponent("Info.plist"))
        default:
            return nil
        }
    }

    func readAppInfo(inPayload payloadDirectory: String) -> AppInfo? {
        let appBundle = (try? fileManager.contentsOfDirectory(atPath: payloadDirectory))?.first { $0.pathExtension == "app" }
        return appBundle.flatMap { readAppInfo(payloadDirectory.stringByAppendingPathComponent($0)) }
    }

    func fillAppChanges() {
        displayNameField.stringValue = inputAppInfo?.displayName ?? ""
        versionField.stringValue = inputAppInfo?.version ?? ""
        buildField.stringValue = inputAppInfo?.build ?? ""
        if appIDField.isEnabled {
            appIDField.stringValue = inputAppInfo?.bundleID ?? ""
        }
    }

    func releaseAppIDField() {
        if !appIDField.isEnabled {
            appIDField.isEnabled = true
            appIDField.stringValue = inputAppInfo?.bundleID ?? ""
        }
        updateProfileWarning()
    }

    func changedValue(_ field: NSTextField, original: String?) -> String {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == original ? "" : value
    }

    func updateProfileWarning() {
        if let warning = profileWarning() {
            setStatus(warning, isWarning: true)
        } else if isStatusWarning {
            setStatus("Ready")
        }
    }

    func profileWarning() -> String? {
        guard let originalAppID = inputAppInfo?.bundleID, let profileAppID = selectedProfileAppID else { return nil }
        guard profileAppID.hasSuffix("*") else {
            return originalAppID == profileAppID ? nil : "⚠︎ App ID \(originalAppID) doesn't match the profile, it will be changed to \(profileAppID)"
        }
        let editedAppID = appIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = editedAppID.isEmpty ? originalAppID : editedAppID
        return appID.hasPrefix(String(profileAppID.dropLast())) ? nil : "⚠︎ App ID \(appID) isn't covered by the profile \(profileAppID)"
    }
}
