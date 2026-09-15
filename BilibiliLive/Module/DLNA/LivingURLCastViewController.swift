import AVFoundation

/// Standard DLNA senders may supply a playable URL without Bilibili IDs.
final class LivingURLCastViewController: CommonPlayerViewController {
    private let url: URL
    private let context: LivingCastContext
    private var buffering: VideoBufferingController?
    private let danmakuCID: Int?
    private var danmakuTask: Task<Void, Never>?
    private weak var activePlayer: AVPlayer?

    init(url: URL, context: LivingCastContext, danmakuCID: Int? = nil) {
        self.url = url
        self.context = context
        self.danmakuCID = danmakuCID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let danmakuCID {
            addPlugin(plugin: SpeedChangerPlugin())
            let provider = VideoDanmuProvider(enableDanmuFilter: Settings.enableDanmuFilter,
                                             enableDanmuRemoveDup: Settings.enableDanmuRemoveDup)
            let danmaku = DanmuViewPlugin(provider: provider)
            // Initialize before attaching the time observer; provider.cid must
            // exist even when the media URL becomes ready immediately.
            danmakuTask = Task { @MainActor [weak self] in
                await provider.initVideo(cid: danmakuCID, startPos: 0)
                guard !Task.isCancelled, let self else { return }
                self.addPlugin(plugin: danmaku)
                if let player = self.activePlayer {
                    danmaku.playerDidChange(player: player)
                    if player.currentItem?.status == .readyToPlay {
                        danmaku.playerWillStart(player: player)
                        if player.rate > 0 { danmaku.playerDidStart(player: player) }
                    }
                }
                self.updateMenus()
            }
        }
        addPlugin(plugin: BUpnpPlugin(duration: nil, context: context))
        let plugin = URLPlayPlugin(referer: "https://www.bilibili.com/")
        addPlugin(plugin: plugin)
        plugin.play(urlString: url.absoluteString)
    }
    override func playerWillStart(player: AVPlayer) {
        super.playerWillStart(player: player)
        activePlayer = player
        if let item = player.currentItem {
            buffering = VideoBufferingController(item: item, target: Double(Settings.videoBufferDuration.rawValue))
        }
    }
    override func playerDidFail(player: AVPlayer) {
        super.playerDidFail(player: player)
        // AVPlayer errors can embed the signed URL; display a fixed message.
        Logger.warn("[cast] direct media playback failed")
        showErrorAlertAndExit(message: "手机发送的视频地址无法播放，请重新投屏。")
    }
    override func stopPlayback() {
        danmakuTask?.cancel()
        danmakuTask = nil
        activePlayer = nil
        buffering?.stop()
        buffering = nil
        super.stopPlayback()
    }
    override func viewDidDisappear(_ animated: Bool) {
        danmakuTask?.cancel()
        danmakuTask = nil
        buffering?.stop()
        buffering = nil
        super.viewDidDisappear(animated)
    }
}
