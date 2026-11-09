import Cocoa

@MainActor
final class ShareJob {
    enum State: Equatable {
        case ready
        case preparing
        case running(Double?)
        case finished(ShareResult)
        case deleting(ShareResult)
        case failed(String)
    }

    static let droppedShareMessage = "Sharing stopped: the tunnel closed unexpectedly."

    let service: ShareService
    let file: URL
    var onChange: (@MainActor () -> Void)?
    private(set) var deletionError: String?
    private(set) var state = State.ready {
        didSet { onChange?() }
    }
    private var runID = 0
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init(service: ShareService, file: URL) {
        self.service = service
        self.file = file
    }

    var isActive: Bool {
        switch state {
        case .running, .deleting:
            return true
        case .finished(let result):
            return result.liveShare?.isActive == true
        case .ready, .preparing, .failed:
            return false
        }
    }

    func start(in window: NSWindow) {
        switch state {
        case .ready, .failed:
            break
        default:
            return
        }
        guard !service.isReadyToShare else {
            run()
            return
        }
        state = .preparing
        Task {
            if await service.prepareToShare(in: window) {
                run()
            } else {
                state = .ready
            }
        }
    }

    func cancel() {
        guard case .running = state else { return }
        task?.cancel()
        task = nil
        runID += 1
        endKeepingAwake()
        state = .ready
    }

    func stopSharing() {
        guard case .finished(let result) = state, let share = result.liveShare else { return }
        share.onEnd = nil
        share.stop()
        state = .ready
    }

    func halt() {
        cancel()
        stopSharing()
    }

    func delete() {
        guard case .finished(let result) = state, !result.deletionRequests.isEmpty else { return }
        deletionError = nil
        state = .deleting(result)
        Task {
            do {
                try await ShareServices.delete(result.deletionRequests, service: service.name)
                state = .ready
            } catch {
                deletionError = "Could not delete: \(error.localizedDescription)"
                state = .finished(result)
            }
        }
    }

    private func run() {
        runID += 1
        let id = runID
        deletionError = nil
        state = .running(service.isLiveShare ? nil : 0)
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: LiveShare.activityReason)
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            DispatchQueue.main.async { self?.report(fraction, runID: id) }
        }
        task = Task { [service, file] in
            do {
                finish(with: try await service.share(file, progress: progress), runID: id)
            } catch {
                fail(with: error, runID: id)
            }
        }
    }

    private func report(_ fraction: Double, runID id: Int) {
        guard id == runID, case .running = state else { return }
        state = .running(fraction < 1 ? fraction : nil)
    }

    private func finish(with result: ShareResult, runID id: Int) {
        guard id == runID else {
            undo(result)
            return
        }
        endKeepingAwake()
        task = nil
        if let share = result.liveShare {
            guard share.isActive else {
                state = .failed(ShareJob.droppedShareMessage)
                return
            }
            share.onEnd = { [weak self] reason in
                Log.write(reason)
                self?.state = .failed(ShareJob.droppedShareMessage)
            }
        }
        state = .finished(result)
    }

    private func fail(with error: Error, runID id: Int) {
        guard id == runID else { return }
        endKeepingAwake()
        task = nil
        switch error {
        case is CancellationError:
            state = .ready
        case ShareError.sessionExpired:
            state = .failed("\(service.name) session expired. Sign in again.")
        default:
            state = .failed(error.localizedDescription)
        }
    }

    private func undo(_ result: ShareResult) {
        result.liveShare?.stop()
        guard !result.deletionRequests.isEmpty else { return }
        let requests = result.deletionRequests
        let serviceName = service.name
        Task.detached { try? await ShareServices.delete(requests, service: serviceName) }
    }

    private func endKeepingAwake() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
