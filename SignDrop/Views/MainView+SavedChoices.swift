import Cocoa

struct SavedProfile: Codable {
    let name: String
    let appID: String
    let teamID: String
    var customFile: String?

    func newestIndex(in candidates: [(identity: SavedProfile, created: Date)]) -> Int? {
        candidates.indices
            .filter {
                let identity = candidates[$0].identity
                return identity.name == name && identity.appID == appID
                    && identity.teamID == teamID
            }
            .max { candidates[$0].created < candidates[$1].created }
    }
}

extension MainView {
    private enum SavedKey {
        static let profile = "provisioningProfile"
        static let isGetTaskAllowSkipped = "isGetTaskAllowSkipped"
        static let isPluginsFolderIgnored = "isPluginsFolderIgnored"
    }

    func restoreSavedChoices() {
        if let isSkipped = defaults.object(forKey: SavedKey.isGetTaskAllowSkipped) as? Bool {
            noGetTaskAllowCheckbox.state = isSkipped ? .on : .off
        }
        if let isIgnored = defaults.object(forKey: SavedKey.isPluginsFolderIgnored) as? Bool {
            ignorePluginsCheckbox.state = isIgnored ? .on : .off
        }
        restoreSavedProfile()
    }

    private func restoreSavedProfile() {
        guard let data = defaults.data(forKey: SavedKey.profile),
            let saved = try? JSONDecoder().decode(SavedProfile.self, from: data)
        else { return }
        if let customFile = saved.customFile {
            if fileManager.fileExists(atPath: customFile) {
                selectCustomProfile(customFile)
            }
            return
        }
        let candidates = provisioningProfiles.map {
            (
                identity: SavedProfile(name: $0.name, appID: $0.appID, teamID: $0.teamID),
                created: $0.created
            )
        }
        if let index = saved.newestIndex(in: candidates) {
            profilePopup.selectItem(at: index + MainView.firstProfileMenuIndex)
            chooseProvisioningProfile(profilePopup)
        }
    }

    @objc func saveOptionChoices(_ sender: NSButton) {
        defaults.set(noGetTaskAllowCheckbox.state == .on, forKey: SavedKey.isGetTaskAllowSkipped)
        defaults.set(ignorePluginsCheckbox.state == .on, forKey: SavedKey.isPluginsFolderIgnored)
    }

    @objc func chooseAndSaveProvisioningProfile(_ sender: NSPopUpButton) {
        chooseProvisioningProfile(sender)
        saveProfileChoice()
    }

    func saveProfileChoice() {
        let index = profilePopup.indexOfSelectedItem - MainView.firstProfileMenuIndex
        guard provisioningProfiles.indices.contains(index) else {
            defaults.removeObject(forKey: SavedKey.profile)
            return
        }
        let profile = provisioningProfiles[index]
        let isCustomFile = customProfiles.contains { $0.filename == profile.filename }
        let saved = SavedProfile(
            name: profile.name, appID: profile.appID, teamID: profile.teamID,
            customFile: isCustomFile ? profile.filename : nil)
        defaults.set(try? JSONEncoder().encode(saved), forKey: SavedKey.profile)
    }
}
