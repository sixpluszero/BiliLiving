import XCTest
import AVKit
import Network
import Swifter
import CocoaAsyncSocket
@testable import BilibiliLive

final class BiliLivingTests: XCTestCase {
    func testCacheTransferTraceDistinguishesQueueFirstByteAndIdleTime() {
        let trace = CacheTransferTrace(context: "id=test", scheduledAt: 10)
        XCTAssertTrue(trace.snapshot.fields(at: 11).contains("phase=scheduled"))
        trace.begin(host: "cdn.example", source: 0, now: 11)
        XCTAssertTrue(trace.snapshot.fields(at: 12).contains("phase=not-observed"))
        trace.progress(totalBytes: 0, taskID: 7, now: 12)
        XCTAssertTrue(trace.snapshot.fields(at: 12).contains("phase=awaiting-bytes"))
        trace.progress(totalBytes: 100, taskID: 7, now: 12)
        trace.progress(totalBytes: 100, taskID: 7, now: 14)
        XCTAssertEqual(trace.snapshot.firstByteAt, 12)
        XCTAssertEqual(trace.snapshot.lastByteAt, 12, "Repeated counters do not mean bytes are arriving")
        XCTAssertEqual(trace.snapshot.receivedBytes, 100)
        XCTAssertTrue(trace.snapshot.fields(at: 15).contains("lastIncreaseObservedMs=3000"))
        trace.progress(totalBytes: 150, taskID: 7, now: 15)
        XCTAssertEqual(trace.snapshot.lastByteAt, 15)
        trace.begin(host: "alternate.example", source: 1, now: 16)
        XCTAssertEqual(trace.snapshot.attempt, 2)
        XCTAssertEqual(trace.snapshot.receivedBytes, 0)
        XCTAssertNil(trace.snapshot.firstByteAt)
        XCTAssertFalse(trace.snapshot.progressObserved)
        XCTAssertEqual(trace.snapshot.scheduledAt, 10)
    }

    func testCacheDiagnosticsSeparateContinuousGapFromResidentAndValidatedBytes() async throws {
        let origin = try SegmentCacheTestOrigin(failingOffset: 8)
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "diagnostic-gap", diagnosticsEnabled: true)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        try await cache.prebuffer(at: 0, target: 20, minimum: 20, maximumWait: 0.5)
        let snapshot = await cache.diagnosticWindow(at: 2)
        XCTAssertEqual(snapshot.cachePosition, 0, "Sampling must not advance the scheduler's playback position")
        XCTAssertEqual(snapshot.playerPosition, 2)
        XCTAssertEqual(snapshot.bufferedSeconds, 3, accuracy: 0.01)
        let gap = try XCTUnwrap(snapshot.gaps.first)
        XCTAssertEqual(gap.segment, 2)
        XCTAssertEqual(gap.start, 5)
        XCTAssertEqual(gap.cachedBytes, 0)
        XCTAssertEqual(gap.firstMissingOffset, 0)
        XCTAssertGreaterThan(gap.cachedBytesBeyondGap, 0)
        XCTAssertEqual(snapshot.validatedBytes, snapshot.residentBytes + snapshot.evictedBytes)
        XCTAssertGreaterThanOrEqual(snapshot.capturedAt, snapshot.positionUpdatedAt)
    }

    func testCacheDiagnosticSamplingDoesNotScheduleDownloads() async throws {
        let origin = try SegmentCacheTestOrigin()
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "diagnostic-passive",
                                         monitor: monitor, diagnosticsEnabled: true)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        try await cache.prebuffer(at: 0, target: 15, minimum: 15, maximumWait: 3)
        let requests = origin.requestCount
        let visible = monitor.value
        await cache.logDiagnostics(playerPosition: 40, nativeBuffer: 0, control: "waiting",
                                   trigger: "test", sampledAt: ProcessInfo.processInfo.systemUptime,
                                   visibleSnapshot: visible)
        let snapshot = await cache.diagnosticWindow(at: 40)
        XCTAssertEqual(snapshot.cachePosition, 0)
        XCTAssertEqual(origin.requestCount, requests)
        XCTAssertEqual(monitor.value.capturedAt, visible.capturedAt, "Reading diagnostic state must not publish new UI state")
        await cache.stop()
        let stopped = await cache.diagnosticWindow(at: 40)
        XCTAssertEqual(stopped.residentBytes, 0)
        XCTAssertEqual(stopped.validatedBytes, stopped.evictedBytes)
    }

    func testSegmentCacheValidatesRemoteAndLocalByteRanges() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/media"))
        let valid = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                                 headerFields: ["Content-Range": "bytes 4-7/100"]))
        XCTAssertEqual(try VideoSegmentCache.validateResponse(valid, bytes: 4, range: 4..<8), 100)
        XCTAssertThrowsError(try VideoSegmentCache.validateResponse(valid, bytes: 3, range: 4..<8))
        XCTAssertThrowsError(try VideoSegmentCache.validateResponse(valid, bytes: 4, range: 0..<4))
        XCTAssertThrowsError(try VideoSegmentCache.validateResponse(valid, bytes: 4, range: 4..<8, totalSize: 101))
        let ignored = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try VideoSegmentCache.validateResponse(ignored, bytes: 4, range: 4..<8))
        XCTAssertEqual(try VideoSegmentCache.responseRange(nil, length: 10), 0..<10)
        XCTAssertEqual(try VideoSegmentCache.responseRange("bytes=2-5", length: 10), 2..<6)
        XCTAssertEqual(try VideoSegmentCache.responseRange("bytes=8-", length: 10), 8..<10)
        XCTAssertEqual(try VideoSegmentCache.responseRange("bytes=-3", length: 10), 7..<10)
        XCTAssertEqual(try VideoSegmentCache.responseRange("bytes=8-100", length: 10), 8..<10)
        for invalid in ["bytes=10-", "bytes=5-2", "bytes=0-1,3-4", "bytes=-0", "bytes=x-y"] {
            XCTAssertThrowsError(try VideoSegmentCache.responseRange(invalid, length: 10))
        }
    }

    func testSegmentCacheRanksRealTransfersInsteadOfLastCompletingServer() {
        let now = Date()
        var health = VideoSegmentCache.SourceHealth()
        XCTAssertEqual(health.select(count: 2, inFlight: [], now: now), 0)
        XCTAssertEqual(health.select(count: 2, inFlight: [0], now: now), 1,
                       "An unmeasured alternative gets a real media block, not a synthetic probe")
        health.record(source: 0, bytes: 524_288, elapsed: 0.1, failedSources: [], now: now)
        health.record(source: 1, bytes: 524_288, elapsed: 4, failedSources: [], now: now)
        XCTAssertEqual(health.select(count: 2, inFlight: [], now: now), 0,
                       "A late slow response must not overwrite the faster preferred source")
        health.record(source: 1, bytes: 524_288, elapsed: 0.2, failedSources: [0], now: now)
        XCTAssertEqual(health.select(count: 2, inFlight: [], now: now), 1,
                       "A failed source must cool down even if its historical throughput was high")
        var single = VideoSegmentCache.SourceHealth()
        XCTAssertEqual(single.select(count: 1, inFlight: [0], now: now), 0)
    }

    func testSegmentCachePrefetchesWithoutPlayerRequestsAndServesDiskHits() async throws {
        let origin = try SegmentCacheTestOrigin()
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "prefetch-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        try await cache.prebuffer(at: 0, target: 20, minimum: 20, maximumWait: 3)
        XCTAssertGreaterThanOrEqual(monitor.value.bufferedSeconds, 20)
        XCTAssertEqual(monitor.value.misses, 0, "Prefetch must not wait for an AVPlayer request")
        let before = origin.requestCount
        let response = try await cache.response(track: "video", index: 2, rangeHeader: nil)
        XCTAssertEqual(response.data, origin.payload.subdata(in: 8..<12))
        XCTAssertEqual(origin.requestCount, before, "The complete fragment must come from disk")
        XCTAssertGreaterThan(monitor.value.hits, 0)
        XCTAssertLessThanOrEqual(origin.maximumActiveRequests, 8)
    }

    func testSegmentCacheRejectsTruncatedCDNAndRetriesSameFragment() async throws {
        let broken = try SegmentCacheTestOrigin(truncated: true)
        let healthy = try SegmentCacheTestOrigin()
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "failover-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); broken.stop(); healthy.stop() }
        try await cache.register(broken.track(urls: [broken.url, healthy.url]))
        let response = try await cache.response(track: "video", index: 3, rangeHeader: nil)
        XCTAssertEqual(response.data, healthy.payload.subdata(in: 12..<16))
        XCTAssertEqual(broken.requestCount, 1)
        XCTAssertEqual(healthy.requestCount, 1)
        let cached = try await cache.response(track: "video", index: 3, rangeHeader: "bytes=1-2")
        XCTAssertEqual(cached.status, 206)
        XCTAssertEqual(cached.headers["Content-Range"], "bytes 1-2/4")
        XCTAssertEqual(cached.data, healthy.payload.subdata(in: 13..<15))
        XCTAssertEqual(healthy.requestCount, 1)
        XCTAssertEqual(monitor.value.storedBytes, 4, "Never cache the truncated body")
    }

    func testSegmentCacheRejectsIgnoredRangeAndRetriesAlternate() async throws {
        let broken = try SegmentCacheTestOrigin(ignoresRange: true)
        let healthy = try SegmentCacheTestOrigin()
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "ignored-range-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); broken.stop(); healthy.stop() }
        try await cache.register(broken.track(urls: [broken.url, healthy.url]))
        let response = try await cache.response(track: "video", index: 3, rangeHeader: nil)
        XCTAssertEqual(response.data, healthy.payload.subdata(in: 12..<16))
        XCTAssertEqual(monitor.value.storedBytes, 4)
        XCTAssertEqual(broken.requestCount, 1)
        XCTAssertEqual(healthy.requestCount, 1)
    }

    func testSegmentCacheCoalescesRequestsAndCancelsOnStop() async throws {
        let origin = try SegmentCacheTestOrigin(delay: 0.2)
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "coalesce-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        async let first = cache.response(track: "video", index: 2, rangeHeader: nil)
        async let second = cache.response(track: "video", index: 2, rangeHeader: nil)
        let values = try await [first, second]
        XCTAssertEqual(values[0].data, values[1].data)
        XCTAssertEqual(origin.requestCount, 1)
        let pending = Task { try await cache.response(track: "video", index: 5, rangeHeader: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await cache.stop()
        do {
            _ = try await pending.value
            XCTFail("Stopped playback must cancel outstanding media requests")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertEqual(monitor.value.activeDownloads, 0)
        XCTAssertEqual(monitor.value.storedBytes, 0)
    }

    func testSegmentCacheBoundsDiskUsageAndRefillsAfterSeek() async throws {
        let origin = try SegmentCacheTestOrigin()
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "budget-test", monitor: monitor, maximumBytes: 20)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        try await cache.prebuffer(at: 0, target: 20, minimum: 20, maximumWait: 3)
        XCTAssertEqual(monitor.value.storedBytes, 20)
        try await cache.prebuffer(at: 30, target: 20, minimum: 15, maximumWait: 3)
        XCTAssertGreaterThanOrEqual(monitor.value.bufferedSeconds, 15)
        XCTAssertLessThanOrEqual(monitor.value.storedBytes, 20)
        let sought = try await cache.response(track: "video", index: 7, rangeHeader: nil)
        XCTAssertEqual(sought.data, origin.payload.subdata(in: 28..<32))
    }

    func testSegmentCacheWarmupHonorsWaitingBudget() async throws {
        let origin = try SegmentCacheTestOrigin(delay: 0.6)
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "deadline-test")
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        let start = ProcessInfo.processInfo.systemUptime
        try await cache.prebuffer(at: 0, target: 60, minimum: 30, maximumWait: 0.05)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5,
                          "A slow connection must not make the extra startup wait unbounded")
    }

    func testSegmentCacheDoesNotCountFragmentsBeyondAHole() async throws {
        let origin = try SegmentCacheTestOrigin(failingOffset: 8)
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "hole-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        try await cache.prebuffer(at: 0, target: 20, minimum: 20, maximumWait: 0.5)
        XCTAssertEqual(monitor.value.bufferedSeconds, 5, accuracy: 0.01)
        XCTAssertGreaterThan(monitor.value.storedBytes, 8, "Later downloaded fragments must not hide the missing one")
    }

    func testSegmentCacheRequiresAudioAsWellAsVideo() async throws {
        let video = try SegmentCacheTestOrigin()
        let audio = try SegmentCacheTestOrigin(truncated: true)
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "audio-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); video.stop(); audio.stop() }
        try await cache.register(video.track())
        try await cache.register(.init(id: "audio", isVideo: false, isPrimary: true, mimeType: "audio/mp4",
                                       urls: [audio.url], segments: audio.track().segments))
        try await cache.prebuffer(at: 0, target: 20, minimum: 20, maximumWait: 0.5)
        XCTAssertEqual(monitor.value.bufferedSeconds, 0)
        XCTAssertGreaterThan(monitor.value.storedBytes, 0, "Video alone is not continuous playable buffer")
    }

    func testSegmentCachePrioritizesPlaybackOverPreviewRequests() async throws {
        let origin = try SegmentCacheTestOrigin(delay: 0.2)
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "priority-test", concurrency: 1)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.track())
        let preview = Task { try await cache.response(track: "video", index: 18, rangeHeader: nil, isPreview: true) }
        try await eventually { origin.requestCount == 1 }
        let playback = try await cache.response(track: "video", index: 1, rangeHeader: nil)
        XCTAssertEqual(playback.data, origin.payload.subdata(in: 4..<8))
        XCTAssertEqual(Array(origin.requestedOffsets.prefix(2)), [72, 4])
        let previewData = try await preview.value.data
        XCTAssertEqual(previewData, origin.payload.subdata(in: 72..<76))
    }

    func testSegmentCacheLoopbackServerServesRangesAndHead() async throws {
        let origin = try SegmentCacheTestOrigin()
        let server = try VideoSegmentCacheServer(headers: [:], diagnosticID: "http-test")
        addTeardownBlock { server.stop(); origin.stop() }
        try await server.cache.register(origin.track())
        let url = try XCTUnwrap(URL(string: server.url(track: "video", index: 2)))
        XCTAssertEqual(url.host, "127.0.0.1")
        var request = URLRequest(url: url)
        request.setValue("bytes=1-2", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, origin.payload.subdata(in: 9..<11))
        request.httpMethod = "HEAD"
        let (headData, head) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "2")
        XCTAssertEqual(origin.requestCount, 1)
    }

    func testSegmentCacheResumesLargeFragmentWithoutRedownloadingVerifiedPrefix() async throws {
        let chunk = VideoSegmentCache.downloadChunkBytes
        let origin = try SegmentCacheTestOrigin(payloadBytes: 4 + chunk * 3, failOnceAt: 4 + chunk)
        let monitor = VideoSegmentCacheMonitor()
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "resume-chunk-test", monitor: monitor)
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.largeTrack())
        do {
            _ = try await cache.response(track: "video", index: 1, rangeHeader: nil)
            XCTFail("A truncated second chunk must not be served as a complete fragment")
        } catch {
            XCTAssertEqual(monitor.value.storedBytes, chunk, "Keep the already validated prefix on disk")
        }
        let response = try await cache.response(track: "video", index: 1, rangeHeader: nil)
        XCTAssertEqual(response.data, origin.payload.subdata(in: 4..<origin.payload.count))
        XCTAssertEqual(origin.requestedOffsets.filter { $0 == 4 }.count, 1, "Retry the failed chunk, not the entire GOP")
        XCTAssertEqual(origin.requestedOffsets.filter { $0 == 4 + chunk }.count, 2)
        XCTAssertEqual(monitor.value.storedBytes, chunk * 3)
    }

    func testSegmentCacheLargeFragmentCanTakeLongerThanFifteenSeconds() async throws {
        let chunk = VideoSegmentCache.downloadChunkBytes
        let origin = try SegmentCacheTestOrigin(payloadBytes: 4 + chunk * 4, secondsPerChunk: 4.1)
        let cache = try VideoSegmentCache(headers: [:], diagnosticID: "large-slow-fragment-test")
        addTeardownBlock { await cache.stop(); origin.stop() }
        try await cache.register(origin.largeTrack())
        let start = ProcessInfo.processInfo.systemUptime
        let response = try await cache.response(track: "video", index: 1, rangeHeader: nil)
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 15)
        XCTAssertEqual(response.data, origin.payload.subdata(in: 4..<origin.payload.count))
        XCTAssertEqual(origin.requestCount, 4, "Small verified ranges must survive a slow multi-megabyte fragment")
    }

    func testSegmentCacheStreamsVerifiedPrefixBeforeFragmentCompletes() async throws {
        let chunk = VideoSegmentCache.downloadChunkBytes
        let origin = try SegmentCacheTestOrigin(payloadBytes: 4 + chunk * 3, secondsPerChunk: 0.4)
        let server = try VideoSegmentCacheServer(headers: [:], diagnosticID: "streaming-test")
        let client = URLSession(configuration: .ephemeral)
        addTeardownBlock { client.invalidateAndCancel(); server.stop(); origin.stop() }
        try await server.cache.register(origin.largeTrack())
        let url = try XCTUnwrap(URL(string: server.url(track: "video", index: 1)))
        let (bytes, response) = try await client.bytes(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "\(chunk * 3)")
        var iterator = bytes.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, origin.payload[4])
        XCTAssertLessThan(origin.requestCount, 3, "The player must receive data before the entire fragment is downloaded")
    }

    func testPlaybackDiagnosticsRedactsSignedURLsAndPreservesErrorChain() {
        let url = "https://user:password@cdn.example/video.m4s?token=secret&deadline=123#fragment"
        XCTAssertEqual(PlaybackDiagnostics.resource(url), "https://cdn.example/video.m4s")
        let underlying = NSError(domain: NSURLErrorDomain, code: -1001,
                                 userInfo: [NSLocalizedDescriptionKey: "timeout \(url)"])
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        let logged = PlaybackDiagnostics.error(error)
        XCTAssertTrue(logged.contains("-11800"))
        XCTAssertTrue(logged.contains("-1001"))
        XCTAssertTrue(logged.contains("cdn.example/video.m4s"))
        XCTAssertFalse(logged.contains("secret"))
        XCTAssertFalse(logged.contains("password"))
        XCTAssertFalse(logged.contains("deadline"))
    }

    func testCDNProbeRejectsHTTPErrorAndInvalidRanges() {
        XCTAssertNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 0-262143/1000000", receivedBytes: 262144, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 403, contentRange: nil, receivedBytes: 100, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 200, contentRange: nil, receivedBytes: 262144, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 100-199/1000", receivedBytes: 100, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 0-262143/1000000", receivedBytes: 100, requestedBytes: 262144))
        let result = CDNDiagnostics.ProbeResult(url: "https://cdn.example/video", bytes: 262144,
                                               transferTime: 0.02, setupTime: 1, error: nil, totalTime: 1.02)
        XCTAssertEqual(result.mbps ?? 0, 104.8576, accuracy: 0.001)
        XCTAssertEqual(result.endToEndMbps ?? 0, 2.056, accuracy: 0.001)
    }

    func testCDNRecoveryDoesNotTrustFastBodyOnFailingServer() {
        let current = CDNDiagnostics.ProbeResult(url: "https://current.example/video", bytes: 262144,
                                                transferTime: 0.01, setupTime: 0.03, error: nil, totalTime: 0.04)
        let alternate = CDNDiagnostics.ProbeResult(url: "https://alternate.example/video", bytes: 262144,
                                                  transferTime: 0.17, setupTime: 0.1, error: nil, totalTime: 0.27)
        let failed = CDNDiagnostics.ProbeResult(url: "https://failed.example/video", bytes: 200,
                                               transferTime: 0.001, setupTime: 0, error: "HTTP 403", totalTime: 0.001)
        XCTAssertGreaterThan(current.mbps ?? 0, (alternate.mbps ?? 0) * 10)
        XCTAssertEqual(CDNDiagnostics.recoveryCandidate(from: [current, failed, alternate],
                                                       currentHost: current.host)?.host, alternate.host)
        XCTAssertNil(CDNDiagnostics.recoveryCandidate(from: [current, failed], currentHost: current.host))

        let highLatency = CDNDiagnostics.ProbeResult(url: "https://slow-setup.example/video", bytes: 262144,
                                                    transferTime: 0.01, setupTime: 2, error: nil, totalTime: 2.01)
        XCTAssertEqual(CDNDiagnostics.ranked([highLatency, alternate]).first?.host, alternate.host,
                       "Startup ranking must include connection and first-byte wait")
    }

    func testPlaybackRecoverySeparatesSystemFailureFromPauseAndBoundsRetries() {
        var state = BVideoPlayPlugin.PlaybackRecoveryState()
        state.recordRateChange(rate: 1.5, reason: AVPlayer.RateDidChangeReason.setRateCalled.rawValue)
        state.recordRateChange(rate: 0, reason: AVPlayer.RateDidChangeReason.setRateFailed.rawValue)
        XCTAssertFalse(state.isPaused, "A system failure must not erase playback intent")
        XCTAssertEqual(state.rate, 1.5)
        XCTAssertTrue(state.beginFailureRecovery())
        XCTAssertTrue(state.beginFailureRecovery())
        XCTAssertFalse(state.beginFailureRecovery(), "Repeated failures must not reload indefinitely")
        state.recordRateChange(rate: 0, reason: AVPlayer.RateDidChangeReason.setRateCalled.rawValue)
        XCTAssertTrue(state.isPaused)
        XCTAssertFalse(state.beginFailureRecovery(), "An explicit pause must stop recovery")
        state.recordRateChange(rate: 1.5, reason: AVPlayer.RateDidChangeReason.setRateCalled.rawValue)
        XCTAssertTrue(state.beginFailureRecovery(), "An explicit resume may retry again")
        for reason in [AVPlayer.RateDidChangeReason.audioSessionInterrupted, .appBackgrounded] {
            state.recordRateChange(rate: 0, reason: reason.rawValue)
            XCTAssertTrue(state.isPaused, "Do not restart playback over a system interruption")
        }
    }

    func testIncompatibleFormatErrorsAreNotNetworkRecoveryCandidates() {
        for code in [AVError.Code.incompatibleAsset, .noCompatibleAlternatesForExternalDisplay,
                     .decoderNotFound, .formatUnsupported] {
            XCTAssertNotNil(BVideoPlayPlugin.incompatiblePlaybackMessage(
                NSError(domain: AVFoundationErrorDomain, code: code.rawValue)))
        }
        XCTAssertNil(BVideoPlayPlugin.incompatiblePlaybackMessage(NSError(domain: NSURLErrorDomain, code: -1001)))
        XCTAssertNil(BVideoPlayPlugin.incompatiblePlaybackMessage(NSError(domain: "CoreMediaErrorDomain", code: -19602)))
        XCTAssertNil(BVideoPlayPlugin.incompatiblePlaybackMessage(nil))
    }

    @MainActor func testFailedToEndIsHandledOnceWithoutFailedItemStatus() throws {
        let container = CommonPlayerViewController()
        container.loadViewIfNeeded()
        let playerVC = try XCTUnwrap(container.children.first as? AVPlayerViewController)
        let plugin = FailureRecoveryTestPlugin()
        container.addPlugin(plugin: plugin)
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        playerVC.player = player
        defer { container.stopPlayback() }
        XCTAssertNotEqual(item.status, .failed)
        let error = NSError(domain: "CoreMediaErrorDomain", code: -19602)
        let postFailure: (AVPlayerItem) -> Void = {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: $0,
                                            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
        }
        postFailure(item)
        postFailure(item)
        XCTAssertEqual(plugin.recoveryCount, 1)
        XCTAssertEqual((plugin.error as NSError?)?.code, -19602)
        XCTAssertEqual(plugin.failureCount, 0, "A handled recovery must not also trigger an independent retry")
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        playerVC.player = AVPlayer(playerItem: replacement)
        postFailure(item)
        XCTAssertEqual(plugin.recoveryCount, 1, "Ignore stale item failures")
        postFailure(replacement)
        XCTAssertEqual(plugin.recoveryCount, 2)
        container.stopPlayback()
        postFailure(replacement)
        XCTAssertEqual(plugin.recoveryCount, 2, "Remove failure observers on exit")
    }

    @MainActor func testLiveURLFailureAndSystemPauseRetryOnlyOnce() throws {
        let playerVC = AVPlayerViewController()
        let plugin = URLPlayPlugin(isLive: true)
        plugin.playerDidLoad(playerVC: playerVC)
        var retries = 0
        plugin.onPlayFail = { retries += 1 }
        let oldPlayer = AVPlayer()
        playerVC.player = oldPlayer
        plugin.playerDidFail(player: oldPlayer)
        plugin.playerDidPause(player: oldPlayer)
        XCTAssertEqual(retries, 1, "Failed-to-end followed by a system pause must not skip two live CDN candidates")
        plugin.play(urlString: "file:///dev/null")
        let newPlayer = try XCTUnwrap(playerVC.player)
        plugin.playerDidPause(player: oldPlayer)
        XCTAssertEqual(retries, 1, "Ignore callbacks from an old player")
        plugin.playerDidFail(player: newPlayer)
        plugin.playerDidPause(player: newPlayer)
        XCTAssertEqual(retries, 2, "A new stream gets its own failure attempt")
        newPlayer.replaceCurrentItem(with: nil)
    }

    @MainActor func testBufferingOverlayShowsRecoveryAndSanitizedCandidatesAboveControls() throws {
        var details = PlaybackBufferingDetails(phase: "正在重新连接", isRecovering: true,
                                               videoHost: "current.example", audioHost: "audio.example",
                                               candidates: [
                                                .init(host: "current.example", isPCDN: false, result: nil),
                                                .init(host: "alternate.example", isPCDN: false,
                                                      result: .init(url: "https://alternate.example/video?token=secret",
                                                                    bytes: 262144, transferTime: 0.02, setupTime: 1,
                                                                    error: nil, totalTime: 1.02))
                                               ], lastError: "CoreMediaErrorDomain(-19602)")
        XCTAssertTrue(PlaybackBufferingOverlay.shouldShow(timeControlStatus: .paused, details: details))
        XCTAssertTrue(PlaybackBufferingOverlay.shouldShow(timeControlStatus: .waitingToPlayAtSpecifiedRate, details: nil))
        XCTAssertFalse(PlaybackBufferingOverlay.shouldShow(timeControlStatus: .playing, details: nil))
        XCTAssertFalse(PlaybackBufferingOverlay.shouldShow(timeControlStatus: .paused, details: nil))
        let text = PlaybackBufferingOverlay.detailText(player: nil, details: details)
        for expected in ["current.example", "audio.example", "alternate.example", "2.1 Mbps", "待测速", "-19602"] {
            XCTAssertTrue(text.contains(expected), "Missing diagnostic: \(expected)")
        }
        XCTAssertFalse(text.contains("104.9 Mbps"), "Do not present body-only throughput as end-to-end speed")
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("token"))

        let playerVC = AVPlayerViewController()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        window.rootViewController = playerVC
        playerVC.loadViewIfNeeded()
        let overlay = PlaybackBufferingOverlay(playerVC: playerVC) { details }
        defer { overlay.stop(); window.rootViewController = original }
        overlay.superview?.addSubview(UIView())
        playerVC.view.layoutIfNeeded()
        overlay.refresh()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(overlay.superview?.subviews.last === overlay, "Later danmaku overlays must stay behind diagnostics")
        XCTAssertFalse(overlay.isUserInteractionEnabled, "Diagnostics must not steal remote focus")
        let frame = overlay.convert(overlay.bounds, to: playerVC.view)
        let guide = playerVC.unobscuredContentGuide
        let guideOwner = try XCTUnwrap(guide.owningView)
        let guideFrame = guideOwner.convert(guide.layoutFrame, to: playerVC.view)
        XCTAssertLessThanOrEqual(frame.maxY, guideFrame.maxY - 23)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertFalse(overlay.hasAmbiguousLayout)
        let image = UIGraphicsImageRenderer(bounds: playerVC.view.bounds).image { _ in
            playerVC.view.drawHierarchy(in: playerVC.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Buffering diagnostics above native controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        details.isRecovering = false
        overlay.refresh()
        XCTAssertTrue(overlay.isHidden, "Hide after recovery or explicit pause")
    }

    func testDefaultNavigationAndQualityPolicy() {
        XCTAssertEqual(TabBarPage.defaultTabBarPages, [.feed, .search, .personal])
        XCTAssertEqual(MediaQualityEnum.quality_1080p.qn, 80)
        XCTAssertEqual(Settings.defaultPlacements.filter { $0.section == .tabBar }.map(\.page), [.feed, .search, .personal])
    }

    func testDefaultQualityPersistsExistingChoice() throws {
        let key = "Settings.mediaQuality"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.mediaQuality, .bestAvailable)
        for quality in MediaQualityEnum.allCases {
            Settings.mediaQuality = quality
            XCTAssertEqual(Settings.mediaQuality, quality)
        }
        // Existing enum encodings must still decode after adding the new case.
        let saved = Data(#"{"quality_2160p":{}}"#.utf8)
        UserDefaults.standard.set(saved, forKey: key)
        XCTAssertEqual(Settings.mediaQuality, .quality_2160p)
    }

    func testProactiveCacheDefaultsPreserveExistingBufferChoiceAndSeparateWarmupKeys() {
        let keys = ["Settings.videoBufferDuration", "Settings.videoProactiveBuffering"]
        let oldValues = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, oldValues) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertEqual(Settings.videoBufferDuration, .maximum)
        XCTAssertTrue(Settings.videoProactiveBuffering)
        Settings.videoBufferDuration = .extended
        XCTAssertEqual(Settings.videoBufferDuration.rawValue, 120)
        let cached = PlayerMediaPreferences.current
        Settings.videoProactiveBuffering = false
        let native = PlayerMediaPreferences.current
        XCTAssertFalse(native.proactiveBuffering)
        XCTAssertNotEqual(PlayerMediaWarmupManager.CacheKey(sequenceKey: "same", preferences: cached),
                          PlayerMediaWarmupManager.CacheKey(sequenceKey: "same", preferences: native))
        XCTAssertEqual(Settings.videoBufferDuration.rawValue, 120)
    }

    func testQualitySelectionHonors4KAndBestAvailable() throws {
        func stream(_ quality: Int, _ codec: String, _ bandwidth: Int) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
            .init(id: quality, base_url: "https://example.invalid/video.m4s", backup_url: nil,
                  bandwidth: bandwidth, mime_type: "video/mp4", codecs: codec,
                  width: 3840, height: 2160, frame_rate: "30", sar: nil, start_with_sap: nil,
                  segment_base: .init(initialization: "0-100", index_range: "101-200"), codecid: nil)
        }
        let streams = [stream(64, "avc1.640028", 1000), stream(80, "avc1.640028", 2000),
                       stream(120, "hvc1.1.6.L153.B0", 4000), stream(120, "avc1.640034", 6000),
                       stream(126, "dvh1.08.06", 5000), stream(127, "av01.0.16M.10", 7000)]
        let fourK = PlayerMediaPreferences(quality: .quality_2160p, preferAVC: true, losslessAudio: false)
        let best = PlayerMediaPreferences(quality: .bestAvailable, preferAVC: true, losslessAudio: false)
        XCTAssertEqual(fourK.selectVideos(from: streams).map(\.id), [120], "4K must not include lower ABR variants")
        XCTAssertEqual(fourK.selectVideos(from: streams).first?.codecs, "avc1.640034")
        XCTAssertEqual(best.selectVideos(from: streams).map(\.id), [126], "Skip unsupported AV1, retain highest playable quality")
        XCTAssertEqual(fourK.selectVideos(from: Array(streams.prefix(2))).map(\.id), [80], "Fall back when source/account lacks 4K")
        XCTAssertEqual(best.selectVideos(from: Array(streams.prefix(1))).map(\.id), [64])
        XCTAssertEqual(best.selectVideos(from: streams, streamIndex: 1).map(\.id), [80], "Explicit quality still overrides the default")
        XCTAssertTrue(best.selectVideos(from: streams, streamIndex: -1).isEmpty)
        XCTAssertTrue(best.selectVideos(from: streams, streamIndex: 5).isEmpty)
        XCTAssertNotEqual(PlayerMediaWarmupManager.CacheKey(sequenceKey: "same-video", preferences: fourK),
                          PlayerMediaWarmupManager.CacheKey(sequenceKey: "same-video", preferences: best),
                          "Changing defaults must not reuse a warmed asset at the old quality")
    }

    func testDeviceCodecFallbackPreservesResolutionAndFrameRate() {
        func stream(_ quality: Int, codec: String, width: Int = 3840, height: Int = 2160,
                    fps: String = "59.933") -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
            .init(id: quality, base_url: "https://example.invalid/video.m4s", backup_url: nil,
                  bandwidth: 19_000_000, mime_type: "video/mp4", codecs: codec,
                  width: width, height: height, frame_rate: fps, sar: nil, start_with_sap: nil,
                  segment_base: .init(initialization: "0-100", index_range: "101-200"), codecid: nil)
        }
        let avc4K = stream(120, codec: "avc1.640034")
        let hevcHDR = stream(125, codec: "hvc1.2.4.L153.90")
        let lower = stream(116, codec: "avc1.640032", width: 1920, height: 1080)
        let streams = [hevcHDR, avc4K, lower]
        let preferences = PlayerMediaPreferences(quality: .quality_2160p, preferAVC: true, losslessAudio: false)
        let compatible: (VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Bool = { $0.codecs != "avc1.640034" }
        XCTAssertEqual(preferences.selectVideos(from: streams, isPlayable: compatible).map(\.id), [125],
                       "Use supported 4K60 HDR instead of unsupported 4K60 AVC")
        XCTAssertEqual(preferences.selectVideos(from: streams, isPlayable: { _ in true }).map(\.id), [120],
                       "Do not change a supported SDR choice")
        XCTAssertTrue(preferences.selectVideos(from: [avc4K, lower], isPlayable: compatible).isEmpty,
                      "Do not silently lower resolution when the selected codec is incompatible")
        let slowerHDR = stream(125, codec: "hvc1.2.4.L153.90", fps: "30")
        XCTAssertTrue(preferences.selectVideos(from: [avc4K, slowerHDR], isPlayable: compatible).isEmpty,
                      "Do not silently halve the frame rate")
        XCTAssertTrue(preferences.selectVideos(from: streams, streamIndex: 1, isPlayable: compatible).isEmpty,
                      "Explicit incompatible codec choices must fail, not silently switch")
        let fractionalHDR = stream(125, codec: "hvc1.2.4.L153.90", fps: "60000/1001")
        XCTAssertEqual(preferences.selectVideos(from: [avc4K, fractionalHDR], isPlayable: compatible).map(\.id), [125])
    }

    func testAVCHigh52DeclarationDefersToMediaWithoutInventingALowerLevel() {
        func stream(_ codec: String) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
            .init(id: 120, base_url: "https://example.invalid/video.m4s", backup_url: nil,
                  bandwidth: 19_031_651, mime_type: "video/mp4", codecs: codec,
                  width: 3840, height: 2160, frame_rate: "59.933", sar: nil, start_with_sap: nil,
                  segment_base: .init(initialization: "0-100", index_range: "101-200"), codecid: nil)
        }
        let avc = stream("avc1.640034")
        XCTAssertEqual(PlayerMediaPreferences.hlsCodec(avc, supportsMIME: { _ in false }), "avc1")
        XCTAssertEqual(PlayerMediaPreferences.hlsCodec(avc, supportsMIME: { _ in true }), avc.codecs)
        for codec in ["avc1.640033", "avc1.64003C", "hvc1.2.4.L153.90", "av01.0.13M.08"] {
            XCTAssertEqual(PlayerMediaPreferences.hlsCodec(stream(codec), supportsMIME: { _ in false }), codec,
                           "Do not generalize the verified workaround to untested formats")
        }
        XCTAssertEqual(avc.width, 3840)
        XCTAssertEqual(avc.height, 2160)
        XCTAssertEqual(avc.frame_rate, "59.933")
        XCTAssertEqual(avc.codecs, "avc1.640034", "Original metadata must remain truthful")
    }

    func testHDRFrameRateCompatibilityIsLimitedToVerifiedHardwareAndFormat() {
        func stream(_ quality: Int, fps: String) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
            .init(id: quality, base_url: "https://example.invalid/video.m4s", backup_url: nil,
                  bandwidth: 17_344_172, mime_type: "video/mp4", codecs: "hvc1.2.4.L153.90",
                  width: 3840, height: 2160, frame_rate: fps, sar: nil, start_with_sap: nil,
                  segment_base: .init(initialization: "0-100", index_range: "101-200"), codecid: nil)
        }
        let hdr = stream(125, fps: "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(hdr, deviceModel: "AppleTV6,2"), "30")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(hdr, deviceModel: "AppleTV11,1"), "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(hdr, deviceModel: "AppleTV14,1"), "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(hdr, deviceModel: ""), "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(stream(120, fps: "59.933"), deviceModel: "AppleTV6,2"), "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(stream(126, fps: "59.933"), deviceModel: "AppleTV6,2"), "59.933")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(stream(125, fps: "24"), deviceModel: "AppleTV6,2"), "24")
        XCTAssertEqual(PlayerMediaPreferences.hlsFrameRate(stream(125, fps: "60000/1001"), deviceModel: "AppleTV6,2"), "30")
        XCTAssertEqual(hdr.frame_rate, "59.933", "Do not mutate actual media metadata")
    }

    @MainActor func testReported4K60PlaybackUsesActualFramesAndContinuousCache() async throws {
        try await verifyReported4KPlayback(hdr: false)
    }

    @MainActor func testReportedHDR60PlaybackPreservesPQAndActualFrameRate() async throws {
        try await verifyReported4KPlayback(hdr: true)
    }

    @MainActor private func verifyReported4KPlayback(hdr: Bool) async throws {
        let aid = 117332567397550
        let cid = 42200205797
        let info = try await WebRequest.requestPlayUrl(aid: aid, cid: cid)
        guard let index = info.dash.video.firstIndex(where: {
            hdr ? ($0.id == 125 && $0.isHevc) : ($0.id == 120 && $0.codecs == "avc1.640034")
        }) else {
            throw XCTSkip("The on-device 4K entitlement is required for this regression")
        }
        let previous = Settings.videoProactiveBuffering
        let previousQuality = Settings.mediaQuality
        Settings.videoProactiveBuffering = true
        Settings.mediaQuality = hdr ? .bestAvailable : .quality_2160p
        defer {
            Settings.videoProactiveBuffering = previous
            Settings.mediaQuality = previousQuality
        }
        let data = PlayerDetailData(aid: aid, cid: cid, epid: nil, seasonId: nil, subType: nil, videoPlayURLInfo: info)
        let container = CommonPlayerViewController()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        window.rootViewController = container
        container.loadViewIfNeeded()
        let plugin = BVideoPlayPlugin(playInfo: .init(aid: aid, cid: cid), detailData: data, reportWatchHistory: false)
        plugin.onLoadFailure = { XCTFail("The 4K source failed: \($0)") }
        container.addPlugin(plugin: plugin)
        defer { container.stopPlayback(); window.rootViewController = original }
        let controller = try XCTUnwrap(container.children.first as? AVPlayerViewController)
        try await eventually(timeout: 60) { controller.player?.timeControlStatus == .playing }
        let player = try XCTUnwrap(controller.player)
        let item = try XCTUnwrap(player.currentItem)
        let delegate = try XCTUnwrap((item.asset as? AVURLAsset)?.resourceLoader.delegate as? BilibiliVideoResourceLoaderDelegate)
        let stream = delegate.streamDiagnostics(for: item.accessLog()?.events.last?.uri)
        XCTAssertEqual(stream.codec, info.dash.video[index].codecs)
        XCTAssertEqual(stream.bandwidth, info.dash.video[index].bandwidth)
        XCTAssertTrue(delegate.masterPlaylist.contains("RESOLUTION=3840x2160"))
        XCTAssertTrue(delegate.masterPlaylist.contains("FRAME-RATE=\(PlayerMediaPreferences.hlsFrameRate(info.dash.video[index]))"))
        if !hdr { XCTAssertFalse(delegate.masterPlaylist.contains("FRAME-RATE=30,")) }
        XCTAssertTrue(delegate.masterPlaylist.contains("VIDEO-RANGE=\(hdr ? "PQ" : "SDR")"))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        defer { item.remove(output) }
        let probe = HDRPlaybackFrameCadenceProbe(output: output)
        probe.start()
        defer { probe.stop() }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        probe.stop()
        Logger.info("[4k-regression] hdr=\(hdr) cadence=\(probe.summary)")
        XCTAssertGreaterThan(probe.sampledVideoFPS, 50, "Verify near-60 fps decoded frame delivery, not a running audio clock")
        XCTAssertEqual(player.timeControlStatus, .playing)
        let time = player.currentTime()
        var frameTime = CMTime.invalid
        let frame = try XCTUnwrap(output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &frameTime))
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 3840)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 2160)
        XCTAssertEqual(frameTime.seconds, time.seconds, accuracy: 0.1)
        let attachments = CVBufferCopyAttachments(frame, .shouldPropagate) as? [String: Any]
        let transfer = attachments?[kCVImageBufferTransferFunctionKey as String] as? String
        let primaries = attachments?[kCVImageBufferColorPrimariesKey as String] as? String
        if hdr {
            XCTAssertEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        }
        try await eventually(timeout: 90) { (delegate.cacheSnapshot?.bufferedSeconds ?? 0) >= 60 }
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertFalse(item.errorLog()?.events.contains { [-11848, -11868, -16849].contains($0.errorStatusCode) } ?? false)
        Logger.info("[4k-regression] hdr=\(hdr) position=\(player.currentTime().seconds) frame=\(frameTime.seconds) transfer=\(transfer ?? "-") primaries=\(primaries ?? "-") buffered=\(delegate.cacheSnapshot?.bufferedSeconds ?? 0)s storedBytes=\(delegate.cacheSnapshot?.storedBytes ?? 0)")
    }

    @MainActor func testReportedVideoSDRHEVCNegotiation() async throws {
        // Public regression source that offered incompatible AVC 4K60 on the
        // first-generation TV. Run on-device to retain its existing entitlements.
        for (name, flags, preferredCodec) in [
            ("regular", 976, 0),
            ("sdr-hevc", 144, 1),
            ("dash-hevc", 16, 1),
            ("all-hevc", 4048, 1),
        ] {
            let info: VideoPlayURLInfo = try await WebRequest.request(
                url: WebRequest.EndPoint.playUrl,
                parameters: ["avid": 117332567397550, "cid": 42200205797,
                             "qn": 120, "fnver": 0, "fnval": flags, "fourk": 1,
                             "prefer_codec_type": preferredCodec, "otype": "json"])
            XCTAssertFalse(info.dash.video.isEmpty)
            let candidates = info.dash.video.filter { $0.id >= 116 }
            for stream in candidates {
                Logger.info("[codec-negotiation] request=\(name) fnval=\(flags) qn=\(stream.id) codec=\(stream.codecs) size=\(stream.width ?? 0)x\(stream.height ?? 0) fps=\(stream.frame_rate ?? "-") bandwidth=\(stream.bandwidth) mimePlayable=\(PlayerMediaPreferences.isPlayable(stream))")
            }
            Logger.info("[codec-negotiation] request=\(name) has4KSDRHEVC=\(candidates.contains { $0.id == 120 && $0.isHevc && ($0.width ?? 0) >= 3840 })")
        }
    }

    @MainActor func testReportedHDRPlaybackCompatibilityMatrix() async throws {
        let aid = 117332567397550
        let info = try await WebRequest.requestPlayUrl(aid: aid, cid: 42200205797)
        guard let video = info.dash.video.first(where: { $0.id == 125 && $0.isHevc }),
              let audio = info.dash.audio?.first else {
            throw XCTSkip("This diagnostic needs the device account's HDR stream entitlement")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HDRPlaybackMatrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let videoFixture = try await HDRPlaybackTestFixture.prepare(media: video, aid: aid, name: "video", directory: directory)
        let audioFixture = try await HDRPlaybackTestFixture.prepare(media: audio, aid: aid, name: "audio", directory: directory)
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server["/video.mp4"] = { videoFixture.response($0) }
        server["/audio.mp4"] = { audioFixture.response($0) }
        server["/video.m3u8"] = { _ in .ok(.text(videoFixture.playlist), ["Content-Type": "application/vnd.apple.mpegurl"]) }
        server["/audio.m3u8"] = { _ in .ok(.text(audioFixture.playlist), ["Content-Type": "application/vnd.apple.mpegurl"]) }
        let fullCodecs = "\(video.codecs),\(audio.codecs)"
        let variants: [(name: String, frameRate: String?, codecs: String?, resolution: Bool)] = [
            ("declared-source-rate", video.frame_rate, video.codecs, true),
            ("declared-60-with-audio-codec", "60", fullCodecs, true),
            ("hdr-generic-codec", video.frame_rate, "hvc1,\(audio.codecs)", true),
            ("hdr-omitted-codecs", video.frame_rate, nil, true),
            ("omitted-optional-frame-rate", nil, fullCodecs, true),
            ("omitted-frame-rate-video-codec-only", nil, video.codecs, true),
            ("omitted-frame-rate-and-resolution", nil, fullCodecs, false),
            ("declared-source-rate-without-resolution", video.frame_rate, fullCodecs, false),
            // Diagnostic control only: this reproduces the previous manifest,
            // not a proposal to disguise 60 fps media as a 30 fps source.
            ("legacy-declared-30-control", "30", fullCodecs, true),
        ]
        for variant in variants {
            let frameRate = variant.frameRate.map { ",FRAME-RATE=\($0)" } ?? ""
            let codecs = variant.codecs.map { ",CODECS=\"\($0)\"" } ?? ""
            let resolution = variant.resolution ? ",RESOLUTION=\(video.width ?? 0)x\(video.height ?? 0)" : ""
            let master = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",DEFAULT=YES,AUTOSELECT=YES,NAME="audio",URI="audio.m3u8"
            #EXT-X-STREAM-INF:AUDIO="audio"\(codecs)\(resolution)\(frameRate),BANDWIDTH=\(Int(Double(video.bandwidth + audio.bandwidth) * 1.5)),AVERAGE-BANDWIDTH=\(video.bandwidth + audio.bandwidth),VIDEO-RANGE=PQ
            video.m3u8

            """
            server["/\(variant.name).m3u8"] = { _ in
                Logger.info("[hdr-matrix-http] master=\(variant.name)")
                return .ok(.text(master), ["Content-Type": "application/vnd.apple.mpegurl"])
            }
        }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let port = try server.port()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        defer { window.rootViewController = original }
        var outcomes = [String]()
        for variant in variants {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(variant.name).m3u8"))
            outcomes.append(try await inspectHDRPlayback(url: url, name: variant.name, window: window))
        }
        outcomes.append(try await inspectHDRPlayback(url: videoFixture.file, name: "direct-local-fmp4", window: window))
        let directHTTP = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/video.mp4"))
        outcomes.append(try await inspectHDRPlayback(url: directHTTP, name: "direct-http-fmp4", window: window))
        let mediaPlaylist = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/video.m3u8"))
        outcomes.append(try await inspectHDRPlayback(url: mediaPlaylist, name: "direct-media-playlist", window: window))
        if let avc = info.dash.video.first(where: { $0.id == 120 && $0.codecs.hasPrefix("avc") }) {
            let fixture = try await HDRPlaybackTestFixture.prepare(media: avc, aid: aid, name: "avc", directory: directory)
            outcomes.append(try await inspectHDRPlayback(url: fixture.file, name: "direct-local-avc-control", window: window))
        }
        let attachment = XCTAttachment(string: outcomes.joined(separator: "\n"))
        attachment.name = "Same-source HDR compatibility matrix"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(outcomes.count, variants.count + 3 + (info.dash.video.contains { $0.id == 120 && $0.codecs.hasPrefix("avc") } ? 1 : 0))
    }

    @MainActor private func inspectHDRPlayback(url: URL, name: String, window: UIWindow) async throws -> String {
        let controller = AVPlayerViewController()
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        controller.allowsPictureInPicturePlayback = false
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        controller.player = player
        var videoOutput: AVPlayerItemVideoOutput?
        defer {
            player.pause()
            if let videoOutput { item.remove(videoOutput) }
            player.replaceCurrentItem(with: nil)
            controller.player = nil
            window.rootViewController = UIViewController()
        }
        let start = ProcessInfo.processInfo.systemUptime
        Logger.info("[hdr-matrix] name=\(name) begin hdrEligible=\(AVPlayer.eligibleForHDRPlayback) matching=\(window.avDisplayManager.isDisplayCriteriaMatchingEnabled)")
        while item.status == .unknown, ProcessInfo.processInfo.systemUptime - start < 12 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if item.status == .readyToPlay {
            player.play()
            let displayDeadline = Date().addingTimeInterval(5)
            while !controller.isReadyForDisplay, item.status == .readyToPlay, Date() < displayDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            videoOutput = output
        }
        var frames = 0
        var lastFramePosition = -1.0
        var size = "none"
        var transferFunction = "-"
        var colorPrimaries = "-"
        var frameGaps = 0
        var largestFrameLag = 0.0
        var cadence = "none"
        if let videoOutput {
            let probe = HDRPlaybackFrameCadenceProbe(output: videoOutput)
            probe.start()
            defer { probe.stop() }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            probe.stop()
            cadence = probe.summary
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let time = player.currentTime()
                var displayTime = CMTime.invalid
                if videoOutput.hasNewPixelBuffer(forItemTime: time),
                   let frame = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) {
                    if displayTime.seconds > lastFramePosition { frames += 1 }
                    lastFramePosition = displayTime.seconds
                    largestFrameLag = max(largestFrameLag, time.seconds - displayTime.seconds)
                    size = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
                    let attachments = CVBufferCopyAttachments(frame, .shouldPropagate) as? [String: Any]
                    transferFunction = attachments?[kCVImageBufferTransferFunctionKey as String] as? String ?? "-"
                    colorPrimaries = attachments?[kCVImageBufferColorPrimariesKey as String] as? String ?? "-"
                    Logger.info("[hdr-matrix-frame] name=\(name) position=\(time.seconds) framePosition=\(displayTime.seconds) size=\(size) transfer=\(transferFunction) primaries=\(colorPrimaries)")
                } else {
                    frameGaps += 1
                }
            }
        }
        let trackInfo: String
        do {
            if let track = try await item.asset.loadTracks(withMediaType: .video).first {
                trackInfo = "nominalFPS=\(try await track.load(.nominalFrameRate))"
            } else { trackInfo = "no-video-track" }
        } catch {
            trackInfo = "trackError=\(PlaybackDiagnostics.error(error))"
        }
        let result = "name=\(name) item=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue) displayReady=\(controller.isReadyForDisplay) position=\(player.currentTime().seconds) freshFrames=\(frames) frameGaps=\(frameGaps) maxFrameLag=\(largestFrameLag) lastFrame=\(lastFramePosition) size=\(size) transfer=\(transferFunction) primaries=\(colorPrimaries) \(trackInfo) cadence={\(cadence)} screenMaxFPS=\(UIScreen.main.maximumFramesPerSecond) elapsed=\(ProcessInfo.processInfo.systemUptime - start)s error=\(PlaybackDiagnostics.error(item.error))"
        Logger.info("[hdr-matrix] \(result)")
        if let error = item.error as NSError? {
            let failedURL = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            Logger.info("[hdr-matrix-error] name=\(name) userInfoKeys=\(error.userInfo.keys.sorted().joined(separator: ",")) failedURL=\(PlaybackDiagnostics.resource(failedURL))")
        }
        for error in item.errorLog()?.events ?? [] {
            Logger.warn("[hdr-matrix-error] name=\(name) code=\(error.errorStatusCode) domain=\(error.errorDomain) comment=\(PlaybackDiagnostics.sanitize(error.errorComment ?? "-"))")
        }
        print(result)
        return result
    }

    @MainActor func testReportedAVCCodecDeclarationMatrix() async throws {
        let aid = 117332567397550
        let info = try await WebRequest.requestPlayUrl(aid: aid, cid: 42200205797)
        guard let video = info.dash.video.first(where: { $0.id == 120 && $0.codecs.hasPrefix("avc") }),
              let audio = info.dash.audio?.first else {
            throw XCTSkip("This diagnostic needs the device account's 4K stream entitlement")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AVCPlaybackMatrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let videoFixture = try await HDRPlaybackTestFixture.prepare(media: video, aid: aid, name: "video", directory: directory)
        let audioFixture = try await HDRPlaybackTestFixture.prepare(media: audio, aid: aid, name: "audio", directory: directory)
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server["/video.mp4"] = { videoFixture.response($0) }
        server["/audio.mp4"] = { audioFixture.response($0) }
        server["/video.m3u8"] = { _ in .ok(.text(videoFixture.playlist), ["Content-Type": "application/vnd.apple.mpegurl"]) }
        server["/audio.m3u8"] = { _ in .ok(.text(audioFixture.playlist), ["Content-Type": "application/vnd.apple.mpegurl"]) }
        let variants: [(name: String, codecs: String?, frameRate: String?)] = [
            ("avc-declared-codec", "\(video.codecs),\(audio.codecs)", video.frame_rate),
            ("avc-omitted-optional-codecs", nil, video.frame_rate),
            ("avc-generic-sample-entry", "avc1,\(audio.codecs)", video.frame_rate),
            ("avc-omitted-codecs-and-rate", nil, nil),
        ]
        for variant in variants {
            let codecs = variant.codecs.map { ",CODECS=\"\($0)\"" } ?? ""
            let rate = variant.frameRate.map { ",FRAME-RATE=\($0)" } ?? ""
            let master = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",DEFAULT=YES,AUTOSELECT=YES,NAME="audio",URI="audio.m3u8"
            #EXT-X-STREAM-INF:AUDIO="audio"\(codecs),RESOLUTION=\(video.width ?? 0)x\(video.height ?? 0)\(rate),BANDWIDTH=\(Int(Double(video.bandwidth + audio.bandwidth) * 1.5)),VIDEO-RANGE=SDR
            video.m3u8

            """
            server["/\(variant.name).m3u8"] = { _ in
                Logger.info("[hdr-matrix-http] master=\(variant.name)")
                return .ok(.text(master), ["Content-Type": "application/vnd.apple.mpegurl"])
            }
        }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let port = try server.port()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        defer { window.rootViewController = original }
        var outcomes = [String]()
        for variant in variants {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(variant.name).m3u8"))
            outcomes.append(try await inspectHDRPlayback(url: url, name: variant.name, window: window))
        }
        let mediaPlaylist = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/video.m3u8"))
        outcomes.append(try await inspectHDRPlayback(url: mediaPlaylist, name: "avc-direct-media-playlist", window: window))
        let attachment = XCTAttachment(string: outcomes.joined(separator: "\n"))
        attachment.name = "Same-source AVC codec declaration matrix"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(outcomes.count, variants.count + 1)
    }

    @MainActor func testFollowUsesVerifiedStateAndPreservesStateOnFailure() async throws {
        enum Failure: Error { case rejected }
        var writes = [Bool]()
        var reject = true
        let model = UploaderFollowModel(isFollowing: false, read: { true }, write: { following in
            writes.append(following)
            if reject { throw Failure.rejected }
        })
        do { try await model.toggle(); XCTFail("Request should fail") } catch {}
        XCTAssertEqual(writes, [false], "Verify an existing follow before sending an unfollow")
        XCTAssertTrue(model.isFollowing, "Failure must not show a false success")
        XCTAssertFalse(model.isBusy)
        reject = false
        try await model.toggle()
        XCTAssertFalse(model.isFollowing)
        try await model.toggle()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(writes, [false, false, true])
        XCTAssertEqual(model.title, "已关注")
    }

    @MainActor func testFollowPreventsDuplicateRequests() async throws {
        var writes = 0
        var finish: CheckedContinuation<Void, Never>?
        let model = UploaderFollowModel(isFollowing: false, read: { false }, write: { _ in
            writes += 1
            await withCheckedContinuation { finish = $0 }
        })
        let first = Task { try await model.toggle() }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isFollowing)
        try await model.toggle()
        XCTAssertEqual(writes, 1)
        finish?.resume()
        try await first.value
        XCTAssertTrue(model.isFollowing)
        XCTAssertFalse(model.isBusy)
        for attribute in [0, 128] { XCTAssertFalse(WebRequest.UpSpaceRelation(attribute: attribute).isFollowing) }
        for attribute in [1, 2, 6] { XCTAssertTrue(WebRequest.UpSpaceRelation(attribute: attribute).isFollowing) }
    }

    @MainActor func testQRCodeIsDecodableAtDisplaySize() throws {
        let value = "https://passport.bilibili.com/test?auth_code=local-test-only"
        let image = try XCTUnwrap(LoginViewController.create().generateQRCode(from: value))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let feature = try XCTUnwrap(detector.features(in: ciImage).first as? CIQRCodeFeature)
        XCTAssertEqual(feature.messageString, value)
    }

    @MainActor func testLiveSearchAndVideoMetadata() async throws {
        let result = try await WebRequest.requestSearchResult(key: "Apple TV")
        var videos: [SearchResult.Video] = []
        for section in result.result { if case let .video(items) = section { videos += items } }
        XCTAssertFalse(videos.isEmpty, "Live search must return real video records")
        let first = try XCTUnwrap(videos.first)
        XCTAssertFalse(first.title.contains("<em"))
        let cid = try await WebRequest.requestCid(aid: first.aid)
        XCTAssertGreaterThan(cid, 0)
        let detail = try await WebRequest.requestDetailVideo(aid: first.aid)
        XCTAssertEqual(detail.View.aid, first.aid)
        XCTAssertFalse(detail.View.title.isEmpty)
    }

    @MainActor func testLiveQRGenerationAndWaitingState() async throws {
        let generated = expectation(description: "Live QR endpoint")
        var key = ""
        ApiRequest.requestLoginQR(onFailure: { error in XCTFail("QR generation failed: \(error)"); generated.fulfill() }) { code, url in
            key = code
            XCTAssertFalse(code.isEmpty)
            XCTAssertNotNil(URL(string: url))
            generated.fulfill()
        }
        await fulfillment(of: [generated], timeout: 30)
        guard !key.isEmpty else { return }
        let polled = expectation(description: "Unscanned QR waits")
        ApiRequest.verifyLoginQR(code: key) { state in
            if case .waiting = state {} else { XCTFail("New, unscanned QR should wait") }
            polled.fulfill()
        }
        await fulfillment(of: [polled], timeout: 30)
    }

    @MainActor func testLiveDanmakuFetchAndDelivery() async throws {
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first)
        let provider = VideoDanmuProvider(enableDanmuFilter: false, enableDanmuRemoveDup: false)
        let delivered = expectation(description: "Real protobuf danmaku delivered")
        delivered.assertForOverFulfill = false
        let subscription = provider.onSendTextModel.sink { _ in delivered.fulfill() }
        await provider.initVideo(cid: video.cid, startPos: 0)
        for second in 1...120 { provider.playerTimeChange(time: Double(second)) }
        await fulfillment(of: [delivered], timeout: 20)
        withExtendedLifetime(subscription) {}
    }
    @MainActor func testLivePlaybackQualitySwitchAndPausePreservation() async throws {
        let previousBuffer = Settings.videoBufferDuration
        let previousPrefetch = Settings.videoProactiveBuffering
        Settings.videoBufferDuration = .extended
        Settings.videoProactiveBuffering = true
        defer {
            Settings.videoBufferDuration = previousBuffer
            Settings.videoProactiveBuffering = previousPrefetch
        }
        let hot = try await WebRequest.requestHotVideo(page: 1)
        let video = try XCTUnwrap(hot.list.first { $0.duration > 120 })
        let info = try await WebRequest.requestPlayUrl(aid: video.aid, cid: video.cid)
        XCTAssertFalse(info.dash.video.isEmpty)
        let initialPosition = min(40, info.dash.duration / 4)
        var detail = PlayerDetailData(aid: video.aid, cid: video.cid, epid: nil, seasonId: nil, subType: nil, videoPlayURLInfo: info)
        detail.playerStartPos = initialPosition
        let container = CommonPlayerViewController()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        window.rootViewController = container
        container.loadViewIfNeeded()
        let plugin = BVideoPlayPlugin(playInfo: PlayInfo(aid: video.aid, cid: video.cid), detailData: detail, reportWatchHistory: false)
        plugin.onLoadFailure = { XCTFail("Playback recovery failed: \($0)") }
        container.addPlugin(plugin: plugin)
        let playerVC = try XCTUnwrap(container.children.first as? AVPlayerViewController)
        defer { container.stopPlayback(); window.rootViewController = original }
        for _ in 0..<200 {
            if playerVC.player?.timeControlStatus == .playing,
               (playerVC.player?.currentTime().seconds ?? 0) > Double(initialPosition + 2) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let player = try XCTUnwrap(playerVC.player)
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(player.currentTime().seconds, Double(initialPosition + 2), "Resume at the prebuffered position")
        try await eventually {
            guard let item = player.currentItem else { return false }
            return VideoBufferingController.bufferedSeconds(
                in: item.loadedTimeRanges.map(\.timeRangeValue), at: player.currentTime().seconds) > 20
        }
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration, 30,
                       "A large disk window must not force the same-sized native memory buffer")
        let cachedDelegate = try XCTUnwrap((player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate
            as? BilibiliVideoResourceLoaderDelegate)
        try await eventually(timeout: 30) {
            (cachedDelegate.cacheSnapshot?.bufferedSeconds ?? 0) > 60
        }
        XCTAssertEqual(cachedDelegate.cacheSnapshot?.targetSeconds, 120)
        XCTAssertGreaterThanOrEqual(cachedDelegate.cacheSnapshot?.position ?? 0, Double(initialPosition))
        XCTAssertGreaterThan(cachedDelegate.cacheSnapshot?.storedBytes ?? 0, 0)
        XCTAssertGreaterThan(cachedDelegate.cacheSnapshot?.hits ?? 0, 0, "AVPlayer must actually consume cached fragments")
        XCTAssertFalse(cachedDelegate.masterPlaylist.contains("#EXT-X-I-FRAME-STREAM-INF"),
                       "Full GOPs are not a valid I-frame-only rendition")
        let item = try XCTUnwrap(player.currentItem)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(videoOutput)
        defer { item.remove(videoOutput) }
        var lastFrameTime = -1.0
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let time = player.currentTime()
            XCTAssertTrue(videoOutput.hasNewPixelBuffer(forItemTime: time), "A moving playback clock is not proof of moving video")
            var frameTime = CMTime.invalid
            let frame = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &frameTime)
            XCTAssertNotNil(frame, "The decoder must provide a new video frame")
            XCTAssertGreaterThan(frameTime.seconds, lastFrameTime)
            XCTAssertEqual(frameTime.seconds, time.seconds, accuracy: 1)
            lastFrameTime = frameTime.seconds
        }
        if let item = player.currentItem {
            print("Verified forward buffer: \(VideoBufferingController.bufferedSeconds(in: item.loadedTimeRanges.map(\.timeRangeValue), at: player.currentTime().seconds))s")
        }
        player.pause()
        container.autoPlayWhenReady = false
        let position = player.currentTime().seconds
        let stream = try XCTUnwrap(info.dash.video.enumerated().first { $0.element.codecs.hasPrefix("avc") })
        let switched = await plugin.switchQuality(to: stream.element.id, streamIndex: stream.offset)
        XCTAssertTrue(switched)
        XCTAssertFalse(container.autoPlayWhenReady, "A quality switch must not overwrite casting pause policy")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let nextPlayer = try XCTUnwrap(playerVC.player)
        XCTAssertEqual(nextPlayer.rate, 0, "Changing quality must preserve pause")
        XCTAssertEqual(nextPlayer.currentTime().seconds, position, accuracy: 1.5)
        let selector = BVideoQualityPlugin(detailData: detail) { _, _ in true }
        var current: [UIMenuElement] = []
        let menu = try XCTUnwrap(selector.addMenuItems(current: &current).first as? UIMenu)
        XCTAssertEqual(menu.title, "清晰度")
        XCTAssertTrue(menu.children.contains { $0.title == "默认 · \(Settings.mediaQuality.desp)" })
        let videoDetail = try await WebRequest.requestDetailVideo(aid: video.aid)
        let infoTabs = VideoPlayerInfoTabsPlugin(detail: videoDetail,
                                                currentPlayInfo: PlayInfo(aid: video.aid, cid: video.cid),
                                                sequenceProvider: nil)
        let followAction = try XCTUnwrap(infoTabs.addMenuItems(current: &current).first as? UIAction)
        XCTAssertEqual(followAction.identifier.rawValue, "follow-uploader")
        XCTAssertFalse(followAction.title.isEmpty)
        container.autoPlayWhenReady = true
        nextPlayer.play()
        try await eventually(timeout: 30) {
            playerVC.player?.timeControlStatus == .playing
                && (playerVC.player?.currentTime().seconds ?? 0) > position + 0.2
        }

        let resumedPlayer = try XCTUnwrap(playerVC.player)
        resumedPlayer.playImmediately(atRate: 1.5)
        try await Task.sleep(nanoseconds: 300_000_000)
        let failurePosition = resumedPlayer.currentTime().seconds
        let beforeDelegate = try XCTUnwrap((resumedPlayer.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate
            as? BilibiliVideoResourceLoaderDelegate)
        let beforeStream = beforeDelegate.streamDiagnostics(for: resumedPlayer.currentItem?.accessLog()?.events.last?.uri)
        let failedItem = try XCTUnwrap(resumedPlayer.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: failedItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey:
                                                    NSError(domain: "CoreMediaErrorDomain", code: -19602)])
        XCTAssertEqual(failedItem.status, .readyToPlay, "Reproduce the failure missed by status-only observation")
        try await eventually(timeout: 35) {
            guard let recovered = playerVC.player, recovered !== resumedPlayer else { return false }
            return recovered.timeControlStatus == .playing && recovered.currentTime().seconds > failurePosition + 1
        }
        let recovered = try XCTUnwrap(playerVC.player)
        XCTAssertTrue(container.manuallyManagedPlayerItem === recovered.currentItem)
        XCTAssertEqual(recovered.rate, 1.5, accuracy: 0.01)
        XCTAssertLessThan(recovered.currentTime().seconds, failurePosition + 15, "Do not restart or skip ahead on recovery")
        let recoveredDelegate = try XCTUnwrap((recovered.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate
            as? BilibiliVideoResourceLoaderDelegate)
        let recoveredStream = recoveredDelegate.streamDiagnostics(for: recovered.currentItem?.accessLog()?.events.last?.uri)
        XCTAssertEqual(recoveredStream.bandwidth, beforeStream.bandwidth)
        XCTAssertEqual(recoveredStream.codec, beforeStream.codec, "Recovery must preserve an explicitly selected stream")

        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: recovered.currentItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey:
                                                    NSError(domain: "CoreMediaErrorDomain", code: -19602)])
        recovered.pause()
        try await eventually { plugin.bufferingDetails?.isRecovering == false }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(playerVC.player === recovered, "A pause during probing must cancel the pending replacement")
        XCTAssertEqual(recovered.rate, 0, "A late recovery must never override an explicit pause")
    }

    @MainActor func testGuestLaunchAndAccountActionPrompt() async throws {
        guard !ApiRequest.isLogin() else { throw XCTSkip("Guest test requires a logged-out simulator") }
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let root = try XCTUnwrap(window.rootViewController)
        XCTAssertTrue(root is BLTabBarViewController, "Guests must launch directly into browsing")
        XCTAssertFalse(root.requireLivingAccount())
        try await Task.sleep(nanoseconds: 500_000_000)
        let prompt = try XCTUnwrap(root.presentedViewController as? UIAlertController)
        XCTAssertEqual(prompt.title, "登录后使用")
        XCTAssertTrue(prompt.actions.contains { $0.title == "继续游客浏览" && $0.style == .cancel })
        XCTAssertTrue(prompt.actions.contains { $0.title == "扫码登录" })
        root.dismiss(animated: false)
    }

    func testCastRequestValidationAndPlayURL() throws {
        let content = try LivingCastRequest.content(action: "Play", body: #"{"aid":"123","cid":"456","seekTs":"37.8","access_key":"ignored"}"#)
        let request = try LivingCastRequest(json: content)
        XCTAssertEqual(request.playInfo.aid, 123)
        XCTAssertEqual(request.playInfo.cid, 456)
        XCTAssertEqual(request.position, 37)
        let ext = #"{"content":{"aid":123,"cid":456,"seekTs":0}}"#
        var url = URLComponents(string: "https://example.com/video")!
        url.queryItems = [URLQueryItem(name: "nva_ext", value: ext)]
        let body = String(data: try JSONSerialization.data(withJSONObject: ["url": url.string!]), encoding: .utf8)!
        let wrapped = try LivingCastRequest.content(action: "PlayUrl", body: body)
        XCTAssertEqual(try LivingCastRequest(json: wrapped).position, 0)
        for body in [#"{"aid":0}"#, #"{"aid":123,"seekTs":-1}"#, #"{"aid":123,"seekTs":"NaN"}"#, #"{"aid":123,"seekTs":true}"#] {
            XCTAssertThrowsError(try LivingCastRequest(json: LivingCastRequest.content(action: "Play", body: body)))
        }
    }

    @MainActor func testBufferingRepeatedSeeksAndTeardown() async throws {
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/video")!)
        let controller = VideoBufferingController(item: item, target: 120, settlingDelay: 0.3)
        defer { controller.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: item)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 15, "An earlier seek must not restore a large buffer during another seek")
        controller.updateTarget(300)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 300)
        controller.prepareForSeek()
        controller.stop()
        item.preferredForwardBufferDuration = 30
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 30, "Teardown must cancel delayed buffer writes")
    }

    func testForwardBufferExcludesHolesAfterSeek() {
        func range(_ start: Double, _ duration: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 100),
                        duration: CMTime(seconds: duration, preferredTimescale: 100))
        }
        let ranges = [range(100, 30), range(0, 20), range(130, 10), range(150, 10)]
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: 110), 30, accuracy: 0.01)
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: 50), 0)
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: .nan), 0)
    }

    @MainActor func testCastUDPPortConflictStillReceivesMulticastSearch() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(false)
        let blocker = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(blocker, 0)
        defer { Darwin.close(blocker); receiver.setEnabled(false); receiver.setEnabled(previous) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1900).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        receiver.setEnabled(true)
        XCTAssertTrue(receiver.isRunning, receiver.status)
        let message = receiver.discoveryMessage(type: "upnp:rootdevice", notify: false)
        let location = try XCTUnwrap(message.components(separatedBy: "\r\n").first { $0.hasPrefix("LOCATION: ") })
        let interface = try XCTUnwrap(URL(string: String(location.dropFirst(10)))?.host)
        let probe = CastMulticastProbe()
        defer { probe.close() }
        try probe.search(interface: interface)
        // Other renderers (including the user's Apple TV) may answer first.
        // Wait for this receiver's advertised URL, not any device's response.
        try await eventually { probe.text.contains("HTTP/1.1 200 OK") && probe.text.contains(location) }
        XCTAssertTrue(probe.text.contains(location))
    }

    @MainActor func testCastPortConflictAndRapidRestart() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(false)
        let blocker = HttpServer()
        try blocker.start(9958, forceIPv4: true)
        defer { blocker.stop(); receiver.setEnabled(previous) }
        receiver.setEnabled(true)
        XCTAssertTrue(receiver.isRunning, receiver.status)
        XCTAssertNotEqual(receiver.httpPort, 9958)
        for _ in 0..<5 {
            receiver.setEnabled(false)
            receiver.setEnabled(true)
            XCTAssertTrue(receiver.isRunning, receiver.status)
            let port = receiver.httpPort
            XCTAssertTrue(receiver.discoveryMessage(type: "upnp:rootdevice", notify: false).contains(":\(port)/description.xml"))
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/description.xml")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(BiliBiliUpnpDMR.deviceName))
            let phone = CastTestPhone(port: port)
            try await phone.setup()
            try await eventually { receiver.connectedCount == 1 }
            phone.close()
            try await eventually { receiver.connectedCount == 0 }
        }
        receiver.setEnabled(false)
        blocker.stop()
    }

    @MainActor func testCastIdentityHandshakeAndReplyCorrelation() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer { receiver.setEnabled(previous) }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/description.xml")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.mimeType, "text/xml")
        let xml = String(decoding: data, as: UTF8.self)
        let deviceID = try XCTUnwrap(xml.range(of: #"(?<=<UDN>uuid:)XY[A-Z0-9]{35}(?=</UDN>)"#, options: .regularExpression).map { String(xml[$0]) })
        let discovery = receiver.discoveryMessage(type: "upnp:rootdevice", notify: false)
        XCTAssertTrue(discovery.contains("USN: uuid:\(deviceID)::upnp:rootdevice\r\n"))
        let (serviceData, serviceResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/dlna/NirvanaControl.xml")!)
        XCTAssertEqual((serviceResponse as? HTTPURLResponse)?.mimeType, "text/xml")
        let serviceXML = String(decoding: serviceData, as: UTF8.self)
        XCTAssertTrue(XMLParser(data: serviceData).parse())
        XCTAssertTrue(serviceXML.contains("<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"))
        XCTAssertTrue(serviceXML.contains("<specVersion>"))
        let phone = CastTestPhone(port: receiver.httpPort)
        defer { phone.close() }
        try await phone.setup()
        XCTAssertEqual(phone.handshakeHeaders["uuid"], deviceID)
        // Burst requests force the server reader to get ahead of the main-thread
        // handler. Each reply must still use its own request's sequence number.
        try await phone.send(CastTestPhone.command("GetVolume", sequence: 71)
                             + CastTestPhone.command("Pause", sequence: 96)
                             + CastTestPhone.command("GetVolume", sequence: 103))
        try await eventually { phone.replies[71] != nil && phone.replies[96] != nil && phone.replies[103] != nil }
        let volume = try JSONSerialization.jsonObject(with: XCTUnwrap(phone.replies[71])) as? [String: Int]
        XCTAssertEqual(volume?["volume"], 30)
        XCTAssertEqual(phone.replies[96], Data())
        try await eventually { phone.heartbeatCount > 0 }
        phone.close()
        try await eventually { receiver.connectedCount == 0 }
        let restored = CastTestPhone(port: receiver.httpPort)
        defer { restored.close() }
        try await restored.setup(method: "RESTORE")
        XCTAssertEqual(restored.handshakeHeaders["uuid"], deviceID)
        try await eventually { receiver.connectedCount == 1 && restored.text.contains("OnPlayState") }
    }

    @MainActor func testCastDiscoveryAndMalformedConnectionRecovery() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer { receiver.setEnabled(previous) }
        XCTAssertTrue(receiver.isRunning)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/description.xml")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(BiliBiliUpnpDMR.deviceName))
        let (_, debugResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/debug/log")!)
        XCTAssertEqual((debugResponse as? HTTPURLResponse)?.statusCode, 404)
        let discovery = CastTestPhone(port: 1900, udp: true)
        defer { discovery.close() }
        try await discovery.connect()
        try await discovery.send(Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nMX: 1\r\n\r\n".utf8))
        try await eventually { discovery.text.contains("HTTP/1.1 200 OK") }
        XCTAssertTrue(discovery.text.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
        let invalid = CastTestPhone(port: receiver.httpPort)
        try await invalid.setup()
        try await eventually { receiver.connectedCount == 1 }
        // A claimed 4 GB JSON body must close this connection without allocating it or crashing the app.
        var packet = CastTestPhone.command("Play", body: "")
        packet.replaceSubrange((packet.count - 4)..<packet.count, with: [255, 255, 255, 255])
        try await invalid.send(packet)
        try await eventually { receiver.connectedCount == 0 }
        invalid.close()
        let fresh = CastTestPhone(port: receiver.httpPort)
        defer { fresh.close() }
        try await fresh.setup()
        try await eventually { receiver.connectedCount == 1 }
        XCTAssertTrue(receiver.isRunning)
        try await fresh.send(CastTestPhone.command("Play", body: #"{"aid":0}"#))
        try await eventually { receiver.status.contains("有效的视频") }
        receiver.start() // Idempotent start must preserve an established phone connection.
        XCTAssertEqual(receiver.connectedCount, 1)
        receiver.didEnterBackground()
        XCTAssertFalse(receiver.isRunning)
        receiver.willEnterForeground()
        try await eventually { receiver.isRunning }
        receiver.setEnabled(false)
        XCTAssertFalse(receiver.isRunning)
        XCTAssertEqual(receiver.connectedCount, 0)
    }

    @MainActor func testCastLiveHandoffControlsAndReconnect() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        let previousDanmaku = Defaults.shared.showDanmu
        receiver.setEnabled(true)
        let phone = CastTestPhone(port: receiver.httpPort)
        let reconnected = CastTestPhone(port: receiver.httpPort)
        defer {
            phone.close(); reconnected.close()
            receiver.currentPlugin?.player?.pause()
            AppDelegate.shared.window?.rootViewController?.dismiss(animated: false)
            Defaults.shared.showDanmu = previousDanmaku
            receiver.setEnabled(previous)
        }
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first { $0.duration > 100 })
        try await phone.setup()
        try await eventually { receiver.connectedCount == 1 }
        try await phone.send(CastTestPhone.command("GetVolume", sequence: 51))
        try await eventually { phone.replies[51] != nil }
        let payload = "{\"aid\":\(video.aid),\"cid\":\(video.cid),\"seekTs\":37}"
        try await phone.send(CastTestPhone.command("Play", body: payload))
        try await eventually(timeout: 60) {
            guard let player = receiver.currentPlugin?.player else { return false }
            return player.rate > 0 && player.currentTime().seconds >= 37 && player.currentTime().seconds < 43
        }
        // Replace an active cast. All three commands arrive before the new stream has loaded.
        try await phone.send(CastTestPhone.command("Play", body: payload)
                             + CastTestPhone.command("Pause")
                             + CastTestPhone.command("Seek", body: #"{"seekTs":54}"#))
        try await eventually(timeout: 60) {
            guard let player = receiver.currentPlugin?.player else { return false }
            return player.currentItem?.status == .readyToPlay && abs(player.currentTime().seconds - 54) < 2
        }
        let player = try XCTUnwrap(receiver.currentPlugin?.player)
        XCTAssertEqual(player.rate, 0, "Pause received while loading must survive startup")
        try await phone.send(CastTestPhone.command("Resume"))
        try await eventually { player.currentTime().seconds > 56 }
        try await phone.send(CastTestPhone.command("SwitchDanmaku", body: #"{"open":"false"}"#))
        try await eventually { !Defaults.shared.showDanmu }
        try await phone.send(CastTestPhone.command("Seek", body: #"{"seekTs":70}"#))
        try await eventually { player.currentTime().seconds >= 70 }
        phone.close()
        try await eventually { receiver.connectedCount == 0 }
        let position = player.currentTime().seconds
        try await eventually { player.currentTime().seconds > position + 1 }
        try await reconnected.setup(method: "RESTORE")
        try await eventually { receiver.connectedCount == 1 && reconnected.text.contains("OnProgress") }
        XCTAssertTrue(reconnected.text.contains("OnPlayState"))
        try await reconnected.send(CastTestPhone.command("Stop"))
        try await eventually { receiver.currentPlugin == nil && AppDelegate.shared.window?.rootViewController?.presentedViewController == nil }
    }

    func testSOAPParsingAndValidation() throws {
        let body = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>
        <CurrentURI>https://example.com/video?a=1&amp;b=2</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite&gt;中文&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
        </u:SetAVTransportURI></s:Body></s:Envelope>
        """.utf8)
        let request = try LivingCastSOAP.Request(body: body, soapAction: "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        XCTAssertEqual(request.arguments["CurrentURI"], "https://example.com/video?a=1&b=2")
        XCTAssertEqual(request.arguments["CurrentURIMetaData"], "<DIDL-Lite>中文</DIDL-Lite>")
        XCTAssertThrowsError(try LivingCastSOAP.Request(body: body, soapAction: "urn:schemas-upnp-org:service:AVTransport:1#Play"))
        XCTAssertThrowsError(try LivingCastSOAP.Request(body: Data("<broken>".utf8), soapAction: nil))
        XCTAssertThrowsError(try LivingCastSOAP.Media(uri: "file:///private/test"))
        XCTAssertThrowsError(try LivingCastSOAP.Media(uri: "https://example.com/video?nva_ext=invalid"))
        XCTAssertEqual(LivingCastSOAP.seconds("01:02:03.5"), 3723.5)
        for invalid in ["-1:00:00", "00:60:00", "00:00:NaN", "00:00:inf", "37"] {
            XCTAssertNil(LivingCastSOAP.seconds(invalid))
        }
    }

    @MainActor func testSOAPRealPlaybackControlsAndMediaReplacement() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer {
            receiver.currentPlugin?.player?.pause()
            AppDelegate.shared.window?.rootViewController?.dismiss(animated: false)
            receiver.setEnabled(previous)
        }
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first { $0.duration > 100 })
        let ext = "{\"content\":{\"aid\":\(video.aid),\"cid\":\(video.cid),\"seekTs\":37}}"
        var url = URLComponents(string: "https://example.com/cast")!
        url.queryItems = [URLQueryItem(name: "nva_ext", value: ext), URLQueryItem(name: "test", value: "1&2")]
        // Exercise both paths through actual HTTP, without an NVA session.
        let sources = [url.string!, "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"]
        for (index, source) in sources.enumerated() {
            _ = try await soap("SetAVTransportURI", ["CurrentURI": source, "CurrentURIMetaData": "<DIDL-Lite>测试</DIDL-Lite>"], port: receiver.httpPort)
            let stopped = try await soap("GetTransportInfo", port: receiver.httpPort)
            XCTAssertTrue(stopped.contains("<CurrentTransportState>STOPPED</CurrentTransportState>"))
            _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
            try await eventually(timeout: 60) {
                guard let player = receiver.currentPlugin?.player else { return false }
                return player.rate > 0 && player.currentTime().seconds > (index == 0 ? 38 : 1)
            }
            let player = try XCTUnwrap(receiver.currentPlugin?.player)
            let playing = try await soap("GetTransportInfo", port: receiver.httpPort)
            XCTAssertTrue(playing.contains("<CurrentTransportState>PLAYING</CurrentTransportState>"))
            let position = try await soap("GetPositionInfo", port: receiver.httpPort)
            XCTAssertFalse(position.contains("<TrackDuration>00:00:00</TrackDuration>"))
            _ = try await soap("Pause", port: receiver.httpPort)
            try await eventually { player.rate == 0 }
            _ = try await soap("Seek", ["Unit": "REL_TIME", "Target": "00:00:54"], port: receiver.httpPort)
            try await eventually { abs(player.currentTime().seconds - 54) < 2 }
            XCTAssertEqual(player.rate, 0)
            _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
            try await eventually { player.currentTime().seconds > 55 }
        }
        _ = try await soap("Stop", port: receiver.httpPort)
        try await eventually { receiver.currentPlugin == nil && AppDelegate.shared.window?.rootViewController?.presentedViewController == nil }
        _ = try await soap("Seek", ["Unit": "REL_TIME", "Target": "00:00:10"], port: receiver.httpPort, expectedStatus: 500)
        _ = try await soap("SetAVTransportURI", ["CurrentURI": "file:///invalid", "CurrentURIMetaData": ""], port: receiver.httpPort, expectedStatus: 500)
        // A fault must not poison the previously accepted media or the service.
        _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
        try await eventually(timeout: 60) { (receiver.currentPlugin?.player?.currentTime().seconds ?? 0) > 1 }
        _ = try await soap("Stop", port: receiver.httpPort)
    }

    private func soap(_ action: String, _ arguments: [String: String] = [:], port: UInt16, expectedStatus: Int = 200) async throws -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let service = "urn:schemas-upnp-org:service:AVTransport:1"
        let values = arguments.sorted { $0.key < $1.key }.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action) xmlns:u=\"\(service)\"><InstanceID>0</InstanceID>\(values)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/AVTransport/action")!)
        request.httpMethod = "POST"
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
        XCTAssertTrue(XMLParser(data: data).parse(), "SOAP response must be valid XML")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(expectedStatus == 200 ? "\(action)Response" : "UPnPError"))
        return text
    }

    func testCastVideoHintUsesTrustedCDNAndXMLTitle() throws {
        let uri = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/70/08/38601820870/38601820870-1-192.mp4?ignored=1"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>标题 &amp; 分P</dc:title></item></DIDL-Lite>"
        let hint = try XCTUnwrap(LivingCastVideoHint(url: URL(string: uri)!, metadata: metadata))
        XCTAssertEqual(hint.cid, 38601820870)
        XCTAssertEqual(hint.title, "标题 & 分P")
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri.replacingOccurrences(of: "upos-hz-mirrorakam.akamaized.net", with: "unrelated.example"))!, metadata: metadata))
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri.replacingOccurrences(of: "38601820870-1", with: "123-1"))!, metadata: metadata))
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri)!, metadata: "<broken>")?.title)
    }

    @MainActor func testCastCapturedVideoResolvesByExactCID() async throws {
        // Only public title/CID from the real DLNA report; no signed URL or phone credentials.
        let uri = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/70/08/38601820870/38601820870-1-192.mp4"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>老戴《007 初露锋芒》最高难度剧情流程攻略解说</dc:title></item></DIDL-Lite>"
        let hint = try XCTUnwrap(LivingCastVideoHint(url: URL(string: uri)!, metadata: metadata))
        let resolved = await LivingCastVideoResolver.resolve(hint)
        let info = try XCTUnwrap(resolved, "The user's actual cast must resolve within the startup deadline")
        let detail = try await WebRequest.requestDetailVideo(aid: info.aid)
        XCTAssertEqual(info.cid, hint.cid)
        XCTAssertNotNil(LivingCastVideoResolver.matchingPage(in: detail.View, cid: hint.cid))
        XCTAssertNil(LivingCastVideoResolver.matchingPage(in: detail.View, cid: 1), "Never select a same-title video with a different CID")
        let playerVC = VideoPlayerViewController(playInfo: info, startTimeOverride: 0)
        let root = try XCTUnwrap(AppDelegate.shared.window?.rootViewController)
        root.present(playerVC, animated: false)
        defer { playerVC.stopPlayback(); playerVC.dismiss(animated: false) }
        try await eventually(timeout: 60) {
            let player = (playerVC.children.first as? AVPlayerViewController)?.player
            return (player?.currentTime().seconds ?? 0) > 1
        }
        let av = try XCTUnwrap(playerVC.children.first as? AVPlayerViewController)
        func titles(_ items: [UIMenuElement]) -> [String] { items.flatMap { [$0.title] + (($0 as? UIMenu).map { titles($0.children) } ?? []) } }
        let menuTitles = titles(av.transportBarCustomMenuItems)
        XCTAssertTrue(menuTitles.contains(where: { $0.contains("清晰度") }))
        XCTAssertTrue(menuTitles.contains("Show Danmu"))
        playerVC.stopPlayback()
        await withCheckedContinuation { continuation in
            playerVC.dismiss(animated: false) { continuation.resume() }
        }
    }

    @MainActor func testDirectCastStreamRendersRealDanmaku() async throws {
        let previousShow = Defaults.shared.showDanmu
        let previousAI = Settings.danmuAILevel
        let previousFilter = Settings.enableDanmuFilter
        Defaults.shared.showDanmu = true
        Settings.danmuAILevel = 1
        Settings.enableDanmuFilter = false
        let cid = 38601820870
        let list = try await WebRequest.requestDanmuList(cid: cid, segmentIdx: 1)
        let comment = try XCTUnwrap(list.elems.first { $0.mode == 1 && $0.progress > 3000 && $0.progress < 100000 })
        // Isolate overlay wiring with a stable playable HLS fixture and actual
        // Bilibili comments; title/CID identity is covered by the resolver test.
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!
        let vc = LivingURLCastViewController(url: url, context: LivingCastContext(), danmakuCID: cid)
        let root = try XCTUnwrap(AppDelegate.shared.window?.rootViewController)
        root.present(vc, animated: false)
        defer {
            vc.stopPlayback(); vc.dismiss(animated: false)
            Defaults.shared.showDanmu = previousShow
            Settings.danmuAILevel = previousAI
            Settings.enableDanmuFilter = previousFilter
        }
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        try await eventually(timeout: 30) {
            descendants(vc.view).contains { $0 is DanmakuView } &&
            ((vc.children.first as? AVPlayerViewController)?.player?.currentTime().seconds ?? 0) > 1
        }
        let av = try XCTUnwrap(vc.children.first as? AVPlayerViewController)
        let player = try XCTUnwrap(av.player)
        await player.seek(to: CMTime(seconds: max(0, Double(comment.progress) / 1000 - 2), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually(timeout: 15) { descendants(vc.view).contains { $0 is DanmakuCell } }
        func titles(_ items: [UIMenuElement]) -> [String] { items.flatMap { [$0.title] + (($0 as? UIMenu).map { titles($0.children) } ?? []) } }
        XCTAssertTrue(titles(av.transportBarCustomMenuItems).contains("Show Danmu"))
        vc.stopPlayback()
        await withCheckedContinuation { continuation in
            vc.dismiss(animated: false) { continuation.resume() }
        }
    }

    @MainActor func testHomeAccountSwitchDiscardsOldRecommendations() async throws {
        var account: Int? = 1
        var oldResponse: CheckedContinuation<LivingHomePage, Error>?
        let old = LivingHomeVideo(aid: 1, cid: 1, title: "old", ownerName: "", pic: nil)
        let new = LivingHomeVideo(aid: 2, cid: 2, title: "new", ownerName: "", pic: nil)
        let model = LivingHomeModel(currentAccount: { account }) { mid, _, _ in
            if mid == 1 { return try await withCheckedThrowingContinuation { oldResponse = $0 } }
            return LivingHomePage(videos: [new], nextCursor: 10, hasMore: true)
        }
        let oldLoad = Task { await model.load() }
        try await eventually { oldResponse != nil }
        account = 2
        await model.load()
        oldResponse?.resume(returning: LivingHomePage(videos: [old], nextCursor: 99, hasMore: true))
        await oldLoad.value
        XCTAssertEqual(model.videos, [new])
        XCTAssertEqual(model.accountMID, 2)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.isPersonalized)
    }

    @MainActor func testHomePaginationDeduplicationAndRetry() async throws {
        let a = LivingHomeVideo(aid: 1, cid: 1, title: "A", ownerName: "", pic: nil)
        let b = LivingHomeVideo(aid: 2, cid: 2, title: "B", ownerName: "", pic: nil)
        var calls: [(Int, Int)] = []
        var fail = false
        let model = LivingHomeModel(currentAccount: { 42 }) { mid, cursor, page in
            XCTAssertEqual(mid, 42)
            calls.append((cursor, page))
            if fail { throw NSError(domain: "HomeTest", code: 1) }
            return cursor == 0 ? LivingHomePage(videos: [a, a], nextCursor: 10, hasMore: true)
                : LivingHomePage(videos: [a, b], nextCursor: 20, hasMore: true)
        }
        await model.load()
        XCTAssertEqual(model.videos, [a])
        fail = true
        await model.loadMore()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.videos, [a])
        fail = false
        await model.retry()
        XCTAssertEqual(model.videos, [a, b])
        XCTAssertEqual(calls.map { $0.0 }, [0, 10, 10])
        XCTAssertEqual(calls.map { $0.1 }, [1, 2, 2])
        await model.loadMore()
        XCTAssertFalse(model.hasMore, "Duplicate-only pages must not trigger endless automatic requests")
        fail = true
        await model.load()
        XCTAssertNotNil(model.error)
        fail = false
        await model.retry()
        XCTAssertEqual(model.videos, [a], "Retry of a failed refresh replaces the old batch")
    }

    @MainActor func testHomeLogoutClearsAccountContentOnFailure() async {
        var account: Int? = 42
        var requested: [Int?] = []
        let video = LivingHomeVideo(aid: 1, cid: 1, title: "account", ownerName: "", pic: nil)
        let model = LivingHomeModel(currentAccount: { account }) { mid, _, _ in
            requested.append(mid)
            if mid == nil { throw NSError(domain: "HomeTest", code: 1) }
            return LivingHomePage(videos: [video], nextCursor: 1, hasMore: true)
        }
        await model.load()
        account = nil
        await model.load()
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertFalse(model.isPersonalized)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(requested.count, 2)
        XCTAssertNil(requested.last!)
    }

    @MainActor func testLiveHomeRecommendationSource() async throws {
        // Exercises the real signed app feed, without inventing an account token.
        let items = try await ApiRequest.getFeeds()
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.goto == "av" && !$0.title.isEmpty })
        let guest = try await LivingHomeSource.fetch(accountMID: nil, cursor: 0, page: 1)
        XCTAssertFalse(guest.videos.isEmpty)
    }

    @MainActor private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for casting state")
        throw NSError(domain: "CastingTest", code: 1)
    }

}

@MainActor private final class HDRPlaybackFrameCadenceProbe: NSObject {
    private let output: AVPlayerItemVideoOutput
    private var link: CADisplayLink?
    private var callbacks = 0
    private var frames = 0
    private var firstHost: CFTimeInterval?
    private var lastHost = 0.0
    private var firstFrame: Double?
    private var lastFrame = -1.0

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
        super.init()
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var summary: String {
        let hostDuration = lastHost - (firstHost ?? lastHost)
        return "callbacks=\(callbacks) fresh=\(frames) refreshHz=\(hostDuration > 0 ? Double(max(0, callbacks - 1)) / hostDuration : 0) sampledVideoFPS=\(sampledVideoFPS) lastFrame=\(lastFrame)"
    }

    var sampledVideoFPS: Double {
        let duration = lastFrame - (firstFrame ?? lastFrame)
        return duration > 0 ? Double(max(0, frames - 1)) / duration : 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        callbacks += 1
        if firstHost == nil { firstHost = link.timestamp }
        lastHost = link.timestamp
        let time = output.itemTime(forHostTime: link.timestamp)
        var displayTime = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: time),
           output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) != nil,
           displayTime.seconds > lastFrame {
            frames += 1
            if firstFrame == nil { firstFrame = displayTime.seconds }
            lastFrame = displayTime.seconds
        }
    }
}

private struct HDRPlaybackTestFixture: Sendable {
    let file: URL
    let playlist: String
    let payload: Data
    let mimeType: String

    static func prepare(media: VideoPlayURLInfo.DashInfo.DashMediaInfo, aid: Int,
                        name: String, directory: URL) async throws -> HDRPlaybackTestFixture {
        let downloader = SidxDownloader()
        let downloadedIndex = await downloader.sidx(from: media)
        let result = try XCTUnwrap(downloadedIndex)
        let indexEnd = try XCTUnwrap(media.segment_base.index_range.split(separator: "-").last.flatMap { Int($0) })
        let initialization = media.segment_base.initialization.split(separator: "-").compactMap { Int($0) }
        XCTAssertEqual(initialization.count, 2)
        guard initialization.count == 2, result.sidx.timescale > 0 else {
            throw VideoSegmentCache.CacheError.invalidTrack
        }
        let mediaStart = indexEnd + 1 + result.sidx.firstOffset
        var offset = mediaStart
        var time = 0.0
        var segments = [VideoSegmentCache.Segment(range: 0..<mediaStart, start: 0, duration: 0)]
        for entry in result.sidx.segments.prefix(3) {
            let duration = Double(entry.duration) / Double(result.sidx.timescale)
            segments.append(.init(range: offset..<(offset + entry.size), start: time, duration: duration))
            offset += entry.size
            time += duration
        }
        let urls = BilibiliVideoResourceLoaderDelegate.uniqueHostURLs([result.url] + media.playableURLs).compactMap(URL.init(string:))
        let cache = try VideoSegmentCache(headers: ["User-Agent": Keys.userAgent, "Referer": Keys.referer(for: aid)],
                                         diagnosticID: "hdr-fixture-\(name)")
        let file = directory.appendingPathComponent("\(name).mp4")
        do {
            try await cache.register(.init(id: name, isVideo: (media.width ?? 0) > 0, isPrimary: true,
                                           mimeType: media.mime_type, urls: urls, segments: segments))
            try await cache.prebuffer(at: 0, target: time, minimum: time, maximumWait: 30)
            var data = Data()
            for index in segments.indices {
                let response = try await cache.response(track: name, index: index, rangeHeader: nil)
                data.append(response.data)
            }
            try data.write(to: file, options: .atomic)
            await cache.stop()
            var playlist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:\(result.sidx.maxSegmentDuration() ?? 6)
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="\(name).mp4",BYTERANGE="\(initialization[1] - initialization[0] + 1)@\(initialization[0])"

            """
            for segment in segments.dropFirst() {
                playlist += "#EXTINF:\(segment.duration),\n#EXT-X-BYTERANGE:\(segment.range.count)@\(segment.range.lowerBound)\n\(name).mp4\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            Logger.info("[hdr-fixture] name=\(name) codec=\(media.codecs) bytes=\(data.count) seconds=\(time) sourceFPS=\(media.frame_rate ?? "-")")
            return HDRPlaybackTestFixture(file: file, playlist: playlist, payload: data, mimeType: media.mime_type)
        } catch {
            await cache.stop()
            throw error
        }
    }

    func response(_ request: HttpRequest) -> HttpResponse {
        do {
            Logger.info("[hdr-matrix-http] file=\(file.lastPathComponent) method=\(request.method) range=\(request.headers["range"] ?? "all")")
            let range = try VideoSegmentCache.responseRange(request.headers["range"], length: payload.count)
            var headers = ["Content-Length": "\(range.count)", "Content-Type": mimeType, "Accept-Ranges": "bytes"]
            if request.headers["range"] != nil {
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(payload.count)"
            }
            return .raw(request.headers["range"] == nil ? 200 : 206, "OK", headers) { writer in
                if request.method != "HEAD" { try writer.write(payload.subdata(in: range)) }
            }
        } catch {
            Logger.warn("[hdr-fixture] invalid local range: \(PlaybackDiagnostics.error(error))")
            return .raw(416, "Range Not Satisfiable", ["Content-Length": "0"], nil)
        }
    }
}

private final class SegmentCacheTestOrigin: @unchecked Sendable {
    let payload: Data
    private let server = HttpServer()
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximumActive = 0
    private var offsets = [Int]()
    private var hasFailedOnce = false
    private var port = 0

    var url: URL { URL(string: "http://127.0.0.1:\(port)/media")! }
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    var maximumActiveRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }
    var requestedOffsets: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return offsets
    }

    init(truncated: Bool = false, delay: TimeInterval = 0, failingOffset: Int? = nil,
         ignoresRange: Bool = false, payloadBytes: Int = 128, failOnceAt: Int? = nil,
         secondsPerChunk: TimeInterval = 0) throws {
        payload = Data((0..<payloadBytes).map { UInt8($0 % 251) })
        server.listenAddressIPv4 = "127.0.0.1"
        server["/media"] = { [weak self] request in
            guard let self else { return .notFound() }
            self.lock.lock()
            self.count += 1
            self.active += 1
            self.maximumActive = max(self.maximumActive, self.active)
            if let start = request.headers["range"]?.dropFirst(6).split(separator: "-").first.flatMap({ Int($0) }) {
                self.offsets.append(start)
            }
            self.lock.unlock()
            defer {
                self.lock.lock()
                self.active -= 1
                self.lock.unlock()
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if ignoresRange { return .ok(.data(self.payload, contentType: "video/mp4")) }
            do {
                let range = try VideoSegmentCache.responseRange(request.headers["range"], length: self.payload.count)
                if secondsPerChunk > 0 {
                    Thread.sleep(forTimeInterval: secondsPerChunk * Double(range.count) / Double(VideoSegmentCache.downloadChunkBytes))
                }
                self.lock.lock()
                let failOnce = !self.hasFailedOnce && range.lowerBound == failOnceAt
                if failOnce { self.hasFailedOnce = true }
                self.lock.unlock()
                let requested = self.payload.subdata(in: range)
                let data = truncated || range.lowerBound == failingOffset || failOnce ? Data(requested.dropLast()) : requested
                return .raw(206, "Partial Content",
                            ["Content-Type": "video/mp4", "Content-Length": "\(data.count)",
                             "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(self.payload.count)"],
                            { try $0.write(data) })
            } catch { return .badRequest(.text(error.localizedDescription)) }
        }
        try server.start(0, forceIPv4: true)
        port = try server.port()
    }

    func track(urls: [URL]? = nil) -> VideoSegmentCache.Track {
        let initialization = VideoSegmentCache.Segment(range: 0..<4, start: 0, duration: 0)
        let media = (0..<20).map {
            VideoSegmentCache.Segment(range: (4 + $0 * 4)..<(8 + $0 * 4), start: Double($0) * 5, duration: 5)
        }
        return .init(id: "video", isVideo: true, isPrimary: true, mimeType: "video/mp4",
                     urls: urls ?? [url], segments: [initialization] + media)
    }

    func largeTrack() -> VideoSegmentCache.Track {
        .init(id: "video", isVideo: true, isPrimary: true, mimeType: "video/mp4", urls: [url],
              segments: [.init(range: 0..<4, start: 0, duration: 0),
                         .init(range: 4..<payload.count, start: 0, duration: 5)])
    }

    func stop() { server.stop() }
    deinit { stop() }
}

private final class FailureRecoveryTestPlugin: NSObject, CommonPlayerPlugin {
    var recoveryCount = 0
    var failureCount = 0
    var error: Error?

    func recoverPlayback(player: AVPlayer, error: Error?) -> Bool {
        recoveryCount += 1
        self.error = error
        return true
    }

    func playerDidFail(player: AVPlayer) { failureCount += 1 }
}

/// A phone-side NVA client over real TCP/UDP sockets, independent of the receiver's frame decoder.
@MainActor private final class CastTestPhone {
    private let connection: NWConnection
    private let port: UInt16
    private var received = Data()
    private var wire = Data()
    private(set) var handshakeHeaders: [String: String] = [:]
    private(set) var replies: [UInt32: Data] = [:]
    private(set) var heartbeatCount = 0
    private var protocolError: Error?
    private var expectsNVA = false
    var text: String { String(decoding: received, as: UTF8.self) }
    init(port: UInt16 = 9958, udp: Bool = false) {
        self.port = port
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: udp ? .udp : .tcp)
    }
    func connect() async throws {
        connection.start(queue: DispatchQueue(label: "casting.test.phone"))
        let deadline = Date().addingTimeInterval(5)
        while connection.state != .ready {
            guard Date() < deadline else { throw NSError(domain: "CastConnect", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        receive()
    }
    func setup(method: String = "SETUP") async throws {
        expectsNVA = true
        try await connect()
        try await send(Data("\(method) /projection NVA/1.0\r\nHost: 127.0.0.1:\(port)\r\nSession: simulator-phone\r\nNvaVersion: 1\r\nConnection: Keep-Alive\r\nContent-Length: 0\r\n\r\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while handshakeHeaders.isEmpty {
            if let protocolError { throw protocolError }
            guard Date() < deadline else { throw NSError(domain: "CastSetup", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func parseWire() throws {
        guard expectsNVA else { return }
        if handshakeHeaders.isEmpty {
            guard let end = wire.range(of: Data("\r\n\r\n".utf8)) else { return }
            let lines = String(decoding: wire[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard lines.first == "NVA/1.0 200 OK" else { throw NSError(domain: "NVAStatusLine", code: 1) }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard headers["session"] == "simulator-phone", headers["nvaversion"] == "1",
                  headers["content-length"] == "0", headers["connection"]?.lowercased() == "keep-alive" else {
                throw NSError(domain: "NVAHeaders", code: 1)
            }
            handshakeHeaders = headers
            wire = Data(wire[end.upperBound...])
        }
        while wire.count >= 6 {
            let bytes = [UInt8](wire)
            let kind = bytes[0], count = bytes[1]
            let sequence = bytes[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var offset = 6
            if kind == 0xe0 {
                guard count == 2 || count == 3 else { throw NSError(domain: "NVAFrame", code: 1) }
                guard bytes.count >= 8 else { return }
                guard bytes[6] == 1 else { throw NSError(domain: "NVAFrame", code: 2) }
                offset = 8 + Int(bytes[7])
                guard bytes.count > offset else { return }
                offset += 1 + Int(bytes[offset])
                guard bytes.count >= offset else { return }
            } else if !((kind == 0xc0 && count <= 1) || (kind == 0xe4 && count == 0)) {
                throw NSError(domain: "NVAFrame", code: 3)
            }
            var body = Data()
            if (kind == 0xc0 && count == 1) || (kind == 0xe0 && count == 3) {
                guard bytes.count >= offset + 4 else { return }
                let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                guard length <= 1_048_576 else { throw NSError(domain: "NVAFrame", code: 4) }
                guard bytes.count >= offset + length else { return }
                body = Data(bytes[offset..<offset + length])
                offset += length
            }
            wire = Data(bytes.dropFirst(offset))
            if kind == 0xc0 { replies[sequence] = body }
            if kind == 0xe4 {
                heartbeatCount += 1
                var reply = Data([0xc0, 0])
                reply.append(contentsOf: bytes[2..<6])
                Task { try? await self.send(reply) }
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.received.append(data)
                    self.wire.append(data)
                    do { try self.parseWire() } catch { self.protocolError = error }
                }
                if !ended && error == nil { self.receive() }
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func close() { connection.cancel() }
    static func command(_ action: String, body: String = "", sequence: UInt32 = 1) -> Data {
        var data = Data([0xe0, 0x03])
        data.append(contentsOf: [UInt8((sequence >> 24) & 255), UInt8((sequence >> 16) & 255), UInt8((sequence >> 8) & 255), UInt8(sequence & 255), 1, 7])
        data.append(Data("Command".utf8))
        data.append(UInt8(action.utf8.count))
        data.append(Data(action.utf8))
        let length = UInt32(body.utf8.count)
        data.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(Data(body.utf8))
        return data
    }
}

/// Uses real LAN multicast, including an unconnected socket for the unicast reply.
private final class CastMulticastProbe: NSObject, GCDAsyncUdpSocketDelegate {
    private lazy var udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: .main)
    private(set) var text = ""

    func search(interface: String) throws {
        udp.setIPv6Enabled(false)
        try udp.bind(toPort: 0)
        var failure: NSError?
        udp.perform {
            var address = in_addr()
            inet_pton(AF_INET, interface, &address)
            if setsockopt(self.udp.socket4FD(), IPPROTO_IP, IP_MULTICAST_IF,
                          &address, socklen_t(MemoryLayout<in_addr>.size)) != 0 {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        if let failure { throw failure }
        try udp.beginReceiving()
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: upnp:rootdevice\r\nMX: 1\r\n\r\n"
        udp.send(Data(request.utf8), toHost: "239.255.255.250", port: 1900, withTimeout: 2, tag: 0)
    }

    func close() { udp.close() }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        text += String(decoding: data, as: UTF8.self)
    }
}
