//
//  BVideoPlayPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/24.
//

import AVKit
import UIKit

class BVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    private weak var playerVC: AVPlayerViewController?
    private var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    private var preparingDelegate: BilibiliVideoResourceLoaderDelegate?
    private var pendingCachePosition: Double?
    private var bufferingController: VideoBufferingController?
    private let playInfo: PlayInfo
    private let playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private let minimizeStalling: Bool
    private let isMuted: Bool
    private let proactiveBuffering: Bool
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private var currentQualityId: Int?
    private var hasAppliedStartPosition = false
    // 记录最近一次实际用于加载的 maxQuality/streamIndex，host 切换时原样复用，
    // 不去动用户当前的画质模式（自动多档 fallback 还是手动锁定某一档）
    private var lastMaxQuality: Int?
    private var lastStreamIndex: Int?

    private var networkLogTimer: Timer?
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var isProbingCDN = false
    private var cdnProbeTask: Task<Void, Never>?
    private var cdnResults = [String: CDNDiagnostics.ProbeResult]()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryToken: UUID?
    private var recoveryPhase: String?
    private var recoveryState = PlaybackRecoveryState()
    private var rateChangeObserver: NSObjectProtocol?
    private var cacheTimeObserver: NSObjectProtocol?
    private var cacheDiagnosticObserver: NSKeyValueObservation?
    private weak var failedPlaybackItem: AVPlayerItem?
    private var lastPlaybackError: String?
    private var isPreparingMedia = false

    // 运行时 CDN 健康检测：只在真实卡顿时换 host，不用 observed/indicated 比特率比
    // （indicated 常是峰值 BANDWIDTH，播放流畅时 observed 低于它完全正常）
    private var stallUnhealthyStreak = 0
    private var lastHostSwitchAt: Date?
    /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
    private let stallTriggerCount = 2
    /// 换完 host 后的冷静期，避免连续误触发
    private let hostSwitchCooldown: TimeInterval = 30
    private let networkLogInterval: TimeInterval = 5
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(playInfo: PlayInfo,
         detailData: PlayerDetailData,
         reportWatchHistory: Bool = true,
         minimizeStalling: Bool = true,
         isMuted: Bool = false,
         proactiveBuffering: Bool = true,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil)
    {
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        self.minimizeStalling = minimizeStalling
        self.isMuted = isMuted
        self.proactiveBuffering = proactiveBuffering
        self.mediaWarmupManager = mediaWarmupManager
        currentQualityId = playData.videoPlayURLInfo.quality
    }

    deinit {
        networkLogTimer?.invalidate()
        cdnProbeTask?.cancel()
        recoveryTask?.cancel()
        if let rateChangeObserver { NotificationCenter.default.removeObserver(rateChangeObserver) }
        if let cacheTimeObserver { NotificationCenter.default.removeObserver(cacheTimeObserver) }
        playerDelegate?.cancelPendingIndexLoads()
        preparingDelegate?.cancelPendingIndexLoads()
    }

    private var currentStream: BilibiliVideoResourceLoaderDelegate.StreamDiagnostics? {
        if let playerDelegate {
            return playerDelegate.streamDiagnostics(for: playerVC?.player?.currentItem?.accessLog()?.events.last?.uri)
        }
        guard let video = PlayerMediaPreferences.current.selectVideos(
            from: playData.videoPlayURLInfo.dash.video, maxQuality: lastMaxQuality, streamIndex: lastStreamIndex,
            isPlayable: PlayerMediaPreferences.isPlayable
        ).first else { return nil }
        return .init(host: nil, candidates: BilibiliVideoResourceLoaderDelegate.uniqueHostURLs(video.playableURLs),
                     bandwidth: video.bandwidth, codec: video.codecs)
    }

    private var nativeBufferTarget: Double {
        guard minimizeStalling, proactiveBuffering else { return 15 }
        let target = Double(Settings.videoBufferDuration.rawValue)
        return playerDelegate?.cacheSnapshot == nil ? target : min(30, target)
    }

    private func updateCachePosition(player: AVPlayer) {
        guard player.currentItem?.status == .readyToPlay else { return }
        let time = player.currentTime().seconds
        guard time.isFinite, time >= 0 else { return }
        if let pendingCachePosition {
            guard abs(time - pendingCachePosition) < 2 else { return }
            self.pendingCachePosition = nil
        }
        playerDelegate?.updateCachedPlayback(at: time, target: Double(Settings.videoBufferDuration.rawValue))
    }

    var bufferingDetails: PlaybackBufferingDetails? {
        let stream = preparingDelegate?.streamDiagnostics(for: nil) ?? currentStream
        let candidates = stream?.candidates ?? []
        var cache = (preparingDelegate ?? playerDelegate)?.cacheSnapshot
        if preparingDelegate == nil, let time = playerVC?.player?.currentTime().seconds,
           time.isFinite, let snapshot = cache {
            cache?.bufferedSeconds = max(0, snapshot.bufferedSeconds - max(0, time - snapshot.position))
        }
        return PlaybackBufferingDetails(
            phase: recoveryPhase ?? (isPreparingMedia ? (cache == nil ? "正在准备播放资源" : "质量优先，正在提前缓存（最多 30 秒）") : nil),
            isPreparing: (isPreparingMedia || playerVC?.player?.currentItem?.status == .unknown) && !recoveryState.isPaused,
            isRecovering: recoveryTask != nil && !recoveryState.isPaused,
            videoHost: stream?.host,
            audioHost: (preparingDelegate ?? playerDelegate)?.currentAudioHost,
            candidates: candidates.compactMap { url in
                guard let host = URLComponents(string: url)?.host else { return nil }
                return .init(host: host, isPCDN: BVideoUrlUtils.isPCDN(url), result: cdnResults[url])
            },
            lastError: lastPlaybackError ?? cache?.lastError,
            cache: cache
        )
    }

    /// 供 DebugPlugin 浮层显示的网络诊断信息
    var networkDebugInfo: String {
        var lines = [String]()
        if let host = currentStream?.host {
            lines.append("segment host: \(host)")
        }
        if let item = playerVC?.player?.currentItem {
            lines.append(String(format: "buffer: %.1fs / target %.0fs", bufferedSeconds(of: item), item.preferredForwardBufferDuration))
        }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        if let cache = playerDelegate?.cacheSnapshot {
            lines.append(String(format: "disk buffer: %.1fs / %.0fs, %.1f MB, downloads %d, hits %d / misses %d",
                                cache.bufferedSeconds, cache.targetSeconds, Double(cache.storedBytes) / 1_048_576,
                                cache.activeDownloads, cache.hits, cache.misses))
        }
        return lines.joined(separator: "\n")
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        playerVC.player = nil
        startLoad(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo)
    }

    func playerWillStart(player: AVPlayer) {
        guard !hasAppliedStartPosition else { return }
        hasAppliedStartPosition = true
        if let playerStartPos = playData.playerStartPos {
            player.seek(to: CMTime(seconds: Double(playerStartPos), preferredTimescale: 1),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                DispatchQueue.main.async {
                    guard let self, let player, self.playerVC?.player === player else { return }
                    // A phone or plugin may supersede the initial seek.
                    self.pendingCachePosition = nil
                    self.updateCachePosition(player: player)
                }
            }
        } else {
            pendingCachePosition = nil
        }
    }

    func playerDidStart(player _: AVPlayer) {
        startNetworkLogging()
    }

    func playerDidChange(player: AVPlayer) {
        bufferingController?.stop()
        guard let item = player.currentItem else { return }
        bufferingController = VideoBufferingController(
            item: item, target: nativeBufferTarget)
        lastStalls = 0
        lastDroppedFrames = 0
        stallUnhealthyStreak = 0
        cacheDiagnosticObserver = nil
        if VideoCacheDiagnostics.enabled {
            cacheDiagnosticObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak player] _, _ in
                DispatchQueue.main.async {
                    guard let self, let player, self.playerVC?.player === player else { return }
                    self.logCacheDiagnostics(player: player, trigger: "time-control")
                }
            }
        }
        if let rateChangeObserver { NotificationCenter.default.removeObserver(rateChangeObserver) }
        if let cacheTimeObserver { NotificationCenter.default.removeObserver(cacheTimeObserver) }
        cacheTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: item, queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player, self.playerVC?.player === player else { return }
            self.updateCachePosition(player: player)
        }
        rateChangeObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
        ) { [weak self, weak player] note in
            guard let self, let player, self.playerVC?.player === player else { return }
            let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String
            self.recoveryState.recordRateChange(rate: player.rate, reason: reason)
            Logger.info("[playback-intent] rate=\(player.rate) reason=\(reason ?? "unknown") pausedByCommand=\(self.recoveryState.isPaused)")
            if self.recoveryState.isPaused {
                self.cancelRecovery()
            } else if player.rate > 0, self.failedPlaybackItem === player.currentItem, self.recoveryTask == nil {
                _ = self.recoverPlayback(player: player, error: player.currentItem?.error)
            }
        }
        startNetworkLogging()
    }

    func playerWillSeek(player: AVPlayer) {
        pendingCachePosition = nil
        bufferingController?.prepareForSeek()
    }

    func playerDidCleanUp(player: AVPlayer) {
        bufferingController?.stop()
        bufferingController = nil
        stopNetworkLogging()
        if let rateChangeObserver { NotificationCenter.default.removeObserver(rateChangeObserver) }
        rateChangeObserver = nil
        if let cacheTimeObserver { NotificationCenter.default.removeObserver(cacheTimeObserver) }
        cacheTimeObserver = nil
        cacheDiagnosticObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        // 挂进「播放设置」，与 Debug 并列（依赖 SpeedChangerPlugin 先创建 setting 菜单）
        let busy = isProbingCDN || recoveryTask != nil
        let action = UIAction(title: busy ? "CDN 测速/恢复中…" : "CDN 测速",
                              image: UIImage(systemName: "speedometer"),
                              attributes: busy ? .disabled : [])
        { [weak self] _ in
            self?.probeCDN()
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            let buffering = UIMenu(title: "视频预缓冲", children: VideoBufferDuration.allCases.map { duration in
                UIAction(title: duration.title, state: Settings.videoBufferDuration == duration ? .on : .off) { [weak self] _ in
                    Settings.videoBufferDuration = duration
                    guard let self else { return }
                    self.bufferingController?.updateTarget(self.nativeBufferTarget)
                    if let player = self.playerVC?.player { self.updateCachePosition(player: player) }
                    (self.playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
                }
            })
            current[index] = setting.replacingChildren(setting.children + [buffering, action])
            return []
        }
        return []
    }

    private func probeCDN() {
        guard !isProbingCDN, recoveryTask == nil else { return }
        let candidates = currentStream?.candidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        let currentHost = currentStream?.host
        let generation = loadGeneration
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
        cdnProbeTask = Task { @MainActor [weak self] in
            let results = await CDNDiagnostics.probeAll(urls: candidates) { [weak self] result in
                guard let self, self.loadGeneration == generation, !Task.isCancelled else { return }
                self.cdnResults[result.url] = result
            }
            guard let self, self.loadGeneration == generation, !Task.isCancelled else { return }
            self.cdnProbeReport = CDNDiagnostics.report(results, currentHost: currentHost)
            Logger.info("\(self.cdnProbeReport)")
            self.isProbingCDN = false
            self.cdnProbeTask = nil
            (self.playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
        }
    }

    private func startNetworkLogging() {
        guard networkLogTimer == nil else { return }
        networkLogTimer = Timer.scheduledTimer(withTimeInterval: networkLogInterval, repeats: true) { [weak self] _ in
            self?.logNetworkStatus()
        }
    }

    private func stopNetworkLogging() {
        networkLogTimer?.invalidate()
        networkLogTimer = nil
    }

    private func logNetworkStatus() {
        guard let player = playerVC?.player, let item = player.currentItem else { return }
        let event = item.accessLog()?.events.last
        // event.uri 是内部 variant playlist 的地址（我们用的是自定义 atv://dash/N scheme），
        // 解析出来的 host 恒为 "dash"，跟实际连的 CDN 无关；真实 host 记录在 playerDelegate 里。
        let host = currentStream?.host ?? "-"
        let observedBps = event?.observedBitrate ?? 0
        let indicatedBps = event?.indicatedBitrate ?? 0
        let effectiveIndicated = effectiveIndicatedBitrate(from: indicatedBps)
        let observed = String(format: "%.1f", observedBps / 1_000_000)
        let indicated = String(format: "%.1f", indicatedBps / 1_000_000)
        let effective = String(format: "%.1f", effectiveIndicated / 1_000_000)
        let stalls = event?.numberOfStalls ?? 0
        let dropped = event?.numberOfDroppedVideoFrames ?? 0
        let tcs = player.timeControlStatus
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let keepUp = item.isPlaybackLikelyToKeepUp
        let buffered = bufferedSeconds(of: item)
        let stallDelta = max(0, stalls - lastStalls)
        Logger.info("playback host \(host) observedSource=\(playerDelegate?.cacheSnapshot == nil ? "network" : "local-cache") observed \(observed)Mbps indicated \(indicated)Mbps effective \(effective)Mbps stalls \(stalls)(+\(stallDelta)) dropped \(dropped)(+\(dropped - lastDroppedFrames)) serverChanges \(event?.numberOfServerAddressChanges ?? 0) tcs \(tcs.rawValue) wait \(waiting) keepUp \(keepUp) buffered \(String(format: "%.1f", buffered))s")
        lastStalls = stalls
        lastDroppedFrames = dropped
        updateCachePosition(player: player)
        logCacheDiagnostics(player: player, trigger: "tick")
        if let cache = playerDelegate?.cacheSnapshot {
            Logger.info("[playback-cache] position=\(cache.position) buffered=\(cache.bufferedSeconds)s target=\(cache.targetSeconds)s bytes=\(cache.storedBytes) downloads=\(cache.activeDownloads) hits=\(cache.hits) misses=\(cache.misses) videoHost=\(cache.videoHost ?? "-") audioHost=\(cache.audioHost ?? "-")")
        }

        checkStallHealth(stallDelta: stallDelta, buffered: buffered)
    }

    private func logCacheDiagnostics(player: AVPlayer, trigger: String) {
        guard VideoCacheDiagnostics.enabled, let item = player.currentItem else { return }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        let control: String
        switch player.timeControlStatus {
        case .paused: control = "paused"
        case .waitingToPlayAtSpecifiedRate: control = "waiting"
        case .playing: control = "playing"
        @unknown default: control = "unknown"
        }
        playerDelegate?.logCachedPlayback(at: position, nativeBuffer: bufferedSeconds(of: item),
                                          control: control, trigger: trigger,
                                          sampledAt: ProcessInfo.processInfo.systemUptime)
    }

    private var isUserPaused: Bool {
        recoveryState.isPaused
    }

    private var isWaitingToPlay: Bool {
        playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// access log 的 indicated 在起播/loading 时常为 0 或负值；日志里的 effective 用流声明平均带宽兜底。
    private func effectiveIndicatedBitrate(from accessLogIndicated: Double) -> Double {
        if accessLogIndicated > 0 { return accessLogIndicated }
        guard let declared = currentStream?.bandwidth, declared > 0 else { return 0 }
        return Double(declared)
    }

    private func bufferedSeconds(of item: AVPlayerItem) -> Double {
        VideoBufferingController.bufferedSeconds(
            in: item.loadedTimeRanges.map(\.timeRangeValue), at: item.currentTime().seconds)
    }

    /// 只根据真实卡顿触发换源：正在 waiting，或本周期新增了 stall。
    /// 播放流畅时仅 observed < indicated 不触发——indicated 常是峰值，低一些完全正常。
    private func checkStallHealth(stallDelta: Int, buffered: Double) {
        // Cached playback retries individual ranges without discarding already
        // downloaded media. Terminal player failures still use item recovery.
        guard playerDelegate?.cacheSnapshot == nil else { return }
        guard !isUserPaused, recoveryTask == nil, !isPreparingMedia else {
            stallUnhealthyStreak = 0
            return
        }
        if let lastSwitch = lastHostSwitchAt, Date().timeIntervalSince(lastSwitch) < hostSwitchCooldown {
            return
        }

        let unhealthy = isWaitingToPlay || stallDelta > 0
        if unhealthy {
            stallUnhealthyStreak += 1
        } else {
            stallUnhealthyStreak = 0
            return
        }
        guard stallUnhealthyStreak >= stallTriggerCount else { return }
        stallUnhealthyStreak = 0

        Logger.info("[cdn] 检测到卡顿 (waiting=\(isWaitingToPlay), stallDelta=\(stallDelta), buffered \(String(format: "%.1f", buffered))s)，重新测速")
        guard let player = playerVC?.player else { return }
        scheduleRecovery(player: player, terminalFailure: false)
    }

    func recoverPlayback(player: AVPlayer, error: Error?) -> Bool {
        guard playerVC?.player === player else { return false }
        failedPlaybackItem = player.currentItem
        if let error { lastPlaybackError = PlaybackDiagnostics.error(error) }
        cancelRecovery()
        guard !recoveryState.isPaused else { return true }
        if let message = Self.incompatiblePlaybackMessage(error) {
            playerDelegate?.cancelPendingIndexLoads()
            Logger.warn("[playback-recovery] incompatible format; CDN reload cannot help: \(lastPlaybackError ?? "unknown")")
            guard let onLoadFailure else { return false }
            onLoadFailure(message)
            return true
        }
        guard recoveryState.failureAttempts < 2 else {
            Logger.warn("[playback-recovery] retry limit reached: \(lastPlaybackError ?? "unknown")")
            guard let onLoadFailure else { return false }
            onLoadFailure("播放中断，自动重连两次后仍无法恢复。请返回重试或切换清晰度。")
            return true
        }
        scheduleRecovery(player: player, terminalFailure: true)
        return true
    }

    static func incompatiblePlaybackMessage(_ error: Error?) -> String? {
        guard let error = error as NSError?, error.domain == AVFoundationErrorDomain else { return nil }
        switch error.code {
        case AVError.Code.noCompatibleAlternatesForExternalDisplay.rawValue:
            return "当前 HDR／帧率声明未通过播放器与显示输出协商，换 CDN 无法解决。未自动降低清晰度；请手动选择兼容格式。"
        case AVError.Code.incompatibleAsset.rawValue, AVError.Code.decoderNotFound.rawValue,
             AVError.Code.formatUnsupported.rawValue:
            return "播放器未接受当前编码或格式，换 CDN 无法解决。未自动降低清晰度；请手动选择兼容格式。"
        default:
            return nil
        }
    }

    private func cancelRecovery() {
        let wasRecovering = recoveryTask != nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryToken = nil
        recoveryPhase = nil
        if wasRecovering { (playerVC?.parent as? CommonPlayerViewController)?.updateMenus() }
    }

    private func scheduleRecovery(player: AVPlayer, terminalFailure: Bool) {
        guard recoveryTask == nil, !isUserPaused else { return }
        let sourceItem = player.currentItem
        let sourceGeneration = loadGeneration
        let stream = currentStream
        let currentHost = stream?.host
        // Probe alternatives first, not the server whose real segment request
        // has already failed. This also avoids competing diagnostic downloads.
        let candidates = (stream?.candidates ?? []).filter { URLComponents(string: $0)?.host != currentHost }
        cdnProbeTask?.cancel()
        cdnProbeTask = nil
        isProbingCDN = false
        let token = UUID()
        recoveryToken = token
        recoveryPhase = terminalFailure ? "播放中断，正在检测备用线路" : "卡顿，正在检测备用线路"
        recoveryTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            defer {
                if self.recoveryToken == token {
                    self.recoveryTask = nil
                    self.recoveryToken = nil
                    self.recoveryPhase = nil
                    (self.playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
                }
            }
            let results = await CDNDiagnostics.probeAll(urls: candidates) { [weak self] result in
                guard let self, self.recoveryToken == token, !Task.isCancelled else { return }
                self.cdnResults[result.url] = result
            }
            guard !Task.isCancelled, self.recoveryToken == token,
                  self.loadGeneration == sourceGeneration, self.playerVC?.player === player,
                  player.currentItem === sourceItem, !self.isUserPaused else { return }
            // Do not discard newly downloaded buffer after playback has recovered.
            guard terminalFailure || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            self.cdnProbeReport = CDNDiagnostics.report(results, currentHost: currentHost)
            let target = CDNDiagnostics.recoveryCandidate(from: results, currentHost: currentHost)
            guard terminalFailure || target != nil else {
                Logger.warn("[playback-recovery] no reachable alternate CDN; waiting on current connection")
                return
            }
            let host = target?.host ?? currentHost
            if terminalFailure, !self.recoveryState.beginFailureRecovery() { return }
            self.recoveryPhase = "正在重新连接 \(host ?? "视频服务器")"
            Logger.info("[playback-recovery] reload host \(currentHost ?? "-") -> \(host ?? "-") terminal=\(terminalFailure) codec=\(stream?.codec ?? "-")")
            do {
                try await self.reloadForRecovery(host: host, player: player)
                self.lastHostSwitchAt = Date()
            } catch is CancellationError {
                return
            } catch {
                let message = PlaybackDiagnostics.error(error)
                self.lastPlaybackError = message
                Logger.warn("[playback-recovery] reload failed: \(message)")
                if terminalFailure {
                    self.onLoadFailure?("视频重连失败，请返回重试。\n\(message)")
                }
            }
        }
        (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
    }

    @MainActor
    private func reloadForRecovery(host: String?, player: AVPlayer) async throws {
        let position = player.currentTime().seconds
        let time = position.isFinite && position >= 0 ? position : 0
        let rate = player.rate > 0 ? player.rate : recoveryState.rate
        let generation = beginLoadGeneration(cancelRecovery: false)
        try await playmedia(urlInfo: playData.videoPlayURLInfo,
                            playerInfo: playData.playerInfo,
                            generation: generation,
                            maxQuality: lastMaxQuality,
                            streamIndex: lastStreamIndex,
                            preferredHost: host,
                            isQualitySwitch: true,
                            recoverySource: player)
        let vc = try ensureActiveLoad(generation)
        guard let newPlayer = vc.player else { throw "重连后播放器不可用" }
        let sought = await newPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        _ = try ensureActiveLoad(generation)
        guard vc.player === newPlayer else { throw CancellationError() }
        guard sought else { throw "重连后无法恢复播放位置" }
        pendingCachePosition = nil
        updateCachePosition(player: newPlayer)
        if !recoveryState.isPaused { newPlayer.playImmediately(atRate: rate) }
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        guard reportWatchHistory else { return }
        guard let currentTime = playerVC.player?.currentTime().seconds, currentTime > 0 else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(currentTime), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        bufferingController?.stop()
        invalidatePendingLoad(tearingDown: true)
    }

    private func startLoad(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           isQualitySwitch: Bool = false)
    {
        let generation = beginLoadGeneration()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.playmedia(urlInfo: urlInfo,
                                         playerInfo: playerInfo,
                                         generation: generation,
                                         maxQuality: maxQuality,
                                         streamIndex: streamIndex,
                                         isQualitySwitch: isQualitySwitch)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.playerVC != nil
                else { return }
                Logger.warn("[player] Failed to prepare media: \(error)")
                self.onLoadFailure?(error.localizedDescription)
            }
        }
    }

    private func beginLoadGeneration(cancelRecovery: Bool = true) -> Int {
        if cancelRecovery { self.cancelRecovery() }
        cdnProbeTask?.cancel()
        cdnProbeTask = nil
        isProbingCDN = false
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        return loadGeneration
    }

    private func invalidatePendingLoad(tearingDown: Bool) {
        cancelRecovery()
        cdnProbeTask?.cancel()
        cdnProbeTask = nil
        isProbingCDN = false
        isPreparingMedia = false
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        playerDelegate?.cancelPendingIndexLoads()
        preparingDelegate?.cancelPendingIndexLoads()
        preparingDelegate = nil
        pendingCachePosition = nil
        playerDelegate = nil
        if tearingDown {
            playerVC = nil
        }
    }

    private func ensureActiveLoad(_ generation: Int) throws -> AVPlayerViewController {
        guard !Task.isCancelled,
              loadGeneration == generation,
              let playerVC
        else {
            throw CancellationError()
        }
        return playerVC
    }

    @MainActor
    private func playmedia(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           generation: Int,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           preferredHost: String? = nil,
                           isQualitySwitch: Bool = false,
                           recoverySource: AVPlayer? = nil) async throws
    {
        _ = try ensureActiveLoad(generation)
        isPreparingMedia = true
        defer {
            if loadGeneration == generation { isPreparingMedia = false }
        }
        let prepared = try await preparedMedia(urlInfo: urlInfo,
                                               playerInfo: playerInfo,
                                               maxQuality: maxQuality,
                                               streamIndex: streamIndex,
                                               preferredHost: preferredHost,
                                               isQualitySwitch: isQualitySwitch)
        // The await above may finish after a newer load generation. Validate
        // before retaining its resource-loader delegate or touching the player.
        let playerVC = try ensureActiveLoad(generation)
        if let recoverySource {
            guard playerVC.player === recoverySource, !isUserPaused,
                  failedPlaybackItem === recoverySource.currentItem
                    || recoverySource.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                throw CancellationError()
            }
        }
        let delegate = prepared.delegate
        let asset = prepared.asset
        preparingDelegate = delegate
        delegate.startupProbeResults.forEach { cdnResults[$0.url] = $0 }
        defer {
            if preparingDelegate === delegate { preparingDelegate = nil }
            if playerDelegate !== delegate { delegate.cancelPendingIndexLoads() }
        }
        let cachePosition = isQualitySwitch
            ? (recoverySource ?? playerVC.player)?.currentTime().seconds ?? 0
            : Double(playData.playerStartPos ?? 0)
        try await delegate.prepareCachedPlayback(at: max(0, cachePosition),
                                                 target: Double(Settings.videoBufferDuration.rawValue),
                                                 maximumWait: isQualitySwitch ? 0 : 30)
        _ = try ensureActiveLoad(generation)
        pendingCachePosition = delegate.cacheSnapshot == nil ? nil : cachePosition
        playerDelegate?.cancelPendingIndexLoads()
        playerDelegate = delegate
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex

        // AVKit 不允许在同一场全屏播放里反复切换该属性，因此只在首次装配资源时计算一次。
        if !isQualitySwitch {
            playerVC.appliesPreferredDisplayCriteriaAutomatically = shouldApplyContentMatch(delegate: delegate)
        }
        Logger.info("[playback-display] hdrEligible=\(AVPlayer.eligibleForHDRPlayback) automaticMatch=\(playerVC.appliesPreferredDisplayCriteriaAutomatically) matchingEnabled=\(AppDelegate.shared.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false)")
        #if DEBUG
        Logger.info("[playback-display] hdrModes=\(AVPlayer.availableHDRModes.rawValue) maxRefreshRate=\(UIScreen.main.maximumFramesPerSecond)")
        #endif

        await prepare(toPlay: asset, generation: generation, managePlaybackManually: isQualitySwitch)
    }

    private func preparedMedia(urlInfo: VideoPlayURLInfo,
                               playerInfo: PlayerInfo?,
                               maxQuality: Int?,
                               streamIndex: Int?,
                               preferredHost: String?,
                               isQualitySwitch: Bool) async throws -> PreparedPlayerMedia
    {
        if proactiveBuffering, !isQualitySwitch,
           maxQuality == nil,
           streamIndex == nil,
           preferredHost == nil,
           let mediaWarmupManager
        {
            return try await mediaWarmupManager.preparedMedia(for: playInfo)
        }
        var preferences = PlayerMediaPreferences.current
        preferences.proactiveBuffering = preferences.proactiveBuffering && proactiveBuffering
        return try await PlayerMediaFactory.prepare(aid: playData.aid,
                                                    urlInfo: urlInfo,
                                                    playerInfo: playerInfo,
                                                    maxQuality: maxQuality,
                                                    streamIndex: streamIndex,
                                                    preferredHost: preferredHost,
                                                    preferences: preferences)
    }

    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async -> Bool {
        guard let player = playerVC?.player else { return false }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite && currentTime >= 0 else { return false }

        let shouldResume = !isUserPaused && (player.timeControlStatus != .paused || failedPlaybackItem === player.currentItem)
        let previousRate = player.rate > 0 ? player.rate : recoveryState.rate
        // 重新加载视频，使用新的画质
        do {
            let generation = beginLoadGeneration()
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: qualityId == 0 ? nil : qualityId,
                                streamIndex: streamIndex,
                                isQualitySwitch: true)

            // 恢复播放位置并继续播放
            guard loadGeneration == generation,
                  !Task.isCancelled,
                  playerVC != nil,
                  let newPlayer = playerVC?.player
            else { return false }
            let sought = await newPlayer.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadGeneration == generation, !Task.isCancelled else { return false }
            guard sought else {
                Logger.warn("[quality] Failed to restore playback position")
                return false
            }
            pendingCachePosition = nil
            updateCachePosition(player: newPlayer)
            currentQualityId = qualityId
            if shouldResume && !recoveryState.isPaused { newPlayer.playImmediately(atRate: previousRate) }
            else { newPlayer.pause() }
            return true
        } catch is CancellationError {
            return false
        } catch {
            Logger.warn("[quality] Failed to switch quality: \(error)")
            return false
        }
    }

    struct PlaybackRecoveryState {
        private(set) var rate: Float = 1
        private(set) var isPaused = false
        private(set) var failureAttempts = 0

        mutating func recordRateChange(rate: Float, reason: String?) {
            if rate.isFinite, rate > 0 {
                if isPaused, reason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue {
                    failureAttempts = 0
                }
                self.rate = rate
                isPaused = false
            } else if reason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue
                        || reason == AVPlayer.RateDidChangeReason.audioSessionInterrupted.rawValue
                        || reason == AVPlayer.RateDidChangeReason.appBackgrounded.rawValue {
                isPaused = true
            }
        }

        mutating func beginFailureRecovery() -> Bool {
            guard !isPaused, failureAttempts < 2 else { return false }
            failureAttempts += 1
            return true
        }
    }

    private func shouldApplyContentMatch(delegate: BilibiliVideoResourceLoaderDelegate) -> Bool {
        guard Settings.contentMatch else { return false }
        guard Settings.contentMatchOnlyInHDR else { return true }
        return delegate.isHDR == true
    }

    @MainActor
    func prepare(toPlay asset: AVURLAsset, generation: Int, managePlaybackManually: Bool = false) async {
        guard loadGeneration == generation,
              !Task.isCancelled,
              let playerVC
        else { return }
        let playerItem = AVPlayerItem(asset: asset)
        if let container = playerVC.parent as? CommonPlayerViewController,
           managePlaybackManually || !container.autoPlayWhenReady {
            container.manuallyManagedPlayerItem = playerItem
        }

        // The manifest already fixes the selected quality; keep its bitrate uncapped.
        playerItem.preferredPeakBitRate = 0

        // Begin with a small seek/startup window. playerDidChange installs a
        // controller that expands it once the playback position settles.
        playerItem.preferredForwardBufferDuration = 15

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = minimizeStalling
        player.isMuted = isMuted
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        playerVC.player = nil
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        playerVC.player = player
    }
}
