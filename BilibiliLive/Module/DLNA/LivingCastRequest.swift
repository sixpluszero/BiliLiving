import Foundation
import SwiftyJSON

/// Only video identifiers and playback position cross into the player. Phone credentials are ignored.
struct LivingCastRequest {
    let playInfo: PlayInfo
    let position: Int

    init(json: JSON) throws {
        func integer(_ key: String) -> Int { json[key].int ?? Int(json[key].stringValue) ?? 0 }
        let aid = integer("aid")
        let epid = max(integer("epid"), integer("epId"))
        guard aid > 0 || epid > 0 else { throw CastError.invalidVideo }
        playInfo = PlayInfo(aid: max(0, aid), cid: max(0, integer("cid")), epid: max(0, epid),
                            seasonId: max(integer("season_id"), integer("seasonId")))
        if json["seekTs"].exists() {
            guard let seconds = Self.seconds(json["seekTs"]) else { throw CastError.invalidPosition }
            position = Int(seconds)
        } else { position = 0 }
    }

    static func seconds(_ json: JSON) -> Double? {
        guard json.type != .bool,
              let value = json.double ?? Double(json.stringValue),
              value.isFinite, value >= 0, value <= 31_536_000 else { return nil }
        return value
    }

    static func content(action: String, body: String) throws -> JSON {
        guard let data = body.data(using: .utf8) else { throw CastError.invalidVideo }
        let json = try JSON(data: data)
        guard action == "PlayUrl" else { return json }
        guard let url = json["url"].string,
              let ext = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "nva_ext" })?.value,
              let data = ext.data(using: .utf8) else { throw CastError.invalidVideo }
        return try JSON(data: data)["content"]
    }

    enum CastError: LocalizedError {
        case invalidVideo, invalidPosition
        var errorDescription: String? {
            switch self {
            case .invalidVideo: return "未收到有效的视频，请在手机上重新投屏。"
            case .invalidPosition: return "播放进度无效，请在手机上重新投屏。"
            }
        }
    }
}

/// A new object per cast prevents commands during loading from reaching the previous video.
final class LivingCastContext {
    let id = UUID()
    var pendingSeek: Double?
    var paused = false
}
