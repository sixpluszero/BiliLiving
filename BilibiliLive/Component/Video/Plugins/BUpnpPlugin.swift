//
//  BUpnpPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVFoundation
import Foundation

class BUpnpPlugin: NSObject, CommonPlayerPlugin {
    let duration: Int?
    private let context: LivingCastContext?
    private var attached = false
    weak var player: AVPlayer?
    private var observar: Any?

    init(duration: Int?, context: LivingCastContext? = nil) {
        self.context = context
        self.duration = duration
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        let time = min(time, Double(max(0, (duration ?? Int(time + 1)) - 1)))
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerWillStart(player: AVPlayer) {
        guard let context, BiliBiliUpnpDMR.shared.attach(plugin: self, context: context) else { return }
        attached = true
        if let observar, let previous = self.player { previous.removeTimeObserver(observar) }
        observar = nil
        self.player = player
        if let seconds = context.pendingSeek { seek(to: seconds); context.pendingSeek = nil }
        observar = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .global()) { time in
            guard time.seconds.isFinite else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
                let measured = self.player?.currentItem?.duration.seconds ?? 0
                let duration = self.duration ?? (measured.isFinite && measured >= 0 && measured < Double(Int.max) ? Int(measured) : 0)
                BiliBiliUpnpDMR.shared.sendProgress(duration: duration, current: Int(time.seconds))
            }
        }
    }

    func playerDidStart(player: AVPlayer) {
        guard attached, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
            BiliBiliUpnpDMR.shared.sendStatus(status: .playing)
        }
    }

    func playerDidPause(player: AVPlayer) {
        guard attached, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
            BiliBiliUpnpDMR.shared.sendStatus(status: .paused)
        }
    }

    func playerDidEnd(player: AVPlayer) {
        guard attached, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
            BiliBiliUpnpDMR.shared.sendStatus(status: .end)
        }
    }

    func playerDidFail(player: AVPlayer) {
        guard attached, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, BiliBiliUpnpDMR.shared.currentPlugin === self else { return }
            BiliBiliUpnpDMR.shared.sendStatus(status: .stop)
        }
    }

    func playerDidCleanUp(player: AVPlayer) {
        if let observar {
            player.removeTimeObserver(observar)
        }
        observar = nil
        DispatchQueue.main.async {
            if BiliBiliUpnpDMR.shared.currentPlugin === self {
                BiliBiliUpnpDMR.shared.currentPlugin = nil
                BiliBiliUpnpDMR.shared.sendStatus(status: .stop)
            }
        }
        attached = false
    }
}
