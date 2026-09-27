import XCTest
import AVKit
import Network
import Swifter
import CocoaAsyncSocket
@testable import BilibiliLive

final class BiliLivingTests: XCTestCase {
    func testPlaybackDiagnosticsRedactsSignedURLsAndPreservesErrorChain() {
        let url = "https://user:password@cdn.example/video.m4s?token=secret&deadline=123#fragment"
        XCTAssertEqual(PlaybackDiagnostics.resource(url), "https://cdn.example/video.m4s")
        let underlying = NSError(domain: NSURLErrorDomain, code: -1001,
                                 userInfo: [NSLocalizedDescriptionKey: "timeout \(url)"])
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        let logged = PlaybackDiagnostics.error(error)
        XCTAssertTrue(logged.contains("-11800"))
        XCTAssertTrue(logged.contains("-1001"))
        XCTAssertTrue(logged.contains("cdn.example/video.m4s"))
        XCTAssertFalse(logged.contains("secret"))
        XCTAssertFalse(logged.contains("password"))
        XCTAssertFalse(logged.contains("deadline"))
    }

    func testCDNProbeRejectsHTTPErrorAndInvalidRanges() {
        XCTAssertNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 0-262143/1000000", receivedBytes: 262144, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 403, contentRange: nil, receivedBytes: 100, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 200, contentRange: nil, receivedBytes: 262144, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 100-199/1000", receivedBytes: 100, requestedBytes: 262144))
        XCTAssertNotNil(CDNDiagnostics.probeResponseFailure(status: 206, contentRange: "bytes 0-262143/1000000", receivedBytes: 100, requestedBytes: 262144))
        let result = CDNDiagnostics.ProbeResult(url: "https://cdn.example/video", bytes: 262144,
                                               transferTime: 0.02, setupTime: 1, error: nil, totalTime: 1.02)
        XCTAssertEqual(result.mbps ?? 0, 104.8576, accuracy: 0.001)
        XCTAssertEqual(result.endToEndMbps ?? 0, 2.056, accuracy: 0.001)
    }

    func testDefaultNavigationAndQualityPolicy() {
        XCTAssertEqual(TabBarPage.defaultTabBarPages, [.feed, .search, .personal])
        XCTAssertEqual(MediaQualityEnum.quality_1080p.qn, 80)
        XCTAssertEqual(Settings.defaultPlacements.filter { $0.section == .tabBar }.map(\.page), [.feed, .search, .personal])
    }

    func testDefaultQualityPersistsExistingChoice() throws {
        let key = "Settings.mediaQuality"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.mediaQuality, .bestAvailable)
        for quality in MediaQualityEnum.allCases {
            Settings.mediaQuality = quality
            XCTAssertEqual(Settings.mediaQuality, quality)
        }
        // Existing enum encodings must still decode after adding the new case.
        let saved = Data(#"{"quality_2160p":{}}"#.utf8)
        UserDefaults.standard.set(saved, forKey: key)
        XCTAssertEqual(Settings.mediaQuality, .quality_2160p)
    }

    func testQualitySelectionHonors4KAndBestAvailable() throws {
        func stream(_ quality: Int, _ codec: String, _ bandwidth: Int) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
            .init(id: quality, base_url: "https://example.invalid/video.m4s", backup_url: nil,
                  bandwidth: bandwidth, mime_type: "video/mp4", codecs: codec,
                  width: 3840, height: 2160, frame_rate: "30", sar: nil, start_with_sap: nil,
                  segment_base: .init(initialization: "0-100", index_range: "101-200"), codecid: nil)
        }
        let streams = [stream(64, "avc1.640028", 1000), stream(80, "avc1.640028", 2000),
                       stream(120, "hvc1.1.6.L153.B0", 4000), stream(120, "avc1.640034", 6000),
                       stream(126, "dvh1.08.06", 5000), stream(127, "av01.0.16M.10", 7000)]
        let fourK = PlayerMediaPreferences(quality: .quality_2160p, preferAVC: true, losslessAudio: false)
        let best = PlayerMediaPreferences(quality: .bestAvailable, preferAVC: true, losslessAudio: false)
        XCTAssertEqual(fourK.selectVideos(from: streams).map(\.id), [120], "4K must not include lower ABR variants")
        XCTAssertEqual(fourK.selectVideos(from: streams).first?.codecs, "avc1.640034")
        XCTAssertEqual(best.selectVideos(from: streams).map(\.id), [126], "Skip unsupported AV1, retain highest playable quality")
        XCTAssertEqual(fourK.selectVideos(from: Array(streams.prefix(2))).map(\.id), [80], "Fall back when source/account lacks 4K")
        XCTAssertEqual(best.selectVideos(from: Array(streams.prefix(1))).map(\.id), [64])
        XCTAssertEqual(best.selectVideos(from: streams, streamIndex: 1).map(\.id), [80], "Explicit quality still overrides the default")
        XCTAssertTrue(best.selectVideos(from: streams, streamIndex: -1).isEmpty)
        XCTAssertTrue(best.selectVideos(from: streams, streamIndex: 5).isEmpty)
        XCTAssertNotEqual(PlayerMediaWarmupManager.CacheKey(sequenceKey: "same-video", preferences: fourK),
                          PlayerMediaWarmupManager.CacheKey(sequenceKey: "same-video", preferences: best),
                          "Changing defaults must not reuse a warmed asset at the old quality")
    }

    @MainActor func testFollowUsesVerifiedStateAndPreservesStateOnFailure() async throws {
        enum Failure: Error { case rejected }
        var writes = [Bool]()
        var reject = true
        let model = UploaderFollowModel(isFollowing: false, read: { true }, write: { following in
            writes.append(following)
            if reject { throw Failure.rejected }
        })
        do { try await model.toggle(); XCTFail("Request should fail") } catch {}
        XCTAssertEqual(writes, [false], "Verify an existing follow before sending an unfollow")
        XCTAssertTrue(model.isFollowing, "Failure must not show a false success")
        XCTAssertFalse(model.isBusy)
        reject = false
        try await model.toggle()
        XCTAssertFalse(model.isFollowing)
        try await model.toggle()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(writes, [false, false, true])
        XCTAssertEqual(model.title, "已关注")
    }

    @MainActor func testFollowPreventsDuplicateRequests() async throws {
        var writes = 0
        var finish: CheckedContinuation<Void, Never>?
        let model = UploaderFollowModel(isFollowing: false, read: { false }, write: { _ in
            writes += 1
            await withCheckedContinuation { finish = $0 }
        })
        let first = Task { try await model.toggle() }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isFollowing)
        try await model.toggle()
        XCTAssertEqual(writes, 1)
        finish?.resume()
        try await first.value
        XCTAssertTrue(model.isFollowing)
        XCTAssertFalse(model.isBusy)
        for attribute in [0, 128] { XCTAssertFalse(WebRequest.UpSpaceRelation(attribute: attribute).isFollowing) }
        for attribute in [1, 2, 6] { XCTAssertTrue(WebRequest.UpSpaceRelation(attribute: attribute).isFollowing) }
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
        XCTAssertTrue(menu.children.contains { $0.title == "默认 · \(Settings.mediaQuality.desp)" })
        let videoDetail = try await WebRequest.requestDetailVideo(aid: video.aid)
        let infoTabs = VideoPlayerInfoTabsPlugin(detail: videoDetail,
                                                currentPlayInfo: PlayInfo(aid: video.aid, cid: video.cid),
                                                sequenceProvider: nil)
        let followAction = try XCTUnwrap(infoTabs.addMenuItems(current: &current).first as? UIAction)
        XCTAssertEqual(followAction.identifier.rawValue, "follow-uploader")
        XCTAssertFalse(followAction.title.isEmpty)
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
        // Other renderers (including the user's Apple TV) may answer first.
        // Wait for this receiver's advertised URL, not any device's response.
        try await eventually { probe.text.contains("HTTP/1.1 200 OK") && probe.text.contains(location) }
        XCTAssertTrue(probe.text.contains(location))
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

    func testCastVideoHintUsesTrustedCDNAndXMLTitle() throws {
        let uri = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/70/08/38601820870/38601820870-1-192.mp4?ignored=1"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>标题 &amp; 分P</dc:title></item></DIDL-Lite>"
        let hint = try XCTUnwrap(LivingCastVideoHint(url: URL(string: uri)!, metadata: metadata))
        XCTAssertEqual(hint.cid, 38601820870)
        XCTAssertEqual(hint.title, "标题 & 分P")
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri.replacingOccurrences(of: "upos-hz-mirrorakam.akamaized.net", with: "unrelated.example"))!, metadata: metadata))
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri.replacingOccurrences(of: "38601820870-1", with: "123-1"))!, metadata: metadata))
        XCTAssertNil(LivingCastVideoHint(url: URL(string: uri)!, metadata: "<broken>")?.title)
    }

    @MainActor func testCastCapturedVideoResolvesByExactCID() async throws {
        // Only public title/CID from the real DLNA report; no signed URL or phone credentials.
        let uri = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/70/08/38601820870/38601820870-1-192.mp4"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>老戴《007 初露锋芒》最高难度剧情流程攻略解说</dc:title></item></DIDL-Lite>"
        let hint = try XCTUnwrap(LivingCastVideoHint(url: URL(string: uri)!, metadata: metadata))
        let resolved = await LivingCastVideoResolver.resolve(hint)
        let info = try XCTUnwrap(resolved, "The user's actual cast must resolve within the startup deadline")
        let detail = try await WebRequest.requestDetailVideo(aid: info.aid)
        XCTAssertEqual(info.cid, hint.cid)
        XCTAssertNotNil(LivingCastVideoResolver.matchingPage(in: detail.View, cid: hint.cid))
        XCTAssertNil(LivingCastVideoResolver.matchingPage(in: detail.View, cid: 1), "Never select a same-title video with a different CID")
        let playerVC = VideoPlayerViewController(playInfo: info, startTimeOverride: 0)
        let root = try XCTUnwrap(AppDelegate.shared.window?.rootViewController)
        root.present(playerVC, animated: false)
        defer { playerVC.stopPlayback(); playerVC.dismiss(animated: false) }
        try await eventually(timeout: 60) {
            let player = (playerVC.children.first as? AVPlayerViewController)?.player
            return (player?.currentTime().seconds ?? 0) > 1
        }
        let av = try XCTUnwrap(playerVC.children.first as? AVPlayerViewController)
        func titles(_ items: [UIMenuElement]) -> [String] { items.flatMap { [$0.title] + (($0 as? UIMenu).map { titles($0.children) } ?? []) } }
        let menuTitles = titles(av.transportBarCustomMenuItems)
        XCTAssertTrue(menuTitles.contains(where: { $0.contains("清晰度") }))
        XCTAssertTrue(menuTitles.contains("Show Danmu"))
        playerVC.stopPlayback()
        await withCheckedContinuation { continuation in
            playerVC.dismiss(animated: false) { continuation.resume() }
        }
    }

    @MainActor func testDirectCastStreamRendersRealDanmaku() async throws {
        let previousShow = Defaults.shared.showDanmu
        let previousAI = Settings.danmuAILevel
        let previousFilter = Settings.enableDanmuFilter
        Defaults.shared.showDanmu = true
        Settings.danmuAILevel = 1
        Settings.enableDanmuFilter = false
        let cid = 38601820870
        let list = try await WebRequest.requestDanmuList(cid: cid, segmentIdx: 1)
        let comment = try XCTUnwrap(list.elems.first { $0.mode == 1 && $0.progress > 3000 && $0.progress < 100000 })
        // Isolate overlay wiring with a stable playable HLS fixture and actual
        // Bilibili comments; title/CID identity is covered by the resolver test.
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!
        let vc = LivingURLCastViewController(url: url, context: LivingCastContext(), danmakuCID: cid)
        let root = try XCTUnwrap(AppDelegate.shared.window?.rootViewController)
        root.present(vc, animated: false)
        defer {
            vc.stopPlayback(); vc.dismiss(animated: false)
            Defaults.shared.showDanmu = previousShow
            Settings.danmuAILevel = previousAI
            Settings.enableDanmuFilter = previousFilter
        }
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        try await eventually(timeout: 30) {
            descendants(vc.view).contains { $0 is DanmakuView } &&
            ((vc.children.first as? AVPlayerViewController)?.player?.currentTime().seconds ?? 0) > 1
        }
        let av = try XCTUnwrap(vc.children.first as? AVPlayerViewController)
        let player = try XCTUnwrap(av.player)
        await player.seek(to: CMTime(seconds: max(0, Double(comment.progress) / 1000 - 2), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually(timeout: 15) { descendants(vc.view).contains { $0 is DanmakuCell } }
        func titles(_ items: [UIMenuElement]) -> [String] { items.flatMap { [$0.title] + (($0 as? UIMenu).map { titles($0.children) } ?? []) } }
        XCTAssertTrue(titles(av.transportBarCustomMenuItems).contains("Show Danmu"))
        vc.stopPlayback()
        await withCheckedContinuation { continuation in
            vc.dismiss(animated: false) { continuation.resume() }
        }
    }

    @MainActor func testHomeAccountSwitchDiscardsOldRecommendations() async throws {
        var account: Int? = 1
        var oldResponse: CheckedContinuation<LivingHomePage, Error>?
        let old = LivingHomeVideo(aid: 1, cid: 1, title: "old", ownerName: "", pic: nil)
        let new = LivingHomeVideo(aid: 2, cid: 2, title: "new", ownerName: "", pic: nil)
        let model = LivingHomeModel(currentAccount: { account }) { mid, _, _ in
            if mid == 1 { return try await withCheckedThrowingContinuation { oldResponse = $0 } }
            return LivingHomePage(videos: [new], nextCursor: 10, hasMore: true)
        }
        let oldLoad = Task { await model.load() }
        try await eventually { oldResponse != nil }
        account = 2
        await model.load()
        oldResponse?.resume(returning: LivingHomePage(videos: [old], nextCursor: 99, hasMore: true))
        await oldLoad.value
        XCTAssertEqual(model.videos, [new])
        XCTAssertEqual(model.accountMID, 2)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.isPersonalized)
    }

    @MainActor func testHomePaginationDeduplicationAndRetry() async throws {
        let a = LivingHomeVideo(aid: 1, cid: 1, title: "A", ownerName: "", pic: nil)
        let b = LivingHomeVideo(aid: 2, cid: 2, title: "B", ownerName: "", pic: nil)
        var calls: [(Int, Int)] = []
        var fail = false
        let model = LivingHomeModel(currentAccount: { 42 }) { mid, cursor, page in
            XCTAssertEqual(mid, 42)
            calls.append((cursor, page))
            if fail { throw NSError(domain: "HomeTest", code: 1) }
            return cursor == 0 ? LivingHomePage(videos: [a, a], nextCursor: 10, hasMore: true)
                : LivingHomePage(videos: [a, b], nextCursor: 20, hasMore: true)
        }
        await model.load()
        XCTAssertEqual(model.videos, [a])
        fail = true
        await model.loadMore()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.videos, [a])
        fail = false
        await model.retry()
        XCTAssertEqual(model.videos, [a, b])
        XCTAssertEqual(calls.map { $0.0 }, [0, 10, 10])
        XCTAssertEqual(calls.map { $0.1 }, [1, 2, 2])
        await model.loadMore()
        XCTAssertFalse(model.hasMore, "Duplicate-only pages must not trigger endless automatic requests")
        fail = true
        await model.load()
        XCTAssertNotNil(model.error)
        fail = false
        await model.retry()
        XCTAssertEqual(model.videos, [a], "Retry of a failed refresh replaces the old batch")
    }

    @MainActor func testHomeLogoutClearsAccountContentOnFailure() async {
        var account: Int? = 42
        var requested: [Int?] = []
        let video = LivingHomeVideo(aid: 1, cid: 1, title: "account", ownerName: "", pic: nil)
        let model = LivingHomeModel(currentAccount: { account }) { mid, _, _ in
            requested.append(mid)
            if mid == nil { throw NSError(domain: "HomeTest", code: 1) }
            return LivingHomePage(videos: [video], nextCursor: 1, hasMore: true)
        }
        await model.load()
        account = nil
        await model.load()
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertFalse(model.isPersonalized)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(requested.count, 2)
        XCTAssertNil(requested.last!)
    }

    @MainActor func testLiveHomeRecommendationSource() async throws {
        // Exercises the real signed app feed, without inventing an account token.
        let items = try await ApiRequest.getFeeds()
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.goto == "av" && !$0.title.isEmpty })
        let guest = try await LivingHomeSource.fetch(accountMID: nil, cursor: 0, page: 1)
        XCTAssertFalse(guest.videos.isEmpty)
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

final class EpisodeSelectionTests: XCTestCase {
    private func partList(count: Int = 45) -> VideoEpisodeList {
        VideoEpisodeList(sections: [.init(id: "parts-1", title: "视频分 P", kind: .parts, items: (1...count).map {
            PlayInfo(aid: 1, cid: $0, title: "教程第 \($0) 集")
        })])
    }

    func testRangesDeduplicateByEpisodeNotDisplayMetadata() throws {
        let items = partList().sections[0].items
        var duplicate = items[0]
        duplicate.title = "Changed title"
        let list = VideoEpisodeList(sections: [.init(id: "parts-1", title: "Parts", kind: .parts,
                                                      items: items + [duplicate, PlayInfo(aid: 0, cid: 0)])])
        XCTAssertEqual(list.sections[0].items.count, 45)
        XCTAssertEqual(list.pages.map(\.range), [0..<20, 20..<40, 40..<45])
        XCTAssertTrue(list.hasChoices)
        XCTAssertFalse(partList(count: 1).hasChoices)
        XCTAssertNil(list.item(for: .init(sectionID: "parts-1", index: -1)))
        XCTAssertNil(list.item(for: .init(sectionID: "parts-1", index: 45)))
        XCTAssertNil(list.item(for: .init(sectionID: "missing", index: 0)))
        XCTAssertEqual(list.section(for: duplicate)?.index(of: duplicate), 0)
        XCTAssertEqual(try XCTUnwrap(list.item(for: .init(sectionID: "parts-1", index: 41))).cid, 42)
    }

    func testCollectionOrderGroupsAndExplicitPartChoice() throws {
        let cover = try XCTUnwrap(URL(string: "https://example.invalid/cover.jpg"))
        let first = VideoDetail.Info.UgcSeason.UgcVideoInfo(id: 1, aid: 200, cid: 201,
                                                           arc: .init(pic: cover, ctime: 30), title: "First")
        let second = VideoDetail.Info.UgcSeason.UgcVideoInfo(id: 2, aid: 100, cid: 101,
                                                            arc: .init(pic: cover, ctime: 10), title: "Second")
        let extra = VideoDetail.Info.UgcSeason.UgcVideoInfo(id: 3, aid: 300, cid: 301,
                                                           arc: .init(pic: cover, ctime: 20), title: "Extra")
        let season = VideoDetail.Info.UgcSeason(id: 7, title: "合集", cover: cover, mid: 1, intro: "", attribute: 0,
                                                sections: [.init(season_id: 7, id: 70, title: "正篇", episodes: [first, second]),
                                                           .init(season_id: 7, id: 71, title: "番外", episodes: [extra])])
        let pages = (1...3).map { VideoPage(cid: 100 + $0, page: $0, epid: nil, from: "vupload", part: "P\($0)") }
        let detail = VideoDetail(View: .init(aid: 100, cid: 101, title: "Video", videos: 3, pic: cover, desc: "",
                                             owner: .init(mid: 1, name: "Creator"), pages: pages, dynamic: nil,
                                             bvid: nil, duration: 100, pubdate: nil, ugc_season: season,
                                             redirect_url: nil, stat: .init(favorite: 0, coin: 0, like: 0, share: 0, danmaku: 0, view: 0)),
                                 Related: [], Card: .init(following: false, follower: nil))
        let list = VideoEpisodeList.video(detail)
        XCTAssertEqual(list.sections.map(\.id), ["parts-100", "ugc-7-70", "ugc-7-71"])
        XCTAssertEqual(list.sections[1].items.map(\.aid), [200, 100], "Keep author order, not publication time")
        let current = PlayInfo(aid: 100, cid: 102)
        XCTAssertEqual(list.section(for: current)?.id, "ugc-7-70", "A collection recognizes every part of its current video")
        var navigation = VideoEpisodeNavigation(current: current, followsSeriesAutomatically: true)
        navigation.update(list: list, current: current, selectedSectionID: "parts-100")
        XCTAssertEqual(navigation.next?.cid, 103)
        navigation.update(list: list, current: PlayInfo(aid: second.aid, cid: second.cid), selectedSectionID: "ugc-7-70")
        XCTAssertNil(navigation.next, "Do not automatically cross from the main group into extras")
        XCTAssertEqual(navigation.first?.aid, 200)
        navigation.update(list: VideoEpisodeList(), current: PlayInfo(aid: second.aid, cid: second.cid))
        XCTAssertEqual(navigation.list.sections.map(\.id), ["ugc-7-70", "ugc-7-71"])
    }

    func testDirectBangumiRedirectRecognizesEpisodeButNotSeasonURLs() throws {
        func detail(path: String) throws -> VideoDetail {
            try JSONDecoder().decode(VideoDetail.self, from: Data("""
            {
              "View": {
                "aid": 42, "cid": 84, "title": "Episode", "owner": {"mid": 1, "name": "Creator"},
                "duration": 100, "redirect_url": "https://www.bilibili.com/bangumi/play/\(path)",
                "stat": {"favorite": 0, "coin": 0, "like": 0, "share": 0, "danmaku": 0, "view": 0}
              },
              "Related": [], "Card": {"following": false}
            }
            """.utf8))
        }
        XCTAssertEqual(PlayInfoResolver.bangumiEpisodeID(in: try detail(path: "ep83")), 83)
        for path in ["ss8", "ep0", "ep-1", "epinvalid"] {
            XCTAssertNil(PlayInfoResolver.bangumiEpisodeID(in: try detail(path: path)))
        }
        XCTAssertNil(PlayInfoResolver.bangumiEpisodeID(in: nil))
    }

    private func bangumi() throws -> BangumiInfo {
        try JSONDecoder().decode(BangumiInfo.self, from: Data(#"""
        {
          "type": 1, "season_id": 8,
          "episodes": [
            {"id": 81, "aid": 801, "cid": 8001, "cover": "https://example.invalid/1.jpg", "title": "1", "long_title": "正片一"},
            {"id": 82, "aid": 802, "cid": 8002, "cover": "https://example.invalid/2.jpg", "title": "2"}
          ],
          "section": [
            {"id": 9, "title": "特别篇", "episodes": [
              {"id": 83, "aid": 803, "cid": 8003, "cover": "https://example.invalid/3.jpg", "title": "SP", "long_title": "特别篇"}
            ]}
          ],
          "user_status": {"progress": {"last_time": 25, "last_ep_id": 82, "last_ep_index": "2"}}
        }
        """#.utf8))
    }

    func testBangumiFindsExtrasAndNeverFallsBackFromMissingEpisode() throws {
        let info = try bangumi()
        let list = VideoEpisodeList.bangumi(info)
        XCTAssertEqual(list.sections.map(\.title), ["正片", "特别篇"])
        XCTAssertEqual(list.sections[0].items.map(\.aid), [801, 802])
        let extra = try PlayInfoResolver.resolveBangumi(PlayInfo(aid: 0, epid: 83), using: info)
        XCTAssertEqual(extra.aid, 803)
        XCTAssertEqual(extra.cid, 8003)
        XCTAssertEqual(extra.epid, 83)
        XCTAssertEqual(extra.title, "SP 特别篇")
        XCTAssertThrowsError(try PlayInfoResolver.resolveBangumi(PlayInfo(aid: 0, epid: 999), using: info))
        let resumed = try PlayInfoResolver.resolveBangumi(PlayInfo(aid: 0, seasonId: 8), using: info)
        XCTAssertEqual(resumed.epid, 82)
        XCTAssertEqual(list.section(for: extra)?.id, "pgc-8-extra-9")
    }

    func testKnownBangumiListResolvesExactIDsWithoutAnotherRequest() async throws {
        let list = VideoEpisodeList.bangumi(try bangumi())
        let result = try await PlayInfoResolver.resolveWithEpisodes(
            PlayInfo(aid: 1, cid: 2, epid: 83, lastPlayCid: 8003, playTimeInSecond: 25), knownEpisodes: list)
        XCTAssertEqual(result.playInfo.aid, 803)
        XCTAssertEqual(result.playInfo.cid, 8003)
        XCTAssertEqual(result.playInfo.seasonId, 8)
        XCTAssertEqual(result.playInfo.playTimeInSecond, 25)
        XCTAssertEqual(result.episodes?.sections.count, 2)
    }

    @MainActor func testSelectionAdvancesSeriesWithoutReplacingFeedQueue() throws {
        let list = partList()
        let current = list.sections[0].items[0]
        let unrelated = PlayInfo(aid: 2, cid: 100)
        let feed = VideoSequenceProvider(seq: [current, unrelated])
        var navigation = VideoEpisodeNavigation(current: current, followsSeriesAutomatically: false)
        navigation.update(list: list, current: current)
        XCTAssertFalse(navigation.isFollowingSeries)
        let selected = try XCTUnwrap(list.item(for: .init(sectionID: "parts-1", index: 11)))
        navigation.update(list: list, current: selected, selectedSectionID: "parts-1")
        XCTAssertEqual(navigation.next?.cid, 13, "Selecting episode 12 must continue with episode 13")
        XCTAssertEqual(feed.currentIndex, 0)
        XCTAssertEqual(feed.peekNext(), unrelated)
        navigation.update(list: VideoEpisodeList(), current: selected)
        XCTAssertEqual(navigation.next?.cid, 13, "A missing metadata response must not discard the active series")
        navigation.update(list: list, current: list.sections[0].items[44])
        XCTAssertNil(navigation.next)
        XCTAssertEqual(navigation.first?.cid, 1, "Looping restarts at episode 1, not episode 2")
        navigation.leaveSeries()
        navigation.update(list: list, current: unrelated)
        XCTAssertFalse(navigation.isFollowingSeries)
        XCTAssertEqual(feed.playSeq, [current, unrelated])
    }

    @MainActor func testNativeMenuVisibilityAndNextEpisodeLabel() throws {
        let list = partList()
        let currentInfo = list.sections[0].items[0]
        let plugin = VideoPlayListPlugin(episodes: list, currentPlayInfo: currentInfo)
        let av = AVPlayerViewController()
        av.infoViewActions = [UIAction(title: "Keep", identifier: .init("unrelated")) { _ in }]
        plugin.playerDidLoad(playerVC: av)
        plugin.navigation = { (list.sections[0].items[1], true) }
        plugin.playerWillStart(player: AVPlayer())
        XCTAssertEqual(av.infoViewActions.map(\.title), ["Keep", "下一集"])
        var menus: [UIMenuElement] = [UIMenu(title: "Settings", identifier: .init("setting"), children: [])]
        let actions = plugin.addMenuItems(current: &menus)
        XCTAssertEqual(actions.map(\.title), ["选集"], "The episode button must be a top-level transport action")
        XCTAssertEqual((actions.first as? UIAction)?.identifier.rawValue, "video.episodes")
        XCTAssertTrue((menus.first as? UIMenu)?.children.contains { $0.title == "循环播放" } == true)
        plugin.navigation = { (nil, true) }
        plugin.playerWillStart(player: AVPlayer())
        XCTAssertEqual(av.infoViewActions.map(\.title), ["Keep"])
        let single = VideoPlayListPlugin(episodes: partList(count: 1), currentPlayInfo: currentInfo)
        XCTAssertFalse(single.addMenuItems(current: &menus).contains { $0.title == "选集" })
        let failed = VideoPlayListPlugin(episodes: VideoEpisodeList(), currentPlayInfo: currentInfo, episodeLoadFailed: true)
        XCTAssertTrue(failed.addMenuItems(current: &menus).contains { $0.title == "选集" }, "Failed metadata must remain retryable")
        plugin.playerWillCleanUp(playerVC: av)
        XCTAssertEqual(av.infoViewActions.map(\.title), ["Keep"])
    }

    @MainActor func testPickerFocusRangesConfirmationAndCleanup() async throws {
        let list = partList()
        let container = CommonPlayerViewController()
        let window = try XCTUnwrap(AppDelegate.shared.window)
        let original = window.rootViewController
        window.rootViewController = container
        container.loadViewIfNeeded()
        let av = try XCTUnwrap(container.children.first as? AVPlayerViewController)
        let player = AVPlayer()
        av.player = player
        let plugin = VideoPlayListPlugin(episodes: list, currentPlayInfo: list.sections[0].items[26])
        var selections = [VideoEpisodeList.Selection]()
        plugin.onSelectEpisode = { selections.append($0) }
        container.addPlugin(plugin: plugin)
        defer { container.stopPlayback(); window.rootViewController = original }
        plugin.showEpisodes()
        let picker = try XCTUnwrap(container.presentedViewController as? VideoEpisodePickerViewController)
        XCTAssertTrue(container.suspendsAutomaticPlayback)
        let episodes = try collection(in: picker, identifier: "episode-list")
        let ranges = try collection(in: picker, identifier: "episode-ranges")
        try await eventually {
            !picker.isBeingPresented && episodes.cellForItem(at: IndexPath(item: 6, section: 0))?.isFocused == true
        }
        XCTAssertEqual(picker.selectedPageIndex, 1)
        XCTAssertEqual(episodes.numberOfItems(inSection: 0), 20)
        let currentCell = try XCTUnwrap(episodes.cellForItem(at: IndexPath(item: 6, section: 0)))
        XCTAssertTrue(currentCell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(currentCell.accessibilityLabel?.contains("正在播放") == true)
        let otherCell = try XCTUnwrap(episodes.cellForItem(at: IndexPath(item: 7, section: 0)))
        picker.focusEpisode(at: IndexPath(item: 7, section: 0))
        try await eventually { otherCell.isFocused }
        XCTAssertTrue(selections.isEmpty, "Moving focus must not switch episodes")
        // Capture the settled focus colors, not the crossfade between two rows.
        try await Task.sleep(nanoseconds: 500_000_000)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Episode picker with current episode and ranges"
        attachment.lifetime = .keepAlways
        add(attachment)
        picker.collectionView(ranges, didSelectItemAt: IndexPath(item: 2, section: 0))
        XCTAssertEqual(episodes.numberOfItems(inSection: 0), 5)
        try await eventually { episodes.cellForItem(at: IndexPath(item: 0, section: 0))?.isFocused == true }
        XCTAssertTrue(selections.isEmpty)
        picker.collectionView(episodes, didSelectItemAt: IndexPath(item: 2, section: 0))
        try await eventually { selections.count == 1 && container.presentedViewController == nil }
        XCTAssertEqual(selections, [.init(sectionID: "parts-1", index: 42)])
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(container.suspendsAutomaticPlayback)
        plugin.showEpisodes()
        let reopened = try XCTUnwrap(container.presentedViewController as? VideoEpisodePickerViewController)
        try await eventually { !reopened.isBeingPresented }
        let reopenedEpisodes = try collection(in: reopened, identifier: "episode-list")
        reopened.collectionView(reopenedEpisodes, didSelectItemAt: IndexPath(item: 6, section: 0))
        try await eventually { container.presentedViewController == nil }
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(player.rate, 0, "Selecting the current episode must only close the picker, preserving pause")
        plugin.showEpisodes()
        try await eventually { container.presentedViewController?.isBeingPresented == false }
        container.stopPlayback()
        try await eventually { container.presentedViewController == nil }
        XCTAssertFalse(container.suspendsAutomaticPlayback)
        XCTAssertEqual(selections.count, 1, "Teardown must not invoke selection or restore playback")
    }

    @MainActor func testLiveDirectEntrySelectionAndAutomaticNextPart() async throws {
        // Public multipart course BV1qW4y1a7fU; fetch current CIDs instead of persisting signed URLs.
        let detail = try await WebRequest.requestDetailVideo(aid: 941747210)
        let pages = try XCTUnwrap(detail.View.pages)
        guard pages.count > 2 else {
            XCTFail("The live fixture must contain at least three parts")
            return
        }
        let info = PlayInfo(aid: detail.View.aid, cid: pages[0].cid)
        let targetIndex = 1
        let previousContinue = Settings.continuePlay
        Settings.continuePlay = false
        let playerVC = VideoPlayerViewController(playInfo: info, startTimeOverride: 37)
        let root = try XCTUnwrap(AppDelegate.shared.window?.rootViewController)
        root.present(playerVC, animated: false)
        defer {
            Settings.continuePlay = previousContinue
            playerVC.stopPlayback()
            playerVC.dismiss(animated: false)
        }
        let av = try XCTUnwrap(playerVC.children.first as? AVPlayerViewController)
        try await eventually(timeout: 60) { (av.player?.currentTime().seconds ?? 0) > 37 }
        let oldPlayer = try XCTUnwrap(av.player)
        let oldItem = oldPlayer.currentItem
        let button = try XCTUnwrap(av.transportBarCustomMenuItems.compactMap { $0 as? UIAction }.first { $0.identifier.rawValue == "video.episodes" })
        UIButton(primaryAction: button).sendActions(for: .primaryActionTriggered)
        let firstPicker = try XCTUnwrap(playerVC.presentedViewController as? VideoEpisodePickerViewController)
        try await eventually { !firstPicker.isBeingPresented }
        XCTAssertEqual(oldPlayer.rate, 0)
        firstPicker.close()
        try await eventually { playerVC.presentedViewController == nil && oldPlayer.rate > 0 }
        XCTAssertTrue(av.player === oldPlayer)
        XCTAssertTrue(oldPlayer.currentItem === oldItem)
        oldPlayer.pause()
        UIButton(primaryAction: button).sendActions(for: .primaryActionTriggered)
        let picker = try XCTUnwrap(playerVC.presentedViewController as? VideoEpisodePickerViewController)
        try await eventually { !picker.isBeingPresented }
        let ranges = try collection(in: picker, identifier: "episode-ranges")
        let episodes = try collection(in: picker, identifier: "episode-list")
        picker.collectionView(ranges, didSelectItemAt: IndexPath(item: targetIndex / 20, section: 0))
        picker.collectionView(episodes, didSelectItemAt: IndexPath(item: targetIndex % 20, section: 0))
        try await eventually(timeout: 60) {
            playerVC.currentPlayInfo.cid == pages[targetIndex].cid && (av.player?.currentTime().seconds ?? 0) > 1
        }
        XCTAssertFalse(av.player === oldPlayer)
        XCTAssertLessThan(try XCTUnwrap(av.player?.currentTime().seconds), 20, "A cast/preview's 37-second offset must not be reused for another part")
        XCTAssertEqual(av.infoViewActions.first { $0.title == "下一集" }?.identifier.rawValue,
                       "play.next.\(PlayInfo(aid: info.aid, cid: pages[targetIndex + 1].cid, title: pages[targetIndex + 1].part).sequenceKey)")
        let item = try XCTUnwrap(av.player?.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await eventually(timeout: 60) {
            playerVC.currentPlayInfo.cid == pages[targetIndex + 1].cid && (av.player?.currentTime().seconds ?? 0) > 1
        }
        playerVC.stopPlayback()
        await withCheckedContinuation { continuation in
            playerVC.dismiss(animated: false) { continuation.resume() }
        }
    }

    @MainActor private func collection(in picker: UIViewController, identifier: String) throws -> UICollectionView {
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        picker.loadViewIfNeeded()
        return try XCTUnwrap(descendants(picker.view).first { $0.accessibilityIdentifier == identifier } as? UICollectionView)
    }

    @MainActor private func eventually(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                                      _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for episode selection", file: file, line: line)
        throw NSError(domain: "EpisodeSelectionTests", code: 1)
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
