import XCTest
import AVKit
@testable import BilibiliLive

final class BiliLivingTests: XCTestCase {
    func testDefaultNavigationAnd1080pPolicy() {
        XCTAssertEqual(TabBarPage.defaultTabBarPages, [.feed, .search, .personal])
        XCTAssertEqual(MediaQualityEnum.quality_1080p.qn, 80)
        XCTAssertEqual(Settings.defaultPlacements.filter { $0.section == .tabBar }.map(\.page), [.feed, .search, .personal])
    }

    @MainActor func testQRCodeIsDecodableAtDisplaySize() throws {
        let value = "https://passport.bilibili.com/test?auth_code=local-test-only"
        let image = try XCTUnwrap(LoginViewController.create().generateQRCode(from: value))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let feature = try XCTUnwrap(detector.features(in: ciImage).first as? CIQRCodeFeature)
        XCTAssertEqual(feature.messageString, value)
    }

    @MainActor func testLiveSearchAndVideoMetadata() async throws {
        let result = try await WebRequest.requestSearchResult(key: "Apple TV")
        var videos: [SearchResult.Video] = []
        for section in result.result { if case let .video(items) = section { videos += items } }
        XCTAssertFalse(videos.isEmpty, "Live search must return real video records")
        let first = try XCTUnwrap(videos.first)
        XCTAssertFalse(first.title.contains("<em"))
        let cid = try await WebRequest.requestCid(aid: first.aid)
        XCTAssertGreaterThan(cid, 0)
        let detail = try await WebRequest.requestDetailVideo(aid: first.aid)
        XCTAssertEqual(detail.View.aid, first.aid)
        XCTAssertFalse(detail.View.title.isEmpty)
    }

    @MainActor func testLiveQRGenerationAndWaitingState() async throws {
        let generated = expectation(description: "Live QR endpoint")
        var key = ""
        ApiRequest.requestLoginQR(onFailure: { error in XCTFail("QR generation failed: \(error)"); generated.fulfill() }) { code, url in
            key = code
            XCTAssertFalse(code.isEmpty)
            XCTAssertNotNil(URL(string: url))
            generated.fulfill()
        }
        await fulfillment(of: [generated], timeout: 30)
        guard !key.isEmpty else { return }
        let polled = expectation(description: "Unscanned QR waits")
        ApiRequest.verifyLoginQR(code: key) { state in
            if case .waiting = state {} else { XCTFail("New, unscanned QR should wait") }
            polled.fulfill()
        }
        await fulfillment(of: [polled], timeout: 30)
    }

    @MainActor func testLiveDanmakuFetchAndDelivery() async throws {
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first)
        let provider = VideoDanmuProvider(enableDanmuFilter: false, enableDanmuRemoveDup: false)
        let delivered = expectation(description: "Real protobuf danmaku delivered")
        delivered.assertForOverFulfill = false
        let subscription = provider.onSendTextModel.sink { _ in delivered.fulfill() }
        await provider.initVideo(cid: video.cid, startPos: 0)
        for second in 1...120 { provider.playerTimeChange(time: Double(second)) }
        await fulfillment(of: [delivered], timeout: 20)
        withExtendedLifetime(subscription) {}
    }
    @MainActor func testLivePlaybackQualitySwitchAndPausePreservation() async throws {
        let hot = try await WebRequest.requestHotVideo(page: 1)
        let video = try XCTUnwrap(hot.list.first)
        let info = try await WebRequest.requestPlayUrl(aid: video.aid, cid: video.cid)
        XCTAssertFalse(info.dash.video.isEmpty)
        let detail = PlayerDetailData(aid: video.aid, cid: video.cid, epid: nil, seasonId: nil, subType: nil, videoPlayURLInfo: info)
        let container = CommonPlayerViewController()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        window.rootViewController = container
        container.loadViewIfNeeded()
        let plugin = BVideoPlayPlugin(playInfo: PlayInfo(aid: video.aid, cid: video.cid), detailData: detail, reportWatchHistory: false)
        container.addPlugin(plugin: plugin)
        let playerVC = try XCTUnwrap(container.children.first as? AVPlayerViewController)
        defer { container.stopPlayback(); window.rootViewController = original }
        for _ in 0..<200 {
            if (playerVC.player?.currentTime().seconds ?? 0) > 2 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let player = try XCTUnwrap(playerVC.player)
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(player.currentTime().seconds, 2, "Real video time must advance")
        player.pause()
        let position = player.currentTime().seconds
        let stream = try XCTUnwrap(info.dash.video.enumerated().first { $0.element.codecs.hasPrefix("avc") })
        let switched = await plugin.switchQuality(to: stream.element.id, streamIndex: stream.offset)
        XCTAssertTrue(switched)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let nextPlayer = try XCTUnwrap(playerVC.player)
        XCTAssertEqual(nextPlayer.rate, 0, "Changing quality must preserve pause")
        XCTAssertEqual(nextPlayer.currentTime().seconds, position, accuracy: 1.5)
        let selector = BVideoQualityPlugin(detailData: detail) { _, _ in true }
        var current: [UIMenuElement] = []
        let menu = try XCTUnwrap(selector.addMenuItems(current: &current).first as? UIMenu)
        XCTAssertEqual(menu.title, "清晰度")
        XCTAssertTrue(menu.children.contains { $0.title == "自动 · 优先 1080p" })
        nextPlayer.play()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(nextPlayer.currentTime().seconds, position)
    }

    @MainActor func testGuestLaunchAndAccountActionPrompt() async throws {
        guard !ApiRequest.isLogin() else { throw XCTSkip("Guest test requires a logged-out simulator") }
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let root = try XCTUnwrap(window.rootViewController)
        XCTAssertTrue(root is BLTabBarViewController, "Guests must launch directly into browsing")
        XCTAssertFalse(root.requireLivingAccount())
        try await Task.sleep(nanoseconds: 500_000_000)
        let prompt = try XCTUnwrap(root.presentedViewController as? UIAlertController)
        XCTAssertEqual(prompt.title, "登录后使用")
        XCTAssertTrue(prompt.actions.contains { $0.title == "继续游客浏览" && $0.style == .cancel })
        XCTAssertTrue(prompt.actions.contains { $0.title == "扫码登录" })
        root.dismiss(animated: false)
    }

}
