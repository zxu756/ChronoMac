import Foundation
import SwiftUI

public enum SampleTier: Int, Codable, CaseIterable, Sendable {
    case raw2s = 0       // Last 2 hours @ 2s resolution
    case rollup15s = 1   // 2h..24h @ 15s peak-preserving buckets
    case rollup60s = 2   // 24h..7d @ 60s peak-preserving buckets
}

public enum ThermalGrade: Int, Codable, CaseIterable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Elevated"
        case .serious: return "Throttling"
        case .critical: return "Critical"
        }
    }
}

public enum TimeRangeWindow: String, CaseIterable, Identifiable, Sendable {
    case oneHour = "1h"
    case sixHours = "6h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"

    public var id: String { rawValue }

    public var durationSeconds: Int64 {
        switch self {
        case .oneHour: return 3_600
        case .sixHours: return 21_600
        case .twentyFourHours: return 86_400
        case .sevenDays: return 604_800
        }
    }

    public var title: String {
        switch self {
        case .oneHour: return "Last 1 hour"
        case .sixHours: return "Last 6 hours"
        case .twentyFourHours: return "Last 24 hours"
        case .sevenDays: return "Last 7 days"
        }
    }
}

public struct SystemTick: Identifiable, Codable, Equatable, Sendable {
    public var ts: Int64
    public var tier: SampleTier
    public var cpuUserPct: Double
    public var cpuSysPct: Double
    public var thermalGrade: ThermalGrade
    public var memUsedBytes: Int64
    public var memTotalBytes: Int64
    public var swapUsedBytes: Int64
    public var diskReadBps: Int64
    public var diskWriteBps: Int64
    public var netInBps: Int64
    public var netOutBps: Int64
    public var activeAgentCount: Int
    public var activeAgentSummary: String

    public var id: Int64 { ts }

    public var totalCPUPct: Double {
        min(100.0, max(0.0, cpuUserPct + cpuSysPct))
    }

    public init(
        ts: Int64,
        tier: SampleTier = .raw2s,
        cpuUserPct: Double,
        cpuSysPct: Double,
        thermalGrade: ThermalGrade = .nominal,
        memUsedBytes: Int64,
        memTotalBytes: Int64,
        swapUsedBytes: Int64,
        diskReadBps: Int64,
        diskWriteBps: Int64,
        netInBps: Int64,
        netOutBps: Int64,
        activeAgentCount: Int = 0,
        activeAgentSummary: String = ""
    ) {
        self.ts = ts
        self.tier = tier
        self.cpuUserPct = max(0, cpuUserPct)
        self.cpuSysPct = max(0, cpuSysPct)
        self.thermalGrade = thermalGrade
        self.memUsedBytes = max(0, memUsedBytes)
        self.memTotalBytes = max(1, memTotalBytes)
        self.swapUsedBytes = max(0, swapUsedBytes)
        self.diskReadBps = max(0, diskReadBps)
        self.diskWriteBps = max(0, diskWriteBps)
        self.netInBps = max(0, netInBps)
        self.netOutBps = max(0, netOutBps)
        self.activeAgentCount = max(0, activeAgentCount)
        self.activeAgentSummary = activeAgentSummary
    }
}

public struct ProcessSample: Identifiable, Codable, Equatable, Sendable {
    public var ts: Int64
    public var pid: Int
    public var ppid: Int
    public var name: String
    public var execPath: String
    public var bundleID: String?
    public var signingTeam: String?
    public var cpuPct: Double
    public var rssBytes: Int64
    public var diskReadBps: Int64
    public var diskWriteBps: Int64
    public var netInBps: Int64
    public var netOutBps: Int64
    public var isAliveNow: Bool

    public var id: String { "\(ts)-\(pid)-\(name)" }

    public init(
        ts: Int64,
        pid: Int,
        ppid: Int,
        name: String,
        execPath: String,
        bundleID: String? = nil,
        signingTeam: String? = nil,
        cpuPct: Double,
        rssBytes: Int64,
        diskReadBps: Int64 = 0,
        diskWriteBps: Int64 = 0,
        netInBps: Int64 = 0,
        netOutBps: Int64 = 0,
        isAliveNow: Bool = true
    ) {
        self.ts = ts
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.execPath = execPath
        self.bundleID = bundleID
        self.signingTeam = signingTeam
        self.cpuPct = max(0, cpuPct)
        self.rssBytes = max(0, rssBytes)
        self.diskReadBps = max(0, diskReadBps)
        self.diskWriteBps = max(0, diskWriteBps)
        self.netInBps = max(0, netInBps)
        self.netOutBps = max(0, netOutBps)
        self.isAliveNow = isAliveNow
    }
}

public struct SocketFlowRecord: Identifiable, Codable, Equatable, Sendable {
    public var bucketHour: Int64
    public var execPath: String
    public var processName: String
    public var remoteEndpoint: String
    public var hostname: String?
    public var protocolName: String
    public var totalBytesIn: Int64
    public var totalBytesOut: Int64
    public var firstSeen: Int64
    public var lastSeen: Int64

    public var id: String { "\(bucketHour)::\(execPath)::\(remoteEndpoint)" }

    public init(
        bucketHour: Int64,
        execPath: String,
        processName: String,
        remoteEndpoint: String,
        hostname: String? = nil,
        protocolName: String = "tcp4",
        totalBytesIn: Int64,
        totalBytesOut: Int64,
        firstSeen: Int64,
        lastSeen: Int64
    ) {
        self.bucketHour = bucketHour
        self.execPath = execPath
        self.processName = processName
        self.remoteEndpoint = remoteEndpoint
        self.hostname = hostname
        self.protocolName = protocolName
        self.totalBytesIn = max(0, totalBytesIn)
        self.totalBytesOut = max(0, totalBytesOut)
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public enum AnomalyKind: String, Codable, CaseIterable, Sendable {
    case swapSurge = "Swap surge"
    case egressBurst = "Outbound spike"
    case runawayCPU = "Sustained CPU"
    case thermalThrottle = "Thermal pressure"
    case newExternalHost = "New remote host"
}

public struct AnomalyBookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var ts: Int64
    public var kind: AnomalyKind
    public var severity: Int
    public var culpritName: String
    public var culpritExec: String
    public var metricBadge: String
    public var summary: String

    public init(
        id: String = UUID().uuidString,
        ts: Int64,
        kind: AnomalyKind,
        severity: Int,
        culpritName: String,
        culpritExec: String,
        metricBadge: String,
        summary: String
    ) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.severity = severity
        self.culpritName = culpritName
        self.culpritExec = culpritExec
        self.metricBadge = metricBadge
        self.summary = summary
    }
}

public struct AgentBurstWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var vendor: String
    public var workspace: String
    public var startTs: Int64
    public var endTs: Int64

    public init(id: String, vendor: String, workspace: String, startTs: Int64, endTs: Int64) {
        self.id = id
        self.vendor = vendor
        self.workspace = workspace
        self.startTs = startTs
        self.endTs = max(startTs, endTs)
    }
}

public enum ChronoFormatter {
    public static func bytes(_ value: Int64) -> String {
        if value <= 0 { return "0 MB" }
        let kb = Double(value) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.0f KB", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024.0 {
            return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }

    public static func rate(_ bytesPerSec: Int64) -> String {
        if bytesPerSec <= 0 { return "0 KB/s" }
        let kb = Double(bytesPerSec) / 1024.0
        if kb < 1024.0 {
            return kb >= 10 ? String(format: "%.0f KB/s", kb) : String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024.0 {
            return mb >= 100 ? String(format: "%.0f MB/s", mb) : String(format: "%.1f MB/s", mb)
        }
        return String(format: "%.2f GB/s", mb / 1024.0)
    }

    public static func clockTime(_ ts: Int64, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.timeZone = timeZone
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    public static func shortAxisTime(_ ts: Int64, spanSeconds: Int64, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.timeZone = timeZone
        df.dateFormat = spanSeconds > 86_400 ? "d MMM HH:mm" : "HH:mm"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    public static func displayPath(_ raw: String) -> String {
        var out = raw
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, out.hasPrefix(home) {
            out = "~" + out.dropFirst(home.count)
        }
        out = out.replacingOccurrences(of: ".app/Contents/MacOS/", with: ".app/")
        out = out.replacingOccurrences(of: "/System/Library/PrivateFrameworks/", with: "/System/Library/")
        out = out.replacingOccurrences(of: ".framework/Versions/A/Resources/", with: ".framework/")
        out = out.replacingOccurrences(of: ".framework/Resources/", with: ".framework/")
        return out
    }
}
