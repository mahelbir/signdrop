//
//  UpdatesController.swift
//  SignDrop
//
//  Created by Daniel Radtke on 2/5/16.
//  Copyright © 2016 Daniel Radtke. All rights reserved.
//

import Foundation
import AppKit
class UpdatesController: NSWindowController {
    //MARK: Variables
    @objc let markdownParser = NSAttributedStringMarkdownParser()
    @objc var latestVersion: String?
    @objc let prefs = UserDefaults.standard
    @objc static var updatesWindow: UpdatesController?
    static let releasesURL = URL(string: "https://api.github.com/repos/mahelbir/signdrop/releases")!

    //MARK: IBOutlets
    @IBOutlet weak var appIcon: NSImageView!
    @IBOutlet var updateWindow: NSWindow!
    @IBOutlet var changelogText: NSTextView!
    @IBOutlet weak var versionLabel: NSTextField!
    
    //MARK: Functions
    static func version(of release: [String: AnyObject]) -> String? {
        return (release["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func isVersion(_ version: String, newerThan currentVersion: String) -> Bool {
        let components = [version, currentVersion].map { $0.split(separator: ".").map { Int($0) ?? 0 } }
        let length = components.map { $0.count }.max() ?? 0
        let padded = components.map { $0 + Array(repeating: 0, count: length - $0.count) }
        return padded[1].lexicographicallyPrecedes(padded[0])
    }

    @objc static func checkForUpdate(
        _ currentVersion: String = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String,
        forceShow: Bool = false,
        releasesURL: URL = UpdatesController.releasesURL,
        callbackFunc: ((_ status: Bool, _ data: Data?, _ response: URLResponse?, _ error: Error?)->Void)? = nil
    ) {
        let urlRequest = URLRequest(url: releasesURL)

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)

        let task = session.dataTask(with: urlRequest, completionHandler: {
            (data, response, error) -> Void in

            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .allowFragments) }
            let releases = (json as? [[String: AnyObject]] ?? []).filter { $0["prerelease"] as? Bool != true }
            guard error == nil,
                (response as? HTTPURLResponse)?.statusCode == 200,
                let latestVersion = releases.first.flatMap(version(of:)),
                isVersion(latestVersion, newerThan: currentVersion),
                forceShow || UserDefaults.standard.string(forKey: "skipVersion") != latestVersion else {
                    callbackFunc?(false, data, response, error)
                    return
            }
            DispatchQueue.main.async {
                if updatesWindow == nil {
                    updatesWindow = UpdatesController(windowNibName: "Updates")
                }
                updatesWindow!.showWindow([currentVersion, releases])
            }
            callbackFunc?(true, data, response, error)
        })

        task.resume()
    }
    
    override init(window: NSWindow?) {
        super.init(window: window)
        
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        appIcon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        var releaseOutput: [String] = []
        if let senderArray = sender as? [AnyObject] {
            if let releases = senderArray[1] as? [[String: AnyObject]],
                let currentVersion = senderArray[0] as? String {
                for release in releases {
                    if let name = UpdatesController.version(of: release),
                        let body = release["body"] as? String {
                        if latestVersion == nil {
                            latestVersion = name
                        }
                        if !UpdatesController.isVersion(name, newerThan: currentVersion) {
                            break
                        }
                        releaseOutput.append("**Version \(name)**\n\(body)")
                    }
                }
                versionLabel.stringValue = "Version \(latestVersion!) is now available, you have \(currentVersion)."
            }
            setChangelog(releaseOutput.joined(separator: "\n\n"))
        }
        
    }
    @objc func setChangelog(_ text: String){
        changelogText.isEditable = true
        changelogText.string = ""
        changelogText.insertText(markdownParser.attributedString(fromMarkdownString: text))
        changelogText.isEditable = false
    }
    
    //MARK: IBActions
    @IBAction func skipVersion(_ sender: NSButton) {
        prefs.setValue(latestVersion, forKey: "skipVersion")
        updateWindow.close()
    }
    @IBAction func remindMeLater(_ sender: NSButton) {
        prefs.setValue(nil, forKey: "skipVersion")
        updateWindow.close()
    }
    @IBAction func visitProjectPage(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "https://github.com/mahelbir/signdrop/releases")!)
        updateWindow.close()
    }
}
