import Foundation
import Swifter
import SwiftyJSON

/// SOAP uses XML text escaping around the media URL (which may itself contain
/// percent-encoded nva_ext JSON). Decode each layer once; never log that URL.
enum LivingCastSOAP {
    static let service = "urn:schemas-upnp-org:service:AVTransport:1"
    static let actions: Set<String> = ["SetAVTransportURI", "Play", "Pause", "Stop", "Seek",
        "GetTransportInfo", "GetPositionInfo", "GetMediaInfo", "GetDeviceCapabilities",
        "GetTransportSettings", "GetCurrentTransportActions", "SetPlayMode"]

    struct Request {
        let action: String
        let arguments: [String: String]
        init(body: Data, soapAction: String?) throws {
            guard body.count <= 1_048_576 else { throw Fault(402, "Invalid Args") }
            let reader = Reader()
            let parser = XMLParser(data: body)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            guard parser.parse(), !reader.invalid, let action = reader.action else { throw Fault(402, "Invalid Args") }
            if let soapAction {
                let header = soapAction.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\r\n"))
                guard header == "\(service)#\(action)" else { throw Fault(401, "Invalid Action") }
            }
            guard actions.contains(action) else { throw Fault(401, "Invalid Action") }
            guard reader.arguments["InstanceID"] == "0" else { throw Fault(718, "Invalid InstanceID") }
            self.action = action
            arguments = reader.arguments
        }
    }

    struct Fault: Error {
        let code: Int
        let message: String
        init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    }

    enum Media {
        case video(LivingCastRequest)
        case url(URL)
        init(uri: String) throws {
            guard let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false else { throw Fault(714, "Illegal MIME-type") }
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "nva_ext" }) == true {
                do {
                    let body = try JSON(["url": uri]).rawData()
                    let content = try LivingCastRequest.content(action: "PlayUrl", body: String(decoding: body, as: UTF8.self))
                    self = .video(try LivingCastRequest(json: content))
                } catch { throw Fault(714, "Invalid video metadata") }
            } else { self = .url(url) }
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func response(action: String, values: [(String, String)] = []) -> HttpResponse {
        let arguments = values.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return envelope("<u:\(action)Response xmlns:u=\"\(service)\">\(arguments)</u:\(action)Response>")
    }

    static func fault(_ fault: Fault) -> HttpResponse {
        envelope("<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(fault.code)</errorCode><errorDescription>\(escape(fault.message))</errorDescription></UPnPError></detail></s:Fault>", code: 500)
    }

    private static func envelope(_ body: String, code: Int = 200) -> HttpResponse {
        let data = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\(body)</s:Body></s:Envelope>".utf8)
        return .raw(code, code == 200 ? "OK" : "Internal Server Error", ["Content-Type": "text/xml; charset=\"utf-8\"", "Content-Length": "\(data.count)"]) { try $0.write(data) }
    }

    static func time(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    static func seconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours.isFinite, hours >= 0, hours.rounded(.down) == hours,
              minutes >= 0, minutes < 60, minutes.rounded(.down) == minutes,
              seconds >= 0, seconds < 60 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result <= 31_536_000 ? result : nil
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var action: String?
        var arguments: [String: String] = [:]
        var invalid = false
        private var path: [String] = []
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name)
            if path.count == 1 && (name != "Envelope" || namespaceURI != "http://schemas.xmlsoap.org/soap/envelope/") { invalid = true }
            if path.count == 2 && name == "Body" && namespaceURI != "http://schemas.xmlsoap.org/soap/envelope/" { invalid = true }
            if path.count == 3 && path[1] == "Body" {
                if action != nil || namespaceURI != service { invalid = true }
                action = name
            }
            if path.count == 4 && path[1] == "Body" {
                if arguments[name] != nil { invalid = true }
                text = ""
            }
            if path.count > 4 { invalid = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if path.count == 4 { text += string } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if path.count == 4 { text += String(decoding: CDATABlock, as: UTF8.self) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if path.count == 4 && path[1] == "Body" { arguments[name] = text }
            path.removeLast()
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
    }
}
