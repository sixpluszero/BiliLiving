import Foundation

struct VideoEpisodeList {
    struct Section {
        enum Kind {
            case parts
            case collection
            case bangumi
        }

        let id: String
        let title: String
        let kind: Kind
        let items: [PlayInfo]

        func index(of playInfo: PlayInfo) -> Int? {
            items.firstIndex { item in
                if kind == .collection {
                    return item.aid == playInfo.aid
                }
                if let epid = item.epid, epid > 0 {
                    return epid == playInfo.epid
                }
                return item.aid == playInfo.aid && item.cid == playInfo.cid
            }
        }
    }

    struct Selection: Equatable {
        let sectionID: String
        let index: Int
    }

    struct Page {
        let sectionIndex: Int
        let range: Range<Int>
    }

    let sections: [Section]

    init(sections: [Section] = []) {
        self.sections = sections.compactMap { section in
            var seen = Set<String>()
            let items = section.items.filter { item in
                guard item.aid > 0, item.isCidVaild else {
                    Logger.warn("选集忽略无效视频标识: aid=\(item.aid), cid=\(item.cid ?? 0)")
                    return false
                }
                return seen.insert(Self.identity(of: item)).inserted
            }
            guard !items.isEmpty else { return nil }
            return Section(id: section.id, title: section.title, kind: section.kind, items: items)
        }
    }

    var hasChoices: Bool {
        Set(sections.flatMap(\.items).map(Self.identity(of:))).count > 1
    }

    var pages: [Page] {
        sections.enumerated().flatMap { index, section in
            stride(from: 0, to: section.items.count, by: 20).map {
                Page(sectionIndex: index, range: $0..<min($0 + 20, section.items.count))
            }
        }
    }

    func section(for playInfo: PlayInfo, preferredID: String? = nil) -> Section? {
        let matching = sections.filter { $0.index(of: playInfo) != nil }
        return matching.first { $0.id == preferredID }
            ?? matching.first { $0.kind == .collection }
            ?? matching.first
    }

    func item(for selection: Selection) -> PlayInfo? {
        guard let section = sections.first(where: { $0.id == selection.sectionID }),
              section.items.indices.contains(selection.index)
        else { return nil }
        return section.items[selection.index]
    }

    func retaining(_ section: Section?) -> VideoEpisodeList {
        guard let section, !sections.contains(where: { $0.id == section.id }) else { return self }
        return VideoEpisodeList(sections: sections + [section])
    }

    static func partsSectionID(aid: Int) -> String {
        "parts-\(aid)"
    }

    static func video(_ detail: VideoDetail) -> VideoEpisodeList {
        let video = detail.View
        var sections = [Section]()
        if let pages = video.pages, pages.count > 1 {
            sections.append(Section(id: partsSectionID(aid: video.aid),
                                    title: "视频分 P",
                                    kind: .parts,
                                    items: pages.map {
                                        PlayInfo(aid: video.aid, cid: $0.cid, title: $0.part,
                                                 ownerName: video.owner.name, coverURL: video.pic)
                                    }))
        }
        if let season = video.ugc_season {
            sections += season.sections.map { section in
                Section(id: "ugc-\(season.id)-\(section.id)",
                        title: section.title.isEmpty ? season.title : "\(season.title) · \(section.title)",
                        kind: .collection,
                        items: section.episodes.map {
                            PlayInfo(aid: $0.aid, cid: $0.cid, title: $0.title,
                                     ownerName: video.owner.name, coverURL: $0.pic)
                        })
            }
        }
        return VideoEpisodeList(sections: sections)
    }

    static func bangumi(_ info: BangumiInfo) -> VideoEpisodeList {
        func items(_ episodes: [BangumiInfo.Episode]) -> [PlayInfo] {
            episodes.map {
                PlayInfo(aid: $0.aid, cid: $0.cid, epid: $0.id, seasonId: info.season_id,
                         subType: info.type,
                         title: [$0.title, $0.long_title].filter { !$0.isEmpty }.joined(separator: " "),
                         coverURL: $0.cover)
            }
        }
        var sections = [Section(id: "pgc-\(info.season_id)-main", title: "正片",
                                kind: .bangumi, items: items(info.episodes))]
        sections += (info.section ?? []).enumerated().map { index, section in
            Section(id: "pgc-\(info.season_id)-extra-\(section.id.map(String.init) ?? String(index))",
                    title: section.title.flatMap { $0.isEmpty ? nil : $0 } ?? "其他剧集 \(index + 1)",
                    kind: .bangumi, items: items(section.episodes))
        }
        return VideoEpisodeList(sections: sections)
    }

    private static func identity(of playInfo: PlayInfo) -> String {
        if let epid = playInfo.epid, epid > 0 { return "ep-\(epid)" }
        return "\(playInfo.aid)-\(playInfo.cid ?? 0)"
    }
}

struct VideoEpisodeNavigation {
    private(set) var list = VideoEpisodeList()
    private(set) var current: PlayInfo
    private(set) var activeSectionID: String?
    private let followsSeriesAutomatically: Bool

    init(current: PlayInfo, followsSeriesAutomatically: Bool) {
        self.current = current
        self.followsSeriesAutomatically = followsSeriesAutomatically
    }

    var isFollowingSeries: Bool { activeSectionID != nil }

    var activeSection: VideoEpisodeList.Section? {
        list.sections.first { $0.id == activeSectionID }
    }

    var next: PlayInfo? {
        guard let section = activeSection,
              let index = section.index(of: current),
              section.items.indices.contains(index + 1)
        else { return nil }
        return section.items[index + 1]
    }

    var first: PlayInfo? { activeSection?.items.first }

    mutating func update(list: VideoEpisodeList, current: PlayInfo, selectedSectionID: String? = nil) {
        let preferredID = selectedSectionID ?? activeSectionID
        let retained = self.list.sections.first { $0.id == preferredID && $0.index(of: current) != nil }
        var updated = list
        if let retained {
            // Some episode responses omit the collection; keep its known groups, not the previous video's parts.
            let sections = list.sections.isEmpty && retained.kind != .parts
                ? self.list.sections.filter { $0.kind != .parts } : [retained]
            for section in sections { updated = updated.retaining(section) }
        }
        self.list = updated
        self.current = current
        if followsSeriesAutomatically || preferredID != nil {
            activeSectionID = self.list.section(for: current, preferredID: preferredID)?.id
        } else {
            activeSectionID = nil
        }
    }

    mutating func leaveSeries() {
        activeSectionID = nil
    }
}
