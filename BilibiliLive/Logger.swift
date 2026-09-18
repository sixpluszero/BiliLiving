//
//  Logger.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/12/9.
//

import CocoaLumberjackSwift
import Foundation

class Logger {
    private static let fileLogger = DDFileLogger()
    static func setup() {
        DDLog.add(DDOSLogger.sharedInstance)
        let dataFormatter = DateFormatter()
        dataFormatter.setLocalizedDateFormatFromTemplate("YYYY/MM/dd HH:mm:ss:SSS")
        fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: dataFormatter)
        fileLogger.rollingFrequency = 60 * 60 * 24 // 24 hours
        fileLogger.logFileManager.maximumNumberOfLogFiles = 2
        fileLogger.doNotReuseLogFiles = true
        fileLogger.maximumFileSize = 1024 * 1024 * 5
        DDLog.add(fileLogger)
    }

    static func debug(_ message: @autoclosure () -> DDLogMessageFormat,
                      file: StaticString = #file,
                      function: StaticString = #function,
                      line: UInt = #line)
    {
        DDLogDebug(message(), file: file, function: function, line: line)
    }

    static func info(_ message: @autoclosure () -> DDLogMessageFormat,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogInfo(message(), file: file, function: function, line: line)
    }

    static func warn(_ message: @autoclosure () -> DDLogMessageFormat,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogWarn(message(), file: file, function: function, line: line)
    }

    static func warn(_ error: Any,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogWarn("\(error)", file: file, function: function, line: line)
    }

    static func latestLogPath() -> String? {
        fileLogger.logFileManager.sortedLogFilePaths.first
    }

    static func oldestLogPath() -> String? {
        fileLogger.logFileManager.sortedLogFilePaths.last
    }
}

/// Diagnostics retain CDN hosts and media paths, never signed URL queries or cookies.
enum PlaybackDiagnostics {
    static func resource(_ value: String?) -> String {
        guard let value, let url = URLComponents(string: value),
              let scheme = url.scheme, let host = url.host else { return "-" }
        return "\(scheme)://\(host)\(url.path)"
    }

    static func sanitize(_ text: String) -> String {
        let pattern = #"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "-" }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: resource(String(result[range])))
        }
        return String(result.replacingOccurrences(of: "\n", with: " ").prefix(1500))
    }

    static func error(_ error: Error?) -> String {
        guard let error else { return "none" }
        var current: NSError? = error as NSError
        var parts = [String]()
        for _ in 0..<5 {
            guard let value = current else { break }
            parts.append("\(value.domain)(\(value.code)): \(sanitize(value.localizedDescription))")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }

    static func milliseconds(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "-" }
        return String(format: "%.1f", end.timeIntervalSince(start) * 1000)
    }

    static func networkMetrics(_ metrics: URLSessionTaskMetrics?) -> String {
        guard let metrics else { return "metrics=none" }
        let transactions = metrics.transactionMetrics.map { m in
            "host=\(m.response?.url?.host ?? m.request.url?.host ?? "-") protocol=\(m.networkProtocolName ?? "-") fetchType=\(m.resourceFetchType.rawValue) reused=\(m.isReusedConnection) proxy=\(m.isProxyConnection) dnsMs=\(milliseconds(m.domainLookupStartDate, m.domainLookupEndDate)) connectMs=\(milliseconds(m.connectStartDate, m.connectEndDate)) tlsMs=\(milliseconds(m.secureConnectionStartDate, m.secureConnectionEndDate)) ttfbMs=\(milliseconds(m.requestStartDate, m.responseStartDate)) bodyMs=\(milliseconds(m.responseStartDate, m.responseEndDate))"
        }
        return "totalMs=\(String(format: "%.1f", metrics.taskInterval.duration * 1000)) redirects=\(metrics.redirectCount) [\(transactions.joined(separator: "; "))]"
    }
}
