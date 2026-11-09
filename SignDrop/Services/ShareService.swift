import Cocoa

struct ShareResult: Equatable {
    let link: URL?
    let warnings: [String]
    var itmsLink: String?
    var deletionRequests: [URLRequest] = []
    var liveShare: LiveShare?
}

enum ShareError: LocalizedError, Equatable {
    case sessionExpired
    case invalidFile(String)
    case server(String)
    case network(String)

    static let invalidBuild = ShareError.invalidFile(
        "This file does not appear to be a valid iOS build. Please choose a valid IPA file.")

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Your token is invalid, expired, or was revoked."
        case .invalidFile(let message), .server(let message), .network(let message):
            return message
        }
    }

    static func from(_ error: Error, service: String, stallTimeout: TimeInterval? = nil) -> Error {
        if error is ShareError || error is CancellationError {
            return error
        }
        switch (error as? URLError)?.code {
        case .cancelled?:
            return CancellationError()
        case .timedOut? where stallTimeout != nil:
            return ShareError.network(
                "Upload stalled — no data for \(Int(stallTimeout ?? 0))s. Check your connection.")
        case .timedOut?:
            return ShareError.network("Request timed out. Check your connection or try again.")
        default:
            return ShareError.network("Could not reach \(service). Check your connection.")
        }
    }
}

@MainActor
protocol ShareService: AnyObject {
    var name: String { get }
    var accountName: String? { get }
    var isSignInRequired: Bool { get }
    var isReadyToShare: Bool { get }
    var isLiveShare: Bool { get }
    func signIn(in window: NSWindow) async -> Bool
    func prepareToShare(in window: NSWindow) async -> Bool
    func signOut() async
    func share(_ file: URL, progress: @escaping (Double) -> Void) async throws -> ShareResult
}

extension ShareService {
    var isReadyToShare: Bool {
        !isSignInRequired || accountName != nil
    }

    var isLiveShare: Bool {
        false
    }

    func prepareToShare(in window: NSWindow) async -> Bool {
        await signIn(in: window)
    }
}

@MainActor
final class LiveShare: Equatable {
    static let activityReason = "Sharing an app from this Mac"
    var onEnd: (@MainActor (String) -> Void)?
    private var stopHandler: (@MainActor () -> Void)?
    private var activity: NSObjectProtocol?

    init(stop: @escaping @MainActor () -> Void) {
        stopHandler = stop
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: LiveShare.activityReason)
    }

    var isActive: Bool {
        stopHandler != nil
    }

    func stop() {
        guard let stopHandler else { return }
        self.stopHandler = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        stopHandler()
    }

    func end(_ reason: String) {
        guard isActive else { return }
        stop()
        onEnd?(reason)
    }

    nonisolated static func == (lhs: LiveShare, rhs: LiveShare) -> Bool {
        lhs === rhs
    }
}

enum ShareServices {
    @MainActor static let all: [ShareService] = [
        BetaDropService(), StreamShareService(),
        TunnelShareService(tunnel: CommandLineTunnel.cloudflareQuickTunnel()),
    ]
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func delete(
        _ requests: [URLRequest], service: String, session: URLSession = ShareServices.session
    ) async throws {
        for request in requests {
            let (_, status) = try await session.response(for: request, service: service)
            guard (200..<300).contains(status) else {
                throw ShareError.server("\(service) returned an error (HTTP \(status)).")
            }
        }
    }

    static func deletionCommand(_ requests: [URLRequest]) -> String {
        requests.map { request in
            let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map {
                "-H \(shellQuoted("\($0.key): \($0.value)"))"
            }
            return
                (["curl", "-X", request.httpMethod ?? "GET"] + headers + [
                    shellQuoted(request.url?.absoluteString ?? "")
                ]).joined(separator: " ")
        }.joined(separator: " && ")
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension URLSession {
    func response(for request: URLRequest, service: String) async throws -> (
        data: Data, status: Int
    ) {
        do {
            let (data, response) = try await data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ShareError.from(error, service: service)
        }
    }
}

extension Notification.Name {
    static let shareAccountDidChange = Notification.Name("shareAccountDidChange")
}
