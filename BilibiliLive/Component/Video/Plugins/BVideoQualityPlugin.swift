import AVKit

/// One choice per resolution; codec selection remains an implementation detail.
class BVideoQualityPlugin: NSObject, CommonPlayerPlugin {
    private weak var playerVC: AVPlayerViewController?
    private let playData: PlayerDetailData
    private var selectedID: Int?
    private var switching = false
    private let onQualityChange: (Int, Int?) async -> Bool

    init(detailData: PlayerDetailData, onQualityChange: @escaping (Int, Int?) async -> Bool) {
        playData = detailData
        self.onQualityChange = onQualityChange
        super.init()
    }
    func playerDidLoad(playerVC: AVPlayerViewController) { self.playerVC = playerVC }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let info = playData.videoPlayURLInfo
        let groups = Dictionary(grouping: info.dash.video.enumerated().filter {
            $0.element.codecs.hasPrefix("avc") || $0.element.isHevc
        }, by: { $0.element.id })
        guard !groups.isEmpty else { return [] }
        var actions: [UIMenuElement] = [UIAction(title: "自动 · 优先 1080p", state: selectedID == nil ? .on : .off) { [weak self] _ in
            self?.select(quality: nil, index: nil)
        }]
        for id in groups.keys.sorted(by: >) {
            guard let streams = groups[id], let stream = streams.sorted(by: {
                if $0.element.isHevc != $1.element.isHevc {
                    return Settings.preferAvc ? !$0.element.isHevc : $0.element.isHevc
                }
                return $0.element.bandwidth > $1.element.bandwidth
            }).first else { continue }
            let title = info.support_formats.first(where: { $0.quality == id })?.new_description ?? "清晰度 \(id)"
            actions.append(UIAction(title: title, state: selectedID == id ? .on : .off) { [weak self] _ in
                self?.select(quality: id, index: stream.offset)
            })
        }
        return [UIMenu(title: switching ? "正在切换…" : "清晰度", image: UIImage(systemName: "slider.horizontal.3"), identifier: UIMenu.Identifier("quality"), children: actions)]
    }
    private func select(quality: Int?, index: Int?) {
        guard !switching else { return }
        switching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await onQualityChange(quality ?? 0, index)
            switching = false
            if succeeded { selectedID = quality }
            (playerVC?.parent as? CommonPlayerViewController)?.updateMenus()
            if !succeeded {
                let alert = UIAlertController(title: "清晰度切换失败", message: "请稍后重试，或选择其他清晰度。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .cancel))
                playerVC?.present(alert, animated: true)
            }
        }
    }
}
