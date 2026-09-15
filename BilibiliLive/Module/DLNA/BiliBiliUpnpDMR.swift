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
    private weak var castPlayer: VideoPlayerViewController?
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
    private let httpPort: in_port_t = 9958
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
        if Settings.uuid.count > 0 {
            return Settings.uuid
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var randomString = ""
        for _ in 0..<35 {
            let rand = arc4random_uniform(36)
            let nextChar = letters[letters.index(letters.startIndex, offsetBy: Int(rand))]
            randomString.append(nextChar)
        }
        Settings.uuid = randomString
        return randomString
    }()

    override private init() { super.init() }
    @MainActor func start() {
        if configured { startIfNeed(); return }
        configured = true
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        httpServer["/description.xml"] = { [weak self] req in
            Logger.debug("handel serverInfo")
            return HttpResponse.ok(.text(self?.serverInfo ?? ""))
        }

        httpServer["/projection"] = nvasocket(uuid: bUuid, didConnect: { [weak self] session in
            Logger.info("session connected \(session)")
            DispatchQueue.main.async {
                guard let self, self.started, self.sessions.count < 4 else { session.close(); return }
                self.sessions.insert(session)
                self.connectedCount = self.sessions.count
                self.status = "手机已连接"
                session.sendCommand(action: "OnPlayState", content: ["playState": self.lastStatus.rawValue])
                session.sendCommand(action: "OnProgress", content: ["duration": self.lastDuration, "position": self.lastPosition])
            }
        }, didDisconnect: { [weak self] session in
            Logger.info("session disconnect \(session)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessions.remove(session)
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
            return HttpResponse.ok(.text(txt))
        }

        httpServer.get["/dlna/AVTransport.xml"] = {
            [weak self] req in
            Logger.debug("handle AVTransport.xml")
            let txt = self?.avTransportScpd ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.post["/AVTransport/action"] = {
            req in
            return HttpResponse.badRequest(.text("Use the Bilibili NVA projection service"))
        }

        httpServer["/AVTransport/event"] = {
            req in
            return HttpResponse.internalServerError(nil)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.foreground, Settings.enableDLNA else { return }
                if path.status != .satisfied {
                    self.stop()
                    self.status = "网络未连接 · 等待恢复"
                } else if !self.started || self.ip != self.getIPAddress() {
                    self.startIfNeed()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "living.cast.network"))
        startIfNeed()
    }

    @MainActor func stop() {
        presentationTask?.cancel()
        sessions.forEach { $0.close() }
        sessions.removeAll()
        connectedCount = 0
        isRunning = false
        status = Settings.enableDLNA ? "投屏已暂停" : "投屏已关闭"
        boardcastTimer?.invalidate()
        boardcastTimer = nil
        udp?.close()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startIfNeed()
        }
    }

    @MainActor private func startIfNeed() {
        guard Settings.enableDLNA, foreground else { stop(); return }
        let address = getIPAddress()
        if started && address == ip { return }
        stop()
        ip = address
        guard ip != nil else { status = "网络未连接 · 等待恢复"; return }
        do {
            udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
            try udp.enableBroadcast(true)
            try udp.enableReusePort(true)
            try udp.bind(toPort: ssdpPort)
            try udp.joinMulticastGroup(ssdpHost)
            try udp.beginReceiving()
            try httpServer.start(httpPort)
            started = true
            isRunning = true
            status = "等待手机投屏"
            Logger.info("dmr started, http: \(httpPort), ssdp: \(ssdpPort)")
        } catch let err {
            started = false
            status = "投屏启动失败 · 请重试"
            udp?.close()
            udp = nil
            httpServer.stop()
            Logger.warn("dmr start fail: \(err.localizedDescription).")
            return
        }
        boardcastTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            guard started else { return }
            for type in discoveryTypes {
                let data = Data(discoveryMessage(type: type, notify: true).utf8)
                udp.send(data, toHost: ssdpHost, port: ssdpPort, withTimeout: 1, tag: 0)
            }
        }
    }

    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { return "" }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "en2" || name == "en3" || name == "en4" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        if name == "en0" {
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private var discoveryTypes: [String] {
        ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1",
         "urn:schemas-upnp-org:service:NirvanaControl:3", "urn:app-bilibili-com:service:NirvanaControl:3"]
    }

    func discoveryMessage(type: String, notify: Bool) -> String {
        let location = "http://\(ip ?? "127.0.0.1"):\(httpPort)/description.xml"
        var lines = notify ? ["NOTIFY * HTTP/1.1", "HOST: \(ssdpHost):\(ssdpPort)", "NTS: ssdp:alive", "NT: \(type)"]
            : ["HTTP/1.1 200 OK", "EXT:", "ST: \(type)"]
        lines += ["LOCATION: \(location)", "CACHE-CONTROL: max-age=60", "SERVER: \(mockServerName)",
                  "USN: uuid:atvbilibili&\(bUuid)::\(type)", "DATE: \(ssdpDateString())", "", ""]
        return lines.joined(separator: "\r\n")
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
        switch frame.action {
        case "GetVolume":
            session.sendReply(content: ["volume": 30])
            return
        case "Play", "PlayUrl":
            do {
                let content = try LivingCastRequest.content(action: frame.action, body: frame.body)
                playVideo(request: try LivingCastRequest(json: content))
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
            presentationTask?.cancel()
            castContext = nil
            currentPlugin = nil
            castPlayer?.stopPlayback()
            castPlayer?.dismiss(animated: true)
            castPlayer = nil
            sendStatus(status: .stop)
        default: break
        }
        session.sendEmpty()
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
        if !sessions.isEmpty {
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
        presentationTask?.cancel()
        currentPlugin = nil
        let context = LivingCastContext()
        castContext = context
        lastDuration = 0
        lastPosition = request.position
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
            let player = VideoPlayerViewController(playInfo: request.playInfo, startTimeOverride: request.position, castContext: context)
            player.autoPlayWhenReady = !context.paused
            player.onLoadFailure = { [weak self, weak context] message in
                guard let self, let context, self.castContext === context else { return }
                self.sendStatus(status: .stop)
                self.status = "投屏失败：\(message)"
            }
            self.castPlayer = player
            root.present(player, animated: true)
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
            guard let self, self.started else { return }
            let types = target == "ssdp:all" ? self.discoveryTypes : self.discoveryTypes.filter { $0 == target }
            for type in types {
                sock.send(Data(self.discoveryMessage(type: type, notify: false).utf8), toAddress: address, withTimeout: 1, tag: 0)
            }
        }
    }
}
