import XCTest
import AVKit
import Network
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

    func testCastRequestValidationAndPlayURL() throws {
        let content = try LivingCastRequest.content(action: "Play", body: #"{"aid":"123","cid":"456","seekTs":"37.8","access_key":"ignored"}"#)
        let request = try LivingCastRequest(json: content)
        XCTAssertEqual(request.playInfo.aid, 123)
        XCTAssertEqual(request.playInfo.cid, 456)
        XCTAssertEqual(request.position, 37)
        let ext = #"{"content":{"aid":123,"cid":456,"seekTs":0}}"#
        var url = URLComponents(string: "https://example.com/video")!
        url.queryItems = [URLQueryItem(name: "nva_ext", value: ext)]
        let body = String(data: try JSONSerialization.data(withJSONObject: ["url": url.string!]), encoding: .utf8)!
        let wrapped = try LivingCastRequest.content(action: "PlayUrl", body: body)
        XCTAssertEqual(try LivingCastRequest(json: wrapped).position, 0)
        for body in [#"{"aid":0}"#, #"{"aid":123,"seekTs":-1}"#, #"{"aid":123,"seekTs":"NaN"}"#, #"{"aid":123,"seekTs":true}"#] {
            XCTAssertThrowsError(try LivingCastRequest(json: LivingCastRequest.content(action: "Play", body: body)))
        }
    }

    @MainActor func testCastDiscoveryAndMalformedConnectionRecovery() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer { receiver.setEnabled(previous) }
        XCTAssertTrue(receiver.isRunning)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9958/description.xml")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(BiliBiliUpnpDMR.deviceName))
        let (_, debugResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9958/debug/log")!)
        XCTAssertEqual((debugResponse as? HTTPURLResponse)?.statusCode, 404)
        let discovery = CastTestPhone(port: 1900, udp: true)
        defer { discovery.close() }
        try await discovery.connect()
        try await discovery.send(Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nMX: 1\r\n\r\n".utf8))
        try await eventually { discovery.text.contains("HTTP/1.1 200 OK") }
        XCTAssertTrue(discovery.text.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
        let invalid = CastTestPhone()
        try await invalid.setup()
        try await eventually { receiver.connectedCount == 1 }
        // A claimed 4 GB JSON body must close this connection without allocating it or crashing the app.
        var packet = CastTestPhone.command("Play", body: "")
        packet.replaceSubrange((packet.count - 4)..<packet.count, with: [255, 255, 255, 255])
        try await invalid.send(packet)
        try await eventually { receiver.connectedCount == 0 }
        invalid.close()
        let fresh = CastTestPhone()
        defer { fresh.close() }
        try await fresh.setup()
        try await eventually { receiver.connectedCount == 1 }
        XCTAssertTrue(receiver.isRunning)
        try await fresh.send(CastTestPhone.command("Play", body: #"{"aid":0}"#))
        try await eventually { receiver.status.contains("有效的视频") }
        receiver.start() // Idempotent start must preserve an established phone connection.
        XCTAssertEqual(receiver.connectedCount, 1)
        receiver.didEnterBackground()
        XCTAssertFalse(receiver.isRunning)
        receiver.willEnterForeground()
        try await eventually { receiver.isRunning }
        receiver.setEnabled(false)
        XCTAssertFalse(receiver.isRunning)
        XCTAssertEqual(receiver.connectedCount, 0)
    }

    @MainActor func testCastLiveHandoffControlsAndReconnect() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        let previousDanmaku = Defaults.shared.showDanmu
        receiver.setEnabled(true)
        let phone = CastTestPhone()
        let reconnected = CastTestPhone()
        defer {
            phone.close(); reconnected.close()
            receiver.currentPlugin?.player?.pause()
            AppDelegate.shared.window?.rootViewController?.dismiss(animated: false)
            Defaults.shared.showDanmu = previousDanmaku
            receiver.setEnabled(previous)
        }
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first { $0.duration > 100 })
        try await phone.setup()
        try await eventually { receiver.connectedCount == 1 }
        let payload = "{\"aid\":\(video.aid),\"cid\":\(video.cid),\"seekTs\":37}"
        try await phone.send(CastTestPhone.command("Play", body: payload))
        try await eventually(timeout: 60) {
            guard let player = receiver.currentPlugin?.player else { return false }
            return player.rate > 0 && player.currentTime().seconds >= 37 && player.currentTime().seconds < 43
        }
        // Replace an active cast. All three commands arrive before the new stream has loaded.
        try await phone.send(CastTestPhone.command("Play", body: payload)
                             + CastTestPhone.command("Pause")
                             + CastTestPhone.command("Seek", body: #"{"seekTs":54}"#))
        try await eventually(timeout: 60) {
            guard let player = receiver.currentPlugin?.player else { return false }
            return player.currentItem?.status == .readyToPlay && abs(player.currentTime().seconds - 54) < 2
        }
        let player = try XCTUnwrap(receiver.currentPlugin?.player)
        XCTAssertEqual(player.rate, 0, "Pause received while loading must survive startup")
        try await phone.send(CastTestPhone.command("Resume"))
        try await eventually { player.currentTime().seconds > 56 }
        try await phone.send(CastTestPhone.command("SwitchDanmaku", body: #"{"open":"false"}"#))
        try await eventually { !Defaults.shared.showDanmu }
        try await phone.send(CastTestPhone.command("Seek", body: #"{"seekTs":70}"#))
        try await eventually { player.currentTime().seconds >= 70 }
        phone.close()
        try await eventually { receiver.connectedCount == 0 }
        let position = player.currentTime().seconds
        try await eventually { player.currentTime().seconds > position + 1 }
        try await reconnected.setup()
        try await eventually { receiver.connectedCount == 1 && reconnected.text.contains("OnProgress") }
        XCTAssertTrue(reconnected.text.contains("OnPlayState"))
        try await reconnected.send(CastTestPhone.command("Stop"))
        try await eventually { receiver.currentPlugin == nil && AppDelegate.shared.window?.rootViewController?.presentedViewController == nil }
    }

    @MainActor private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for casting state")
        throw NSError(domain: "CastingTest", code: 1)
    }

}

/// A phone-side NVA client over real TCP/UDP sockets, independent of the receiver's frame decoder.
@MainActor private final class CastTestPhone {
    private let connection: NWConnection
    private var received = Data()
    var text: String { String(decoding: received, as: UTF8.self) }
    init(port: UInt16 = 9958, udp: Bool = false) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: udp ? .udp : .tcp)
    }
    func connect() async throws {
        connection.start(queue: DispatchQueue(label: "casting.test.phone"))
        let deadline = Date().addingTimeInterval(5)
        while connection.state != .ready {
            guard Date() < deadline else { throw NSError(domain: "CastConnect", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        receive()
    }
    func setup() async throws {
        try await connect()
        try await send(Data("SETUP /projection HTTP/1.1\r\nHost: 127.0.0.1:9958\r\nSession: simulator-phone\r\nContent-Length: 0\r\n\r\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while !text.contains("200 OK") {
            guard Date() < deadline else { throw NSError(domain: "CastSetup", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.received.append(data) }
                if !ended && error == nil { self.receive() }
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func close() { connection.cancel() }
    static func command(_ action: String, body: String = "") -> Data {
        var data = Data([0xe0, 0x03, 0, 0, 0, 1, 1, 7])
        data.append(Data("Command".utf8))
        data.append(UInt8(action.utf8.count))
        data.append(Data(action.utf8))
        let length = UInt32(body.utf8.count)
        data.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(Data(body.utf8))
        return data
    }
}
