import AppKit
import Foundation
@testable import SignDrop

@MainActor
final class ControlledShareService: ShareService {
    let name: String
    var accountName: String?
    var isSignInRequired = false
    var isReadyToShare = true
    var isLiveShare = false
    var isPrepareSuccessful = true
    var isCancellationIgnored = false
    private(set) var prepareWindows: [NSWindow] = []
    private(set) var shareCount = 0
    private(set) var progress: ((Double) -> Void)?
    private var pending: CheckedContinuation<ShareResult, Error>?

    init(name: String = "Fake Service") {
        self.name = name
    }

    func signIn(in window: NSWindow) async -> Bool {
        true
    }

    func prepareToShare(in window: NSWindow) async -> Bool {
        prepareWindows.append(window)
        if isPrepareSuccessful {
            isReadyToShare = true
        }
        return isPrepareSuccessful
    }

    func signOut() async {}

    func share(_ file: URL, progress: @escaping (Double) -> Void) async throws -> ShareResult {
        shareCount += 1
        self.progress = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, !self.isCancellationIgnored else { return }
                self.complete(.failure(CancellationError()))
            }
        }
    }

    func complete(_ result: Result<ShareResult, Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}
