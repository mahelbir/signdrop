import Cocoa

@MainActor
final class StreamShareService: UploadService {
    let name = StreamShareAPI.serviceName
    let accountName: String? = nil
    let isSignInRequired = false
    private let api: StreamShareAPI
    private let shorteners: [LinkShortener]

    init(api: StreamShareAPI = StreamShareAPI(), shorteners: [LinkShortener] = LinkShortener.all) {
        self.api = api
        self.shorteners = shorteners
    }

    func signIn(in window: NSWindow) async -> Bool {
        true
    }

    func signOut() async {}

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult {
        let path = file.path
        guard let app = await Task.detached(operation: { AppInfo(ipa: path) }).value else {
            throw UploadError.invalidBuild
        }
        var files = [try await api.upload(file, progress: progress)]
        do {
            let manifest = try await api.upload(InstallLink.manifest(for: app, package: api.downloadURL(for: files[0])), name: "manifest.plist")
            files.append(manifest)
            let webLink = try InstallLink.webLink(manifest: api.downloadURL(for: manifest))
            let deletionRequests = files.map(api.deletionRequest(for:))
            do {
                let shortLink = try await InstallLink.shorten(webLink, with: shorteners, session: api.session)
                return UploadResult(link: shortLink, warnings: [], deletionRequests: deletionRequests)
            } catch let error as UploadError {
                return UploadResult(link: webLink, warnings: [error.localizedDescription], deletionRequests: deletionRequests)
            }
        } catch {
            for uploaded in files {
                try? await api.delete(uploaded)
            }
            throw error
        }
    }
}
