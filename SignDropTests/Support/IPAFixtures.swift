import Foundation

let sampleAppInfo: [String: Any] = [
    "CFBundleIdentifier": "com.acme.sample",
    "CFBundleDisplayName": "Sample App",
    "CFBundleName": "Sample",
    "CFBundleShortVersionString": "2.1",
    "CFBundleVersion": "42",
]

func randomData(_ count: Int) -> Data {
    let block = Data((0..<1_048_576).map { _ in UInt8.random(in: .min ... .max) })
    var data = Data()
    while data.count < count {
        data.append(block.prefix(count - data.count))
    }
    return data
}

func manifestItem(_ data: Data?) -> (assets: [[String: String]]?, metadata: [String: String]?) {
    let plist =
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        as? [String: Any]
    let item = (plist?["items"] as? [[String: Any]])?.first
    return (item?["assets"] as? [[String: String]], item?["metadata"] as? [String: String])
}

extension WorkDirectory {
    func payload(_ info: [String: Any]?) -> URL {
        let payload = child("app-\(UUID().uuidString)/Payload")
        let app = payload.appendingPathComponent("Sample.app")
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        if let info,
            let data = try? PropertyListSerialization.data(
                fromPropertyList: info, format: .binary, options: 0)
        {
            FileManager.default.createFile(
                atPath: app.appendingPathComponent("Info.plist").path, contents: data)
        }
        FileManager.default.createFile(
            atPath: app.appendingPathComponent("Sample").path,
            contents: Data(repeating: 7, count: 5000))
        return payload
    }

    func ipa(_ name: String, _ info: [String: Any]?) -> URL {
        let payload = payload(info)
        let ipa = child(name)
        try? FileManager.default.removeItem(at: ipa)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = payload.deletingLastPathComponent()
        zip.arguments = ["-qry", ipa.path, "Payload"]
        try? zip.run()
        zip.waitUntilExit()
        return ipa
    }
}
