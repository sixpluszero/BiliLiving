//
//  NVASocket.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/11/25.
//

import Foundation
import Swifter
import SwiftyJSON

public func nvasocket(
    uuid: String,
    didConnect: ((NVASession) -> Void)? = nil,
    didDisconnect: ((NVASession) -> Void)? = nil,
    processor: ((NVASession, NVASession.NVAFrame) -> Void)? = nil
) -> ((HttpRequest) -> HttpResponse) {
    return { request in
        guard request.method == "SETUP", let connectSession = request.headers["session"] else {
            return .badRequest(.text("No setup"))
        }

        let protocolSessionClosure: ((Socket) -> Void) = { socket in
            let session = NVASession(socket)
            func read() throws {
                while true {
                    let frame = try session.readFrame()
                    if frame.isPing {
                        session.sendEmpty()
                    } else {
                        if frame.isCommand && frame.paramCount > 0 {
                            processor?(session, frame)
                        }
                    }
                }
            }
            didConnect?(session)
            do {
                try read()
            } catch let err {
                Logger.warn("\(err)")
            }
            didDisconnect?(session)
        }
        let header = ["Session": connectSession,
                      "NvaVersion": "1",
                      "Connection": "Keep-Alive",
                      "UUID": uuid,
                      "User-Agent": "Linux/3.0.0 UPnP/1.0 Platinum/1.0.5.13"]
        return HttpResponse.rawProtocol(200, "OK", header, "NVA", protocolSessionClosure)
    }
}

public class NVASession: Hashable, Equatable {
    public static func == (lhs: NVASession, rhs: NVASession) -> Bool {
        lhs.socket == rhs.socket
    }

    var timer: Timer?

    private let versionLock = NSLock()
    private var version: UInt32 = 1
    private func nextVersion() -> UInt32 {
        versionLock.lock(); defer { versionLock.unlock() }
        version &+= 1
        return version
    }
    private func receivedVersion(_ value: UInt32) {
        versionLock.lock(); defer { versionLock.unlock() }
        version = value
    }
    func close() { socket.close() }
    enum FrameError: Error { case malformed, oversized }
    private func text(length: Int) throws -> String {
        guard let value = String(bytes: try socket.read(length: length), encoding: .utf8) else { throw FrameError.malformed }
        return value
    }
    private func uint32() throws -> UInt32 {
        try socket.read(length: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    lazy var socketQueue = DispatchQueue(label: "nva-socket")

    public struct NVAFrame {
        // e0
        var isCommand = false
        var isPing = false
        var paramCount: Int = 0 // 2 or 3  0 menans ping
        var number: UInt32 = 0
        var version = 0x01
        var commandLength: UInt8 = 0
        var command: String = ""
        var actionLength: UInt8 = 0
        var action: String = ""
        var bodyLength: UInt32 = 0
        var body: String = ""
    }

    func readFrame() throws -> NVAFrame {
        var frame = NVAFrame()
        let fst = try socket.read()
        frame.isCommand = fst == 0xe0
        frame.isPing = fst == 0xe4
        frame.paramCount = try Int(socket.read())

        guard [0xe0, 0xc0, 0xe4].contains(fst), frame.paramCount <= 3 else { throw FrameError.malformed }
        let version = try uint32()
        frame.version = Int(version)
        receivedVersion(version)

        if frame.paramCount == 0 {
            // is ping
            return frame
        }
        if !frame.isCommand {
            guard frame.paramCount == 1 else { throw FrameError.malformed }
            let length = try uint32()
            guard length <= 1_048_576 else { throw FrameError.oversized }
            frame.body = try text(length: Int(length))
            return frame
        }
        guard try socket.read() == 0x01 else { throw FrameError.malformed }
        frame.commandLength = try socket.read()
        frame.command = try text(length: Int(frame.commandLength))

        if fst != 0xe0 || frame.paramCount == 1 {
            Logger.debug("reply: \(frame.command)")
            return frame
        }

        frame.actionLength = try socket.read()
        frame.action = try text(length: Int(frame.actionLength))

        if frame.paramCount == 3 {
            let part3Length = try uint32()
            guard part3Length <= 1_048_576 else { throw FrameError.oversized }
            frame.bodyLength = part3Length
            frame.body = try text(length: Int(frame.bodyLength))
        }

        return frame
    }

    func writeData(_ data: Data) {
        socketQueue.async { [weak self] in
            try? self?.socket.writeData(data)
        }
    }

    func sendReply(content: [String: Any]) {
        let str = try! JSON(content).rawData()
        let length = UInt32(str.count)
        var arr: [UInt8] = [0xc0, 0x01]
        arr.append(contentsOf: nextVersion().toUInt8s)
        arr.append(contentsOf: length.toUInt8s)
        var data = Data(arr)
        data.append(str)
        writeData(data)
    }

    func sendPing() {
        var arr: [UInt8] = [0xe4, 0x00]
        arr.append(contentsOf: nextVersion().toUInt8s)
        writeData(Data(arr))
    }

    func sendCommand(action: String, content: [String: Any]) {
        let str = try! JSON(content).rawData()
        let length = UInt32(str.count)
        var arr = Data([0xe0, 0x03])
        arr.append(contentsOf: nextVersion().toUInt8s)
        let command = "Command".data(using: .ascii)!
        arr.append(0x01)
        arr.append(UInt8(command.count))
        arr.append(command)
        let actionData = action.data(using: .ascii)!
        arr.append(UInt8(actionData.count))
        arr.append(actionData)

        arr.append(contentsOf: length.toUInt8s)
        arr.append(str)
        writeData(arr)
    }

    func sendEmpty() {
        var arr: [UInt8] = [0xc0, 0x00]
        arr.append(contentsOf: nextVersion().toUInt8s)
        writeData(Data(arr))
    }

    let socket: Socket

    init(_ socket: Socket) {
        self.socket = socket
//        DispatchQueue.main.async {
//            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
//                print("send ping")
//                self?.sendPing()
//            }
//        }
    }

    deinit {
        timer?.invalidate()
        socket.close()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(socket)
    }
}
