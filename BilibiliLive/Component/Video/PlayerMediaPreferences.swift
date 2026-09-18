import Foundation

/// Capture settings once so a preloaded asset and its cache key always agree.
struct PlayerMediaPreferences: Hashable {
    let quality: MediaQualityEnum
    let preferAVC: Bool
    let losslessAudio: Bool

    static var current: Self {
        Self(quality: Settings.mediaQuality, preferAVC: Settings.preferAvc,
             losslessAudio: Settings.losslessAudio)
    }

    func selectVideos(from streams: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                      maxQuality: Int? = nil, streamIndex: Int? = nil,
                      excluding codecs: [String] = []) -> [VideoPlayURLInfo.DashInfo.DashMediaInfo] {
        let supported = streams.filter {
            ($0.codecs.hasPrefix("avc") || $0.isHevc) && !codecs.contains($0.codecs)
        }
        if let streamIndex {
            guard streams.indices.contains(streamIndex), supported.contains(streams[streamIndex]) else { return [] }
            return [streams[streamIndex]]
        }
        let qualityID = maxQuality ?? supported.filter { $0.id <= quality.qn }.map(\.id).max()
        var videos = supported.filter { $0.id == qualityID }
        if preferAVC, videos.contains(where: { $0.codecs.hasPrefix("avc") }) {
            videos.removeAll { !$0.codecs.hasPrefix("avc") }
        }
        // Keep CDN/codec alternatives at this quality. Including lower qualities
        // lets AVPlayer override the user's default during startup or buffering.
        return videos.sorted { $0.bandwidth > $1.bandwidth }
    }
}
