import Foundation
@testable import SignDrop

func httpRequest(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async -> (status: Int, data: Data, length: String?) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 5
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return (0, Data(), nil) }
    return (http.statusCode, data, http.value(forHTTPHeaderField: "Content-Length"))
}

func responseHead(_ url: URL, isHead: Bool = false) -> (status: String, location: String?) {
    let arguments = isHead ? ["-sI", url.absoluteString] : ["-s", "-D", "-", "-o", "/dev/null", url.absoluteString]
    let lines = Process().execute("/usr/bin/curl", workingDirectory: nil, arguments: arguments).output.components(separatedBy: "\r\n")
    let location = lines.first { $0.lowercased().hasPrefix("location: ") }.map { String($0.dropFirst("location: ".count)) }
    return (lines.first ?? "", location)
}

func startCurl(_ arguments: [String]) -> Process {
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = arguments
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle.nullDevice
    try? curl.run()
    return curl
}

func fileSize(_ url: URL) -> UInt64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
}

func isAlive(_ pattern: String) -> Bool {
    Process().execute("/usr/bin/pgrep", workingDirectory: nil, arguments: ["-f", pattern]).status == 0
}

func newMarker() -> String {
    "mk-\(UUID().uuidString)"
}

func manifestURL(fromItmsLink link: String?) -> URL? {
    guard let encoded = link?.components(separatedBy: "url=").last, let decoded = encoded.removingPercentEncoding else { return nil }
    return URL(string: decoded)
}

func manifestURL(fromWebLink webLink: URL?) -> URL? {
    guard let code = webLink?.absoluteString.components(separatedBy: InstallLink.maskerURL).last, let data = Data(base64Encoded: code) else { return nil }
    return manifestURL(fromItmsLink: String(data: data, encoding: .utf8))
}

var isAccountFileIsolated: Bool {
    let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
    return configHome.hasPrefix("/") && configHome.hasSuffix("/SignDropTestsConfig") && !configHome.contains("$(") && BetaDropConfig.fileURL().path.hasPrefix(configHome)
}
