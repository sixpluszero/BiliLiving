import Foundation

enum VideoCacheDiagnostics {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-CacheDiagnostics")

    struct Gap: Sendable {
        let track: String
        let isVideo: Bool
        let segment: Int
        let start: Double
        let end: Double
        let requiredBytes: Int
        let cachedBytes: Int
        let missingBlocks: Int
        let firstMissingOffset: Int
        let firstMissingState: String
        let cachedBytesBeyondGap: Int
    }

    struct Window: Sendable {
        let capturedAt: TimeInterval
        let positionUpdatedAt: TimeInterval
        let playerPosition: Double
        let cachePosition: Double
        let bufferedSeconds: Double
        let residentBytes: Int
        let validatedBytes: Int
        let evictedBytes: Int
        let activeDownloads: Int
        let pendingBlocks: Int
        let cooldownBlocks: Int
        let reservedBytes: Int
        let gaps: [Gap]
    }
}

/// Progress callbacks only update this small locked record; no per-packet
/// logging or actor hops are added to the transfer's critical path.
final class CacheTransferTrace: @unchecked Sendable {
    struct State: Sendable {
        let scheduledAt: TimeInterval
        var startedAt: TimeInterval?
        var firstByteAt: TimeInterval?
        var lastByteAt: TimeInterval?
        var receivedBytes = 0
        var attempt = 0
        var host = "-"
        var source = -1
        var taskID = -1
        var progressObserved = false
        var taskState = "unknown"

        func fields(at now: TimeInterval) -> String {
            let age = max(0, now - (startedAt ?? scheduledAt))
            let idle = lastByteAt.map { max(0, now - $0) } ?? age
            let phase = startedAt == nil ? "scheduled" : !progressObserved ? "not-observed" : firstByteAt == nil ? "awaiting-bytes" : "has-bytes"
            return "attempt=\(attempt) host=\(host) source=\(source) task=\(taskID) taskState=\(taskState) phase=\(phase) progressObserved=\(progressObserved) received=\(receivedBytes) ageMs=\(Int(age * 1000)) lastIncreaseObservedMs=\(Int(idle * 1000))"
        }
    }

    private let lock = NSLock()
    private let context: String
    private var state: State
    private var metrics: URLSessionTaskMetrics?

    init(context: String, scheduledAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.context = context
        state = State(scheduledAt: scheduledAt)
    }

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func begin(host: String, source: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        let scheduledAt = state.scheduledAt
        let attempt = state.attempt + 1
        state = State(scheduledAt: scheduledAt, startedAt: now, attempt: attempt, host: host, source: source)
        metrics = nil
        lock.unlock()
        Logger.info("[cache-request] \(context) event=start attempt=\(attempt) host=\(host) source=\(source) uptime=\(now) sinceScheduledMs=\(Int((now - scheduledAt) * 1000))")
    }

    func progress(totalBytes: Int, taskID: Int, taskState: String = "running",
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        state.taskID = taskID
        state.taskState = taskState
        state.progressObserved = true
        if totalBytes > state.receivedBytes {
            if state.firstByteAt == nil { state.firstByteAt = now }
            state.lastByteAt = now
            state.receivedBytes = totalBytes
        }
    }

    func collected(_ metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func finish(outcome: String, error: Error? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        let state = state
        let metrics = metrics
        lock.unlock()
        let transaction = metrics?.transactionMetrics.last
        let status = (transaction?.response as? HTTPURLResponse)?.statusCode ?? -1
        Logger.info("[cache-request] \(context) event=end outcome=\(outcome) uptime=\(now) \(state.fields(at: now)) status=\(status) bodyBytes=\(transaction?.countOfResponseBodyBytesReceived ?? -1) remoteIP=\(transaction?.remoteAddress ?? "-") \(PlaybackDiagnostics.networkMetrics(metrics)) error=\(PlaybackDiagnostics.error(error))")
    }
}
