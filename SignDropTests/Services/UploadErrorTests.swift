import Foundation
import Testing
@testable import SignDrop

struct UploadErrorTests {
    @Test func mapsTransportErrorsToUserTexts() {
        #expect(
            UploadError.from(URLError(.timedOut), service: "Svc") as? UploadError
                == .network("Request timed out. Check your connection or try again."),
            "error.timeout")
        #expect(
            UploadError.from(URLError(.timedOut), service: "Svc", stallTimeout: 3) as? UploadError
                == .network("Upload stalled — no data for 3s. Check your connection."),
            "error.stall")
        #expect(
            UploadError.from(URLError(.cannotConnectToHost), service: "Svc") as? UploadError
                == .network("Could not reach Svc. Check your connection."), "error.unreachable")
        #expect(
            UploadError.from(NSError(domain: NSPOSIXErrorDomain, code: 57), service: "Svc")
                as? UploadError == .network("Could not reach Svc. Check your connection."),
            "error.socket")
    }

    @Test func keepsCancellationAndUploadErrors() {
        #expect(
            UploadError.from(URLError(.cancelled), service: "Svc") is CancellationError,
            "error.cancelled")
        #expect(
            UploadError.from(UploadError.server("Boom"), service: "Svc") as? UploadError
                == .server("Boom"), "error.keepsUploadError")
        #expect(
            UploadError.from(CancellationError(), service: "Svc") is CancellationError,
            "error.keepsCancellation")
    }

    @Test func sharedSessionDoesNotCache() {
        #expect(UploadServices.session.configuration.urlCache == nil, "session.noCache")
    }
}
