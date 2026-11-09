import Foundation
import Testing
@testable import SignDrop

extension SerialTests {
    struct BetaDropConfigTests {
        private let work: WorkDirectory
        private let url: URL
        private let config = BetaDropConfig(
            apiUrl: "https://api.betadrop.app", token: "bd_live_abc",
            user: .init(id: "u1", email: "dev@example.com", role: "user"))

        init() throws {
            work = try WorkDirectory()
            url = work.child("config/betadrop/config.json")
        }

        private func store(_ text: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        private func permissions() throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber)?.intValue
        }

        @Test func resolvesTheConfigPath() {
            let home = URL(fileURLWithPath: "/Users/tester")
            #expect(
                BetaDropConfig.fileURL(environment: ["XDG_CONFIG_HOME": "/x/config"], home: home)
                    .path == "/x/config/betadrop/config.json", "config.path.xdg")
            #expect(
                BetaDropConfig.fileURL(environment: ["XDG_CONFIG_HOME": ""], home: home).path
                    == "/Users/tester/.betadrop/config.json", "config.path.emptyXDG")
            #expect(
                BetaDropConfig.fileURL(environment: [:], home: home).path
                    == "/Users/tester/.betadrop/config.json", "config.path.home")
        }

        @Test func readsNothingWhenTheFileIsMissing() {
            #expect(BetaDropConfig.read(from: url) == nil, "config.read.missing")
        }

        @Test func writesThePrivateCLIFormat() throws {
            try config.write(to: url)
            #expect(BetaDropConfig.read(from: url) == config, "config.write.roundTrip")
            #expect(try permissions() == 0o600, "config.write.permissions")
            let json =
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(
                json?["apiUrl"] as? String == "https://api.betadrop.app", "config.write.cliKeys")
            #expect(json?["token"] as? String == "bd_live_abc", "config.write.cliKeys")
            #expect(
                (json?["user"] as? [String: Any])?["email"] as? String == "dev@example.com",
                "config.write.cliKeys")
            #expect(
                try String(contentsOf: url).contains("https://api.betadrop.app"),
                "config.write.noSlashEscaping")
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: url.deletingLastPathComponent().path) == ["config.json"],
                "config.write.noTempFiles")
        }

        @Test func replacesLoosePermissionsOnWrite() throws {
            try store("{\"apiUrl\":\"x\",\"token\":\"old\"}")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
            try config.write(to: url)
            #expect(
                try permissions() == 0o600
                    && BetaDropConfig.read(from: url)?.token == "bd_live_abc",
                "config.write.replacesLoosePermissions")
        }

        @Test func rejectsUnusableFiles() throws {
            try store("{")
            #expect(BetaDropConfig.read(from: url) == nil, "config.read.corrupt")
            try store("{\"apiUrl\":\"x\",\"token\":\"\"}")
            #expect(BetaDropConfig.read(from: url) == nil, "config.read.emptyToken")
        }

        @Test func readsFilesWrittenByTheCLI() throws {
            try store(
                "{\"token\":\"bd_live_cli\",\"user\":{\"id\":7,\"email\":\"cli@example.com\"}}")
            let cliConfig = BetaDropConfig.read(from: url)
            #expect(
                cliConfig?.user?.id == "7" && cliConfig?.user?.email == "cli@example.com"
                    && cliConfig?.user?.role == nil, "config.read.cliNumericID")
            #expect(cliConfig?.apiUrl == BetaDropConfig.defaultAPIURL, "config.read.defaultAPIURL")
        }

        @Test func readsTheExactFileTheCLIWrites() throws {
            try store(
                """
                {
                  "apiUrl": "https://api.betadrop.app",
                  "token": "bd_live_fromcli",
                  "user": {
                    "id": 7,
                    "email": "dev@example.com",
                    "role": "user"
                  }
                }
                """)
            let read = BetaDropConfig.read(from: url)
            #expect(
                read?.token == "bd_live_fromcli" && read?.user?.email == "dev@example.com"
                    && read?.apiUrl == "https://api.betadrop.app", "interop.signDropReadsCLIConfig")
        }

        @Test func writesTheKeysTheCLIReads() throws {
            try config.write(to: url)
            let json = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let user = try #require(json["user"] as? [String: Any])
            #expect(
                Set(json.keys) == ["apiUrl", "token", "user"]
                    && Set(user.keys) == ["id", "email", "role"], "interop.cliReadsSignDropConfig")
        }

        @Test func keepsTheTokenWhenTheUserIsBroken() throws {
            try store("{\"apiUrl\":\"x\",\"token\":\"bd_live_cli\",\"user\":{\"id\":\"u\"}}")
            let brokenUser = BetaDropConfig.read(from: url)
            #expect(
                brokenUser?.token == "bd_live_cli" && brokenUser?.user == nil,
                "config.read.brokenUserKeepsToken")
        }

        @Test func clearRemovesTheFile() throws {
            try config.write(to: url)
            BetaDropConfig.clear(at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path), "config.clear")
        }
    }
}
