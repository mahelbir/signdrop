import Cocoa

struct UploadResult: Equatable {
    let link: URL?
    let warnings: [String]
    var deletionRequests: [URLRequest] = []
}

enum UploadError: LocalizedError, Equatable {
    case sessionExpired
    case invalidFile(String)
    case server(String)
    case network(String)

    static let invalidBuild = UploadError.invalidFile("This file does not appear to be a valid iOS build. Please upload a valid IPA file.")

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Your token is invalid, expired, or was revoked."
        case .invalidFile(let message), .server(let message), .network(let message):
            return message
        }
    }

    static func from(_ error: Error, service: String, stallTimeout: TimeInterval? = nil) -> Error {
        if error is UploadError || error is CancellationError {
            return error
        }
        switch (error as? URLError)?.code {
        case .cancelled?:
            return CancellationError()
        case .timedOut? where stallTimeout != nil:
            return UploadError.network("Upload stalled — no data for \(Int(stallTimeout ?? 0))s. Check your connection.")
        case .timedOut?:
            return UploadError.network("Request timed out. Check your connection or try again.")
        default:
            return UploadError.network("Could not reach \(service). Check your connection.")
        }
    }
}

@MainActor
protocol UploadService: AnyObject {
    var name: String { get }
    var accountName: String? { get }
    var isSignInRequired: Bool { get }
    func signIn(in window: NSWindow) async -> Bool
    func signOut() async
    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult
}

enum UploadServices {
    @MainActor static let all: [UploadService] = [BetaDropService(), StreamShareService()]
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func delete(_ requests: [URLRequest], service: String, session: URLSession = UploadServices.session) async throws {
        for request in requests {
            let (_, status) = try await session.response(for: request, service: service)
            guard (200..<300).contains(status) else {
                throw UploadError.server("\(service) returned an error (HTTP \(status)).")
            }
        }
    }

    static func deletionCommand(_ requests: [URLRequest]) -> String {
        requests.map { request in
            let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { "-H \(shellQuoted("\($0.key): \($0.value)"))" }
            return (["curl", "-X", request.httpMethod ?? "GET"] + headers + [shellQuoted(request.url?.absoluteString ?? "")]).joined(separator: " ")
        }.joined(separator: " && ")
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension URLSession {
    func response(for request: URLRequest, service: String) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw UploadError.from(error, service: service)
        }
    }
}

extension Notification.Name {
    static let uploadAccountDidChange = Notification.Name("uploadAccountDidChange")
}
