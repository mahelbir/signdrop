import Foundation
import Testing
@testable import SignDrop

func download(_ url: URL) async -> Data? {
    let response = await httpRequest(url)
    return response.status == 200 ? response.data : nil
}

extension StreamShareMockServer {
    func api(_ scenario: String) -> StreamShareAPI {
        var api = StreamShareAPI(
            baseURL: URL(string: "\(baseURL)/s/\(scenario)")!,
            socketURL: URL(string: "\(socketURL)/s/\(scenario)")!)
        api.stallTimeout = 2
        return api
    }
}

extension SerialTests {
    struct StreamShareAPITests {
        private let mock: StreamShareMockServer
        private let work: WorkDirectory
        private let sample = StreamShareFile(id: "abc123", deletionToken: "tok9")

        init() async throws {
            mock = try await StreamShareMockServer()
            work = try WorkDirectory()
        }

        private func bigIPA() -> URL {
            work.file("Big Name.ipa", randomData(9 * 1_048_576 + 123))
        }

        @Test func defaultsPointAtTheRealService() {
            let defaults = StreamShareAPI()
            #expect(
                defaults.baseURL.absoluteString == "https://streamshare.wireway.ch"
                    && defaults.socketURL.absoluteString == "wss://streamshare.wireway.ch",
                "streamshare.defaults")
            #expect(
                defaults.downloadURL(for: sample).absoluteString
                    == "https://streamshare.wireway.ch/download/abc123", "streamshare.downloadURL")
            let deletion = defaults.deletionRequest(for: sample)
            #expect(
                deletion.httpMethod == "DELETE"
                    && deletion.url?.absoluteString
                        == "https://streamshare.wireway.ch/api/delete/abc123/tok9",
                "streamshare.deletionRequest")
        }

        @Test func uploadsAFileInAcknowledgedChunks() async throws {
            let ipa = bigIPA()
            let fractions = Collector<Double>()
            let uploaded = try? await mock.api("ok").upload(ipa) { fractions.append($0) }
            _ = await isEventuallyTrue(3) { !mock.uploads("ok").isEmpty }
            let received = mock.stats["ok"]
            let upload = mock.uploads("ok").first
            #expect(
                uploaded == StreamShareFile(id: "ok-1", deletionToken: "tok1"),
                "streamshare.upload.file")
            #expect(
                received["names"] as? [String] == ["Big Name.ipa"]
                    && received["contentType"] as? String == "application/json",
                "streamshare.upload.create")
            #expect(
                upload?["sha256"] as? String == sha256Hex(ofFile: ipa), "streamshare.upload.sha256")
            #expect(
                upload?["chunks"] as? [Int] == Array(repeating: 1_048_576, count: 9) + [123],
                "streamshare.upload.chunks")
            #expect(
                upload?["closeCode"] as? Int == 1000
                    && upload?["closeReason"] as? String == "FILE_UPLOAD_DONE",
                "streamshare.upload.closed")
            #expect(
                fractions.all.count == 10 && fractions.all == fractions.all.sorted()
                    && fractions.all.last == 1, "streamshare.upload.progress")
        }

        @Test func uploadsInMemoryData() async {
            let manifestData = Data("<plist/>".utf8)
            let manifestAPI = mock.api("ok~data")
            let manifest = try? await manifestAPI.upload(manifestData, name: "manifest.plist")
            _ = await isEventuallyTrue(3) { !mock.uploads("ok~data").isEmpty }
            #expect(manifest?.id == "ok~data-1", "streamshare.uploadData.file")
            #expect(
                mock.stats["ok~data"]["names"] as? [String] == ["manifest.plist"],
                "streamshare.uploadData.create")
            #expect(
                await download(manifestAPI.downloadURL(for: manifest ?? sample)) == manifestData,
                "streamshare.uploadData.downloadable")
        }

        @Test func reportsAFailedCreate() async {
            let ipa = bigIPA()
            await #expect(
                throws: ShareError.server("StreamShare could not start the upload (HTTP 500)."),
                "streamshare.create.error"
            ) { try await mock.api("create-500").upload(ipa) { _ in } }
        }

        @Test func deletesTheFileAfterABadReply() async {
            let ipa = bigIPA()
            await #expect(
                throws: ShareError.server("Unexpected response from StreamShare."),
                "streamshare.upload.badReply"
            ) { try await mock.api("bad-reply").upload(ipa) { _ in } }
            _ = await isEventuallyTrue(3) { mock.stats["bad-reply"]["deleted"] != nil }
            #expect(
                mock.stats["bad-reply"]["deleted"] as? [String] == ["bad-reply-1/tok1"],
                "streamshare.upload.badReplyDeletes")
        }

        @Test func deletesTheFileAfterAStall() async {
            let ipa = bigIPA()
            await #expect(
                throws: ShareError.network(
                    "Upload stalled — no data for 2s. Check your connection."),
                "streamshare.upload.stall"
            ) { try await mock.api("stall").upload(ipa) { _ in } }
            _ = await isEventuallyTrue(3) { mock.stats["stall"]["deleted"] != nil }
            #expect(
                mock.stats["stall"]["deleted"] as? [String] == ["stall-1/tok1"],
                "streamshare.upload.stallDeletes")
        }

        @Test func cancellingStopsPromptlyAndRemovesTheFile() async {
            let ipa = bigIPA()
            let upload = Task { try await mock.api("stall~cancel").upload(ipa) { _ in } }
            _ = await isEventuallyTrue(3) { mock.stats["stall~cancel"]["create"] != nil }
            await pause(0.2)
            let started = Date()
            upload.cancel()
            let outcome = await upload.result
            #expect(Date().timeIntervalSince(started) < 1.5, "streamshare.cancelIsPrompt")
            #expect(throws: CancellationError.self, "streamshare.cancelThrows") {
                try outcome.get()
            }
            _ = await isEventuallyTrue(3) { mock.stats["stall~cancel"]["deleted"] != nil }
            #expect(
                mock.stats["stall~cancel"]["deleted"] as? [String] == ["stall~cancel-1/tok1"],
                "streamshare.cancelDeletes")
        }

        @Test func missingFileCreatesNothing() async {
            await #expect(
                throws: ShareError.invalidFile("Could not read file: \(work.path)/absent.ipa"),
                "streamshare.upload.missingFile"
            ) {
                try await mock.api("ok~missing").upload(work.child("absent.ipa")) { _ in }
            }
            #expect(
                mock.stats["ok~missing"]["create"] == nil,
                "streamshare.upload.missingFileSkipsCreate")
        }

        @Test func reportsAnUnreachableServer() async {
            let ipa = work.file("Small.ipa", Data("x".utf8))
            let offline = StreamShareAPI(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                socketURL: URL(string: "ws://127.0.0.1:1")!)
            await #expect(
                throws: ShareError.network("Could not reach StreamShare. Check your connection."),
                "streamshare.unreachable"
            ) { try await offline.upload(ipa) { _ in } }
        }

        @Test func deletesUploadedFiles() async throws {
            let deleteAPI = mock.api("ok~delete")
            let file = try await deleteAPI.upload(Data("x".utf8), name: "x.txt")
            _ = await isEventuallyTrue(3) { !mock.uploads("ok~delete").isEmpty }
            try? await deleteAPI.delete(file)
            #expect(
                mock.stats["ok~delete"]["deleted"] as? [String] == ["ok~delete-1/tok1"],
                "streamshare.delete.sent")
            #expect(
                await download(deleteAPI.downloadURL(for: file)) == nil,
                "streamshare.delete.removed")
        }

        @Test func reportsAFailedDelete() async {
            await #expect(
                throws: ShareError.server("StreamShare returned an error (HTTP 404)."),
                "streamshare.delete.error"
            ) { try await mock.api("delete-404").delete(sample) }
        }

        @Test func sendsDeletionRequests() async throws {
            let api = mock.api("ok~deletion")
            let first = try await api.upload(Data("a".utf8), name: "a.txt")
            let second = try await api.upload(Data("b".utf8), name: "b.txt")
            _ = await isEventuallyTrue(3) { mock.uploads("ok~deletion").count == 2 }
            try await ShareServices.delete(
                [first, second].map(api.deletionRequest(for:)), service: "StreamShare")
            #expect(
                mock.stats["ok~deletion"]["deleted"] as? [String] == [
                    "ok~deletion-1/tok1", "ok~deletion-2/tok2",
                ], "deletion.sent")
        }

        @Test func reportsDeletionFailures() async {
            let missing = StreamShareFile(id: "x", deletionToken: "y")
            await #expect(
                throws: ShareError.server("StreamShare returned an error (HTTP 404)."),
                "deletion.error"
            ) {
                try await ShareServices.delete(
                    [mock.api("delete-404").deletionRequest(for: missing)], service: "StreamShare")
            }
            await #expect(
                throws: ShareError.network("Could not reach StreamShare. Check your connection."),
                "deletion.unreachable"
            ) {
                try await ShareServices.delete(
                    [URLRequest(url: URL(string: "http://127.0.0.1:1/x")!)], service: "StreamShare")
            }
        }
    }
}
