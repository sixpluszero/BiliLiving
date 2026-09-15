import AVFoundation

/// Standard DLNA senders may supply a playable URL without Bilibili IDs.
final class LivingURLCastViewController: CommonPlayerViewController {
    private let url: URL
    private let context: LivingCastContext
    private var buffering: VideoBufferingController?

    init(url: URL, context: LivingCastContext) {
        self.url = url
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addPlugin(plugin: BUpnpPlugin(duration: nil, context: context))
        let plugin = URLPlayPlugin(referer: "https://www.bilibili.com/")
        addPlugin(plugin: plugin)
        plugin.play(urlString: url.absoluteString)
    }
    override func playerWillStart(player: AVPlayer) {
        super.playerWillStart(player: player)
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
    override func viewDidDisappear(_ animated: Bool) {
        buffering?.stop()
        buffering = nil
        super.viewDidDisappear(animated)
    }
}
