import AVFoundation
import Foundation

/// Capture settings once so a preloaded asset and its cache key always agree.
struct PlayerMediaPreferences: Hashable {
    let quality: MediaQualityEnum
    let preferAVC: Bool
    let losslessAudio: Bool
    var proactiveBuffering = true

    static var current: Self {
        Self(quality: Settings.mediaQuality, preferAVC: Settings.preferAvc,
             losslessAudio: Settings.losslessAudio,
             proactiveBuffering: Settings.videoProactiveBuffering)
    }

    func selectVideos(from streams: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                      maxQuality: Int? = nil, streamIndex: Int? = nil,
                      excluding codecs: [String] = [],
                      isPlayable: (VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Bool = { _ in true })
        -> [VideoPlayURLInfo.DashInfo.DashMediaInfo] {
        let supported = streams.filter {
            ($0.codecs.hasPrefix("avc") || $0.isHevc) && !codecs.contains($0.codecs)
        }
        if let streamIndex {
            guard streams.indices.contains(streamIndex), supported.contains(streams[streamIndex]),
                  isPlayable(streams[streamIndex]) else { return [] }
            return [streams[streamIndex]]
        }
        let qualityID = maxQuality ?? supported.filter { $0.id <= quality.qn }.map(\.id).max()
        let requested = supported.filter { $0.id == qualityID }
        var videos = requested.filter(isPlayable)
        if videos.isEmpty, let desired = requested.first,
           let width = desired.width, let height = desired.height, width > 0, height > 0,
           let frameRate = Self.frameRate(desired.frame_rate) {
            let compatible = supported.filter {
                $0.isHevc && isPlayable($0) && $0.width == width && $0.height == height
                    && Self.frameRate($0.frame_rate).map { $0 >= frameRate - 0.01 } == true
            }
            let alternateQuality = compatible.map(\.id).max()
            videos = compatible.filter { $0.id == alternateQuality }
        }
        if preferAVC, videos.contains(where: { $0.codecs.hasPrefix("avc") }) {
            videos.removeAll { !$0.codecs.hasPrefix("avc") }
        }
        // Keep CDN/codec alternatives at this quality. Including lower qualities
        // lets AVPlayer override the user's default during startup or buffering.
        return videos.sorted { $0.bandwidth > $1.bandwidth }
    }

    static func isPlayable(_ stream: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Bool {
        AVURLAsset.isPlayableExtendedMIMEType("\(stream.mime_type); codecs=\"\(stream.codecs)\"")
    }

    private static func frameRate(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/")
        let rate: Double?
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 {
            rate = numerator / denominator
        } else { rate = Double(value) }
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }
}
