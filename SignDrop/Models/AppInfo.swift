import Foundation

struct AppInfo: Equatable {
    let bundleID: String
    let displayName: String
    let version: String
    let build: String

    init?(infoPlist path: String) {
        guard let info = try? NSDictionary(contentsOf: URL(fileURLWithPath: path), error: ()), let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        self.bundleID = bundleID
        displayName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ""
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
    }

    init?(payload directory: String) {
        guard let appBundle = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.first(where: { $0.pathExtension == "app" }) else { return nil }
        self.init(infoPlist: directory.stringByAppendingPathComponent(appBundle).stringByAppendingPathComponent("Info.plist"))
    }

    init?(ipa path: String) {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("signdrop-appinfo-" + UUID().uuidString).path
        guard FileManager.default.fileExists(atPath: path), (try? FileManager.default.createDirectory(atPath: tempFolder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tempFolder) }
        _ = Process().execute("/usr/bin/unzip", workingDirectory: nil, arguments: ["-q", path, "Payload/*.app/Info.plist", "-d", tempFolder])
        self.init(payload: tempFolder.stringByAppendingPathComponent("Payload"))
    }
}
