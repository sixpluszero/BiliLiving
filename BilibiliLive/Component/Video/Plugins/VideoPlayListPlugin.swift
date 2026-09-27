//
//  VideoPlayListPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/26.
//

import AVKit

final class VideoPlayListPlugin: NSObject, CommonPlayerPlugin {
    private let nextActionIdentifierPrefix = "play.next"
    private weak var playerVC: AVPlayerViewController?
    private weak var picker: VideoEpisodePickerViewController?
    private var episodes: VideoEpisodeList
    private let currentPlayInfo: PlayInfo
    private let preferredSectionID: String?
    private var episodeLoadFailed: Bool
    private var isActive = true
    private var advanceTask: Task<Void, Never>?
    private var episodeLoadTask: Task<Void, Never>?
    var navigation: (@MainActor () -> (next: PlayInfo?, isSeries: Bool))?
    var onPlayEnd: (@MainActor () -> Void)?
    var onPlayNext: (@MainActor () async -> Bool)?
    var onRestart: (@MainActor () -> Bool)?
    var onShowCurrentDetail: (@MainActor (PlayInfo) -> Void)?
    var onSelectEpisode: (@MainActor (VideoEpisodeList.Selection) -> Void)?
    var onReloadEpisodes: (@MainActor () async throws -> VideoEpisodeList)?

    init(episodes: VideoEpisodeList, currentPlayInfo: PlayInfo,
         preferredSectionID: String? = nil, episodeLoadFailed: Bool = false) {
        self.episodes = episodes
        self.currentPlayInfo = currentPlayInfo
        self.preferredSectionID = preferredSectionID
        self.episodeLoadFailed = episodeLoadFailed
        super.init()
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerWillStart(player: AVPlayer) {
        MainActor.assumeIsolated { refreshNextAction() }
    }

    @MainActor private func refreshNextAction() {
        guard let playerVC else { return }
        let state = navigation?()
        var actions = playerVC.infoViewActions.filter {
            !$0.identifier.rawValue.hasPrefix(nextActionIdentifierPrefix)
        }
        if let next = state?.next {
            let nextAction = UIAction(title: state?.isSeries == true ? "下一集" : "下一条",
                                      image: UIImage(systemName: "forward.end.fill"),
                                      identifier: .init(rawValue: "\(nextActionIdentifierPrefix).\(next.sequenceKey)"))
            { [weak self] _ in
                self?.advance(isPlaybackEnd: false)
            }
            actions.append(nextAction)
        }
        playerVC.infoViewActions = actions
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        MainActor.assumeIsolated { makeMenuItems(current: &current) }
    }

    @MainActor private func makeMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        var directActions = [UIMenuElement]()
        if episodes.hasChoices || episodeLoadFailed {
            directActions.append(UIAction(title: episodeLoadTask == nil ? "选集" : "选集加载中…",
                                          image: UIImage(systemName: "list.bullet.rectangle"),
                                          identifier: .init("video.episodes"),
                                          attributes: episodeLoadTask == nil ? [] : .disabled) { [weak self] _ in
                self?.showEpisodes()
            })
        }
        let loopImage = UIImage(systemName: "infinity")
        let loopAction = UIAction(title: "循环播放", image: loopImage, state: Settings.loopPlay ? .on : .off) {
            action in
            action.state = (action.state == .off) ? .on : .off
            Settings.loopPlay = action.state == .on
        }
        var actions = [UIMenuElement](arrayLiteral: loopAction)
        if let onShowCurrentDetail {
            let detailAction = UIAction(title: "查看详情", image: UIImage(systemName: "info.circle")) { [currentPlayInfo] _ in
                onShowCurrentDetail(currentPlayInfo)
            }
            actions.append(detailAction)
        }

        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") })
        {
            var child = setting.children
            child.append(contentsOf: actions)
            if let index = current.firstIndex(of: setting) {
                current[index] = setting.replacingChildren(child)
            }
            return directActions
        }
        return directActions + actions
    }

    func playerDidEnd(player: AVPlayer) {
        MainActor.assumeIsolated { advance(isPlaybackEnd: true) }
    }

    @MainActor private func advance(isPlaybackEnd: Bool) {
        guard isActive, advanceTask == nil, picker == nil,
              playerVC?.parent?.presentedViewController == nil
        else { return }
        advanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { advanceTask = nil }
            if await onPlayNext?() == true { return }
            guard !Task.isCancelled, isActive, isPlaybackEnd else { return }
            if Settings.loopPlay {
                if onRestart?() != true, let player = playerVC?.player {
                    await player.seek(to: .zero)
                    guard !Task.isCancelled, isActive, playerVC?.player === player else { return }
                    player.play()
                }
            } else {
                onPlayEnd?()
            }
        }
    }

    @MainActor func showEpisodes() {
        guard isActive, picker == nil, episodeLoadTask == nil,
              let playerVC, let presenter = playerVC.parent,
              presenter.presentedViewController == nil
        else { return }
        guard !episodeLoadFailed else {
            showEpisodeLoadError("暂时无法获取选集信息，请重试。")
            return
        }
        guard episodes.hasChoices else { return }
        let picker = VideoEpisodePickerViewController(episodes: episodes, currentPlayInfo: currentPlayInfo,
                                                       preferredSectionID: preferredSectionID)
        self.picker = picker
        let container = presenter as? CommonPlayerViewController
        container?.suspendsAutomaticPlayback = true
        let player = playerVC.player
        let resumeRate = player?.rate ?? 0
        let isPreparing = player?.currentItem?.status == .unknown && container?.autoPlayWhenReady == true
        let shouldResume = player?.timeControlStatus != .paused || isPreparing
        player?.pause()
        picker.onClose = { [weak self, weak player] selection in
            guard let self, self.isActive else { return }
            self.picker = nil
            (self.playerVC?.parent as? CommonPlayerViewController)?.suspendsAutomaticPlayback = false
            if let player, self.playerVC?.player === player, shouldResume,
               (self.playerVC?.parent as? CommonPlayerViewController)?.autoPlayWhenReady != false {
                player.playImmediately(atRate: resumeRate > 0 ? resumeRate : 1)
            }
            if let selection {
                self.onSelectEpisode?(selection)
            }
        }
        presenter.present(picker, animated: true)
    }

    @MainActor private func showEpisodeLoadError(_ message: String) {
        guard let presenter = playerVC?.parent, presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "选集加载失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in self?.reloadEpisodes() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }

    @MainActor private func reloadEpisodes() {
        guard let onReloadEpisodes, episodeLoadTask == nil else { return }
        episodeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let list = try await onReloadEpisodes()
                guard !Task.isCancelled, isActive else { return }
                episodes = list
                episodeLoadFailed = false
                episodeLoadTask = nil
                refreshNextAction()
                (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
                if episodes.hasChoices {
                    showEpisodes()
                } else if let presenter = playerVC?.parent, presenter.presentedViewController == nil {
                    let alert = UIAlertController(title: "暂无选集", message: "当前视频没有其他可选剧集。", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .cancel))
                    presenter.present(alert, animated: true)
                }
            } catch {
                guard !Task.isCancelled, isActive else { return }
                episodeLoadTask = nil
                Logger.warn("选集加载失败: \(error.localizedDescription)")
                (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
                showEpisodeLoadError(error.localizedDescription)
            }
        }
        (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        MainActor.assumeIsolated {
            isActive = false
            advanceTask?.cancel()
            episodeLoadTask?.cancel()
            (playerVC.parent as? CommonPlayerViewController)?.suspendsAutomaticPlayback = false
            picker?.onClose = nil
            picker?.dismiss(animated: false)
            picker = nil
            playerVC.infoViewActions.removeAll { $0.identifier.rawValue.hasPrefix(nextActionIdentifierPrefix) }
        }
    }
}
