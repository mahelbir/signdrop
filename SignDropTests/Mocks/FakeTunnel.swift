import AppKit
import Foundation
@testable import SignDrop

extension WorkDirectory {
    func installFakeTunnelTools() throws {
        try script(
            "mock-tunnel",
            """
            #!/bin/sh
            trap 'exit 0' TERM
            case "$1" in
              url) echo "2026-09-28T10:00:00Z INF |  https://abc-def.trycloudflare.com  |" >&2; while :; do sleep 0.2; done ;;
              url-then-exit) echo "INF | https://abc-def.trycloudflare.com |" >&2; sleep 1; echo "ERR connection lost" >&2; exit 1 ;;
              fail) echo "INF starting" >&2; echo "ERR failed to request quick Tunnel: 429" >&2; exit 1 ;;
              silent) while :; do sleep 0.2; done ;;
              chatty-silent) echo "INF still connecting" >&2; while :; do sleep 0.2; done ;;
            esac
            """)
        try script(
            "fake-shell",
            """
            #!/bin/sh
            echo "noise from a login profile"
            echo "$(dirname "$0")/mock-tunnel"
            """)
        _ = try directory("fakebrew")
        try script("fakebrew/brew", "#!/bin/sh\nexit 0\n")
    }

    private func script(_ name: String, _ text: String) throws {
        let file = child(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}

@MainActor
final class FakeTunnel: Tunnel {
    enum Mode {
        case passthrough
        case fail
        case unreachable
        case dropsWhileStarting
        case pinned
        case pinnedUnreachable
    }

    let name = "Fake Tunnel"
    var isReady = true
    let mode: Mode
    private(set) var openedPort: UInt16?
    private(set) var tunnel: OpenTunnel?
    private(set) var isClosed = false

    init(_ mode: Mode) {
        self.mode = mode
    }

    func prepare(in window: NSWindow) async -> Bool {
        isReady
    }

    func open(port: UInt16) async throws -> OpenTunnel {
        openedPort = port
        if mode == .fail {
            throw ShareError.server("ERR boom")
        }
        let host: String
        switch mode {
        case .passthrough:
            host = "http://127.0.0.1:\(port)"
        case .pinned:
            host = "http://fresh-host.invalid:\(port)"
        case .pinnedUnreachable:
            host = "http://fresh-host.invalid:9"
        default:
            host = "http://127.0.0.1:9"
        }
        let tunnel = OpenTunnel(publicURL: URL(string: host)!) { [weak self] in
            self?.isClosed = true
        }
        if mode == .pinned || mode == .pinnedUnreachable {
            tunnel.resolvedAddresses = ["127.0.0.1"]
        }
        self.tunnel = tunnel
        if mode == .dropsWhileStarting {
            Task { @MainActor in
                await pause(0.3)
                tunnel.reportUnexpectedClose("ERR lost")
            }
        }
        return tunnel
    }
}
