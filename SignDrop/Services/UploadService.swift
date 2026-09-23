import Cocoa

struct UploadResult: Equatable {
    let link: URL?
    let warnings: [String]
}

enum UploadError: LocalizedError, Equatable {
    case sessionExpired
    case invalidFile(String)
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Your token is invalid, expired, or was revoked."
        case .invalidFile(let message), .server(let message), .network(let message):
            return message
        }
    }
}

@MainActor
protocol UploadService: AnyObject {
    var name: String { get }
    var accountName: String? { get }
    func signIn(in window: NSWindow) async -> Bool
    func signOut() async
    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult
}

enum UploadServices {
    @MainActor static let all: [UploadService] = [BetaDropService()]
}

extension Notification.Name {
    static let uploadAccountDidChange = Notification.Name("uploadAccountDidChange")
}
