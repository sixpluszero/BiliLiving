//
//  CommonPlayerPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import UIKit

protocol CommonPlayerPlugin: NSObject {
    var bufferingDetails: PlaybackBufferingDetails? { get }
    func addViewToPlayerOverlay(container: UIView)
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement]

    func playerDidLoad(playerVC: AVPlayerViewController)
    func playerDidDismiss(playerVC: AVPlayerViewController)
    func playerWillCleanUp(playerVC: AVPlayerViewController)
    func playerDidChange(player: AVPlayer)
    func playerItemDidChange(playerItem: AVPlayerItem)

    func playerWillStart(player: AVPlayer)
    func playerDidStart(player: AVPlayer)
    func playerDidPause(player: AVPlayer)
    func playerDidEnd(player: AVPlayer)
    func playerDidStall(player: AVPlayer)
    func playerWillSeek(player: AVPlayer)
    func playerDidFail(player: AVPlayer)
    func recoverPlayback(player: AVPlayer, error: Error?) -> Bool
    func playerDidCleanUp(player: AVPlayer)
}

extension CommonPlayerPlugin {
    var bufferingDetails: PlaybackBufferingDetails? { nil }
    func addViewToPlayerOverlay(container: UIView) {}
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] { return [] }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidPause(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerWillSeek(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}
    func recoverPlayback(player: AVPlayer, error: Error?) -> Bool { false }
    func playerDidCleanUp(player: AVPlayer) {}

    func playerDidLoad(playerVC: AVPlayerViewController) {}
    func playerDidDismiss(playerVC: AVPlayerViewController) {}
    func playerWillCleanUp(playerVC: AVPlayerViewController) {}
    func playerDidChange(player: AVPlayer) {}
    func playerItemDidChange(playerItem: AVPlayerItem) {}
}
