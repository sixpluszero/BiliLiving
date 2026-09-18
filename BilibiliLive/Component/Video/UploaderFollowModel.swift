import UIKit

@MainActor
final class UploaderFollowModel {
    private(set) var isFollowing: Bool
    private(set) var isBusy = false
    private var hasLoadedState = false
    private let read: () async throws -> Bool
    private let write: (Bool) async throws -> Void
    var onChange: (() -> Void)?

    var title: String { isBusy ? "处理中…" : (isFollowing ? "已关注" : "关注博主") }

    init(isFollowing: Bool, read: @escaping () async throws -> Bool,
         write: @escaping (Bool) async throws -> Void) {
        self.isFollowing = isFollowing
        self.read = read
        self.write = write
    }

    convenience init(mid: Int, isFollowing: Bool) {
        self.init(isFollowing: isFollowing, read: {
            try await WebRequest.requestUpSpaceRelation(mid: mid).isFollowing
        }, write: { following in
            try await WebRequest.requestFollow(mid: mid, follow: following)
        })
    }

    func refresh() async throws {
        guard !isBusy else { return }
        isBusy = true
        onChange?()
        defer { isBusy = false; onChange?() }
        isFollowing = try await read()
        hasLoadedState = true
    }

    func toggle() async throws {
        guard !isBusy else { return }
        isBusy = true
        onChange?()
        defer { isBusy = false; onChange?() }
        // Detail responses can omit the relationship. Verify it before deciding
        // whether this is a follow or an unfollow request.
        if !hasLoadedState {
            isFollowing = try await read()
            hasLoadedState = true
        }
        let next = !isFollowing
        try await write(next)
        isFollowing = next
    }

    func toggle(from presenter: UIViewController) {
        guard presenter.requireLivingAccount(), !isBusy else { return }
        Task { [weak self, weak presenter] in
            do {
                try await self?.toggle()
            } catch {
                guard let presenter else { return }
                let alert = UIAlertController(title: "关注操作失败", message: "未能更新关注状态，请稍后重试。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .cancel))
                presenter.present(alert, animated: true)
            }
        }
    }
}
