import CryptoKit
import Foundation
import Testing

@Suite(.serialized) struct SerialTests {}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(reading handle: FileHandle, byteCount: Int = .max) -> String {
    var hasher = SHA256()
    var remaining = byteCount
    while remaining > 0, autoreleasepool(invoking: {
        guard let chunk = try? handle.read(upToCount: min(remaining, 4 << 20)), !chunk.isEmpty else { return false }
        hasher.update(data: chunk)
        remaining -= chunk.count
        return true
    }) {}
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(ofFile url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    return sha256Hex(reading: handle)
}

final class Collector<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []

    func append(_ item: Item) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class WorkDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("SignDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String {
        url.path
    }

    func child(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func directory(_ name: String) throws -> URL {
        let directory = child(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func file(_ name: String, _ data: Data) -> URL {
        let file = child(name)
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: data)
        return file
    }
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

func isEventuallyTrue(isolation: isolated (any Actor)? = #isolation, _ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        await pause(0.05)
    }
    return condition()
}

func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return Double(info.resident_size) / 1_048_576
}

func peakResidentGrowth(during operation: () async -> Void) async -> Double {
    let before = residentMegabytes()
    let peak = Collector<Double>()
    let sampler = Task.detached {
        while !Task.isCancelled {
            peak.append(residentMegabytes())
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    await operation()
    sampler.cancel()
    return (peak.all.max() ?? before) - before
}
