import Foundation

enum InstallLink {
    static let maskerURL = "https://axorax.github.io/urlmskr/"
    private static let queryValueCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")

    static func manifest(for app: AppInfo, package: URL) throws -> Data {
        let metadata = [
            "bundle-identifier": app.bundleID,
            "bundle-version": app.version.isEmpty ? app.build : app.version,
            "kind": "software",
            "title": app.displayName.isEmpty ? app.bundleID : app.displayName,
        ]
        let item: [String: Any] = ["assets": [["kind": "software-package", "url": package.absoluteString]], "metadata": metadata]
        return try PropertyListSerialization.data(fromPropertyList: ["items": [item]], format: .xml, options: 0)
    }

    static func webLink(manifest: URL) throws -> URL {
        let installLink = "itms-services://?action=download-manifest&url=" + encodeQueryValue(manifest.absoluteString)
        let code = Data(installLink.utf8).base64EncodedString()
        guard !code.contains("/"), let link = URL(string: maskerURL + code) else {
            throw UploadError.server("Could not build a web link for \(installLink)")
        }
        return link
    }

    static func shorten(_ link: URL, with shorteners: [LinkShortener] = LinkShortener.all, session: URLSession = UploadServices.session) async throws -> URL {
        for shortener in shorteners {
            if let shortLink = try await shortener.shorten(link, session: session) {
                return shortLink
            }
        }
        throw UploadError.server("Could not shorten the link (\(shorteners.map(\.name).joined(separator: ", "))).")
    }

    static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) ?? value
    }
}
