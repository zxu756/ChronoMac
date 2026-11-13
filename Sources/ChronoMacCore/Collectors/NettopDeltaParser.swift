import Foundation

public struct NettopSocketDelta: Sendable, Equatable {
    public var pid: Int
    public var processName: String
    public var protocolName: String
    public var remoteEndpoint: String
    public var deltaBytesIn: Int64
    public var deltaBytesOut: Int64
}

public struct NettopSnapshotResult: Sendable, Equatable {
    public var perPIDBytesInDelta: [Int: Int64]
    public var perPIDBytesOutDelta: [Int: Int64]
    public var externalSocketDeltas: [NettopSocketDelta]
    public var totalInBps: Int64
    public var totalOutBps: Int64
}

public final class NettopDeltaParser: @unchecked Sendable {
    private struct CounterPair: Equatable {
        var bytesIn: Int64
        var bytesOut: Int64
    }

    private var prevProcessCounters: [String: CounterPair] = [:]
    private var prevSocketCounters: [String: CounterPair] = [:]
    private var lastSampleTime: TimeInterval?
    private let lock = NSLock()

    public init() {}

    public func sampleLiveHost(now: TimeInterval = Date().timeIntervalSince1970) -> NettopSnapshotResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = ["-L", "1", "-n", "-J", "bytes_in,bytes_out,state"]
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

    /// Ingests raw `nettop -L 1 -n -J bytes_in,bytes_out,state` CSV output and computes positive counter deltas.
    public func ingestCSV(_ csv: String, now: TimeInterval) -> NettopSnapshotResult {
        lock.lock()
        defer { lock.unlock() }

        let dt = max(0.5, lastSampleTime.map { now - $0 } ?? 1.0)
        let isFirstBaseline = (lastSampleTime == nil)
        lastSampleTime = now

        var curProcCounters: [String: CounterPair] = [:]
        var curSockCounters: [String: CounterPair] = [:]
        var perPIDIn: [Int: Int64] = [:]
        var perPIDOut: [Int: Int64] = [:]
        var sockDeltas: [NettopSocketDelta] = []

        var currentPID: Int?
        var currentProcName: String = ""

        let lines = csv.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let cols = rawLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !cols.isEmpty else { continue }
            let first = cols[0].trimmingCharacters(in: .whitespaces)
            if first.isEmpty || first == "time" { continue }

            // Socket row starts with tcp4 / tcp6 / udp4 / udp6 and contains "<->"
            if (first.hasPrefix("tcp") || first.hasPrefix("udp")), first.contains("<->") {
                guard let pid = currentPID, cols.count >= 4 else { continue }
                let bytesIn = Int64(cols[2]) ?? 0
                let bytesOut = Int64(cols[3]) ?? 0
                guard let parsed = Self.parseSocketEndpoint(first) else { continue }
                if Self.isLoopbackOrLinkLocal(parsed.remoteEndpoint) { continue }

                let sockKey = "\(pid)|\(first)"
                curSockCounters[sockKey] = CounterPair(bytesIn: bytesIn, bytesOut: bytesOut)

                if !isFirstBaseline {
                    let prev = prevSocketCounters[sockKey] ?? CounterPair(bytesIn: 0, bytesOut: 0)
                    let dIn = bytesIn >= prev.bytesIn ? bytesIn - prev.bytesIn : bytesIn
                    let dOut = bytesOut >= prev.bytesOut ? bytesOut - prev.bytesOut : bytesOut
                    if dIn > 0 || dOut > 0 {
                        sockDeltas.append(
                            NettopSocketDelta(
                                pid: pid,
                                processName: currentProcName,
                                protocolName: parsed.proto,
                                remoteEndpoint: parsed.remoteEndpoint,
                                deltaBytesIn: dIn,
                                deltaBytesOut: dOut
                            )
                        )
                    }
                }
            } else if let dotIdx = first.lastIndex(of: "."),
                      let pid = Int(first[first.index(after: dotIdx)...]),
                      cols.count >= 4 {
                // Process header row: e.g. `apsd.140,,888109,3218172,`
                let name = String(first[..<dotIdx])
                currentPID = pid
                currentProcName = name
                let bytesIn = Int64(cols[2]) ?? 0
                let bytesOut = Int64(cols[3]) ?? 0
                let procKey = "\(name).\(pid)"
                curProcCounters[procKey] = CounterPair(bytesIn: bytesIn, bytesOut: bytesOut)

                if !isFirstBaseline, let prev = prevProcessCounters[procKey] {
                    let dIn = bytesIn >= prev.bytesIn ? bytesIn - prev.bytesIn : 0
                    let dOut = bytesOut >= prev.bytesOut ? bytesOut - prev.bytesOut : 0
                    if dIn > 0 { perPIDIn[pid, default: 0] += Int64(Double(dIn) / dt) }
                    if dOut > 0 { perPIDOut[pid, default: 0] += Int64(Double(dOut) / dt) }
                }
            }
        }

        prevProcessCounters = curProcCounters
        prevSocketCounters = curSockCounters

        let totalInBps = perPIDIn.values.reduce(0, +)
        let totalOutBps = perPIDOut.values.reduce(0, +)

        return NettopSnapshotResult(
            perPIDBytesInDelta: perPIDIn,
            perPIDBytesOutDelta: perPIDOut,
            externalSocketDeltas: sockDeltas,
            totalInBps: totalInBps,
            totalOutBps: totalOutBps
        )
    }

    public static func parseSocketEndpoint(_ token: String) -> (proto: String, remoteEndpoint: String)? {
        let parts = token.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let proto = parts[0]
        let arrowParts = parts[1].components(separatedBy: "<->")
        guard arrowParts.count == 2 else { return nil }
        let remote = arrowParts[1].trimmingCharacters(in: .whitespaces)
        if remote.hasPrefix("*:") || remote.hasPrefix("*.") || remote == "*:*" {
            return nil
        }
        return (proto, remote)
    }

    public static func extractRemoteIP(_ endpoint: String) -> String {
        // IPv4 `17.57.145.41:5223` or IPv6 `2606:4700::6810:85e5.443`
        if endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.lastIndex(of: ":") {
            return String(endpoint[..<colon])
        }
        if let dot = endpoint.lastIndex(of: "."), endpoint.contains(":") {
            return String(endpoint[..<dot])
        }
        return endpoint
    }

    public static func isLoopbackOrLinkLocal(_ remote: String) -> Bool {
        let lower = remote.lowercased()
        return lower.hasPrefix("127.")
            || lower.hasPrefix("::1")
            || lower.hasPrefix("fe80:")
            || lower.hasPrefix("0.0.0.0")
            || lower.hasPrefix("*")
    }
}
