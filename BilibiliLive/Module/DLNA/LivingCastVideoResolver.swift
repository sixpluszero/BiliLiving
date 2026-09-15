import Foundation

/// The phone's generic DLNA stream has no quality ladder. Recover the original
/// video only when its CDN CID matches a page returned by Bilibili's own API.
struct LivingCastVideoHint {
    let cid: Int
    let title: String?

    init?(url: URL, metadata: String) {
        guard let host = url.host?.lowercased(),
              host == "bilivideo.com" || host.hasSuffix(".bilivideo.com") ||
              host == "bilivideo.cn" || host.hasSuffix(".bilivideo.cn") ||
              host == "upos-hz-mirrorakam.akamaized.net" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 5, parts[0] == "upgcxcode",
              parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber),
              let cid = Int(parts[3]), cid > 0,
              parts[4].hasPrefix("\(cid)-"), ["mp4", "m4s", "flv"].contains(url.pathExtension.lowercased()) else { return nil }
        self.cid = cid
        title = Self.readTitle(metadata)
    }

    private static func readTitle(_ metadata: String) -> String? {
        guard !metadata.isEmpty, metadata.utf8.count <= 1_048_576 else { return nil }
        let reader = TitleReader()
        let parser = XMLParser(data: Data(metadata.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid else { return nil }
        let title = reader.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 300 ? title : nil
    }

    private final class TitleReader: NSObject, XMLParserDelegate {
        var title = ""
        var invalid = false
        private var reading = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if elementName == "title", namespaceURI == "http://purl.org/dc/elements/1.1/", title.isEmpty { reading = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { title += string } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if reading { title += String(decoding: CDATABlock, as: UTF8.self) } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "title" { reading = false }
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
    }
}

@MainActor enum LivingCastVideoResolver {
    private static var cache: [Int: PlayInfo] = [:]

    /// Bounded startup delay. Older WebRequest continuations do not propagate
    /// cancellation to Alamofire, so don't wait on a cancelled network task.
    static func resolve(_ hint: LivingCastVideoHint, timeout: TimeInterval = 8) async -> PlayInfo? {
        if let cached = cache[hint.cid] { return cached }
        guard let title = hint.title else { return nil }
        var finished = false
        var result: PlayInfo?
        let lookup = Task { @MainActor in
            result = await search(title: title, cid: hint.cid)
            finished = true
        }
        defer { lookup.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return nil }
        }
        guard !Task.isCancelled, finished, let result else { return nil }
        if cache.count >= 32 { cache.removeAll() }
        cache[hint.cid] = result
        return result
    }

    static func matchingPage(in detail: VideoDetail.Info, cid: Int) -> PlayInfo? {
        guard detail.cid == cid || detail.pages?.contains(where: { $0.cid == cid }) == true else { return nil }
        return PlayInfo(aid: detail.aid, cid: cid, title: detail.title,
                        ownerName: detail.owner.name, coverURL: detail.pic)
    }

    private static func search(title: String, cid: Int) async -> PlayInfo? {
        do {
            let result = try await WebRequest.requestSearchResult(key: title)
            try Task.checkCancellation()
            var videos = [SearchResult.Video]()
            for section in result.result {
                if case let .video(items) = section { videos += items }
            }
            // SearchResult deduplicates with Set, so restore a deterministic
            // order and check exact-title candidates before broader matches.
            func normalize(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
            let expected = normalize(title)
            videos.sort {
                let leftExact = normalize($0.title) == expected
                let rightExact = normalize($1.title) == expected
                return leftExact == rightExact ? $0.aid < $1.aid : leftExact
            }
            // A title is only a search hint, never sufficient proof of identity.
            for video in videos.prefix(5) {
                try Task.checkCancellation()
                // Only need CID/pages: don't load related videos or user state.
                guard let detail: VideoDetail.Info = try? await WebRequest.request(
                    url: "https://api.bilibili.com/x/web-interface/wbi/view", parameters: ["aid": video.aid]
                ) else { continue }
                try Task.checkCancellation()
                if let info = matchingPage(in: detail, cid: cid) { return info }
            }
        } catch { /* Keep the phone's playable stream when lookup is unavailable. */ }
        return nil
    }
}
