import XCTest
import AVKit
import Network
import Swifter
import CocoaAsyncSocket
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
        let previousBuffer = Settings.videoBufferDuration
        Settings.videoBufferDuration = .extended
        defer { Settings.videoBufferDuration = previousBuffer }
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
        try await eventually {
            guard let item = player.currentItem else { return false }
            return VideoBufferingController.bufferedSeconds(
                in: item.loadedTimeRanges.map(\.timeRangeValue), at: player.currentTime().seconds) > 20
        }
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration, 120)
        if let item = player.currentItem {
            print("Verified forward buffer: \(VideoBufferingController.bufferedSeconds(in: item.loadedTimeRanges.map(\.timeRangeValue), at: player.currentTime().seconds))s")
        }
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

    @MainActor func testBufferingRepeatedSeeksAndTeardown() async throws {
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/video")!)
        let controller = VideoBufferingController(item: item, target: 120, settlingDelay: 0.3)
        defer { controller.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: item)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 15, "An earlier seek must not restore a large buffer during another seek")
        controller.updateTarget(300)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 300)
        controller.prepareForSeek()
        controller.stop()
        item.preferredForwardBufferDuration = 30
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(item.preferredForwardBufferDuration, 30, "Teardown must cancel delayed buffer writes")
    }

    func testForwardBufferExcludesHolesAfterSeek() {
        func range(_ start: Double, _ duration: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 100),
                        duration: CMTime(seconds: duration, preferredTimescale: 100))
        }
        let ranges = [range(100, 30), range(0, 20), range(130, 10), range(150, 10)]
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: 110), 30, accuracy: 0.01)
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: 50), 0)
        XCTAssertEqual(VideoBufferingController.bufferedSeconds(in: ranges, at: .nan), 0)
    }

    @MainActor func testCastUDPPortConflictStillReceivesMulticastSearch() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(false)
        let blocker = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(blocker, 0)
        defer { Darwin.close(blocker); receiver.setEnabled(false); receiver.setEnabled(previous) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1900).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        receiver.setEnabled(true)
        XCTAssertTrue(receiver.isRunning, receiver.status)
        let message = receiver.discoveryMessage(type: "upnp:rootdevice", notify: false)
        let location = try XCTUnwrap(message.components(separatedBy: "\r\n").first { $0.hasPrefix("LOCATION: ") })
        let interface = try XCTUnwrap(URL(string: String(location.dropFirst(10)))?.host)
        let probe = CastMulticastProbe()
        defer { probe.close() }
        try probe.search(interface: interface)
        try await eventually { probe.text.contains("HTTP/1.1 200 OK") }
        XCTAssertTrue(probe.text.contains("LOCATION:"))
    }

    @MainActor func testCastPortConflictAndRapidRestart() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(false)
        let blocker = HttpServer()
        try blocker.start(9958, forceIPv4: true)
        defer { blocker.stop(); receiver.setEnabled(previous) }
        receiver.setEnabled(true)
        XCTAssertTrue(receiver.isRunning, receiver.status)
        XCTAssertNotEqual(receiver.httpPort, 9958)
        for _ in 0..<5 {
            receiver.setEnabled(false)
            receiver.setEnabled(true)
            XCTAssertTrue(receiver.isRunning, receiver.status)
            let port = receiver.httpPort
            XCTAssertTrue(receiver.discoveryMessage(type: "upnp:rootdevice", notify: false).contains(":\(port)/description.xml"))
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/description.xml")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(BiliBiliUpnpDMR.deviceName))
            let phone = CastTestPhone(port: port)
            try await phone.setup()
            try await eventually { receiver.connectedCount == 1 }
            phone.close()
            try await eventually { receiver.connectedCount == 0 }
        }
        receiver.setEnabled(false)
        blocker.stop()
    }

    @MainActor func testCastIdentityHandshakeAndReplyCorrelation() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer { receiver.setEnabled(previous) }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/description.xml")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.mimeType, "text/xml")
        let xml = String(decoding: data, as: UTF8.self)
        let deviceID = try XCTUnwrap(xml.range(of: #"(?<=<UDN>uuid:)XY[A-Z0-9]{35}(?=</UDN>)"#, options: .regularExpression).map { String(xml[$0]) })
        let discovery = receiver.discoveryMessage(type: "upnp:rootdevice", notify: false)
        XCTAssertTrue(discovery.contains("USN: uuid:\(deviceID)::upnp:rootdevice\r\n"))
        let (serviceData, serviceResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/dlna/NirvanaControl.xml")!)
        XCTAssertEqual((serviceResponse as? HTTPURLResponse)?.mimeType, "text/xml")
        let serviceXML = String(decoding: serviceData, as: UTF8.self)
        XCTAssertTrue(XMLParser(data: serviceData).parse())
        XCTAssertTrue(serviceXML.contains("<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"))
        XCTAssertTrue(serviceXML.contains("<specVersion>"))
        let phone = CastTestPhone(port: receiver.httpPort)
        defer { phone.close() }
        try await phone.setup()
        XCTAssertEqual(phone.handshakeHeaders["uuid"], deviceID)
        // Burst requests force the server reader to get ahead of the main-thread
        // handler. Each reply must still use its own request's sequence number.
        try await phone.send(CastTestPhone.command("GetVolume", sequence: 71)
                             + CastTestPhone.command("Pause", sequence: 96)
                             + CastTestPhone.command("GetVolume", sequence: 103))
        try await eventually { phone.replies[71] != nil && phone.replies[96] != nil && phone.replies[103] != nil }
        let volume = try JSONSerialization.jsonObject(with: XCTUnwrap(phone.replies[71])) as? [String: Int]
        XCTAssertEqual(volume?["volume"], 30)
        XCTAssertEqual(phone.replies[96], Data())
        try await eventually { phone.heartbeatCount > 0 }
        phone.close()
        try await eventually { receiver.connectedCount == 0 }
        let restored = CastTestPhone(port: receiver.httpPort)
        defer { restored.close() }
        try await restored.setup(method: "RESTORE")
        XCTAssertEqual(restored.handshakeHeaders["uuid"], deviceID)
        try await eventually { receiver.connectedCount == 1 && restored.text.contains("OnPlayState") }
    }

    @MainActor func testCastDiscoveryAndMalformedConnectionRecovery() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer { receiver.setEnabled(previous) }
        XCTAssertTrue(receiver.isRunning)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/description.xml")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(BiliBiliUpnpDMR.deviceName))
        let (_, debugResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.httpPort)/debug/log")!)
        XCTAssertEqual((debugResponse as? HTTPURLResponse)?.statusCode, 404)
        let discovery = CastTestPhone(port: 1900, udp: true)
        defer { discovery.close() }
        try await discovery.connect()
        try await discovery.send(Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nMX: 1\r\n\r\n".utf8))
        try await eventually { discovery.text.contains("HTTP/1.1 200 OK") }
        XCTAssertTrue(discovery.text.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
        let invalid = CastTestPhone(port: receiver.httpPort)
        try await invalid.setup()
        try await eventually { receiver.connectedCount == 1 }
        // A claimed 4 GB JSON body must close this connection without allocating it or crashing the app.
        var packet = CastTestPhone.command("Play", body: "")
        packet.replaceSubrange((packet.count - 4)..<packet.count, with: [255, 255, 255, 255])
        try await invalid.send(packet)
        try await eventually { receiver.connectedCount == 0 }
        invalid.close()
        let fresh = CastTestPhone(port: receiver.httpPort)
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
        let phone = CastTestPhone(port: receiver.httpPort)
        let reconnected = CastTestPhone(port: receiver.httpPort)
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
        try await phone.send(CastTestPhone.command("GetVolume", sequence: 51))
        try await eventually { phone.replies[51] != nil }
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
        try await reconnected.setup(method: "RESTORE")
        try await eventually { receiver.connectedCount == 1 && reconnected.text.contains("OnProgress") }
        XCTAssertTrue(reconnected.text.contains("OnPlayState"))
        try await reconnected.send(CastTestPhone.command("Stop"))
        try await eventually { receiver.currentPlugin == nil && AppDelegate.shared.window?.rootViewController?.presentedViewController == nil }
    }

    func testSOAPParsingAndValidation() throws {
        let body = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>
        <CurrentURI>https://example.com/video?a=1&amp;b=2</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite&gt;中文&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
        </u:SetAVTransportURI></s:Body></s:Envelope>
        """.utf8)
        let request = try LivingCastSOAP.Request(body: body, soapAction: "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        XCTAssertEqual(request.arguments["CurrentURI"], "https://example.com/video?a=1&b=2")
        XCTAssertEqual(request.arguments["CurrentURIMetaData"], "<DIDL-Lite>中文</DIDL-Lite>")
        XCTAssertThrowsError(try LivingCastSOAP.Request(body: body, soapAction: "urn:schemas-upnp-org:service:AVTransport:1#Play"))
        XCTAssertThrowsError(try LivingCastSOAP.Request(body: Data("<broken>".utf8), soapAction: nil))
        XCTAssertThrowsError(try LivingCastSOAP.Media(uri: "file:///private/test"))
        XCTAssertThrowsError(try LivingCastSOAP.Media(uri: "https://example.com/video?nva_ext=invalid"))
        XCTAssertEqual(LivingCastSOAP.seconds("01:02:03.5"), 3723.5)
        for invalid in ["-1:00:00", "00:60:00", "00:00:NaN", "00:00:inf", "37"] {
            XCTAssertNil(LivingCastSOAP.seconds(invalid))
        }
    }

    @MainActor func testSOAPRealPlaybackControlsAndMediaReplacement() async throws {
        let receiver = BiliBiliUpnpDMR.shared
        let previous = Settings.enableDLNA
        receiver.setEnabled(true)
        defer {
            receiver.currentPlugin?.player?.pause()
            AppDelegate.shared.window?.rootViewController?.dismiss(animated: false)
            receiver.setEnabled(previous)
        }
        let videos = try await WebRequest.requestHotVideo(page: 1).list
        let video = try XCTUnwrap(videos.first { $0.duration > 100 })
        let ext = "{\"content\":{\"aid\":\(video.aid),\"cid\":\(video.cid),\"seekTs\":37}}"
        var url = URLComponents(string: "https://example.com/cast")!
        url.queryItems = [URLQueryItem(name: "nva_ext", value: ext), URLQueryItem(name: "test", value: "1&2")]
        // Exercise both paths through actual HTTP, without an NVA session.
        let sources = [url.string!, "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"]
        for (index, source) in sources.enumerated() {
            _ = try await soap("SetAVTransportURI", ["CurrentURI": source, "CurrentURIMetaData": "<DIDL-Lite>测试</DIDL-Lite>"], port: receiver.httpPort)
            let stopped = try await soap("GetTransportInfo", port: receiver.httpPort)
            XCTAssertTrue(stopped.contains("<CurrentTransportState>STOPPED</CurrentTransportState>"))
            _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
            try await eventually(timeout: 60) {
                guard let player = receiver.currentPlugin?.player else { return false }
                return player.rate > 0 && player.currentTime().seconds > (index == 0 ? 38 : 1)
            }
            let player = try XCTUnwrap(receiver.currentPlugin?.player)
            let playing = try await soap("GetTransportInfo", port: receiver.httpPort)
            XCTAssertTrue(playing.contains("<CurrentTransportState>PLAYING</CurrentTransportState>"))
            let position = try await soap("GetPositionInfo", port: receiver.httpPort)
            XCTAssertFalse(position.contains("<TrackDuration>00:00:00</TrackDuration>"))
            _ = try await soap("Pause", port: receiver.httpPort)
            try await eventually { player.rate == 0 }
            _ = try await soap("Seek", ["Unit": "REL_TIME", "Target": "00:00:54"], port: receiver.httpPort)
            try await eventually { abs(player.currentTime().seconds - 54) < 2 }
            XCTAssertEqual(player.rate, 0)
            _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
            try await eventually { player.currentTime().seconds > 55 }
        }
        _ = try await soap("Stop", port: receiver.httpPort)
        try await eventually { receiver.currentPlugin == nil && AppDelegate.shared.window?.rootViewController?.presentedViewController == nil }
        _ = try await soap("Seek", ["Unit": "REL_TIME", "Target": "00:00:10"], port: receiver.httpPort, expectedStatus: 500)
        _ = try await soap("SetAVTransportURI", ["CurrentURI": "file:///invalid", "CurrentURIMetaData": ""], port: receiver.httpPort, expectedStatus: 500)
        // A fault must not poison the previously accepted media or the service.
        _ = try await soap("Play", ["Speed": "1"], port: receiver.httpPort)
        try await eventually(timeout: 60) { (receiver.currentPlugin?.player?.currentTime().seconds ?? 0) > 1 }
        _ = try await soap("Stop", port: receiver.httpPort)
    }

    private func soap(_ action: String, _ arguments: [String: String] = [:], port: UInt16, expectedStatus: Int = 200) async throws -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let service = "urn:schemas-upnp-org:service:AVTransport:1"
        let values = arguments.sorted { $0.key < $1.key }.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action) xmlns:u=\"\(service)\"><InstanceID>0</InstanceID>\(values)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/AVTransport/action")!)
        request.httpMethod = "POST"
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
        XCTAssertTrue(XMLParser(data: data).parse(), "SOAP response must be valid XML")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(expectedStatus == 200 ? "\(action)Response" : "UPnPError"))
        return text
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
    private let port: UInt16
    private var received = Data()
    private var wire = Data()
    private(set) var handshakeHeaders: [String: String] = [:]
    private(set) var replies: [UInt32: Data] = [:]
    private(set) var heartbeatCount = 0
    private var protocolError: Error?
    private var expectsNVA = false
    var text: String { String(decoding: received, as: UTF8.self) }
    init(port: UInt16 = 9958, udp: Bool = false) {
        self.port = port
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
    func setup(method: String = "SETUP") async throws {
        expectsNVA = true
        try await connect()
        try await send(Data("\(method) /projection NVA/1.0\r\nHost: 127.0.0.1:\(port)\r\nSession: simulator-phone\r\nNvaVersion: 1\r\nConnection: Keep-Alive\r\nContent-Length: 0\r\n\r\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while handshakeHeaders.isEmpty {
            if let protocolError { throw protocolError }
            guard Date() < deadline else { throw NSError(domain: "CastSetup", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func parseWire() throws {
        guard expectsNVA else { return }
        if handshakeHeaders.isEmpty {
            guard let end = wire.range(of: Data("\r\n\r\n".utf8)) else { return }
            let lines = String(decoding: wire[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard lines.first == "NVA/1.0 200 OK" else { throw NSError(domain: "NVAStatusLine", code: 1) }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard headers["session"] == "simulator-phone", headers["nvaversion"] == "1",
                  headers["content-length"] == "0", headers["connection"]?.lowercased() == "keep-alive" else {
                throw NSError(domain: "NVAHeaders", code: 1)
            }
            handshakeHeaders = headers
            wire = Data(wire[end.upperBound...])
        }
        while wire.count >= 6 {
            let bytes = [UInt8](wire)
            let kind = bytes[0], count = bytes[1]
            let sequence = bytes[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var offset = 6
            if kind == 0xe0 {
                guard count == 2 || count == 3 else { throw NSError(domain: "NVAFrame", code: 1) }
                guard bytes.count >= 8 else { return }
                guard bytes[6] == 1 else { throw NSError(domain: "NVAFrame", code: 2) }
                offset = 8 + Int(bytes[7])
                guard bytes.count > offset else { return }
                offset += 1 + Int(bytes[offset])
                guard bytes.count >= offset else { return }
            } else if !((kind == 0xc0 && count <= 1) || (kind == 0xe4 && count == 0)) {
                throw NSError(domain: "NVAFrame", code: 3)
            }
            var body = Data()
            if (kind == 0xc0 && count == 1) || (kind == 0xe0 && count == 3) {
                guard bytes.count >= offset + 4 else { return }
                let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                guard length <= 1_048_576 else { throw NSError(domain: "NVAFrame", code: 4) }
                guard bytes.count >= offset + length else { return }
                body = Data(bytes[offset..<offset + length])
                offset += length
            }
            wire = Data(bytes.dropFirst(offset))
            if kind == 0xc0 { replies[sequence] = body }
            if kind == 0xe4 {
                heartbeatCount += 1
                var reply = Data([0xc0, 0])
                reply.append(contentsOf: bytes[2..<6])
                Task { try? await self.send(reply) }
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.received.append(data)
                    self.wire.append(data)
                    do { try self.parseWire() } catch { self.protocolError = error }
                }
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
    static func command(_ action: String, body: String = "", sequence: UInt32 = 1) -> Data {
        var data = Data([0xe0, 0x03])
        data.append(contentsOf: [UInt8((sequence >> 24) & 255), UInt8((sequence >> 16) & 255), UInt8((sequence >> 8) & 255), UInt8(sequence & 255), 1, 7])
        data.append(Data("Command".utf8))
        data.append(UInt8(action.utf8.count))
        data.append(Data(action.utf8))
        let length = UInt32(body.utf8.count)
        data.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(Data(body.utf8))
        return data
    }
}

/// Uses real LAN multicast, including an unconnected socket for the unicast reply.
private final class CastMulticastProbe: NSObject, GCDAsyncUdpSocketDelegate {
    private lazy var udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: .main)
    private(set) var text = ""

    func search(interface: String) throws {
        udp.setIPv6Enabled(false)
        try udp.bind(toPort: 0)
        var failure: NSError?
        udp.perform {
            var address = in_addr()
            inet_pton(AF_INET, interface, &address)
            if setsockopt(self.udp.socket4FD(), IPPROTO_IP, IP_MULTICAST_IF,
                          &address, socklen_t(MemoryLayout<in_addr>.size)) != 0 {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        if let failure { throw failure }
        try udp.beginReceiving()
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: upnp:rootdevice\r\nMX: 1\r\n\r\n"
        udp.send(Data(request.utf8), toHost: "239.255.255.250", port: 1900, withTimeout: 2, tag: 0)
    }

    func close() { udp.close() }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        text += String(decoding: data, as: UTF8.self)
    }
}
