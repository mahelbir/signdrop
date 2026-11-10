import Foundation

struct LinkShortener {
    static let all: [LinkShortener] = [.spoo(), .tinyURL()]
    static let timeout: TimeInterval = 15

    let name: String
    let makeRequest: (String) -> URLRequest?
    let readShortLink: (Data) -> String?

    static func spoo(_ endpoint: String = "https://spoo.me/api/v1/shorten") -> LinkShortener {
        LinkShortener(
            name: "Spoo.me",
            makeRequest: { link in
                post(
                    endpoint, contentType: "application/json",
                    body: try? JSONEncoder().encode(["long_url": link]))
            }, readShortLink: { jsonValue(in: $0, at: ["short_url"]) })
    }

    static func tinyURL(_ endpoint: String = "https://tinyurl.com/api-create.php") -> LinkShortener
    {
        LinkShortener(
            name: "TinyURL",
            makeRequest: { link in
                URL(string: endpoint + "?url=" + InstallLink.encodeQueryValue(link)).map {
                    URLRequest(url: $0)
                }
            }, readShortLink: { String(decoding: $0, as: UTF8.self) })
    }

    func shorten(_ link: URL, session: URLSession) async throws -> URL? {
        guard var request = makeRequest(link.absoluteString) else { return nil }
        request.timeoutInterval = LinkShortener.timeout
        do {
            let (data, status) = try await session.response(for: request, service: name)
            guard (200..<300).contains(status),
                let text = readShortLink(data)?.trimmingCharacters(in: .whitespacesAndNewlines),
                let shortLink = URL(string: text), shortLink.scheme == "https"
            else {
                return nil
            }
            return shortLink
        } catch is ShareError {
            return nil
        }
    }

    private static func post(_ endpoint: String, contentType: String, body: Data?) -> URLRequest? {
        guard let url = URL(string: endpoint), let body else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func jsonValue(in data: Data, at path: [String]) -> String? {
        var value = try? JSONSerialization.jsonObject(with: data)
        for key in path {
            value = (value as? [String: Any])?[key]
        }
        return value as? String
    }
}
