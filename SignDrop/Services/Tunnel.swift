import Cocoa

@MainActor
protocol Tunnel: AnyObject {
    var name: String { get }
    var isReady: Bool { get }
    func prepare(in window: NSWindow) async -> Bool
    func open(port: UInt16) async throws -> OpenTunnel
}

@MainActor
final class OpenTunnel {
    let publicURL: URL
    var onUnexpectedClose: (@MainActor (String) -> Void)?
    private(set) var isClosed = false
    private let closeHandler: @MainActor () -> Void

    init(publicURL: URL, close: @escaping @MainActor () -> Void) {
        self.publicURL = publicURL
        closeHandler = close
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        closeHandler()
    }

    func reportUnexpectedClose(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        closeHandler()
        onUnexpectedClose?(reason)
    }
}

enum AuthoritativeDNS {
    enum Answer {
        case published
        case missing
        case unreachable
    }

    static func answer(for host: String) async -> Answer {
        await Task.detached {
            let zone = host.split(separator: ".").dropFirst().joined(separator: ".")
            guard let servers = dig(["+short", "+time=2", "+tries=1", "NS", zone]), !servers.isEmpty else { return .unreachable }
            var answer = Answer.published
            for server in servers {
                guard let records = dig(["+short", "+norecurse", "+time=2", "+tries=1", "@\(server)", host, "A"]) else { return .unreachable }
                if records.isEmpty {
                    answer = .missing
                }
            }
            return answer
        }.value
    }

    static func records(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix(";") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func dig(_ arguments: [String]) -> [String]? {
        let result = Process().execute("/usr/bin/dig", workingDirectory: nil, arguments: arguments)
        return result.status == 0 ? records(in: result.output) : nil
    }
}

@MainActor
final class CommandLineTunnel: Tunnel {
    static let wrapperScript = "\"$0\" \"$@\" & c=$!; exec >/dev/null 2>&1; read _; kill $c; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 $c || exit 0; sleep 0.3; done; kill -9 $c; exit 0"

    let name: String
    let executable: String
    let brewPackage: String
    let installPage: URL
    let arguments: (UInt16) -> [String]
    let publicURLPattern: String
    let hasFreshHostname: Bool
    var searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    var loginShell: String? = "/bin/zsh"
    var startTimeout: TimeInterval = 30
    var unreachableDNSDelay: TimeInterval = 8
    var hostnameAnswer: (String) async -> AuthoritativeDNS.Answer = { await AuthoritativeDNS.answer(for: $0) }
    var log: (String) -> Void = { Log.write($0) }
    private var shellFoundPath: String?

    init(name: String, executable: String, brewPackage: String, installPage: URL, arguments: @escaping (UInt16) -> [String], publicURLPattern: String, hasFreshHostname: Bool = false) {
        self.name = name
        self.executable = executable
        self.brewPackage = brewPackage
        self.installPage = installPage
        self.arguments = arguments
        self.publicURLPattern = publicURLPattern
        self.hasFreshHostname = hasFreshHostname
    }

    var isReady: Bool {
        executablePath != nil
    }

    var executablePath: String? {
        knownPath(executable) ?? shellFoundPath
    }

    var brewPath: String? {
        knownPath("brew")
    }

    var installCommand: String {
        "brew install \(brewPackage)"
    }

    func knownPath(_ tool: String) -> String? {
        searchPaths.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func publicURL(in line: String) -> URL? {
        guard let range = line.range(of: publicURLPattern, options: .regularExpression) else { return nil }
        return URL(string: String(line[range]))
    }

    func lookUpInLoginShell() async -> String? {
        guard let loginShell else { return nil }
        let executable = executable
        return await Task.detached {
            let result = Process().execute(loginShell, workingDirectory: nil, arguments: ["-lc", "command -v \(executable)"])
            let path = result.output.components(separatedBy: .newlines).last { !$0.isEmpty } ?? ""
            return result.status == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }.value
    }

    func prepare(in window: NSWindow) async -> Bool {
        if isReady {
            return true
        }
        if let path = await lookUpInLoginShell() {
            shellFoundPath = path
            return true
        }
        let alert = makeInstallAlert()
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch alert.buttons.indices.contains(index) ? alert.buttons[index].title : "" {
        case "Copy Command":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        case "Open Install Page":
            NSWorkspace.shared.open(installPage)
        default:
            break
        }
        return false
    }

    func makeInstallAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(name) needs \(executable)"
        if brewPath != nil {
            alert.informativeText = "Install it with Homebrew by running “\(installCommand)” in Terminal, then try again."
            alert.addButton(withTitle: "Copy Command")
        } else {
            alert.informativeText = "Download it from the install page, put it in /usr/local/bin, then try again."
        }
        alert.addButton(withTitle: "Open Install Page")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func open(port: UInt16) async throws -> OpenTunnel {
        guard let path = executablePath else {
            throw UploadError.server("\(name) needs \(executable). Install it and try again.")
        }
        let deadline = Date().addingTimeInterval(startTimeout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.wrapperScript, path] + arguments(port)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw UploadError.server("Could not start \(executable): \(error.localizedDescription)")
        }
        let launch = Launch(name: name, log: log) {
            try? input.fileHandleForWriting.close()
        }
        Task { @MainActor in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    launch.receive(line, url: publicURL(in: line))
                }
            } catch {}
            launch.finish()
        }
        Task { @MainActor [startTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(startTimeout * 1_000_000_000))
            launch.timeOut()
        }
        let tunnel = try await launch.wait()
        if hasFreshHostname {
            try await waitUntilPublished(tunnel, deadline: deadline)
        }
        return tunnel
    }

    private func waitUntilPublished(_ tunnel: OpenTunnel, deadline: Date) async throws {
        var closeReason: String?
        tunnel.onUnexpectedClose = { closeReason = $0 }
        defer { tunnel.onUnexpectedClose = nil }
        let host = tunnel.publicURL.host ?? ""
        let started = Date()
        var lastAnswer: AuthoritativeDNS.Answer?
        do {
            while true {
                if let closeReason {
                    throw UploadError.server(closeReason)
                }
                let answer = await hostnameAnswer(host)
                if answer != lastAnswer {
                    lastAnswer = answer
                    log("\(name): DNS \(answer) for \(host) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                }
                switch answer {
                case .published:
                    return
                case .unreachable:
                    try await Task.sleep(nanoseconds: UInt64(max(0, min(unreachableDNSDelay, deadline.timeIntervalSinceNow)) * 1_000_000_000))
                    if let closeReason {
                        throw UploadError.server(closeReason)
                    }
                    return
                case .missing:
                    break
                }
                guard Date() < deadline else {
                    throw UploadError.server("The tunnel address was not published in time.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch {
            tunnel.close()
            throw error
        }
    }

    @MainActor
    private final class Launch {
        private let name: String
        private let log: (String) -> Void
        private let stop: @MainActor () -> Void
        private var continuation: CheckedContinuation<OpenTunnel, Error>?
        private var pending: Result<OpenTunnel, Error>?
        private var tunnel: OpenTunnel?
        private var isSettled = false
        private var lastLine = ""

        init(name: String, log: @escaping (String) -> Void, stop: @escaping @MainActor () -> Void) {
            self.name = name
            self.log = log
            self.stop = stop
        }

        func wait() async throws -> OpenTunnel {
            try await withCheckedThrowingContinuation { continuation in
                if let pending {
                    continuation.resume(with: pending)
                } else {
                    self.continuation = continuation
                }
            }
        }

        func receive(_ line: String, url: URL?) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lastLine = trimmed
                log("\(name): \(trimmed)")
            }
            guard let url, !isSettled else { return }
            let tunnel = OpenTunnel(publicURL: url, close: stop)
            self.tunnel = tunnel
            settle(.success(tunnel))
        }

        func finish() {
            if let tunnel {
                tunnel.reportUnexpectedClose(lastLine.isEmpty ? "\(name) closed unexpectedly." : lastLine)
            } else {
                fail(UploadError.server(lastLine.isEmpty ? "\(name) stopped before it was ready." : lastLine))
            }
        }

        func timeOut() {
            fail(UploadError.server(lastLine.isEmpty ? "The tunnel did not start in time." : "The tunnel did not start in time. Last output: \(lastLine)"))
        }

        func fail(_ error: Error) {
            guard !isSettled else { return }
            stop()
            settle(.failure(error))
        }

        private func settle(_ result: Result<OpenTunnel, Error>) {
            guard !isSettled else { return }
            isSettled = true
            if let continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                pending = result
            }
        }
    }
}
