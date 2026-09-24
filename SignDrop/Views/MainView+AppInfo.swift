import Cocoa

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
        setStatus("Ready")
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
            return AppInfo(ipa: inputFile)
        case "xcarchive":
            return AppInfo(payload: inputFile.stringByAppendingPathComponent("Products/Applications"))
        case "app", "appex":
            return AppInfo(infoPlist: inputFile.stringByAppendingPathComponent("Info.plist"))
        default:
            return nil
        }
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
