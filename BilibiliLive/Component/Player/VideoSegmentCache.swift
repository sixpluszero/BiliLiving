import Foundation
import Swifter

struct VideoSegmentCacheSnapshot: Sendable {
    var position = 0.0
    var bufferedSeconds = 0.0
    var targetSeconds = 0.0
    var storedBytes = 0
    var activeDownloads = 0
    var hits = 0
    var misses = 0
    var videoHost: String?
    var audioHost: String?
    var lastError: String?
}

final class VideoSegmentCacheMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = VideoSegmentCacheSnapshot()

    var value: VideoSegmentCacheSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(_ value: VideoSegmentCacheSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshot = value
    }
}

actor VideoSegmentCache {
    static let downloadChunkBytes = 512 * 1024

    struct Segment: Sendable {
        let range: Range<Int>
        let start: Double
        let duration: Double

        var end: Double { start + duration }
    }

    struct Track: Sendable {
        let id: String
        let isVideo: Bool
        let isPrimary: Bool
        let mimeType: String
        let urls: [URL]
        // The initialization fragment is index zero.
        let segments: [Segment]
    }

    struct Response: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
        let range: Range<Int>
    }

    enum CacheError: LocalizedError {
        case invalidTrack
        case invalidRange
        case invalidResponse(String)
        case unavailable(String)
        case capacity

        var errorDescription: String? {
            switch self {
            case .invalidTrack: return "Unknown or invalid media segment"
            case .invalidRange: return "Invalid media byte range"
            case let .invalidResponse(message): return "Invalid segment response: \(message)"
            case let .unavailable(message): return "Segment download failed: \(message)"
            case .capacity: return "Media segment exceeds the disk cache budget"
            }
        }
    }

    private struct Key: Hashable, Sendable {
        let track: String
        let index: Int
        var offset = 0
    }

    private struct Entry {
        let file: URL
        let bytes: Int
    }

    private struct Download: Sendable {
        let file: URL
        let bytes: Int
        let source: Int
        let host: String
        let totalSize: Int
        let elapsed: TimeInterval
        let failedSources: [Int]
    }

    struct SourceHealth {
        private var rates = [Int: Double]()
        private var retryAfter = [Int: Date]()
        private var selections = 0

        mutating func select(count: Int, inFlight: Set<Int>, now: Date = Date()) -> Int {
            let available = (0..<count).filter { retryAfter[$0].map { $0 <= now } ?? true }
            let candidates = available.isEmpty ? Array(0..<count) : available
            selections += 1
            if let unmeasured = candidates.first(where: { rates[$0] == nil && !inFlight.contains($0) }) {
                return unmeasured
            }
            let ranked = candidates.sorted {
                let lhs = rates[$0] ?? 0
                let rhs = rates[$1] ?? 0
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }
            // Re-evaluate alternatives with useful media, never extra probes.
            if selections.isMultiple(of: 16),
               let alternate = ranked.dropFirst().first(where: { !inFlight.contains($0) }) {
                return alternate
            }
            return ranked.first ?? 0
        }

        mutating func record(source: Int, bytes: Int, elapsed: TimeInterval,
                             failedSources: [Int], now: Date = Date()) {
            for failed in failedSources { retryAfter[failed] = now.addingTimeInterval(15) }
            retryAfter[source] = nil
            guard bytes >= 32 * 1024, elapsed.isFinite, elapsed > 0 else { return }
            let rate = Double(bytes) / elapsed
            rates[source] = rates[source].map { $0 * 0.65 + rate * 0.35 } ?? rate
        }
    }

    private final class DownloadValidator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let range: Range<Int>
        private let totalSize: Int?
        private let lock = NSLock()
        private var failure: Error?

        init(range: Range<Int>, totalSize: Int?) {
            self.range = range
            self.totalSize = totalSize
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            do {
                guard totalBytesWritten <= range.count,
                      let response = downloadTask.response as? HTTPURLResponse else {
                    throw CacheError.invalidResponse("response exceeds the requested range")
                }
                // Reject ignored/mismatched ranges before downloading a whole
                // video. The completed file's actual size is checked separately.
                _ = try VideoSegmentCache.validateResponse(response, bytes: range.count,
                                                            range: range, totalSize: totalSize)
            } catch {
                lock.lock()
                failure = error
                lock.unlock()
                downloadTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    private struct Job {
        let token: UUID
        let bytes: Int
        let source: Int
        let task: Task<Void, Never>
    }

    private let directory: URL
    private let session: URLSession
    private let headers: [String: String]
    private let maximumBytes: Int
    private let concurrency: Int
    private let diagnosticID: String
    private let monitor: VideoSegmentCacheMonitor
    private var tracks = [String: Track]()
    private var activeTracks = Set<String>()
    private var sourceHealth = [String: SourceHealth]()
    private var totalSizes = [String: Int]()
    private var entries = [Key: Entry]()
    private var jobs = [Key: Job]()
    private var waiters = [Key: [UUID: CheckedContinuation<Data, Error>]]()
    private var demandOrder = [Key]()
    private var previewOrder = [Key]()
    private var retryAfter = [Key: Date]()
    private var retryTask: Task<Void, Never>?
    private var position = 0.0
    private var target = 0.0
    private var prefetchEnabled = false
    private var stopped = false
    private var state = VideoSegmentCacheSnapshot()

    static func removeAbandonedCaches() {
        do {
            let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            for url in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
                let name = url.lastPathComponent
                guard name.hasPrefix("PlaybackSegments-"),
                      UUID(uuidString: String(name.dropFirst("PlaybackSegments-".count))) != nil,
                      try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            Logger.warn("[segment-cache] abandoned cache cleanup failed: \(PlaybackDiagnostics.error(error))")
        }
    }

    init(directory: URL? = nil, headers: [String: String], diagnosticID: String,
         monitor: VideoSegmentCacheMonitor = VideoSegmentCacheMonitor(),
         maximumBytes: Int = 1024 * 1024 * 1024, concurrency: Int = 8) throws {
        let base = try directory ?? FileManager.default.url(for: .cachesDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
        self.directory = base.appendingPathComponent("PlaybackSegments-\(UUID().uuidString)", isDirectory: true)
        self.headers = headers
        self.diagnosticID = diagnosticID
        self.monitor = monitor
        self.maximumBytes = max(1, maximumBytes)
        self.concurrency = max(1, concurrency)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = max(1, concurrency)
        session = URLSession(configuration: configuration)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func register(_ track: Track) throws {
        guard !stopped else { throw CancellationError() }
        if tracks[track.id] != nil { return }
        guard !track.urls.isEmpty, track.urls.allSatisfy({ ["https", "http"].contains($0.scheme) }),
              !track.segments.isEmpty,
              track.segments.allSatisfy({
                  $0.range.lowerBound >= 0 && !$0.range.isEmpty
                      && $0.range.count <= min(maximumBytes, 64 * 1024 * 1024)
                      && $0.start.isFinite && $0.duration.isFinite && $0.duration >= 0
              }) else { throw CacheError.invalidTrack }
        tracks[track.id] = track
        if track.isPrimary { activeTracks.insert(track.id) }
        publish()
    }

    func prebuffer(at time: Double, target: Double, minimum: Double = 30,
                   maximumWait: TimeInterval = 30) async throws {
        guard time.isFinite, time >= 0, target.isFinite, target > 0,
              minimum.isFinite, minimum >= 0, maximumWait.isFinite, maximumWait >= 0 else {
            throw CacheError.invalidRange
        }
        guard !stopped else { throw CancellationError() }
        position = time
        self.target = target
        prefetchEnabled = true
        trimObsoleteEntries()
        pump()
        let started = ProcessInfo.processInfo.systemUptime
        let remaining = activeTracks.compactMap { tracks[$0]?.segments.last?.end }.min().map { max(0, $0 - time) } ?? 0
        let required = min(minimum, target, remaining)
        while forwardBuffer() + 0.05 < required,
              ProcessInfo.processInfo.systemUptime - started < maximumWait {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let remainingWait = maximumWait - (ProcessInfo.processInfo.systemUptime - started)
            if remainingWait > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(0.1, remainingWait) * 1_000_000_000))
            }
        }
        try Task.checkCancellation()
        Logger.info("[segment-cache] id=\(diagnosticID) prebuffer position=\(time) buffered=\(forwardBuffer())s target=\(target)s elapsed=\(ProcessInfo.processInfo.systemUptime - started)s deadlineReached=\(forwardBuffer() + 0.05 < required)")
    }

    func updatePosition(_ time: Double, target: Double) {
        guard !stopped, time.isFinite, time >= 0, target.isFinite, target > 0 else { return }
        position = time
        self.target = target
        trimObsoleteEntries()
        pump()
    }

    func responseMetadata(track id: String, index: Int, rangeHeader: String?) throws -> Response {
        guard !stopped else { throw CancellationError() }
        guard let track = tracks[id], track.segments.indices.contains(index) else {
            throw CacheError.invalidTrack
        }
        let length = track.segments[index].range.count
        let range = try Self.responseRange(rangeHeader, length: length)
        var headers = ["Content-Type": track.mimeType, "Content-Length": "\(range.count)",
                       "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if rangeHeader != nil {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)"
        }
        return Response(data: Data(), status: rangeHeader == nil ? 200 : 206, headers: headers, range: range)
    }

    func response(track id: String, index: Int, rangeHeader: String?, headOnly: Bool = false,
                  isPreview: Bool = false) async throws -> Response {
        let metadata = try responseMetadata(track: id, index: index, rangeHeader: rangeHeader)
        guard !headOnly else { return metadata }
        guard let track = tracks[id] else { throw CacheError.invalidTrack }
        if index > 0, !isPreview {
            activeTracks = activeTracks.filter { tracks[$0]?.isVideo != track.isVideo || $0 == id }
            activeTracks.insert(id)
        }
        var body = Data()
        let range = metadata.range
        let firstOffset = range.lowerBound / Self.downloadChunkBytes * Self.downloadChunkBytes
        for offset in stride(from: firstOffset, to: range.upperBound, by: Self.downloadChunkBytes) {
            try Task.checkCancellation()
            let chunk = try await data(for: Key(track: id, index: index, offset: offset), isPreview: isPreview)
            let lower = max(0, range.lowerBound - offset)
            let upper = min(chunk.count, range.upperBound - offset)
            body.append(chunk[lower..<upper])
        }
        return Response(data: body, status: metadata.status, headers: metadata.headers, range: range)
    }

    static func responseRange(_ header: String?, length: Int) throws -> Range<Int> {
        guard length > 0 else { throw CacheError.invalidRange }
        guard let header else { return 0..<length }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw CacheError.invalidRange }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw CacheError.invalidRange }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { throw CacheError.invalidRange }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { throw CacheError.invalidRange }
        if parts[1].isEmpty { return start..<length }
        guard let end = Int(parts[1]), end >= start else { throw CacheError.invalidRange }
        return start..<(min(end, length - 1) + 1)
    }

    static func validateResponse(_ response: HTTPURLResponse, bytes: Int, range: Range<Int>,
                                 totalSize: Int? = nil) throws -> Int {
        guard response.statusCode == 206,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ") else {
            throw CacheError.invalidResponse("expected HTTP 206 with Content-Range, got \(response.statusCode)")
        }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let size = Int(parts[1]), size >= range.upperBound,
              totalSize == nil || totalSize == size else {
            throw CacheError.invalidResponse("inconsistent resource length")
        }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, Int(bounds[0]) == range.lowerBound,
              Int(bounds[1]) == range.upperBound - 1, bytes == range.count else {
            throw CacheError.invalidResponse("truncated or mismatched Range")
        }
        return size
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        jobs.values.forEach { $0.task.cancel() }
        jobs.removeAll()
        session.invalidateAndCancel()
        waiters.values.flatMap(\.values).forEach { $0.resume(throwing: CancellationError()) }
        waiters.removeAll()
        demandOrder.removeAll()
        previewOrder.removeAll()
        entries.removeAll()
        state.storedBytes = 0
        removeFile(directory)
        publish()
    }

    private func data(for key: Key, isPreview: Bool) async throws -> Data {
        if let entry = entries[key] {
            do {
                let data = try Data(contentsOf: entry.file, options: .mappedIfSafe)
                guard data.count == entry.bytes else { throw CacheError.invalidResponse("cached file was truncated") }
                state.hits += 1
                publish()
                return data
            } catch {
                Logger.warn("[segment-cache] id=\(diagnosticID) cache-read failed: \(PlaybackDiagnostics.error(error))")
                removeEntry(key)
            }
        }
        state.misses += 1
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: [:]][token] = continuation
                if isPreview {
                    if !previewOrder.contains(key) { previewOrder.append(key) }
                } else if !demandOrder.contains(key) {
                    demandOrder.append(key)
                }
                retryAfter[key] = nil
                pump()
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, token: token) }
        }
    }

    private func cancelWaiter(key: Key, token: UUID) {
        waiters[key]?.removeValue(forKey: token)?.resume(throwing: CancellationError())
        if waiters[key]?.isEmpty == true {
            waiters[key] = nil
            demandOrder.removeAll { $0 == key }
            previewOrder.removeAll { $0 == key }
        }
    }

    private func wantedKeys() -> [Key] {
        guard prefetchEnabled else { return [] }
        return activeTracks.sorted().flatMap { id -> [Key] in
            guard let track = tracks[id] else { return [] }
            return track.segments.enumerated().flatMap { index, segment -> [Key] in
                guard index == 0 || (segment.end > position && segment.start < position + target) else { return [] }
                return chunkKeys(track: track, index: index)
            }
        }.sorted {
            let lhs = $0.index == 0 ? -1 : tracks[$0.track]?.segments[$0.index].start ?? 0
            let rhs = $1.index == 0 ? -1 : tracks[$1.track]?.segments[$1.index].start ?? 0
            if lhs != rhs { return lhs < rhs }
            let lhsVideo = tracks[$0.track]?.isVideo ?? false
            let rhsVideo = tracks[$1.track]?.isVideo ?? false
            if lhsVideo != rhsVideo { return !lhsVideo }
            return $0.track == $1.track ? $0.offset < $1.offset : $0.track < $1.track
        }
    }

    private func chunkKeys(track: Track, index: Int) -> [Key] {
        stride(from: 0, to: track.segments[index].range.count, by: Self.downloadChunkBytes).map {
            Key(track: track.id, index: index, offset: $0)
        }
    }

    private func hasSegment(track: Track, index: Int) -> Bool {
        chunkKeys(track: track, index: index).allSatisfy { entries[$0] != nil }
    }

    private func pump() {
        guard !stopped else { return }
        let wanted = wantedKeys()
        let wantedSet = Set(wanted)
        for (key, job) in jobs where waiters[key] == nil && !wantedSet.contains(key) {
            job.task.cancel()
            jobs[key] = nil
        }
        if jobs.count >= concurrency, demandOrder.contains(where: { jobs[$0] == nil }),
           let victim = jobs.keys.filter({ !demandOrder.contains($0) }).max(by: {
               abs((tracks[$0.track]?.segments[$0.index].start ?? 0) - position)
                   < abs((tracks[$1.track]?.segments[$1.index].start ?? 0) - position)
           }) {
            jobs.removeValue(forKey: victim)?.task.cancel()
        }
        var candidates = demandOrder + wanted.filter { !demandOrder.contains($0) }
        let previews = previewOrder.filter { !candidates.contains($0) }
        candidates.append(contentsOf: previews)
        while jobs.count < concurrency, !candidates.isEmpty {
            let key = candidates.removeFirst()
            guard entries[key] == nil, jobs[key] == nil,
                  retryAfter[key].map({ $0 <= Date() }) ?? true,
                  let track = tracks[key.track] else { continue }
            let bytes = min(Self.downloadChunkBytes, track.segments[key.index].range.count - key.offset)
            let reserved = jobs.values.reduce(0) { $0 + $1.bytes }
            if state.storedBytes + reserved + bytes > maximumBytes {
                makeRoom(for: bytes + reserved, protecting: key, demand: waiters[key] != nil)
                guard state.storedBytes + reserved + bytes <= maximumBytes else { continue }
            }
            let token = UUID()
            var health = sourceHealth[key.track] ?? SourceHealth()
            let activeSources = Set(jobs.compactMap { $0.key.track == key.track ? $0.value.source : nil })
            let source = health.select(count: track.urls.count, inFlight: activeSources)
            sourceHealth[key.track] = health
            let expectedTotal = totalSizes[key.track]
            let directory = directory
            let session = session
            let headers = headers
            let diagnosticID = diagnosticID
            let task = Task { [weak self] in
                let result: Result<Download, Error>
                do {
                    result = .success(try await Self.download(track: track, index: key.index, offset: key.offset,
                        preferredSource: source, expectedTotal: expectedTotal, session: session,
                        headers: headers, directory: directory, diagnosticID: diagnosticID))
                } catch { result = .failure(error) }
                await self?.complete(key: key, token: token, result: result)
            }
            jobs[key] = Job(token: token, bytes: bytes, source: source, task: task)
        }
        if retryTask == nil, wanted.contains(where: { retryAfter[$0] != nil }) {
            retryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                await self?.retry()
            }
        }
        publish()
    }

    private func retry() {
        retryTask = nil
        pump()
    }

    private func complete(key: Key, token: UUID, result: Result<Download, Error>) {
        guard !stopped, jobs[key]?.token == token else {
            if case let .success(download) = result { removeFile(download.file) }
            return
        }
        jobs[key] = nil
        let recipients = waiters.removeValue(forKey: key)?.values.map { $0 } ?? []
        demandOrder.removeAll { $0 == key }
        previewOrder.removeAll { $0 == key }
        do {
            let download = try result.get()
            guard totalSizes[key.track] == nil || totalSizes[key.track] == download.totalSize else {
                removeFile(download.file)
                throw CacheError.invalidResponse("CDN resources have different lengths")
            }
            entries[key] = Entry(file: download.file, bytes: download.bytes)
            state.storedBytes += download.bytes
            totalSizes[key.track] = download.totalSize
            sourceHealth[key.track, default: SourceHealth()].record(
                source: download.source, bytes: download.bytes, elapsed: download.elapsed,
                failedSources: download.failedSources)
            retryAfter[key] = nil
            if tracks[key.track]?.isVideo == true { state.videoHost = download.host }
            else { state.audioHost = download.host }
            if !recipients.isEmpty {
                let data = try Data(contentsOf: download.file, options: .mappedIfSafe)
                recipients.forEach { $0.resume(returning: data) }
            }
        } catch {
            removeEntry(key)
            retryAfter[key] = Date().addingTimeInterval(3)
            state.lastError = PlaybackDiagnostics.error(error)
            if !(error is CancellationError) {
                Logger.warn("[segment-cache] id=\(diagnosticID) track=\(key.track) segment=\(key.index) offset=\(key.offset) unavailable: \(PlaybackDiagnostics.error(error))")
            }
            recipients.forEach { $0.resume(throwing: error) }
        }
        pump()
    }

    private static func download(track: Track, index: Int, offset: Int, preferredSource: Int, expectedTotal: Int?,
                                 session: URLSession, headers: [String: String], directory: URL,
                                 diagnosticID: String) async throws -> Download {
        let segment = track.segments[index]
        let startOffset = segment.range.lowerBound + offset
        let range = startOffset..<min(segment.range.upperBound, startOffset + downloadChunkBytes)
        let sources = [preferredSource] + track.urls.indices.filter { $0 != preferredSource }
        var lastError = "no available CDN"
        var failedSources = [Int]()
        for source in sources {
            try Task.checkCancellation()
            let url = track.urls[source]
            let host = url.host ?? "-"
            let start = ProcessInfo.processInfo.systemUptime
            let validator = DownloadValidator(range: range, totalSize: expectedTotal)
            var temporaryFile: URL?
            do {
                var request = URLRequest(url: url)
                request.allHTTPHeaderFields = headers
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (file, response) = try await session.download(for: request, delegate: validator)
                temporaryFile = file
                try Task.checkCancellation()
                if let error = validator.error { throw error }
                guard let response = response as? HTTPURLResponse else {
                    throw CacheError.invalidResponse("non-HTTP response")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber else {
                    throw CacheError.invalidResponse("missing downloaded file size")
                }
                let total = try validateResponse(response, bytes: size.intValue, range: range,
                                                 totalSize: expectedTotal)
                let destination = directory.appendingPathComponent(UUID().uuidString + ".m4s")
                try FileManager.default.moveItem(at: file, to: destination)
                temporaryFile = nil
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let actualHost = response.url?.host ?? host
                Logger.info("[segment-cache] id=\(diagnosticID) track=\(track.id) segment=\(index) offset=\(offset) host=\(actualHost) bytes=\(size.intValue) mediaSeconds=\(segment.duration) elapsed=\(elapsed)s totalMbps=\(Double(size.intValue) * 8 / max(elapsed, 0.001) / 1_000_000) alternate=\(source != preferredSource)")
                return Download(file: destination, bytes: size.intValue, source: source, host: actualHost,
                                totalSize: total, elapsed: elapsed, failedSources: failedSources)
            } catch {
                if let temporaryFile {
                    do { try FileManager.default.removeItem(at: temporaryFile) }
                    catch { Logger.warn("[segment-cache] temporary file cleanup: \(PlaybackDiagnostics.error(error))") }
                }
                try Task.checkCancellation()
                lastError = PlaybackDiagnostics.error(validator.error ?? error)
                failedSources.append(source)
                Logger.warn("[segment-cache] id=\(diagnosticID) track=\(track.id) segment=\(index) offset=\(offset) host=\(host) retry-next-CDN error=\(lastError)")
            }
        }
        throw CacheError.unavailable(lastError)
    }

    private func forwardBuffer() -> Double {
        activeTracks.compactMap { id -> Double? in
            guard let track = tracks[id] else { return nil }
            guard hasSegment(track: track, index: 0) else { return 0 }
            var end = position
            for (index, segment) in track.segments.enumerated() where index > 0 && segment.end > position {
                guard segment.start <= end + 0.05, hasSegment(track: track, index: index) else { break }
                end = segment.end
            }
            return max(0, end - position)
        }.min() ?? 0
    }

    private func trimObsoleteEntries() {
        for key in Array(entries.keys) {
            guard key.index > 0, let segment = tracks[key.track]?.segments[key.index] else { continue }
            if !activeTracks.contains(key.track) || segment.end < position - 30 || segment.start > position + target + 30 {
                removeEntry(key)
            }
        }
    }

    private func makeRoom(for bytes: Int, protecting key: Key, demand: Bool) {
        let removable = entries.keys.filter {
            $0 != key && $0.index > 0 && (demand || (tracks[$0.track]?.segments[$0.index].end ?? .infinity) <= position)
        }.sorted {
            let lhs = abs((tracks[$0.track]?.segments[$0.index].start ?? 0) - position)
            let rhs = abs((tracks[$1.track]?.segments[$1.index].start ?? 0) - position)
            return lhs > rhs
        }
        for candidate in removable where state.storedBytes + bytes > maximumBytes { removeEntry(candidate) }
    }

    private func removeEntry(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        state.storedBytes -= entry.bytes
        removeFile(entry.file)
    }

    private func removeFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { Logger.warn("[segment-cache] file cleanup failed: \(PlaybackDiagnostics.error(error))") }
    }

    private func publish() {
        state.position = position
        state.bufferedSeconds = forwardBuffer()
        state.targetSeconds = target
        state.activeDownloads = jobs.count
        monitor.update(state)
    }
}

final class VideoSegmentCacheServer: @unchecked Sendable {
    let cache: VideoSegmentCache
    let monitor: VideoSegmentCacheMonitor
    private let server = HttpServer()
    private let token = UUID().uuidString
    private(set) var port = 0

    init(headers: [String: String], diagnosticID: String) throws {
        monitor = VideoSegmentCacheMonitor()
        cache = try VideoSegmentCache(headers: headers, diagnosticID: diagnosticID, monitor: monitor)
        server.listenAddressIPv4 = "127.0.0.1"
        server["/\(token)/:kind/:track/:segment"] = { [weak self] request in
            guard let self, let track = request.params[":track"],
                  let segment = request.params[":segment"].flatMap(Int.init),
                  let kind = request.params[":kind"], ["media", "preview"].contains(kind),
                  ["GET", "HEAD"].contains(request.method) else {
                return .badRequest(.text("Invalid media request"))
            }
            let pending = PendingResponse()
            let cache = self.cache
            let range = request.headers["range"]
            let headOnly = request.method == "HEAD"
            let task = Task {
                do {
                    pending.finish(.success(try await cache.responseMetadata(track: track, index: segment,
                                                                            rangeHeader: range)))
                } catch { pending.finish(.failure(error)) }
            }
            guard let result = pending.wait() else {
                task.cancel()
                Logger.warn("[segment-cache] local media request timed out")
                return .raw(504, "Gateway Timeout", ["Content-Length": "0"], nil)
            }
            switch result {
            case let .success(response):
                return .raw(response.status, response.status == 206 ? "Partial Content" : "OK",
                            response.headers) { writer in
                    guard !headOnly else { return }
                    // Send headers immediately, then verified chunks as they
                    // arrive. A large fragment must not look like a silent CDN.
                    var offset = response.range.lowerBound
                    while offset < response.range.upperBound {
                        let end = min(response.range.upperBound,
                                      (offset / VideoSegmentCache.downloadChunkBytes + 1) * VideoSegmentCache.downloadChunkBytes)
                        let pending = PendingResponse()
                        let header = "bytes=\(offset)-\(end - 1)"
                        let task = Task {
                            do {
                                pending.finish(.success(try await cache.response(
                                    track: track, index: segment, rangeHeader: header, isPreview: kind == "preview")))
                            } catch { pending.finish(.failure(error)) }
                        }
                        guard let result = pending.wait() else {
                            task.cancel()
                            Logger.warn("[segment-cache] local media chunk timed out")
                            throw VideoSegmentCache.CacheError.unavailable("local media chunk timed out")
                        }
                        do { try writer.write(result.get().data) }
                        catch {
                            task.cancel()
                            Logger.warn("[segment-cache] local media stream interrupted: \(PlaybackDiagnostics.error(error))")
                            throw error
                        }
                        offset = end
                    }
                }
            case let .failure(error):
                Logger.warn("[segment-cache] local media request failed: \(PlaybackDiagnostics.error(error))")
                let status = (error as? VideoSegmentCache.CacheError).map {
                    if case .invalidRange = $0 { return 416 }
                    if case .invalidTrack = $0 { return 404 }
                    return 503
                } ?? 503
                return .raw(status, "Media Unavailable", ["Content-Length": "0"], nil)
            }
        }
        do {
            try server.start(0, forceIPv4: true, priority: .userInitiated)
            port = try server.port()
        } catch {
            let cache = cache
            Task { await cache.stop() }
            throw error
        }
    }

    func url(track: String, index: Int, isPreview: Bool = false) -> String {
        "http://127.0.0.1:\(port)/\(token)/\(isPreview ? "preview" : "media")/\(track)/\(index)"
    }

    func stop() {
        let cache = cache
        Task { await cache.stop() }
        server.stop()
    }

    deinit { stop() }

    // Swifter invokes handlers on its GCD client queues, never on the main
    // actor. Bridge only there; all network I/O and cache scheduling stay async.
    private final class PendingResponse: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<VideoSegmentCache.Response, Error>?

        func finish(_ result: Result<VideoSegmentCache.Response, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> Result<VideoSegmentCache.Response, Error>? {
            guard semaphore.wait(timeout: .now() + 30) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }
}
