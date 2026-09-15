import AVFoundation

enum VideoBufferDuration: Int, Codable, CaseIterable {
    case standard = 30
    case extended = 120
    case maximum = 300

    var title: String {
        switch self {
        case .standard: return "30 秒"
        case .extended: return "2 分钟（推荐）"
        case .maximum: return "5 分钟"
        }
    }
}

/// Let AVPlayer fetch well ahead during steady playback, while keeping rapid
/// seeks inexpensive. This is a forward-buffer preference, not a startup gate:
/// playback does not have to wait for the entire target to download.
final class VideoBufferingController {
    private weak var item: AVPlayerItem?
    private var timeJumpObserver: NSObjectProtocol?
    private var restoreWork: DispatchWorkItem?
    private var target: TimeInterval
    private let settlingDelay: TimeInterval

    init(item: AVPlayerItem, target: TimeInterval, settlingDelay: TimeInterval = 2) {
        self.item = item
        self.target = target
        self.settlingDelay = settlingDelay
        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: item, queue: .main
        ) { [weak self] _ in self?.prepareForSeek() }
        prepareForSeek()
    }

    func updateTarget(_ target: TimeInterval) {
        self.target = target
        if restoreWork == nil { item?.preferredForwardBufferDuration = target }
    }

    func prepareForSeek() {
        restoreWork?.cancel()
        item?.preferredForwardBufferDuration = min(15, target)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.item?.preferredForwardBufferDuration = self.target
            self.restoreWork = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settlingDelay, execute: work)
    }

    func stop() {
        restoreWork?.cancel()
        restoreWork = nil
        if let timeJumpObserver { NotificationCenter.default.removeObserver(timeJumpObserver) }
        timeJumpObserver = nil
        item = nil
    }

    deinit { stop() }

    static func bufferedSeconds(in ranges: [CMTimeRange], at current: Double) -> Double {
        guard current.isFinite else { return 0 }
        var end = current
        for range in ranges.sorted(by: { $0.start.seconds < $1.start.seconds }) {
            let start = range.start.seconds
            let rangeEnd = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, rangeEnd.isFinite else { continue }
            if start > end + 0.05 { break }
            end = max(end, rangeEnd)
        }
        return max(0, end - current)
    }
}
