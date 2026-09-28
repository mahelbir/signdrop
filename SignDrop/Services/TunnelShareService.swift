import Cocoa

@MainActor
final class TunnelShareService: UploadService {
    enum LinkStyle {
        case installRedirect
        case shortened
    }

    let tunnel: Tunnel
    let accountName: String? = nil
    let isSignInRequired = false
    let isLiveShare = true
    var linkStyle = LinkStyle.installRedirect
    var readyTimeout: TimeInterval = 30
    var log: (String) -> Void = { Log.write($0) }
    private let shorteners: [LinkShortener]
    private let session: URLSession

    init(tunnel: Tunnel, shorteners: [LinkShortener] = LinkShortener.all, session: URLSession = UploadServices.session) {
        self.tunnel = tunnel
        self.shorteners = shorteners
        self.session = session
    }

    var name: String {
        tunnel.name
    }

    var isReadyToUpload: Bool {
        tunnel.isReady
    }

    func signIn(in window: NSWindow) async -> Bool {
        true
    }

    func signOut() async {}

    func prepareToUpload(in window: NSWindow) async -> Bool {
        await tunnel.prepare(in: window)
    }

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> UploadResult {
        let path = file.path
        guard let app = await Task.detached(operation: { AppInfo(ipa: path) }).value else {
            throw UploadError.invalidBuild
        }
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else {
            throw UploadError.invalidFile("Could not read \(file.lastPathComponent).")
        }
        let token = UUID().uuidString.lowercased()
        let server = LocalFileServer()
        server.onRequest = { [log] method, path, status in log("\(method) \(path) \(status)") }
        server.setRoute("/\(token)/app.ipa", .init(content: .file(handle, size: size), contentType: "application/octet-stream"))
        var openTunnel: OpenTunnel?
        var share: LiveShare?
        do {
            let port: UInt16
            do {
                port = try await server.start()
            } catch {
                throw UploadError.server("Could not start the local server.")
            }
            let opened = try await tunnel.open(port: port)
            openTunnel = opened
            var closeReason: String?
            opened.onUnexpectedClose = { closeReason = $0 }
            let folder = opened.publicURL.appendingPathComponent(token)
            let manifestURL = folder.appendingPathComponent("manifest.plist")
            let manifest = try InstallLink.manifest(for: app, package: folder.appendingPathComponent("app.ipa"))
            server.setRoute("/\(token)/manifest.plist", .init(content: .data(manifest), contentType: "text/xml"))
            server.setRoute("/\(token)/install", .init(content: .redirect(InstallLink.itmsLink(manifest: manifestURL)), contentType: "text/plain"))
            try await waitUntilReachable(manifestURL) { closeReason }
            let liveShare = LiveShare {
                opened.close()
                server.stop()
            }
            share = liveShare
            opened.onUnexpectedClose = { [weak liveShare] reason in
                closeReason = reason
                liveShare?.end(reason)
            }
            let shared: (link: URL, warnings: [String])
            switch linkStyle {
            case .installRedirect:
                shared = (folder.appendingPathComponent("install"), [])
            case .shortened:
                shared = try await InstallLink.shortenOrKeep(try InstallLink.webLink(manifest: manifestURL), with: shorteners, session: session)
            }
            if let closeReason {
                throw UploadError.server(closeReason)
            }
            return UploadResult(link: shared.link, warnings: shared.warnings, liveShare: liveShare)
        } catch {
            share?.stop()
            openTunnel?.close()
            server.stop()
            throw error
        }
    }

    private func waitUntilReachable(_ url: URL, closeReason: () -> String?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let deadline = Date().addingTimeInterval(readyTimeout)
        repeat {
            if let reason = closeReason() {
                throw UploadError.server(reason)
            }
            if let response = try? await session.response(for: request, service: name), response.status == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } while Date() < deadline
        throw UploadError.server("The link did not become reachable.")
    }
}
