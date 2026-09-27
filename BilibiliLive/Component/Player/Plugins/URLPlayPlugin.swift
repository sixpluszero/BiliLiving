//
//  URLPlayPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/6/6.
//

import AVKit
import Foundation

class URLPlayPlugin: NSObject {
    var onPlayFail: (() -> Void)?

    private weak var playerVC: AVPlayerViewController?
    private let referer: String
    private let isLive: Bool
    private var currentUrl: String?
    private var reportedFailure = false

    init(referer: String = "", isLive: Bool = false) {
        self.referer = referer
        self.isLive = isLive
    }

    func play(urlString: String) {
        currentUrl = urlString
        reportedFailure = false
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": referer,
        ]
        let asset = AVURLAsset(url: URL(string: urlString)!, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = !isLive
        playerVC?.player = player
    }

    private func reportFailure(player: AVPlayer) {
        guard playerVC?.player === player, !reportedFailure else { return }
        reportedFailure = true
        onPlayFail?()
    }
}

extension URLPlayPlugin: CommonPlayerPlugin {
    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        playerVC.requiresLinearPlayback = isLive
        playerVC.player = nil
        if let currentUrl {
            play(urlString: currentUrl)
        }
    }

    func playerDidFail(player: AVPlayer) {
        reportFailure(player: player)
    }

    func playerDidPause(player: AVPlayer) {
        if isLive {
            reportFailure(player: player)
        }
    }
}
