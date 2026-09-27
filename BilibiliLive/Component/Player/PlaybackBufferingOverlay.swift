import AVKit
import UIKit

struct PlaybackBufferingDetails {
    struct Candidate {
        let host: String
        let isPCDN: Bool
        let result: CDNDiagnostics.ProbeResult?
    }

    var phase: String?
    var isPreparing = false
    var isRecovering = false
    var videoHost: String?
    var audioHost: String?
    var candidates = [Candidate]()
    var lastError: String?
}

/// Uses AVKit's public guide so the card stays above the native transport bar.
final class PlaybackBufferingOverlay: UIView {
    private weak var playerVC: AVPlayerViewController?
    private let detailsProvider: () -> PlaybackBufferingDetails?
    private let titleLabel = UILabel()
    private let detailsLabel = UILabel()
    private var timer: Timer?
    private var waitingSince: TimeInterval?

    init(playerVC: AVPlayerViewController, details: @escaping () -> PlaybackBufferingDetails?) {
        self.playerVC = playerVC
        detailsProvider = details
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        accessibilityIdentifier = "playback-buffering-overlay"
        backgroundColor = UIColor.black.withAlphaComponent(0.86)
        layer.cornerRadius = 20

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        detailsLabel.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        detailsLabel.textColor = .white.withAlphaComponent(0.9)
        titleLabel.numberOfLines = 0
        detailsLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailsLabel])
        stack.axis = .vertical
        stack.spacing = 10
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(24) }

        guard let container = playerVC.contentOverlayView else { return }
        container.addSubview(self)
        snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.82).priority(750)
            make.width.lessThanOrEqualTo(1160)
            make.bottom.equalTo(playerVC.unobscuredContentGuide.snp.bottom).offset(-24)
            make.top.greaterThanOrEqualTo(container.safeAreaLayoutGuide.snp.top).offset(24)
        }
        start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    func start() {
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        waitingSince = nil
        isHidden = true
    }

    static func shouldShow(timeControlStatus: AVPlayer.TimeControlStatus?,
                           details: PlaybackBufferingDetails?) -> Bool {
        timeControlStatus == .waitingToPlayAtSpecifiedRate
            || details?.isPreparing == true || details?.isRecovering == true
    }

    func refresh() {
        guard let playerVC else { stop(); return }
        let player = playerVC.player
        let details = detailsProvider()
        guard playerVC.showsPlaybackControls,
              Self.shouldShow(timeControlStatus: player?.timeControlStatus, details: details) else {
            waitingSince = nil
            isHidden = true
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if waitingSince == nil { waitingSince = now }
        let elapsed = Int(now - (waitingSince ?? now))
        titleLabel.text = "\(details?.phase ?? "正在缓冲") · 等待 \(elapsed) 秒"
        detailsLabel.text = Self.detailText(player: player, details: details)
        superview?.bringSubviewToFront(self)
        isHidden = false
    }

    static func detailText(player: AVPlayer?, details: PlaybackBufferingDetails?) -> String {
        var lines = [String]()
        let item = player?.currentItem
        let event = item?.accessLog()?.events.last
        if let item {
            let buffered = VideoBufferingController.bufferedSeconds(
                in: item.loadedTimeRanges.map(\.timeRangeValue), at: item.currentTime().seconds)
            var buffer = String(format: "连续缓冲 %.1f 秒 / 目标 %.0f 秒", buffered, item.preferredForwardBufferDuration)
            if let observed = event?.observedBitrate, observed.isFinite, observed > 0 {
                buffer += String(format: " · 播放器采样 %.1f Mbps", observed / 1_000_000)
            }
            lines.append(buffer)
        } else {
            lines.append("正在准备播放资源")
        }
        let resource = event?.uri.flatMap(URL.init(string:)) ?? (item?.asset as? AVURLAsset)?.url
        let directHost = ["http", "https"].contains(resource?.scheme ?? "") ? resource?.host : nil
        lines.append("视频服务器：\(details?.videoHost ?? directHost ?? "连接中")")
        if let audioHost = details?.audioHost, audioHost != details?.videoHost {
            lines.append("音频服务器：\(audioHost)")
        }
        if let address = event?.serverAddress { lines.append("最近连接 IP：\(address)") }
        if let reason = player?.reasonForWaitingToPlay {
            switch reason {
            case .toMinimizeStalls: lines.append("系统状态：等待足够缓冲")
            case .evaluatingBufferingRate: lines.append("系统状态：评估下载速度")
            case .noItemToPlay: lines.append("系统状态：等待媒体资源")
            default: lines.append("系统状态：等待恢复播放")
            }
        }
        if let error = details?.lastError {
            let sanitized = PlaybackDiagnostics.sanitize(error)
            lines.append("最近错误：\(sanitized.prefix(220))\(sanitized.count > 220 ? "…" : "")")
        }
        let candidates = details?.candidates ?? []
        if candidates.isEmpty {
            lines.append("候选 CDN：当前来源未提供备用节点")
        } else {
            lines.append("候选 CDN（短请求参考值，不代表持续网速）：")
            for candidate in candidates.prefix(3) {
                let measurement: String
                if let result = candidate.result {
                    if let speed = result.endToEndMbps {
                        measurement = String(format: "%.1f Mbps · 建连/等待 %.0f ms", speed, result.setupTime * 1000)
                    } else {
                        measurement = "测速失败"
                    }
                } else {
                    measurement = "待测速"
                }
                let active = candidate.host == details?.videoHost ? " · 当前" : ""
                let pcdn = candidate.isPCDN ? " · PCDN" : ""
                lines.append("\(candidate.host) · \(measurement)\(active)\(pcdn)")
            }
            if candidates.count > 3 { lines.append("另有 \(candidates.count - 3) 个候选节点") }
        }
        return lines.joined(separator: "\n")
    }
}
