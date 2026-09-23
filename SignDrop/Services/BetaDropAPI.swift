import Foundation

struct BetaDropDeviceCode: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String
    let expiresIn: TimeInterval
    let interval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

enum BetaDropDeviceTokenResult: Equatable {
    case approved(token: String, user: BetaDropConfig.User?)
    case pending
    case slowDown(interval: TimeInterval?)
    case denied
    case expired
}

struct BetaDropPublishResult: Equatable {
    let link: URL
    let warnings: [String]
}

struct BetaDropAPI {
    static let appURL = "https://betadrop.app"
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    let baseURL: String
    var session = BetaDropAPI.sharedSession
    var stallTimeout: TimeInterval = 60
    var retries = 2
    var temporaryDirectory = FileManager.default.temporaryDirectory

    init(baseURL: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    static func validateBuild(_ file: URL) throws {
        let fileExtension = file.pathExtension.lowercased()
        guard fileExtension == "ipa" else {
            throw UploadError.invalidFile("Unsupported file type \"\(fileExtension.isEmpty ? "" : "." + fileExtension)\". Expected .ipa.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw UploadError.invalidFile("File not found: \(file.path)")
        }
        guard !isDirectory.boolValue else {
            throw UploadError.invalidFile("Not a file: \(file.path)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
        guard size != 0 else {
            throw UploadError.invalidFile("The file is empty.")
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw UploadError.invalidFile("Could not read file to validate it: \(file.path)")
        }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw UploadError.invalidFile("This file does not appear to be a valid iOS build. Please upload a valid IPA file.")
        }
    }

    func whoami(token: String) async throws -> BetaDropConfig.User {
        let payload: BetaDropWhoami? = try await send(makeRequest("/api/cli/whoami", token: token))
        guard let user = payload?.user else {
            throw UploadError.server("Unexpected response from BetaDrop — could not verify token.")
        }
        return user
    }

    func logout(token: String) async {
        let _: BetaDropIgnored? = try? await send(makeRequest("/api/cli/logout", method: "POST", token: token))
    }

    func requestDeviceCode(clientName: String) async throws -> BetaDropDeviceCode {
        let request = try makeRequest("/api/cli/device/code", method: "POST", body: ["client_name": clientName, "scope": "publish read"])
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status) else {
            throw UploadError.server("BetaDrop returned an error (HTTP \(status)). Try again, or use an API token.")
        }
        guard let code = try? JSONDecoder().decode(BetaDropDeviceCode.self, from: data) else {
            throw BetaDropAPI.unexpectedResponse(status)
        }
        return code
    }

    func pollDeviceToken(deviceCode: String) async throws -> BetaDropDeviceTokenResult {
        let request = try makeRequest("/api/cli/device/token", method: "POST", body: ["device_code": deviceCode])
        let (data, status) = try await perform(request)
        let body = (try? JSONDecoder().decode(BetaDropDeviceTokenBody.self, from: data)) ?? BetaDropDeviceTokenBody()
        if (200..<300).contains(status), let token = body.accessToken {
            return .approved(token: token, user: body.user)
        }
        switch body.error ?? "expired_token" {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(interval: body.interval)
        case "access_denied":
            return .denied
        default:
            return .expired
        }
    }

    func publish(file: URL, token: String, progress: @escaping (Double) -> Void) async throws -> BetaDropPublishResult {
        try BetaDropAPI.validateBuild(file)
        let boundary = "----signdrop" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let body = try makeMultipartBody(for: file, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = try makeRequest("/api/cli/publish", method: "POST", token: token, timeout: stallTimeout)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var attempt = 0
        while true {
            attempt += 1
            let (data, status) = try await perform(request, fromFile: body, delegate: BetaDropUploadProgress(progress))
            if attempt <= retries && BetaDropAPI.isRetryable(data, status: status) {
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000) << (attempt - 1))
                continue
            }
            let response: BetaDropPublishResponse? = try decode(data, status: status, fallback: "Upload failed")
            guard let response else {
                throw BetaDropAPI.unexpectedResponse(status)
            }
            return try result(for: response, status: status)
        }
    }

    private static func isRetryable(_ data: Data, status: Int) -> Bool {
        guard (500..<600).contains(status) else { return false }
        return (try? JSONDecoder().decode(BetaDropEnvelope<BetaDropIgnored>.self, from: data))?.hasErrorDetail != true
    }

    private static func unexpectedResponse(_ status: Int) -> UploadError {
        UploadError.server("Unexpected response from BetaDrop (HTTP \(status)).")
    }

    private func makeRequest(_ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw UploadError.server("Invalid BetaDrop API URL: \(baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func perform(_ request: URLRequest, fromFile file: URL? = nil, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, Int) {
        do {
            let (data, response): (Data, URLResponse)
            if let file {
                (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            throw networkError(error, isUpload: file != nil)
        }
    }

    private func networkError(_ error: URLError, isUpload: Bool) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .timedOut where isUpload:
            return UploadError.network("Upload stalled — no data for \(Int(stallTimeout))s. Check your connection.")
        case .timedOut:
            return UploadError.network("Request timed out. Check your connection or try again.")
        default:
            return UploadError.network("Could not reach BetaDrop. Check your connection.")
        }
    }

    private func send<Payload: Decodable>(_ request: URLRequest) async throws -> Payload? {
        let (data, status) = try await perform(request)
        return try decode(data, status: status, fallback: "Request failed")
    }

    private func decode<Payload: Decodable>(_ data: Data, status: Int, fallback: String) throws -> Payload? {
        if status == 401 {
            throw UploadError.sessionExpired
        }
        guard let envelope = try? JSONDecoder().decode(BetaDropEnvelope<Payload>.self, from: data) else {
            throw BetaDropAPI.unexpectedResponse(status)
        }
        if !(200..<300).contains(status) || envelope.isSuccess == false {
            throw UploadError.server(envelope.errorText ?? "\(fallback) (HTTP \(status)).")
        }
        return envelope.data
    }

    private func result(for response: BetaDropPublishResponse, status: Int) throws -> BetaDropPublishResult {
        var components = URLComponents(string: BetaDropAPI.appURL + "/install/")
        components?.queryItems = [URLQueryItem(name: "i", value: response.shortId)]
        guard let link = components?.url else {
            throw BetaDropAPI.unexpectedResponse(status)
        }
        let warnings = response.duplicateOf.map { ["\($0.message) (\($0.url))"] } ?? []
        return BetaDropPublishResult(link: link, warnings: warnings)
    }

    private func makeMultipartBody(for file: URL, boundary: String) throws -> URL {
        let fileName = file.lastPathComponent.replacingOccurrences(of: "[\"\\\\\r\n]", with: "_", options: .regularExpression)
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        let footer = "\r\n--\(boundary)--\r\n"
        let body = temporaryDirectory.appendingPathComponent("signdrop-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: body.path, contents: Data(header.utf8)) else {
            throw UploadError.invalidFile("Could not prepare the upload in \(temporaryDirectory.path).")
        }
        do {
            let output = try FileHandle(forWritingTo: body)
            defer { try? output.close() }
            try output.seekToEnd()
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var hasMoreData = true
            while hasMoreData {
                hasMoreData = try autoreleasepool {
                    guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                    try output.write(contentsOf: chunk)
                    return true
                }
            }
            try output.write(contentsOf: Data(footer.utf8))
        } catch {
            try? FileManager.default.removeItem(at: body)
            throw UploadError.invalidFile("Could not prepare the upload: \(error.localizedDescription)")
        }
        return body
    }
}

private struct BetaDropEnvelope<Payload: Decodable>: Decodable {
    let isSuccess: Bool?
    let data: Payload?
    let error: String?
    let message: String?
    let hasErrorDetail: Bool

    enum CodingKeys: String, CodingKey {
        case isSuccess = "success"
        case data, error, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = try? container.decodeIfPresent(Bool.self, forKey: .isSuccess)
        data = try? container.decodeIfPresent(Payload.self, forKey: .data)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        hasErrorDetail = BetaDropEnvelope.isTruthy(container, .error) || BetaDropEnvelope.isTruthy(container, .message)
    }

    var errorText: String? {
        [error, message].compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func isTruthy(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return false }
        if let text = try? container.decode(String.self, forKey: key) {
            return !text.isEmpty
        }
        if let flag = try? container.decode(Bool.self, forKey: key) {
            return flag
        }
        if let number = try? container.decode(Double.self, forKey: key) {
            return number != 0
        }
        return true
    }
}

private struct BetaDropDeviceTokenBody: Decodable {
    var accessToken: String?
    var user: BetaDropConfig.User?
    var error: String?
    var interval: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user, error, interval
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
        user = try? container.decodeIfPresent(BetaDropConfig.User.self, forKey: .user)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        interval = try? container.decodeIfPresent(TimeInterval.self, forKey: .interval)
    }
}

private struct BetaDropPublishResponse: Decodable {
    struct Duplicate: Decodable {
        let message: String
        let url: String
    }

    let shortId: String
    let duplicateOf: Duplicate?

    enum CodingKeys: String, CodingKey {
        case shortId, duplicateOf
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortId = try container.decode(String.self, forKey: .shortId)
        duplicateOf = try? container.decodeIfPresent(Duplicate.self, forKey: .duplicateOf)
    }
}

private struct BetaDropWhoami: Decodable {
    let user: BetaDropConfig.User
}

private struct BetaDropIgnored: Decodable {}

private final class BetaDropUploadProgress: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void

    init(_ onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 1)
        DispatchQueue.main.async { self.onProgress(fraction) }
    }
}
