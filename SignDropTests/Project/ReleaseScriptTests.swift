import Foundation
import Testing

struct ReleaseScriptTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func run(_ executable: String, _ arguments: [String], path: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let path {
            process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func verificationReportsItsResultWhenTheImageStaysBusy() throws {
        let work = try WorkDirectory()
        let stage = try work.directory("stage")
        work.file("stage/file.txt", Data("x".utf8))
        let image = work.child("Test.dmg")
        let created = try run("/usr/bin/hdiutil", ["create", "-volname", "SignDropTest", "-srcfolder", stage.path, "-format", "UDZO", image.path])
        try #require(created.status == 0, "\(created.output)")

        let shimDirectory = try work.directory("shim")
        let busyMounts = work.child("busy-mounts")
        let shim = shimDirectory.appendingPathComponent("hdiutil")
        try """
        #!/bin/sh
        if [ "$1" = detach ]; then
          echo "$2" >> "\(busyMounts.path)"
          echo "hdiutil: couldn't unmount: Resource busy" >&2
          exit 16
        fi
        exec /usr/bin/hdiutil "$@"
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let script = Self.root.appendingPathComponent("scripts/release.sh").path
        let result = try run("/bin/zsh", [script, "--verify", image.path], path: "\(shimDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin")
        let mounts = Set(((try? String(contentsOf: busyMounts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        for mount in mounts {
            _ = try run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"])
            try? FileManager.default.removeItem(atPath: mount)
        }

        let lastLine = result.output.split(separator: "\n").last.map(String.init) ?? ""
        #expect(lastLine.hasSuffix(" FAILED"), "\(result.output)")
    }
}
