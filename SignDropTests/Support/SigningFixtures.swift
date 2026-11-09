import Foundation
import Testing
@testable import SignDrop

enum SigningFixtures {
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SignDropTests-Fixtures")

    static let certificate: String? = {
        let output = Process().execute(
            "/usr/bin/security", workingDirectory: nil,
            arguments: ["find-identity", "-v", "-p", "appleID"]
        ).output
        let names = output.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }
            .map(\.element)
        return names.first { $0.hasPrefix("Apple Distribution") }
            ?? names.first { $0.hasPrefix("Apple Development") }
    }()

    static let sampleApp: (ipa: String, appex: String)? = buildSampleApp()
    static let fixedProfile: String? = buildProfile(expiring: "2030-01-01T00:00:00Z")
    static let expiredProfile: String? = buildProfile(expiring: "2020-01-01T00:00:00Z")

    private static func didRun(_ tool: String, _ arguments: [String], in directory: URL? = nil)
        -> Bool
    {
        Process().execute(tool, workingDirectory: directory?.path, arguments: arguments).status == 0
    }

    private static func didWritePlist(
        _ plist: [String: Any], to url: URL, format: PropertyListSerialization.PropertyListFormat
    ) -> Bool {
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: format, options: 0)
        else { return false }
        return FileManager.default.createFile(atPath: url.path, contents: data)
    }

    private static func buildSampleApp() -> (ipa: String, appex: String)? {
        let directory = root.appendingPathComponent("app")
        try? FileManager.default.removeItem(at: directory)
        let build = directory.appendingPathComponent("build")
        let app = build.appendingPathComponent("Payload/Sample.app")
        let appex = app.appendingPathComponent("PlugIns/Ext.appex")
        let egg = directory.appendingPathComponent("egg")
        let manager = FileManager.default
        for folder in [
            app.appendingPathComponent("Frameworks"), appex, app.appendingPathComponent("Eggs"),
            egg,
        ] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let main = directory.appendingPathComponent("main.c")
        let library = directory.appendingPathComponent("lib.c")
        try? "int main(void){return 0;}\n".write(to: main, atomically: true, encoding: .utf8)
        try? "int one(void){return 1;}\n".write(to: library, atomically: true, encoding: .utf8)
        let sdk = Process().execute(
            "/usr/bin/xcrun", workingDirectory: nil,
            arguments: ["--sdk", "iphoneos", "--show-sdk-path"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let clang = ["clang", "-target", "arm64-apple-ios15.0", "-isysroot", sdk]
        let appInfo: [String: Any] = [
            "CFBundleIdentifier": "com.acme.sample",
            "CFBundleExecutable": "Sample",
            "CFBundleName": "Sample",
            "CFBundleDisplayName": "Sample Display",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos",
            "MinimumOSVersion": "15.0",
            "LSRequiresIPhoneOS": true,
            "UIDeviceFamily": [1],
        ]
        let extensionInfo: [String: Any] = [
            "CFBundleIdentifier": "com.acme.sample.ext",
            "CFBundleExecutable": "Ext",
            "CFBundleName": "Ext",
            "CFBundlePackageType": "XPC!",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos",
            "MinimumOSVersion": "15.0",
            "NSExtension": [
                "NSExtensionAttributes": ["WKAppBundleIdentifier": "com.acme.sample.watchkitapp"],
                "NSExtensionPointIdentifier": "com.apple.watchkit",
            ],
        ]
        let standalone = directory.appendingPathComponent("Standalone.appex")
        let ipa = directory.appendingPathComponent("Sample.ipa")
        let isBuilt =
            didRun(
                "/usr/bin/xcrun",
                clang + ["-o", app.appendingPathComponent("Sample").path, main.path])
            && didRun(
                "/usr/bin/xcrun",
                clang + ["-o", appex.appendingPathComponent("Ext").path, main.path])
            && didRun(
                "/usr/bin/xcrun",
                clang + [
                    "-dynamiclib", "-o", app.appendingPathComponent("Frameworks/libone.dylib").path,
                    library.path,
                ])
            && didRun(
                "/usr/bin/xcrun",
                clang + [
                    "-dynamiclib", "-o", egg.appendingPathComponent("libegg.dylib").path,
                    library.path,
                ])
            && didRun(
                "/usr/bin/codesign", ["-s", "-", egg.appendingPathComponent("libegg.dylib").path])
            && didRun(
                "/usr/bin/zip", ["-qr", app.appendingPathComponent("Eggs/bundle.egg").path, "."],
                in: egg)
            && didWritePlist(appInfo, to: app.appendingPathComponent("Info.plist"), format: .binary)
            && didWritePlist(
                extensionInfo, to: appex.appendingPathComponent("Info.plist"), format: .binary)
            && didRun(
                "/usr/bin/codesign",
                ["-s", "-", app.appendingPathComponent("Frameworks/libone.dylib").path])
            && didRun("/usr/bin/codesign", ["-s", "-", appex.path])
            && didRun("/usr/bin/codesign", ["-s", "-", app.path])
            && didRun("/usr/bin/zip", ["-qr", ipa.path, "Payload"], in: build)
            && (try? manager.copyItem(at: appex, to: standalone)) != nil
        return isBuilt ? (ipa.path, standalone.path) : nil
    }

    private static func buildProfile(expiring expiration: String) -> String? {
        let directory = root.appendingPathComponent("profile-\(expiration)")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("cert.pem")
        let plist = directory.appendingPathComponent("fixed.plist")
        let profile = directory.appendingPathComponent("fixed.mobileprovision")
        let formatter = ISO8601DateFormatter()
        let contents: [String: Any] = [
            "AppIDName": "Acme Fixed",
            "CreationDate": formatter.date(from: "2026-01-01T00:00:00Z") as Any,
            "ExpirationDate": formatter.date(from: expiration) as Any,
            "Name": "SignDrop Test Fixed",
            "TeamIdentifier": ["ABCDE12345"],
            "Entitlements": [
                "application-identifier": "ABCDE12345.com.acme.fixed",
                "com.apple.developer.team-identifier": "ABCDE12345", "get-task-allow": false,
            ] as [String: Any],
        ]
        let isBuilt =
            didWritePlist(contents, to: plist, format: .xml)
            && didRun(
                "/usr/bin/openssl",
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out",
                    certificate.path, "-subj", "/CN=SignDrop Test", "-days", "2",
                ])
            && didRun(
                "/usr/bin/openssl",
                [
                    "cms", "-sign", "-binary", "-nodetach", "-outform", "DER", "-in", plist.path,
                    "-signer", certificate.path, "-inkey", key.path, "-out", profile.path,
                ])
        return isBuilt ? profile.path : nil
    }
}

extension Trait where Self == ConditionTrait {
    static var requiresSigningCertificate: Self {
        .enabled(if: SigningFixtures.certificate != nil, "Needs a signing certificate in Keychain")
    }

    static var requiresIsolatedAccountFile: Self {
        .enabled(if: isAccountFileIsolated, "Would touch the real BetaDrop account file")
    }
}
