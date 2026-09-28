import Foundation

/// Small LRU cache of completed definitions keyed by word + sentence.
public final class LookupCache: @unchecked Sendable {
    private var storage: [LookupRequest: WordDefinition] = [:]
    private var order: [LookupRequest] = []
    private let capacity: Int
    private let lock = NSLock()

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    public func get(_ request: LookupRequest) -> WordDefinition? {
        lock.lock(); defer { lock.unlock() }
        guard let value = storage[request] else { return nil }
        order.removeAll { $0 == request }
        order.append(request)
        return value
    }

    public func set(_ request: LookupRequest, _ value: WordDefinition) {
        lock.lock(); defer { lock.unlock() }
        if storage[request] == nil { order.append(request) }
        storage[request] = value
        while order.count > capacity {
            storage[order.removeFirst()] = nil
        }
    }
}
