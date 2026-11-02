import Foundation

public enum WorkState: String, Sendable, Equatable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct WorkItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var state: WorkState
    public var progress: Double
    public var detail: String?
    public var outputPath: String?

    public init(
        id: String,
        title: String,
        state: WorkState = .queued,
        progress: Double = 0,
        detail: String? = nil,
        outputPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.progress = progress
        self.detail = detail
        self.outputPath = outputPath
    }

    var contribution: Double {
        switch state {
        case .queued:
            return 0
        case .running:
            return min(1, max(0, progress))
        case .succeeded, .failed, .cancelled:
            return 1
        }
    }
}

/// One conversion at a time. The runner asks `nextID()` and does the work.
public struct WorkQueue: Equatable, Sendable {
    public private(set) var items: [WorkItem]

    public init(items: [WorkItem] = []) {
        self.items = items
    }

    @discardableResult
    public mutating func enqueue(id: String, title: String) -> Bool {
        guard !id.isEmpty, !items.contains(where: { $0.id == id }) else { return false }
        items.append(WorkItem(id: id, title: title))
        return true
    }

    public func runningID() -> String? {
        items.first { $0.state == .running }?.id
    }

    /// The first queued item, and only when nothing is already running.
    public func nextID() -> String? {
        guard runningID() == nil else { return nil }
        return items.first { $0.state == .queued }?.id
    }

    @discardableResult
    public mutating func markRunning(_ id: String) -> Bool {
        guard runningID() == nil, let index = index(of: id), items[index].state == .queued else { return false }
        items[index].state = .running
        items[index].progress = 0
        return true
    }

    @discardableResult
    public mutating func setProgress(_ id: String, _ progress: Double) -> Bool {
        guard let index = index(of: id), items[index].state == .running else { return false }
        items[index].progress = min(1, max(0, progress))
        return true
    }

    @discardableResult
    public mutating func succeed(_ id: String, outputPath: String) -> Bool {
        guard let index = index(of: id), items[index].state == .running else { return false }
        items[index].state = .succeeded
        items[index].progress = 1
        items[index].outputPath = outputPath
        items[index].detail = nil
        return true
    }

    /// Queued items can fail without running. That is how a plan records a skip.
    @discardableResult
    public mutating func fail(_ id: String, message: String) -> Bool {
        guard let index = index(of: id) else { return false }
        switch items[index].state {
        case .queued, .running:
            items[index].state = .failed
            items[index].progress = 1
            items[index].detail = message
            return true
        case .succeeded, .failed, .cancelled:
            return false
        }
    }

    @discardableResult
    public mutating func cancelQueued() -> [String] {
        var ids: [String] = []
        for index in items.indices where items[index].state == .queued {
            items[index].state = .cancelled
            items[index].detail = "Stopped before it started."
            ids.append(items[index].id)
        }
        return ids
    }

    @discardableResult
    public mutating func finishCancelled(_ id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        switch items[index].state {
        case .queued, .running:
            items[index].state = .cancelled
            items[index].progress = 1
            items[index].detail = "Stopped."
            return true
        case .succeeded, .failed, .cancelled:
            return false
        }
    }

    public var finishedCount: Int {
        items.filter { $0.state == .succeeded || $0.state == .failed || $0.state == .cancelled }.count
    }

    public var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { $0 + $1.contribution }
        return sum / Double(items.count)
    }

    private func index(of id: String) -> Int? {
        items.firstIndex { $0.id == id }
    }
}
