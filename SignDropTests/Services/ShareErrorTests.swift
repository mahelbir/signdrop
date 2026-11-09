import Foundation
import Testing
@testable import SignDrop

struct ShareErrorTests {
    @Test func mapsTransportErrorsToUserTexts() {
        #expect(
            ShareError.from(URLError(.timedOut), service: "Svc") as? ShareError
                == .network("Request timed out. Check your connection or try again."),
            "error.timeout")
        #expect(
            ShareError.from(URLError(.timedOut), service: "Svc", stallTimeout: 3) as? ShareError
                == .network("Upload stalled — no data for 3s. Check your connection."),
            "error.stall")
        #expect(
            ShareError.from(URLError(.cannotConnectToHost), service: "Svc") as? ShareError
                == .network("Could not reach Svc. Check your connection."), "error.unreachable")
        #expect(
            ShareError.from(NSError(domain: NSPOSIXErrorDomain, code: 57), service: "Svc")
                as? ShareError == .network("Could not reach Svc. Check your connection."),
            "error.socket")
    }

    @Test func keepsCancellationAndShareErrors() {
        #expect(
            ShareError.from(URLError(.cancelled), service: "Svc") is CancellationError,
            "error.cancelled")
        #expect(
            ShareError.from(ShareError.server("Boom"), service: "Svc") as? ShareError
                == .server("Boom"), "error.keepsShareError")
        #expect(
            ShareError.from(CancellationError(), service: "Svc") is CancellationError,
            "error.keepsCancellation")
    }

    @Test func sharedSessionDoesNotCache() {
        #expect(ShareServices.session.configuration.urlCache == nil, "session.noCache")
    }
}
