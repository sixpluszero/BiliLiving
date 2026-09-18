//
//  PlayerMediaWarmup.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/4.
//

import AVFoundation
import Foundation

final class PreparedPlayerMedia: @unchecked Sendable {
    let asset: AVURLAsset
    let delegate: BilibiliVideoResourceLoaderDelegate

    init(asset: AVURLAsset, delegate: BilibiliVideoResourceLoaderDelegate) {
        self.asset = asset
        self.delegate = delegate
    }
}

enum PlayerMediaFactory {
    static func prepare(aid: Int,
                        urlInfo: VideoPlayURLInfo,
                        playerInfo: PlayerInfo?,
                        maxQuality: Int? = nil,
                        streamIndex: Int? = nil,
                        preferredHost: String? = nil,
                        preferences: PlayerMediaPreferences = .current) async throws -> PreparedPlayerMedia
    {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let delegate = BilibiliVideoResourceLoaderDelegate()
        let started = ProcessInfo.processInfo.systemUptime
        var stage = "manifest"
        defer {
            Logger.info("[media-prepare] id=\(delegate.diagnosticID) aid=\(aid) asset=\(ObjectIdentifier(asset)) lastStage=\(stage) elapsed=\(ProcessInfo.processInfo.systemUptime - started)s cancelled=\(Task.isCancelled)")
        }
        Logger.info("[media-prepare] id=\(delegate.diagnosticID) aid=\(aid) asset=\(ObjectIdentifier(asset)) begin quality=\(preferences.quality.qn) maxQuality=\(maxQuality ?? 0) streamIndex=\(streamIndex ?? -1)")
        delegate.setBilibili(info: urlInfo,
                             subtitles: playerInfo?.subtitle?.subtitles ?? [],
                             aid: aid,
                             maxQuality: maxQuality,
                             streamIndex: streamIndex,
                             preferredHost: preferredHost,
                             preferences: preferences)
        // Warmed/sequence playback also needs throughput selection; preparing
        // only SIDX measures latency and used to bypass the normal CDN probe.
        stage = "cdn-probe"
        await delegate.selectPreferredCDNIfNeeded()
        try Task.checkCancellation()
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "loader.\(aid).\(UUID().uuidString)"))
        try Task.checkCancellation()
        stage = "asset-isPlayable"
        Logger.info("[media-prepare] id=\(delegate.diagnosticID) stage=\(stage) elapsed=\(ProcessInfo.processInfo.systemUptime - started)s")
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard playable else {
            throw "加载资源失败"
        }
        stage = "sidx-prewarm"
        Logger.info("[media-prepare] id=\(delegate.diagnosticID) stage=\(stage) elapsed=\(ProcessInfo.processInfo.systemUptime - started)s")
        try await withTaskCancellationHandler {
            await delegate.prewarmPrimaryVideoIndex()
            try Task.checkCancellation()
        } onCancel: {
            delegate.cancelPendingIndexLoads()
        }
        stage = "prepared"
        return PreparedPlayerMedia(asset: asset, delegate: delegate)
    }
}

actor PlayerMediaWarmupManager {
    struct CacheKey: Hashable {
        let sequenceKey: String
        let preferences: PlayerMediaPreferences
    }

    private struct InFlightEntry {
        let token: UUID
        let task: Task<PreparedPlayerMedia, Error>
    }

    private let maxPreparedEntries = 4
    private let playContextCache: PlayContextCache
    private var prepared = [CacheKey: PreparedPlayerMedia]()
    private var inFlight = [CacheKey: InFlightEntry]()
    private var accessOrder = [CacheKey]()
    private var cancellationGeneration = 0

    init(playContextCache: PlayContextCache) {
        self.playContextCache = playContextCache
    }

    func preload(playInfo: PlayInfo) async {
        _ = try? await preparedMedia(for: playInfo)
    }

    func preparedMedia(for playInfo: PlayInfo) async throws -> PreparedPlayerMedia {
        let generation = cancellationGeneration
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        guard cancellationGeneration == generation else { throw CancellationError() }
        let preferences = PlayerMediaPreferences.current
        let key = CacheKey(sequenceKey: resolvedPlayInfo.sequenceKey, preferences: preferences)
        if let cached = prepared[key] {
            touch(key)
            return cached
        }
        if let entry = inFlight[key] {
            return try await resolve(entry, for: key)
        }

        let token = UUID()
        let task = Task<PreparedPlayerMedia, Error> {
            try Task.checkCancellation()
            let snapshot = try await playContextCache.context(for: resolvedPlayInfo, mode: .regular)
            try Task.checkCancellation()
            return try await PlayerMediaFactory.prepare(
                aid: resolvedPlayInfo.aid,
                urlInfo: snapshot.videoPlayURLInfo,
                playerInfo: snapshot.playerInfo,
                preferences: preferences
            )
        }

        let entry = InFlightEntry(token: token, task: task)
        inFlight[key] = entry
        return try await resolve(entry, for: key)
    }

    private func resolve(_ entry: InFlightEntry, for key: CacheKey) async throws -> PreparedPlayerMedia {
        do {
            let media = try await entry.task.value
            if let cached = prepared[key] {
                touch(key)
                return cached
            }
            guard inFlight[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlight[key] = nil
            prepared[key] = media
            touch(key)
            trimToCapacity()
            return media
        } catch {
            if inFlight[key]?.token == entry.token {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func cancelAll() {
        cancellationGeneration += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        prepared.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ key: CacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimToCapacity() {
        while prepared.count > maxPreparedEntries, let key = accessOrder.first {
            accessOrder.removeFirst()
            prepared[key] = nil
        }
    }
}
