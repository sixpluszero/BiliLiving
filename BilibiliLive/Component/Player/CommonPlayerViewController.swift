//
//  CommonPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import UIKit

class CommonPlayerViewController: UIViewController {
    private let playerVC = AVPlayerViewController()
    private var activePlugins = [CommonPlayerPlugin]()
    private var observations = Set<NSKeyValueObservation>()
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playbackDiagnostics: PlayerDiagnosticRecorder?
    private var playToEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var isEnd = false
    private var isRestoringFromPip = false
    /// 新 AVPlayerItem ready 后是否自动 play。换 CDN host 等场景可临时关掉，由调用方按用户暂停状态决定是否续播。
    var autoPlayWhenReady = true
    // Keep suppression attached to the item: readiness KVO may arrive after a quality switch returns.
    weak var manuallyManagedPlayerItem: AVPlayerItem?
    var showsPlaybackControls = true
    var allowsPictureInPicturePlayback = true

    deinit {
        cleanUpPlayerOnExit(force: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        playerVC.delegate = self

        let playerObservation = playerVC.observe(\.player, options: [.old, .new]) { [weak self] vc, obs in
            Logger.debug("player changed: \(String(describing: obs.oldValue)) -> \(String(describing: obs.newValue))")
            if let oldPlayer = obs.oldValue, let oldPlayer {
                self?.activePlugins.forEach { $0.playerDidCleanUp(player: oldPlayer) }
            }
            self?.playerDidChange(player: vc.player)
        }
        observations.insert(playerObservation)
        activePlugins.forEach { $0.playerDidLoad(playerVC: playerVC) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        activePlugins.forEach { $0.playerDidDismiss(playerVC: playerVC) }
        cleanUpPlayerOnExit()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [playerVC.view]
    }

    func addPlugin(plugin: CommonPlayerPlugin) {
        if activePlugins.contains(where: { $0 == plugin }) {
            return
        }
        plugin.addViewToPlayerOverlay(container: playerVC.contentOverlayView!)
        activePlugins.append(plugin)
        plugin.playerDidLoad(playerVC: playerVC)
        if playerVC.transportBarCustomMenuItems.isEmpty == false {
            updateMenus()
        }
    }

    func removePlugin(plugin: CommonPlayerPlugin) {
        let removingPlugins = activePlugins.filter { $0 == plugin }
        removingPlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            removingPlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll { $0 == plugin }
    }

    func removeAllPlugins() {
        guard !activePlugins.isEmpty else { return }
        activePlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            Logger.debug("removeAllPlugins: clean up player: \(player)")
            activePlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll()
    }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}

    func showErrorAlertAndExit(title: String = "播放失败", message: String = "未知错误") {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let actionOk = UIAlertAction(title: "OK", style: .default) {
            [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }
        alertController.addAction(actionOk)
        present(alertController, animated: true, completion: nil)
    }

    func updateMenus() {
        var menus = [UIMenuElement]()
        for activePlugin in activePlugins {
            let newMenus = activePlugin.addMenuItems(current: &menus)
            menus.append(contentsOf: newMenus)
        }
        playerVC.transportBarCustomMenuItems = menus
    }

    func stopPlayback() {
        cleanUpPlayerOnExit(force: true)
    }

    func currentPlaybackTimeInSeconds() -> Int? {
        guard let seconds = playerVC.player?.currentTime().seconds,
              seconds.isFinite,
              seconds > 0
        else {
            return nil
        }
        return Int(seconds.rounded(.down))
    }

    private func cleanUpPlayerOnExit(force: Bool = false) {
        let isPictureInPictureRunning = PipRecorder.shared.playingPipViewController.contains { $0.playerVC == playerVC }
        let shouldCleanUp = force || ((isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true) && !isPictureInPictureRunning)
        guard shouldCleanUp else { return }

        cleanUpObserver()

        let player = playerVC.player
        player?.pause()
        // Plugins may still be preparing the first AVPlayer. Always run their
        // cleanup hook even when playerVC.player has not been installed yet.
        removeAllPlugins()
        player?.replaceCurrentItem(with: nil)
        playerVC.player = nil
    }

    private func cleanUpObserver() {
        playbackDiagnostics?.stop()
        playbackDiagnostics = nil
        rateObserver = nil
        statusObserver = nil
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = nil
    }
}

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        playbackDiagnostics?.stop()
        playbackDiagnostics = player.map { PlayerDiagnosticRecorder(player: $0, viewController: playerVC) }
        if let player {
            activePlugins.forEach { $0.playerDidChange(player: player) }
            rateObserver = player.observe(\.rate, options: [.old, .new]) {
                [weak self] _player, obs in
                DispatchQueue.main.async { [weak self] in
                    self?.playerRateDidChange(player: player)
                }
            }
            if let playItem = player.currentItem {
                observePlayerItem(playItem)
            }
            updateMenus()
        } else {
            cleanUpObserver()
        }
    }

    private func playerRateDidChange(player: AVPlayer) {
        if player.rate > 0 {
            activePlugins.forEach { $0.playerDidStart(player: player) }
            playerDidStart(player: player)
        } else if player.rate == 0 {
            if !isEnd {
                activePlugins.forEach { $0.playerDidPause(player: player) }
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        statusObserver = playerItem.observe(\.status, options: [.new, .old]) {
            [weak self] item, _ in
            guard let self, let player = playerVC.player else { return }
            switch item.status {
            case .readyToPlay:
                isEnd = false
                activePlugins.forEach { $0.playerWillStart(player: player) }
                playerWillStart(player: player)
                if autoPlayWhenReady && manuallyManagedPlayerItem !== item {
                    player.play()
                }
            case .failed:
                activePlugins.forEach { $0.playerDidFail(player: player) }
                playerDidFail(player: player)
            default:
                break
            }
        }
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            guard let self, let player = playerVC.player else { return }
            isEnd = true
            activePlugins.forEach { $0.playerDidEnd(player: player) }
            playerDidEnd(player: player)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, let player = playerVC.player else { return }
            activePlugins.forEach { $0.playerDidStall(player: player) }
            playerDidStall(player: player)
        }
    }
}

extension CommonPlayerViewController: AVPlayerViewControllerDelegate {
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
                              to targetTime: CMTime) -> CMTime {
        if let player = playerViewController.player {
            activePlugins.forEach { $0.playerWillSeek(player: player) }
        }
        return targetTime
    }

    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        if let presentedViewController = UIViewController.topMostViewController() as? CommonPlayerViewController,
           presentedViewController.playerVC == playerViewController
        {
            dismiss(animated: true)
            return false
        }
        return false
    }

    @objc func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
        return true
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isRestoringFromPip = false
        PipRecorder.shared.playingPipViewController.append(self)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        PipRecorder.shared.playingPipViewController.removeAll { $0.playerVC == playerViewController }
        if !isRestoringFromPip {
            // 用户点 ✕ 关闭 PiP，清理资源
            cleanUpPlayerOnExit(force: true)
        }
        isRestoringFromPip = false
    }

    @objc func playerViewController(_ playerViewController: AVPlayerViewController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
    {
        isRestoringFromPip = true
        let presentedViewController = UIViewController.topMostViewController()
        guard let containerPlayer = PipRecorder.shared.playingPipViewController.first(where: { $0.playerVC == playerViewController }) else {
            completionHandler(false)
            return
        }
        if presentedViewController is CommonPlayerViewController {
            let parent = presentedViewController.presentingViewController
            presentedViewController.dismiss(animated: false) {
                parent?.present(containerPlayer, animated: false)
                completionHandler(true)
            }
        } else {
            presentedViewController.present(containerPlayer, animated: false) {
                completionHandler(true)
            }
        }
    }

    class PipRecorder {
        static let shared = PipRecorder()
        var playingPipViewController = [CommonPlayerViewController]()
    }
}

/// Observe independently of rate/ready callbacks: startup may never reach either.
/// AVPlayer owns segment networking; its public access/error logs do not expose
/// per-segment DNS/TTFB. Only our probe/SIDX requests have URLSession metrics.
final class PlayerDiagnosticRecorder {
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private weak var viewController: AVPlayerViewController?
    private let id = String(UUID().uuidString.prefix(8))
    private let started = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var observations = [NSKeyValueObservation]()
    private var notifications = [NSObjectProtocol]()
    private var errorCount = 0
    private var lastPosition: Double?
    private var clockAdvanced = false
    private var stopped = false

    init(player: AVPlayer, viewController: AVPlayerViewController) {
        self.viewController = viewController
        self.player = player
        observations.append(viewController.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.sample("display-ready") }
        })
        item = player.currentItem
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.sample("time-control") }
        })
        if let item {
            observations.append(item.observe(\.status, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.sample("item-status") }
            })
            for name in [NSNotification.Name.AVPlayerItemNewErrorLogEntry,
                         .AVPlayerItemNewAccessLogEntry, .AVPlayerItemPlaybackStalled,
                         .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemTimeJumped] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] note in
                    if let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                        Logger.warn("[playback-diag] id=\(self?.id ?? "-") failedToEnd=\(PlaybackDiagnostics.error(error))")
                    }
                    self?.sample(name.rawValue)
                })
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample("tick") }
        Logger.info("[playback-diag] id=\(id) attached asset=\(item.map { String(describing: ObjectIdentifier($0.asset)) } ?? "-")")
        sample("attached")
    }

    func stop() {
        guard !stopped else { return }
        sample("detached")
        stopped = true
        timer?.invalidate()
        timer = nil
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
    }

    deinit { stop() }

    private func sample(_ trigger: String) {
        guard !stopped, let player, let item else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let position = item.currentTime().seconds
        let buffer = VideoBufferingController.bufferedSeconds(in: item.loadedTimeRanges.map(\.timeRangeValue), at: position)
        if trigger == "tick" {
            if !clockAdvanced, player.timeControlStatus == .playing,
               let lastPosition, position > lastPosition + 0.1 {
                clockAdvanced = true
                Logger.info("[playback-diag] id=\(id) firstObservedClockAdvance elapsed=\(elapsed)s (5s sampling; seeks may also move clock)")
            }
            lastPosition = position
        }
        let state: String
        switch item.status {
        case .unknown: state = "preparing"
        case .readyToPlay: state = "ready"
        case .failed: state = "failed"
        @unknown default: state = "unknown"
        }
        let control: String
        switch player.timeControlStatus {
        case .paused: control = "paused"
        case .waitingToPlayAtSpecifiedRate: control = "waiting"
        case .playing: control = "playing"
        @unknown default: control = "unknown"
        }
        let hint: String
        if item.status == .failed { hint = "item-failed-see-error" }
        else if item.status == .unknown { hint = "preparing-media-cause-undetermined" }
        else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            hint = item.isPlaybackBufferEmpty ? "waiting-empty-buffer" : "waiting-see-system-reason"
        } else if player.timeControlStatus == .paused { hint = "paused-or-play-not-requested" }
        else { hint = "playing" }
        let ranges = item.loadedTimeRanges.prefix(6).map { value in
            let r = value.timeRangeValue
            return String(format: "%.2f..%.2f", r.start.seconds, CMTimeRangeGetEnd(r).seconds)
        }.joined(separator: ",")
        Logger.info("[playback-diag] id=\(id) trigger=\(trigger) elapsed=\(String(format: "%.2f", elapsed))s item=\(state) displayReady=\(viewController?.isReadyForDisplay ?? false) control=\(control) rate=\(player.rate) wait=\(player.reasonForWaitingToPlay?.rawValue ?? "none") position=\(position) buffer=\(String(format: "%.2f", buffer))s target=\(item.preferredForwardBufferDuration)s empty=\(item.isPlaybackBufferEmpty) full=\(item.isPlaybackBufferFull) keepUp=\(item.isPlaybackLikelyToKeepUp) autoWait=\(player.automaticallyWaitsToMinimizeStalling) ranges=[\(ranges)] hint=\(hint) itemError=\(PlaybackDiagnostics.error(item.error)) playerError=\(PlaybackDiagnostics.error(player.error))")
        if let event = item.accessLog()?.events.last {
            Logger.info("[playback-access] id=\(id) uri=\(PlaybackDiagnostics.resource(event.uri)) server=\(event.serverAddress ?? "-") changes=\(event.numberOfServerAddressChanges) observedMbps=\(event.observedBitrate / 1_000_000) indicatedMbps=\(event.indicatedBitrate / 1_000_000) bytes=\(event.numberOfBytesTransferred) transferSeconds=\(event.transferDuration) requests=\(event.numberOfMediaRequests) segments=\(event.numberOfSegmentsDownloaded) downloadedSeconds=\(event.segmentsDownloadedDuration) startupSeconds=\(event.startupTime) stalls=\(event.numberOfStalls) dropped=\(event.numberOfDroppedVideoFrames)")
        } else {
            Logger.info("[playback-access] id=\(id) no-access-log-yet")
        }
        let errors = item.errorLog()?.events ?? []
        if errors.count < errorCount { errorCount = 0 }
        for error in errors.dropFirst(errorCount) {
            Logger.warn("[playback-error] id=\(id) date=\(String(describing: error.date)) uri=\(PlaybackDiagnostics.resource(error.uri)) server=\(error.serverAddress ?? "-") domain=\(error.errorDomain) code=\(error.errorStatusCode) comment=\(PlaybackDiagnostics.sanitize(error.errorComment ?? "-"))")
        }
        errorCount = errors.count
    }
}
