import Foundation

struct BetaDropConfig: Codable, Equatable {
    struct User: Codable, Equatable {
        let id: String
        let email: String
        let role: String?

        init(id: String, email: String, role: String?) {
            self.id = id
            self.email = email
            self.role = role
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let id = try? container.decode(String.self, forKey: .id) {
                self.id = id
            } else {
                id = String(try container.decode(Int.self, forKey: .id))
            }
            email = try container.decode(String.self, forKey: .email)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
        }
    }

    static let defaultAPIURL = "https://api.betadrop.app"

    var apiUrl: String
    var token: String
    var user: User?

    init(apiUrl: String, token: String, user: User?) {
        self.apiUrl = apiUrl
        self.token = token
        self.user = user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiUrl = (try? container.decodeIfPresent(String.self, forKey: .apiUrl)) ?? BetaDropConfig.defaultAPIURL
        token = try container.decode(String.self, forKey: .token)
        user = try? container.decodeIfPresent(User.self, forKey: .user)
    }

    static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("betadrop").appendingPathComponent("config.json")
        }
        return home.appendingPathComponent(".betadrop").appendingPathComponent("config.json")
    }

    static func read(from url: URL = fileURL()) -> BetaDropConfig? {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(BetaDropConfig.self, from: data), !config.token.isEmpty else {
            return nil
        }
        return config
    }

    static func storedAPIURL(from url: URL = fileURL()) -> String? {
        guard let data = try? Data(contentsOf: url), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let apiUrl = json["apiUrl"] as? String, !apiUrl.isEmpty else {
            return nil
        }
        return apiUrl
    }

    static func clear(at url: URL = fileURL()) {
        try? FileManager.default.removeItem(at: url)
    }

    func write(to url: URL = BetaDropConfig.fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
