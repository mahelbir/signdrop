import Cocoa

@MainActor
final class BetaDropService: UploadService {
    static let codeExpired = UploadError.server("The code expired. Try again.")

    let name = "BetaDrop"
    let isSignInRequired = true
    private let configURL: URL
    private let defaultAPIURL: String

    init(configURL: URL = BetaDropConfig.fileURL(), defaultAPIURL: String = BetaDropConfig.defaultAPIURL) {
        self.configURL = configURL
        self.defaultAPIURL = defaultAPIURL
    }

    var accountName: String? {
        guard let config = BetaDropConfig.read(from: configURL) else { return nil }
        return config.user?.email ?? "unknown account"
    }

    var clientName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "SignDrop/\(version) (macOS/\(architecture))"
    }

    func signIn(in window: NSWindow) async -> Bool {
        await BetaDropSignInSheet(service: self).present(in: window)
    }

    func signInWithBrowser(showCode: (BetaDropDeviceCode) -> Void) async throws {
        let api = makeAPI()
        let code = try await api.requestDeviceCode(clientName: clientName)
        showCode(code)
        var interval = code.interval
        let deadline = Date().addingTimeInterval(code.expiresIn)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(min(max(interval, 1), 3600) * 1_000_000_000))
            switch try await api.pollDeviceToken(deviceCode: code.deviceCode) {
            case .approved(let token, let user):
                try await save(token: token, user: user, api: api)
                return
            case .pending:
                continue
            case .slowDown(let newInterval):
                interval = newInterval ?? interval + 5
            case .denied:
                throw UploadError.server("Sign-in was denied in the browser.")
            case .expired:
                throw BetaDropService.codeExpired
            }
        }
        throw BetaDropService.codeExpired
    }

    func signIn(token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("bd_live_") else {
            throw UploadError.server("That doesn't look like a BetaDrop token (expected to start with bd_live_).")
        }
        try await save(token: token, user: nil, api: makeAPI())
    }

    func signOut() async {
        if let config = BetaDropConfig.read(from: configURL) {
            await BetaDropAPI(baseURL: config.apiUrl).logout(token: config.token)
        }
        BetaDropConfig.clear(at: configURL)
        postAccountChange()
    }

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult {
        guard let config = BetaDropConfig.read(from: configURL) else {
            throw UploadError.sessionExpired
        }
        do {
            let result = try await BetaDropAPI(baseURL: config.apiUrl).publish(file: file, token: config.token, progress: progress)
            return UploadResult(link: result.link, warnings: result.warnings)
        } catch UploadError.sessionExpired {
            if BetaDropConfig.read(from: configURL)?.token == config.token {
                BetaDropConfig.clear(at: configURL)
                postAccountChange()
            }
            throw UploadError.sessionExpired
        }
    }

    private func makeAPI() -> BetaDropAPI {
        BetaDropAPI(baseURL: BetaDropConfig.storedAPIURL(from: configURL) ?? defaultAPIURL)
    }

    private func save(token: String, user: BetaDropConfig.User?, api: BetaDropAPI) async throws {
        try Task.checkCancellation()
        let verifiedUser: BetaDropConfig.User
        if let user {
            verifiedUser = user
        } else {
            verifiedUser = try await api.whoami(token: token)
        }
        try Task.checkCancellation()
        do {
            try BetaDropConfig(apiUrl: api.baseURL, token: token, user: verifiedUser).write(to: configURL)
        } catch {
            throw UploadError.server("Could not save the BetaDrop session: \(error.localizedDescription)")
        }
        postAccountChange()
    }

    private func postAccountChange() {
        NotificationCenter.default.post(name: .uploadAccountDidChange, object: self)
    }
}
