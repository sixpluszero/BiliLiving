//
//  PlayInfoResolver.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/6.
//

import Foundation

enum PlayInfoResolver {
    static func bangumiEpisodeID(in detail: VideoDetail?) -> Int? {
        guard let path = detail?.View.redirect_url?.lastPathComponent,
              path.hasPrefix("ep"), let epid = Int(path.dropFirst(2)), epid > 0
        else { return nil }
        return epid
    }

    static func resolve(_ playInfo: PlayInfo) async throws -> PlayInfo {
        try await resolveWithEpisodes(playInfo).playInfo
    }

    static func resolveWithEpisodes(_ playInfo: PlayInfo, knownEpisodes: VideoEpisodeList? = nil) async throws -> (playInfo: PlayInfo, episodes: VideoEpisodeList?) {
        if playInfo.isBangumi {
            if let epid = playInfo.epid, epid > 0,
               let episode = knownEpisodes?.sections.flatMap(\.items).first(where: { $0.epid == epid })
            {
                var resolved = playInfo
                resolved.aid = episode.aid
                resolved.cid = episode.cid
                resolved.seasonId = episode.seasonId
                resolved.subType = resolved.subType ?? episode.subType
                resolved.title = resolved.title ?? episode.title
                resolved.coverURL = resolved.coverURL ?? episode.coverURL
                return (resolved, knownEpisodes)
            }
            let info: BangumiInfo
            if let epid = playInfo.epid, epid > 0 {
                info = try await WebRequest.requestBangumiInfo(epid: epid)
            } else if let seasonId = playInfo.seasonId, seasonId > 0 {
                info = try await WebRequest.requestBangumiInfo(seasonID: seasonId)
            } else {
                throw ValidationError.argumentInvalid(message: "缺少番剧标识，无法解析播放信息")
            }
            return (try resolveBangumi(playInfo, using: info), .bangumi(info))
        }
        guard !playInfo.isCidVaild else { return (playInfo, nil) }
        guard playInfo.aid > 0 else {
            throw ValidationError.argumentInvalid(message: "缺少视频 aid，无法解析播放信息")
        }
        var resolved = playInfo
        resolved.cid = try await WebRequest.requestCid(aid: playInfo.aid)
        return (resolved, nil)
    }

    static func resolveBangumi(_ playInfo: PlayInfo, using info: BangumiInfo) throws -> PlayInfo {
        var resolved = playInfo
        resolved.seasonId = info.season_id
        resolved.subType = resolved.subType ?? info.type

        let matchedEpisode: BangumiInfo.Episode?
        if let epid = resolved.epid, epid > 0 {
            matchedEpisode = info.findEpisodeById(epid)
        } else {
            matchedEpisode = info.user_status?.progress.flatMap { info.findEpisodeById($0.last_ep_id) }
                ?? info.episodes.first
                ?? info.section?.first?.episodes.first
        }

        guard let episode = matchedEpisode, episode.aid > 0, episode.cid > 0 else {
            throw ValidationError.argumentInvalid(message: "找不到所选剧集或该剧集尚不可播放")
        }
        resolved.epid = episode.id
        resolved.aid = episode.aid
        resolved.cid = episode.cid
        if resolved.coverURL == nil {
            resolved.coverURL = episode.cover
        }
        if resolved.title?.isEmpty != false {
            resolved.title = [episode.title, episode.long_title]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return resolved
    }
}
