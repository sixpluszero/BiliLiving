//
//  BiliBiliUpnpDMR.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/11/25.
//

import Combine
import Network
import CocoaAsyncSocket
import CoreMedia
import Foundation
import Swifter
import SwiftyJSON
import UIKit

class BiliBiliUpnpDMR: NSObject, ObservableObject {
    static let deviceName = "BiliLiving · 小电视"
    @Published private(set) var status = "投屏已关闭"
    @Published private(set) var isRunning = false
    @Published private(set) var connectedCount = 0
    private var configured = false
    private let pathMonitor = NWPathMonitor()
    private var foreground = true
    private var castContext: LivingCastContext?
    private weak var castPlayer: CommonPlayerViewController?
    private var soapMedia: LivingCastSOAP.Media?
    private var soapURI = ""
    private var soapMetadata = ""
    private var presentationTask: Task<Void, Never>?
    private var lastStatus: PlayStatus = .stop
    private var lastDuration = 0
    private var lastPosition = 0

    @MainActor func setEnabled(_ enabled: Bool) {
        Settings.enableDLNA = enabled
        start()
    }
    static let shared = BiliBiliUpnpDMR()

    private let ssdpHost = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private(set) var httpPort: in_port_t = 9958
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var serverGeneration = UUID()
    private let mockServerName = "Linux/3.0.0, UPnP/1.0, Platinum/1.0.5.13"

    private let udpQueue = DispatchQueue(label: "com.bilibili.upnp.udp")

    weak var currentPlugin: BUpnpPlugin?

    private var udp: GCDAsyncUdpSocket!
    private var httpServer = HttpServer()
    private var connectedSockets = [GCDAsyncSocket]()
    @MainActor private var sessions = Set<NVASession>()
    private var started = false
    private var ip: String?
    private var boardcastTimer: Timer?

    private lazy var serverInfo: String = {
        let file = Bundle.main.url(forResource: "DLNAInfo", withExtension: "xml")!
        return try! String(contentsOf: file).replacingOccurrences(of: "{{UUID}}", with: bUuid)
    }()

    private lazy var nirvanaControl: String = {
        let file = Bundle.main.url(forResource: "NirvanaControl", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var avTransportScpd: String = {
        let file = Bundle.main.url(forResource: "AvTransportScpd", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var bUuid: String = {
        // The Bilibili receiver ID is XY + 35 uppercase letters/digits.
        // Migrate the old suffix in place so it stays stable across restarts.
        let stored = Settings.uuid
        let suffix = stored.hasPrefix("XY") && stored.count == 37 ? String(stored.dropFirst(2)) : stored
        if suffix.count == 35 && suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) {
            Settings.uuid = "XY" + suffix
            return Settings.uuid
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var randomString = ""
        for _ in 0..<35 {
            let rand = arc4random_uniform(36)
            let nextChar = letters[letters.index(letters.startIndex, offsetBy: Int(rand))]
            randomString.append(nextChar)
        }
        Settings.uuid = "XY" + randomString
        return Settings.uuid
    }()

    override private init() { super.init() }
    @MainActor func start() {
        retryCount = 0
        if configured { startIfNeed(); return }
        configured = true
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.foreground, Settings.enableDLNA else { return }
                if path.status != .satisfied {
                    self.stop()
                    self.status = "网络未连接 · 等待恢复"
                } else if !self.started || self.ip != self.getIPAddress() {
                    self.retryCount = 0
                    self.startIfNeed()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "living.cast.network"))
        startIfNeed()
    }

    @MainActor private func configureHTTPServer() {
        // Swifter's old accept loop calls stop() when it exits. Never restart
        // that same instance: its old loop could stop the newly opened socket.
        httpServer = HttpServer()
        let generation = serverGeneration
        // Only log routing metadata. Bodies and query strings can carry phone
        // credentials and signed media URLs.
        httpServer.middleware.append { request in
            let knownPaths = ["/description.xml", "/projection", "/dlna/NirvanaControl.xml", "/dlna/AVTransport.xml",
                              "/AVTransport/action", "/AVTransport/event", "/NirvanaControl/action", "/NirvanaControl/event"]
            let path = knownPaths.contains(request.path) ? request.path : "<unknown>"
            let method = ["GET", "POST", "SETUP", "RESTORE", "SUBSCRIBE", "UNSUBSCRIBE"].contains(request.method) ? request.method : "<unknown>"
            Logger.info("[cast] request \(method) \(path)")
            return nil
        }
        httpServer["/description.xml"] = { [weak self] req in
            Logger.debug("handel serverInfo")
            return Self.xmlResponse(self?.serverInfo ?? "")
        }

        httpServer["/projection"] = nvasocket(uuid: bUuid, didConnect: { [weak self] session in
            Logger.info("session connected \(session)")
            DispatchQueue.main.async {
                guard let self, self.started, self.serverGeneration == generation, self.sessions.count < 4 else { session.close(); return }
                self.sessions.insert(session)
                self.connectedCount = self.sessions.count
                self.status = "手机已连接"
                session.sendCommand(action: "OnPlayState", content: ["playState": self.lastStatus.rawValue])
                session.sendCommand(action: "OnProgress", content: ["duration": self.lastDuration, "position": self.lastPosition])
            }
        }, didDisconnect: { [weak self] session in
            Logger.info("session disconnect \(session)")
            DispatchQueue.main.async {
                guard let self, self.sessions.remove(session) != nil else { return }
                self.connectedCount = self.sessions.count
                if self.started && self.sessions.isEmpty {
                    self.status = self.castPlayer == nil ? "等待手机投屏" : "手机已断开 · 电视继续播放"
                }
            }
        }, processor: { [weak self] session, frame in
            DispatchQueue.main.async {
                guard let self, self.sessions.contains(session) else { return }
                self.handleEvent(frame: frame, session: session)
            }
        })

        httpServer["/dlna/NirvanaControl.xml"] = {
            [weak self] req in
            Logger.debug("handle NirvanaControl")
            let txt = self?.nirvanaControl ?? ""
            return Self.xmlResponse(txt)
        }

        httpServer.get["/dlna/AVTransport.xml"] = {
            [weak self] req in
            Logger.debug("handle AVTransport.xml")
            let txt = self?.avTransportScpd ?? ""
            return Self.xmlResponse(txt)
        }

        httpServer.post["/AVTransport/action"] = { [weak self] req in
            do {
                let request = try LivingCastSOAP.Request(body: Data(req.body), soapAction: req.headers["soapaction"])
                // Swifter runs handlers on a worker queue. Serialize state with
                // NVA and finish accepting the command before replying to the phone.
                return DispatchQueue.main.sync {
                    guard let self, self.started, self.serverGeneration == generation else {
                        return LivingCastSOAP.fault(.init(501, "Action Failed"))
                    }
                    return self.handleSOAP(request)
                }
            } catch {
                let fault = error as? LivingCastSOAP.Fault ?? .init(402, "Invalid Args")
                Logger.warn("[cast] SOAP request rejected, code \(fault.code)")
                return LivingCastSOAP.fault(fault)
            }
        }

        httpServer["/AVTransport/event"] = {
            req in
            return HttpResponse.internalServerError(nil)
        }

    }

    @MainActor func stop() {
        serverGeneration = UUID()
        retryWork?.cancel()
        retryWork = nil
        presentationTask?.cancel()
        sessions.forEach { $0.close() }
        sessions.removeAll()
        connectedCount = 0
        isRunning = false
        status = Settings.enableDLNA ? "投屏已暂停" : "投屏已关闭"
        boardcastTimer?.invalidate()
        boardcastTimer = nil
        udp?.close()
        udp = nil
        httpServer.stop()
        started = false
        Logger.info("dmr stopped")
    }

    @MainActor @objc func didEnterBackground() {
        foreground = false
        stop()
    }

    @MainActor @objc func willEnterForeground() {
        foreground = true
        retryCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startIfNeed()
        }
    }

    @MainActor private func startIfNeed() {
        guard Settings.enableDLNA, foreground else { stop(); return }
        let address = getIPAddress()
        if started && address == ip && httpServer.operating { return }
        stop()
        ip = address
        guard let address else { status = "网络未连接 · 等待恢复"; return }
        var step = "创建发现服务"
        do {
            udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
            // SSDP uses an IPv4 multicast address. Do not also bind an unused
            // IPv6 socket to port 1900, where other system services may listen.
            udp.setIPv6Enabled(false)
            step = "复用发现端口"
            try udp.enableReusePort(true)
            step = "监听发现端口 1900"
            do {
                try udp.bind(toPort: ssdpPort)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EADDRINUSE) {
                // A system service can own *:1900 without SO_REUSEPORT. Darwin
                // still allows a multicast-specific bind with SO_REUSEADDR.
                // M-SEARCH is addressed to this group, so discovery still works.
                var group = sockaddr_in()
                group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                group.sin_family = sa_family_t(AF_INET)
                group.sin_port = ssdpPort.bigEndian
                inet_pton(AF_INET, ssdpHost, &group.sin_addr)
                let address = withUnsafeBytes(of: &group) { Data($0) }
                try udp.bind(toAddress: address)
                Logger.info("dmr UDP 1900 occupied; listening on SSDP multicast address")
            }
            step = "加入局域网组播"
            try udp.joinMulticastGroup(ssdpHost, onInterface: address)
            step = "设置组播网络接口"
            try setMulticastSendInterface(address, socket: udp)
            step = "接收发现请求"
            try udp.beginReceiving()
            step = "启动投屏连接服务"
            configureHTTPServer()
            do {
                try httpServer.start(9958, forceIPv4: true)
            } catch {
                // Phones discover the port through LOCATION; a fixed port
                // occupied by another service must not disable casting.
                Logger.warn("dmr HTTP 9958 unavailable: \(error); trying an available port")
                configureHTTPServer()
                try httpServer.start(0, forceIPv4: true)
            }
            httpPort = in_port_t(try httpServer.port())
            started = true
            isRunning = true
            retryCount = 0
            status = "等待手机投屏"
            Logger.info("dmr started, http: \(httpPort), ssdp: \(ssdpPort)")
        } catch {
            let error = error as NSError
            stop()
            status = "投屏启动失败 · \(step)（\(error.code)）"
            Logger.warn("dmr start failed at \(step): \(error.domain)(\(error.code)) \(error.localizedDescription)")
            if retryCount < 5 {
                let delay = min(pow(2, Double(retryCount)), 15)
                retryCount += 1
                let work = DispatchWorkItem { [weak self] in self?.startIfNeed() }
                retryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            return
        }
        announce()
        boardcastTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.announce()
        }
    }

    private func setMulticastSendInterface(_ address: String, socket: GCDAsyncUdpSocket) throws {
        // CocoaAsyncSocket's sendIPv4MulticastOnInterface returns NO even on
        // success in our pinned version. Set the option on its protected queue.
        var failure: NSError?
        socket.perform {
            var interface = in_addr()
            guard inet_pton(AF_INET, address, &interface) == 1 else {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
                return
            }
            if setsockopt(socket.socket4FD(), IPPROTO_IP, IP_MULTICAST_IF,
                          &interface, socklen_t(MemoryLayout<in_addr>.size)) != 0 {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        if let failure { throw failure }
    }

    private func announce() {
        guard started else { return }
        for type in discoveryTypes {
            udp.send(Data(discoveryMessage(type: type, notify: true).utf8),
                     toHost: ssdpHost, port: ssdpPort, withTimeout: 1, tag: 0)
        }
    }

    private func getIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        var candidates: [(name: String, address: String)] = []
        while let interface = ptr?.pointee {
            ptr = interface.ifa_next
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  interface.ifa_flags & UInt32(IFF_MULTICAST) != 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname,
                              socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: hostname)))
        }
        // Prefer the interface actually used by the satisfied network path.
        let activeNames = pathMonitor.currentPath.availableInterfaces.filter {
            pathMonitor.currentPath.usesInterfaceType($0.type)
        }.map(\.name)
        return candidates.first(where: { activeNames.contains($0.name) })?.address
            ?? candidates.first?.address
    }

    private var discoveryTypes: [String] {
        ["upnp:rootdevice", "uuid:\(bUuid)", "urn:schemas-upnp-org:device:MediaRenderer:1",
         "urn:schemas-upnp-org:service:AVTransport:1",
         "urn:schemas-upnp-org:service:NirvanaControl:3", "urn:app-bilibili-com:service:NirvanaControl:3"]
    }

    func discoveryMessage(type: String, notify: Bool) -> String {
        let location = "http://\(ip ?? "127.0.0.1"):\(httpPort)/description.xml"
        var lines = notify ? ["NOTIFY * HTTP/1.1", "HOST: \(ssdpHost):\(ssdpPort)", "NTS: ssdp:alive", "NT: \(type)"]
            : ["HTTP/1.1 200 OK", "EXT:", "ST: \(type)"]
        let usn = type == "uuid:\(bUuid)" ? type : "uuid:\(bUuid)::\(type)"
        lines += ["LOCATION: \(location)", "CACHE-CONTROL: max-age=60", "SERVER: \(mockServerName)",
                  "USN: \(usn)", "DATE: \(ssdpDateString())", "", ""]
        return lines.joined(separator: "\r\n")
    }

    private static func xmlResponse(_ content: String) -> HttpResponse {
        let data = Data(content.utf8)
        return .raw(200, "OK", ["Content-Type": "text/xml; charset=\"utf-8\"", "Content-Length": "\(data.count)"]) { writer in
            try writer.write(data)
        }
    }

    private func ssdpDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    @MainActor func handleEvent(frame: NVASession.NVAFrame, session: NVASession) {
        guard started else { return }
        let json = JSON(parseJSON: frame.body)
        let actions = ["GetVolume", "Play", "PlayUrl", "Pause", "Resume", "SwitchDanmaku", "Seek", "Stop"]
        let action = actions.contains(frame.action) ? frame.action : "<unknown>"
        Logger.info("[cast] command \(action), sequence \(frame.number)")
        switch frame.action {
        case "GetVolume":
            session.sendReply(content: ["volume": 30], replyingTo: frame.number)
            return
        case "Play", "PlayUrl":
            do {
                let content = try LivingCastRequest.content(action: frame.action, body: frame.body)
                let request = try LivingCastRequest(json: content)
                soapMedia = nil
                soapURI = ""
                soapMetadata = ""
                playVideo(request: request)
            } catch { sendStatus(status: .stop); status = error.localizedDescription }
        case "Pause":
            castContext?.paused = true
            castPlayer?.autoPlayWhenReady = false
            currentPlugin?.pause()
        case "Resume":
            castContext?.paused = false
            castPlayer?.autoPlayWhenReady = true
            currentPlugin?.resume()
        case "SwitchDanmaku":
            if let open = json["open"].bool ?? Bool(json["open"].stringValue) {
                Defaults.shared.showDanmu = open
                sessions.forEach { $0.sendCommand(action: "OnDanmakuSwitch", content: ["open": open]) }
            }
        case "Seek":
            if let seconds = LivingCastRequest.seconds(json["seekTs"]) {
                if let currentPlugin { currentPlugin.seek(to: seconds) }
                else { castContext?.pendingSeek = seconds }
            }
        case "Stop":
            stopCastPlayback()
        default: break
        }
        session.sendEmpty(replyingTo: frame.number)
    }

    func attach(plugin: BUpnpPlugin, context: LivingCastContext) -> Bool {
        guard castContext === context else { return false }
        currentPlugin = plugin
        return true
    }

    enum PlayStatus: Int {
        case loading = 3
        case playing = 4
        case paused = 5
        case end = 6
        case stop = 7
    }

    @MainActor func sendStatus(status: PlayStatus) {
        lastStatus = status
        if castContext != nil || soapMedia != nil || !sessions.isEmpty {
            switch status {
            case .loading: self.status = "正在接力播放…"
            case .playing: self.status = "正在投屏"
            case .paused: self.status = "投屏已暂停"
            case .end, .stop: self.status = "手机已连接 · 等待投屏"
            }
        }
        Array(sessions).forEach { $0.sendCommand(action: "OnPlayState", content: ["playState": status.rawValue]) }
    }

    @MainActor func sendProgress(duration: Int, current: Int) {
        lastDuration = duration
        lastPosition = current
        Array(sessions).forEach { $0.sendCommand(action: "OnProgress", content: ["duration": duration, "position": current]) }
    }

    func sendVideoSwitch(aid: Int, cid: Int) {
        /* this might cause client disconnect for unkown reason
         let playItem = ["aid": aid, "cid": cid, "contentType": 0, "epId": 0, "seasonId": 0, "roomId": 0] as [String: Any]
         let mockQnDesc = ["curQn": 0,
                           "supportQnList": [
                               [
                                   "description": "",
                                   "displayDesc": "",
                                   "needLogin": false,
                                   "needVip": false,
                                   "quality": 0,
                                   "superscript": "",
                               ],
                           ],
                           "userDesireQn": 0] as [String: Any]
         let data = ["playItem": playItem, "qnDesc": mockQnDesc, "title": "null"] as [String: Any]
         Array(sessions).forEach { $0.sendCommand(action: "OnEpisodeSwitch", content: data) }
          */
    }
}

extension BiliBiliUpnpDMR {
    @MainActor func playVideo(request: LivingCastRequest) {
        Logger.info("[cast] prepare video aid=\(request.playInfo.aid), cid=\(request.playInfo.cid), position=\(request.position)")
        presentCast(position: request.position) { context in
            VideoPlayerViewController(playInfo: request.playInfo, startTimeOverride: request.position, castContext: context)
        }
    }

    @MainActor private func presentCast(position: Int, makePlayer: @escaping (LivingCastContext) -> CommonPlayerViewController) {
        presentationTask?.cancel()
        currentPlugin = nil
        let context = LivingCastContext()
        castContext = context
        lastDuration = 0
        lastPosition = position
        sendStatus(status: .loading)
        presentationTask = Task { @MainActor [weak self] in
            guard let self, let root = AppDelegate.shared.window?.rootViewController else { return }
            if let presented = root.presentedViewController {
                (presented as? CommonPlayerViewController)?.stopPlayback()
                await withCheckedContinuation { continuation in
                    root.dismiss(animated: false) { continuation.resume() }
                }
            }
            guard !Task.isCancelled, self.castContext === context else { return }
            let player = makePlayer(context)
            player.autoPlayWhenReady = !context.paused
            (player as? VideoPlayerViewController)?.onLoadFailure = { [weak self, weak context] message in
                guard let self, let context, self.castContext === context else { return }
                self.sendStatus(status: .stop)
                self.status = "投屏失败：\(message)"
            }
            self.castPlayer = player
            Logger.info("[cast] presenting video player")
            root.present(player, animated: true)
        }
    }
}

extension BiliBiliUpnpDMR {
    @MainActor private func stopCastPlayback() {
        presentationTask?.cancel()
        castContext = nil
        currentPlugin = nil
        castPlayer?.stopPlayback()
        castPlayer?.dismiss(animated: false)
        castPlayer = nil
        sendStatus(status: .stop)
    }

    @MainActor private func handleSOAP(_ request: LivingCastSOAP.Request) -> HttpResponse {
        // Action is validated against an allowlist; no URI, metadata or tokens in logs.
        Logger.info("[cast] SOAP \(request.action)")
        let args = request.arguments
        var values: [(String, String)] = []
        do {
            switch request.action {
            case "SetAVTransportURI":
                guard let uri = args["CurrentURI"], let metadata = args["CurrentURIMetaData"] else {
                    throw LivingCastSOAP.Fault(402, "Invalid Args")
                }
                let media = uri.isEmpty ? nil : try LivingCastSOAP.Media(uri: uri)
                stopCastPlayback()
                soapURI = uri
                soapMetadata = metadata
                soapMedia = media
                lastDuration = 0
                lastPosition = 0
                status = uri.isEmpty ? "等待手机投屏" : "已收到视频 · 等待播放"
                Logger.info("[cast] SOAP media accepted, source \(media == nil ? "empty" : (uri.contains("nva_ext=") ? "video metadata" : "media URL"))")
            case "Play":
                guard args["Speed"] == "1" else { throw LivingCastSOAP.Fault(717, "Play speed not supported") }
                if let context = castContext, castPlayer != nil || lastStatus == .loading {
                    if lastStatus == .end { currentPlugin?.seek(to: 0) }
                    context.paused = false
                    castPlayer?.autoPlayWhenReady = true
                    currentPlugin?.resume()
                } else {
                    guard let media = soapMedia else { throw LivingCastSOAP.Fault(701, "Transition not available") }
                    switch media {
                    case let .video(request): playVideo(request: request)
                    case let .url(url):
                        presentCast(position: 0) { context in
                            LivingURLCastViewController(url: url, context: context)
                        }
                    }
                }
            case "Pause":
                guard let context = castContext else { throw LivingCastSOAP.Fault(701, "Transition not available") }
                context.paused = true
                castPlayer?.autoPlayWhenReady = false
                currentPlugin?.pause()
            case "Stop": stopCastPlayback()
            case "Seek":
                guard args["Unit"] == "REL_TIME" else { throw LivingCastSOAP.Fault(710, "Seek mode not supported") }
                guard let target = args["Target"], let seconds = LivingCastSOAP.seconds(target) else {
                    throw LivingCastSOAP.Fault(711, "Illegal seek target")
                }
                guard let context = castContext else { throw LivingCastSOAP.Fault(701, "Transition not available") }
                if let currentPlugin { currentPlugin.seek(to: seconds) } else { context.pendingSeek = seconds }
            case "GetTransportInfo":
                let state: String
                if soapMedia == nil && castContext == nil { state = "NO_MEDIA_PRESENT" }
                else {
                    switch lastStatus {
                    case .loading: state = "TRANSITIONING"
                    case .playing: state = "PLAYING"
                    case .paused: state = "PAUSED_PLAYBACK"
                    case .stop, .end: state = "STOPPED"
                    }
                }
                values = [("CurrentTransportState", state), ("CurrentTransportStatus", "OK"), ("CurrentSpeed", "1")]
            case "GetPositionInfo":
                values = [("Track", soapURI.isEmpty ? "0" : "1"), ("TrackDuration", LivingCastSOAP.time(lastDuration)),
                          ("TrackMetaData", soapMetadata), ("TrackURI", soapURI),
                          ("RelTime", LivingCastSOAP.time(lastPosition)), ("AbsTime", LivingCastSOAP.time(lastPosition)),
                          ("RelCount", "2147483647"), ("AbsCount", "2147483647")]
            case "GetMediaInfo":
                values = [("NrTracks", soapURI.isEmpty ? "0" : "1"), ("MediaDuration", LivingCastSOAP.time(lastDuration)),
                          ("CurrentURI", soapURI), ("CurrentURIMetaData", soapMetadata), ("NextURI", ""),
                          ("NextURIMetaData", ""), ("PlayMedium", "NETWORK"), ("RecordMedium", "NOT_IMPLEMENTED"),
                          ("WriteStatus", "NOT_IMPLEMENTED")]
            case "GetDeviceCapabilities":
                values = [("PlayMedia", "NETWORK"), ("RecMedia", "NOT_IMPLEMENTED"), ("RecQualityModes", "NOT_IMPLEMENTED")]
            case "GetTransportSettings": values = [("PlayMode", "NORMAL"), ("RecQualityMode", "NOT_IMPLEMENTED")]
            case "GetCurrentTransportActions":
                values = [("Actions", castContext != nil ? "Play,Pause,Stop,Seek" : (soapMedia == nil ? "" : "Play,Stop"))]
            case "SetPlayMode":
                guard args["NewPlayMode"] == "NORMAL" else { throw LivingCastSOAP.Fault(712, "Play mode not supported") }
            default: throw LivingCastSOAP.Fault(401, "Invalid Action")
            }
            return LivingCastSOAP.response(action: request.action, values: values)
        } catch {
            let fault = error as? LivingCastSOAP.Fault ?? .init(501, "Action Failed")
            Logger.warn("[cast] SOAP \(request.action) failed, code \(fault.code)")
            if request.action == "SetAVTransportURI" || request.action == "Play" {
                status = "投屏失败：无法读取手机发送的视频（\(fault.code)）"
            }
            return LivingCastSOAP.fault(fault)
        }
    }
}

extension BiliBiliUpnpDMR: GCDAsyncUdpSocketDelegate {
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        address.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            let sockaddrPtr = pointer.bindMemory(to: sockaddr.self)
            guard let unsafePtr = sockaddrPtr.baseAddress else { return }
            guard getnameinfo(unsafePtr, socklen_t(address.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return
            }
        }
        var ipAddress = String(cString: hostname)
        ipAddress = ipAddress.replacingOccurrences(of: "::ffff:", with: "")
        guard let str = String(data: data, encoding: .utf8),
              str.uppercased().hasPrefix("M-SEARCH "), str.lowercased().contains("ssdp:discover") else { return }
        let target = str.components(separatedBy: "\n").first { $0.uppercased().hasPrefix("ST:") }?
            .dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines) ?? "ssdp:all"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started, self.udp === sock else { return }
            let types = target == "ssdp:all" ? self.discoveryTypes : self.discoveryTypes.filter { $0 == target }
            for type in types {
                sock.send(Data(self.discoveryMessage(type: type, notify: false).utf8), toAddress: address, withTimeout: 1, tag: 0)
            }
        }
    }
}
