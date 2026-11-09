import Foundation

final class MockStats {
    private let lock = NSLock()
    private var entries: [String: [String: Any]] = [:]

    @discardableResult
    func bump(_ scenario: String, _ key: String, _ values: [String: Any?] = [:]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[scenario] ?? [:]
        let count = (entry[key] as? Int ?? 0) + 1
        entry[key] = count
        for (name, value) in values {
            entry[name] = value
        }
        entries[scenario] = entry
        return count
    }

    func append(_ scenario: String, _ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[scenario] ?? [:]
        entry[key] = (entry[key] as? [Any] ?? []) + [value]
        entries[scenario] = entry
    }

    subscript(scenario: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return entries[scenario] ?? [:]
    }
}

func scenarioKind(_ scenario: String) -> String {
    scenario.components(separatedBy: "~")[0]
}
