import Combine
import Foundation

struct LivingHomeVideo: Identifiable, Equatable {
    let aid: Int
    let cid: Int
    let title: String
    let ownerName: String
    let pic: URL?
    var id: Int { aid }
}

struct LivingHomePage {
    let videos: [LivingHomeVideo]
    let nextCursor: Int
    let hasMore: Bool
}

enum LivingHomeSource {
    static func fetch(accountMID: Int?, cursor: Int, page: Int) async throws -> LivingHomePage {
        if accountMID != nil {
            // ApiRequest signs the request and includes the active access_key.
            // Don't silently substitute popular videos when this request fails.
            let items = try await ApiRequest.getFeeds(lastIdx: cursor)
            let videos = items.compactMap { item -> LivingHomeVideo? in
                let aid = Int(item.param) ?? item.player_args?.aid ?? 0
                guard item.goto == "av", item.can_play != 0, aid > 0 else { return nil }
                return LivingHomeVideo(aid: aid, cid: item.player_args?.cid ?? 0,
                                       title: item.title, ownerName: item.ownerName, pic: item.pic)
            }
            let next = items.last?.idx ?? cursor
            return LivingHomePage(videos: videos, nextCursor: next, hasMore: !items.isEmpty && next != cursor)
        }
        let videos = try await WebRequest.requestHotVideo(page: page).list.map {
            LivingHomeVideo(aid: $0.aid, cid: $0.cid, title: $0.title, ownerName: $0.ownerName, pic: $0.pic)
        }
        return LivingHomePage(videos: videos, nextCursor: 0, hasMore: !videos.isEmpty)
    }
}

@MainActor final class LivingHomeModel: ObservableObject {
    typealias Fetch = (Int?, Int, Int) async throws -> LivingHomePage
    @Published private(set) var videos: [LivingHomeVideo] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = true
    @Published private(set) var accountMID: Int?
    var isPersonalized: Bool { accountMID != nil }

    private let fetch: Fetch
    private let currentAccount: () -> Int?
    private var cursor = 0
    private var page = 1
    private var generation = UUID()
    private var retryReplacing = true
    private var accountObserver: AnyCancellable?

    init(currentAccount: @escaping () -> Int? = { ApiRequest.getToken()?.mid },
         fetch: @escaping Fetch = LivingHomeSource.fetch) {
        self.currentAccount = currentAccount
        self.fetch = fetch
        accountMID = currentAccount()
        accountObserver = NotificationCenter.default.publisher(for: AccountManager.didUpdateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.accountMID != self.currentAccount() else { return }
                Task { await self.load() }
            }
    }

    func load() async {
        let account = currentAccount()
        if accountMID != account { videos = [] }
        accountMID = account
        generation = UUID()
        cursor = 0
        page = 1
        hasMore = true
        await request(replacing: true)
    }

    func loadMore() async {
        if accountMID != currentAccount() { await load(); return }
        guard !loading, hasMore else { return }
        await request(replacing: false)
    }

    func retry() async {
        if retryReplacing { await load() } else { await loadMore() }
    }

    private func request(replacing: Bool) async {
        retryReplacing = replacing
        let requestGeneration = generation
        let account = accountMID
        loading = true
        error = nil
        defer { if generation == requestGeneration { loading = false } }
        do {
            let result = try await fetch(account, cursor, page)
            guard !Task.isCancelled, generation == requestGeneration, account == currentAccount() else { return }
            var seen = Set(replacing ? [] : videos.map(\.aid))
            let incoming = result.videos.filter { seen.insert($0.aid).inserted }
            videos = replacing ? incoming : videos + incoming
            cursor = result.nextCursor
            page += 1
            // Repeated recommendations must not trigger an endless load loop.
            hasMore = result.hasMore && !incoming.isEmpty
            if videos.isEmpty { error = isPersonalized ? "暂时没有可展示的推荐，请换一批试试。" : "暂时没有可展示的热门视频。" }
        } catch {
            guard generation == requestGeneration, account == currentAccount() else { return }
            self.error = isPersonalized ? "账号推荐加载失败，请重试；若持续失败，请重新登录。" : "热门视频加载失败，请稍后重试。"
        }
    }
}
