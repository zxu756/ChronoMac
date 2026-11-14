import Foundation

public struct NettopSocketDelta: Sendable, Equatable {
    public var pid: Int
    public var processName: String
    public var protocolName: String
    public var remoteEndpoint: String
    public var deltaBytesIn: Int64
    public var deltaBytesOut: Int64

    public init(
        pid: Int,
        processName: String,
        protocolName: String,
        remoteEndpoint: String,
        deltaBytesIn: Int64,
        deltaBytesOut: Int64
    ) {
        self.pid = pid
        self.processName = processName
        self.protocolName = protocolName
        self.remoteEndpoint = remoteEndpoint
        self.deltaBytesIn = max(0, deltaBytesIn)
        self.deltaBytesOut = max(0, deltaBytesOut)
    }
}

public struct NettopSnapshotResult: Sendable, Equatable {
    public var perPIDBytesInDelta: [Int: Int64]
    public var perPIDBytesOutDelta: [Int: Int64]
    public var perPIDLoopbackInBps: [Int: Int64]
    public var perPIDLoopbackOutBps: [Int: Int64]
    public var externalSocketDeltas: [NettopSocketDelta]
    public var totalInBps: Int64
    public var totalOutBps: Int64
    public var loopbackRxBytesPerSec: Int64
    public var loopbackTxBytesPerSec: Int64

    public init(
        perPIDBytesInDelta: [Int: Int64],
        perPIDBytesOutDelta: [Int: Int64],
        perPIDLoopbackInBps: [Int: Int64] = [:],
        perPIDLoopbackOutBps: [Int: Int64] = [:],
        externalSocketDeltas: [NettopSocketDelta],
        totalInBps: Int64,
        totalOutBps: Int64,
        loopbackRxBytesPerSec: Int64 = 0,
        loopbackTxBytesPerSec: Int64 = 0
    ) {
        self.perPIDBytesInDelta = perPIDBytesInDelta
        self.perPIDBytesOutDelta = perPIDBytesOutDelta
        self.perPIDLoopbackInBps = perPIDLoopbackInBps
        self.perPIDLoopbackOutBps = perPIDLoopbackOutBps
        self.externalSocketDeltas = externalSocketDeltas
        self.totalInBps = max(0, totalInBps)
        self.totalOutBps = max(0, totalOutBps)
        self.loopbackRxBytesPerSec = max(0, loopbackRxBytesPerSec)
        self.loopbackTxBytesPerSec = max(0, loopbackTxBytesPerSec)
    }
}

public final class NettopDeltaParser: @unchecked Sendable {
    private struct RetainedCounter: Equatable {
        var bytesIn: Int64
        var bytesOut: Int64
        var lastSeenTick: Int
    }

    private struct ParsedSocketRow {
        var pid: Int
        var processName: String
        var token: String
        var interfaceName: String?
        var bytesIn: Int64
        var bytesOut: Int64
    }

    public let maxAbsentTicks: Int
    private var prevSocketCounters: [String: RetainedCounter] = [:]
    private var hasEstablishedBaseline = false
    private var tickSequence: Int = 0
    private var lastSampleTime: TimeInterval?
    private let lock = NSLock()

    public convenience init() {
        self.init(maxAbsentTicks: 60)
    }

    public init(maxAbsentTicks: Int) {
        self.maxAbsentTicks = max(0, maxAbsentTicks)
    }

    public var trackedSocketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return prevSocketCounters.count
    }

    public func sampleLiveHost(now: TimeInterval = Date().timeIntervalSince1970) -> NettopSnapshotResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = ["-L", "1", "-n", "-J", "interface,state,bytes_in,bytes_out"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else {
                return NettopSnapshotResult(perPIDBytesInDelta: [:], perPIDBytesOutDelta: [:], externalSocketDeltas: [], totalInBps: 0, totalOutBps: 0)
            }
            return ingestCSV(text, now: now)
        } catch {
            return NettopSnapshotResult(perPIDBytesInDelta: [:], perPIDBytesOutDelta: [:], externalSocketDeltas: [], totalInBps: 0, totalOutBps: 0)
        }
    }

    /// Ingests `nettop -L 1 -n -J interface,state,bytes_in,bytes_out` per-socket CSV output,
    /// separating `lo0` / `127.0.0.0/8` / `::1` loopback traffic into dedicated loopback counters so loopback never inflates external rates.
    /// Global baseline is only established once a snapshot contains at least 1 parsed data row; per-socket counters are retained across up to
    /// `maxAbsentTicks` polls so transiently absent connections do not replay cumulative totals, and evicted beyond `maxAbsentTicks` so state stays bounded.
    public func ingestCSV(_ csv: String, now: TimeInterval) -> NettopSnapshotResult {
        lock.lock()
        defer { lock.unlock() }

        var interfaceColIdx: Int? = nil
        var bytesInColIdx = 2
        var bytesOutColIdx = 3
        var headerParsed = false

        var sawAnyProcessRow = false
        var socketRows: [ParsedSocketRow] = []
        var currentPID: Int?
        var currentProcName: String = ""

        let lines = csv.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let cols = rawLine.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard !cols.isEmpty else { continue }

            // Detect header line dynamically (e.g. `,interface,state,bytes_in,bytes_out,` or `time,state,bytes_in,bytes_out,`)
            if !headerParsed, cols.contains("bytes_in"), cols.contains("bytes_out") {
                interfaceColIdx = cols.firstIndex(of: "interface")
                if let inIdx = cols.firstIndex(of: "bytes_in") { bytesInColIdx = inIdx }
                if let outIdx = cols.firstIndex(of: "bytes_out") { bytesOutColIdx = outIdx }
                headerParsed = true
                continue
            }

            let first = cols[0]
            if first.isEmpty || first == "time" { continue }

            let requiredMaxIdx = max(bytesInColIdx, bytesOutColIdx)
            guard cols.count > requiredMaxIdx else { continue }

            // Socket row starts with tcp* / udp* / quic* and contains "<->"
            if (first.hasPrefix("tcp") || first.hasPrefix("udp") || first.hasPrefix("quic")), first.contains("<->") {
                guard let pid = currentPID else { continue }
                let bytesIn = Int64(cols[bytesInColIdx]) ?? 0
                let bytesOut = Int64(cols[bytesOutColIdx]) ?? 0
                let iface = interfaceColIdx.flatMap { $0 < cols.count ? cols[$0] : nil }
                socketRows.append(
                    ParsedSocketRow(
                        pid: pid,
                        processName: currentProcName,
                        token: first,
                        interfaceName: iface,
                        bytesIn: bytesIn,
                        bytesOut: bytesOut
                    )
                )
            } else if let dotIdx = first.lastIndex(of: "."),
                      let pid = Int(first[first.index(after: dotIdx)...]) {
                // Process summary row: e.g. `apsd.140,,,1429321,4782146,`
                sawAnyProcessRow = true
                currentPID = pid
                currentProcName = String(first[..<dotIdx])
            }
        }

        let sawAnyDataRow = !socketRows.isEmpty || sawAnyProcessRow
        if !sawAnyDataRow {
            // Never consume initial baseline on empty or header-only output.
            if hasEstablishedBaseline {
                tickSequence += 1
                lastSampleTime = now
                let cutoffTick = tickSequence - maxAbsentTicks
                if cutoffTick > 0 {
                    prevSocketCounters = prevSocketCounters.filter { $0.value.lastSeenTick >= cutoffTick }
                }
            }
            return NettopSnapshotResult(
                perPIDBytesInDelta: [:],
                perPIDBytesOutDelta: [:],
                externalSocketDeltas: [],
                totalInBps: 0,
                totalOutBps: 0
            )
        }

        let dt = max(0.5, lastSampleTime.map { now - $0 } ?? 1.0)
        let isFirstBaseline = !hasEstablishedBaseline
        hasEstablishedBaseline = true
        lastSampleTime = now
        tickSequence += 1

        var perPIDExtInBytes: [Int: Int64] = [:]
        var perPIDExtOutBytes: [Int: Int64] = [:]
        var perPIDLoopInBytes: [Int: Int64] = [:]
        var perPIDLoopOutBytes: [Int: Int64] = [:]
        var sockDeltas: [NettopSocketDelta] = []

        for row in socketRows {
            let sockKey = "\(row.pid)|\(row.token)"
            let isLoopback = Self.isLoopbackSocket(token: row.token, interfaceName: row.interfaceName)

            if !isFirstBaseline {
                let dIn: Int64
                let dOut: Int64
                if let prev = prevSocketCounters[sockKey] {
                    dIn = row.bytesIn >= prev.bytesIn ? row.bytesIn - prev.bytesIn : row.bytesIn
                    dOut = row.bytesOut >= prev.bytesOut ? row.bytesOut - prev.bytesOut : row.bytesOut
                } else {
                    dIn = row.bytesIn
                    dOut = row.bytesOut
                }

                if isLoopback {
                    if dIn > 0 { perPIDLoopInBytes[row.pid, default: 0] += dIn }
                    if dOut > 0 { perPIDLoopOutBytes[row.pid, default: 0] += dOut }
                } else if let parsed = Self.parseSocketEndpoint(row.token),
                          !Self.isLoopbackOrLinkLocal(parsed.remoteEndpoint) {
                    if dIn > 0 { perPIDExtInBytes[row.pid, default: 0] += dIn }
                    if dOut > 0 { perPIDExtOutBytes[row.pid, default: 0] += dOut }
                    if dIn > 0 || dOut > 0 {
                        sockDeltas.append(
                            NettopSocketDelta(
                                pid: row.pid,
                                processName: row.processName,
                                protocolName: parsed.proto,
                                remoteEndpoint: parsed.remoteEndpoint,
                                deltaBytesIn: dIn,
                                deltaBytesOut: dOut
                            )
                        )
                    }
                }
            }

            prevSocketCounters[sockKey] = RetainedCounter(
                bytesIn: row.bytesIn,
                bytesOut: row.bytesOut,
                lastSeenTick: tickSequence
            )
        }

        let cutoffTick = tickSequence - maxAbsentTicks
        if cutoffTick > 0 {
            prevSocketCounters = prevSocketCounters.filter { $0.value.lastSeenTick >= cutoffTick }
        }

        var perPIDExtInBps: [Int: Int64] = [:]
        var perPIDExtOutBps: [Int: Int64] = [:]
        for (pid, dIn) in perPIDExtInBytes where dIn > 0 {
            perPIDExtInBps[pid] = Int64(Double(dIn) / dt)
        }
        for (pid, dOut) in perPIDExtOutBytes where dOut > 0 {
            perPIDExtOutBps[pid] = Int64(Double(dOut) / dt)
        }

        var perPIDLoopInBps: [Int: Int64] = [:]
        var perPIDLoopOutBps: [Int: Int64] = [:]
        for (pid, dIn) in perPIDLoopInBytes where dIn > 0 {
            perPIDLoopInBps[pid] = Int64(Double(dIn) / dt)
        }
        for (pid, dOut) in perPIDLoopOutBytes where dOut > 0 {
            perPIDLoopOutBps[pid] = Int64(Double(dOut) / dt)
        }

        let totalExtInBps = perPIDExtInBps.values.reduce(0, +)
        let totalExtOutBps = perPIDExtOutBps.values.reduce(0, +)
        let totalLoopInBps = perPIDLoopInBps.values.reduce(0, +)
        let totalLoopOutBps = perPIDLoopOutBps.values.reduce(0, +)

        return NettopSnapshotResult(
            perPIDBytesInDelta: perPIDExtInBps,
            perPIDBytesOutDelta: perPIDExtOutBps,
            perPIDLoopbackInBps: perPIDLoopInBps,
            perPIDLoopbackOutBps: perPIDLoopOutBps,
            externalSocketDeltas: sockDeltas,
            totalInBps: totalExtInBps,
            totalOutBps: totalExtOutBps,
            loopbackRxBytesPerSec: totalLoopInBps,
            loopbackTxBytesPerSec: totalLoopOutBps
        )
    }

    public static func isLoopbackSocket(token: String, interfaceName: String?) -> Bool {
        if let iface = interfaceName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !iface.isEmpty {
            if iface == "lo0" || iface.hasPrefix("lo") {
                return true
            }
        }
        let parts = token.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let endpoints = parts[1].components(separatedBy: "<->")
        for ep in endpoints {
            let trimmed = ep.trimmingCharacters(in: .whitespaces)
            if isLoopbackEndpoint(trimmed) {
                return true
            }
        }
        return false
    }

    public static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        let ip = extractRemoteIP(endpoint).lowercased()
        return ip.hasPrefix("127.")
            || ip == "::1"
            || ip.hasPrefix("::1%")
            || ip == "[::1]"
            || ip == "localhost"
            || endpoint.lowercased().contains("%lo")
    }

    public static func parseSocketEndpoint(_ token: String) -> (proto: String, remoteEndpoint: String)? {
        let parts = token.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let proto = parts[0]
        let arrowParts = parts[1].components(separatedBy: "<->")
        guard arrowParts.count == 2 else { return nil }
        let remote = arrowParts[1].trimmingCharacters(in: .whitespaces)
        if remote.hasPrefix("*:") || remote.hasPrefix("*.") || remote == "*:*" || remote == "*.*" {
            return nil
        }
        return (proto, remote)
    }

    public static func extractRemoteIP(_ endpoint: String) -> String {
        // IPv4 `17.57.145.41:5223` or IPv6 `2606:4700::6810:85e5.443` / `::1.8080`
        if endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.lastIndex(of: ":") {
            return String(endpoint[..<colon])
        }
        if let dot = endpoint.lastIndex(of: "."), endpoint.contains(":") {
            return String(endpoint[..<dot])
        }
        return endpoint
    }

    public static func isLoopbackOrLinkLocal(_ remote: String) -> Bool {
        if isLoopbackEndpoint(remote) { return true }
        let lower = extractRemoteIP(remote).lowercased()
        return lower.hasPrefix("fe80:")
            || lower.hasPrefix("0.0.0.0")
            || lower.hasPrefix("*")
    }
}
