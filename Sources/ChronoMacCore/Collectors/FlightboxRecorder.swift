import Darwin
import Dispatch
import Foundation

/// Headless 2-second flight-recorder loop (`ChronoMac record`) decoupled from the SwiftUI UI.
/// Uses monotonic deadline scheduling, zero-poll `DispatchSemaphore` sleep, and `SIGINT`/`SIGTERM`
/// signal handling that flushes SQLite WAL cleanly on shutdown.
public final class FlightboxRecorder: @unchecked Sendable {
    public let store: FlightboxStore
    public let sampler: any SystemSamplerProtocol
    public let enableReverseDNS: Bool
    public let processLimit: Int

    private let anomalyDetector = AnomalyDetector()
    private let dnsResolver = ReverseDNSResolver()
    private let stateLock = NSLock()
    private let wakeSemaphore = DispatchSemaphore(value: 0)
    private var stopRequested = false
    private var tickCounter = 0
    private var gapCounter = 0
    private var pendingGaps: [SamplingGapRecord] = []

    public init(
        store: FlightboxStore,
        sampler: any SystemSamplerProtocol = LiveSystemSampler(),
        enableReverseDNS: Bool = true,
        processLimit: Int = 30
    ) {
        self.store = store
        self.sampler = sampler
        self.enableReverseDNS = enableReverseDNS
        self.processLimit = max(5, processLimit)
    }

    public var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    public var recordedGapCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gapCounter
    }

    private func recordTickFailure(ts: Int64, error: Error) {
        let reason = error.localizedDescription
        stateLock.lock()
        gapCounter += 1
        if pendingGaps.count >= 1_024 {
            pendingGaps.removeFirst()
        }
        pendingGaps.append(SamplingGapRecord(ts: ts, reason: reason))
        stateLock.unlock()

        let warning = "[ChronoMac record] sampling gap at \(ts): \(reason)\n"
        fputs(warning, stderr)
        flushPendingGaps()
    }

    private func flushPendingGaps() {
        stateLock.lock()
        guard !pendingGaps.isEmpty else {
            stateLock.unlock()
            return
        }
        let snapshot = pendingGaps
        stateLock.unlock()

        var remaining: [SamplingGapRecord] = []
        for gap in snapshot {
            do {
                try store.recordSamplingGap(ts: gap.ts, reason: gap.reason)
            } catch {
                remaining.append(gap)
            }
        }

        stateLock.lock()
        let persistedTimestamps = Set(snapshot.map(\.ts)).subtracting(Set(remaining.map(\.ts)))
        pendingGaps.removeAll { persistedTimestamps.contains($0.ts) }
        stateLock.unlock()
    }

    public func requestStop() {
        stateLock.lock()
        let alreadyStopped = stopRequested
        stopRequested = true
        stateLock.unlock()
        if !alreadyStopped {
            wakeSemaphore.signal()
        }
    }

    /// Establishes initial host/network/per-PID delta baselines so Tick 0 reports calibrated rates.
    public func warmBaseline(settleSeconds: TimeInterval = 0.25) {
        autoreleasepool {
            let now = Date().timeIntervalSince1970
            _ = sampler.sampleHostState()
            _ = sampler.sampleNetwork(now: now)
            _ = sampler.sampleProcesses(ts: Int64(now), netInBpsByPID: [:], netOutBpsByPID: [:], limit: processLimit)
        }
        if settleSeconds > 0 {
            _ = wakeSemaphore.wait(timeout: .now() + settleSeconds)
        }
    }

    @discardableResult
    public func captureTick(
        nowOverride: Int64? = nil
    ) throws -> (tick: SystemTick, livePIDs: Set<Int>, agentWindows: [AgentBurstWindow]) {
        let now = nowOverride ?? Int64(Date().timeIntervalSince1970)
        let host = sampler.sampleHostState()
        let net = sampler.sampleNetwork(now: TimeInterval(now))
        let procSnap = sampler.sampleProcesses(
            ts: now,
            netInBpsByPID: net.perPIDBytesInDelta,
            netOutBpsByPID: net.perPIDBytesOutDelta,
            limit: processLimit
        )
        let procs = procSnap.processes
        let agentInfo = sampler.detectAgentActivity(now: now)

        var pidToExec: [Int: String] = [:]
        for p in procs where !p.execPath.isEmpty {
            pidToExec[p.pid] = p.execPath
        }

        let bucketHour = (now / 3600) * 3600
        let socketRecords: [SocketFlowRecord] = net.externalSocketDeltas.map { s in
            let resolvedExec = s.pid > 0 ? (pidToExec[s.pid] ?? sampler.resolveExecutablePath(pid: s.pid)) : ""
            let cleanExec = resolvedExec.hasPrefix("/") ? resolvedExec : ""
            return SocketFlowRecord(
                bucketHour: bucketHour,
                execPath: cleanExec,
                processName: s.processName,
                remoteEndpoint: s.remoteEndpoint,
                hostname: nil,
                protocolName: s.protocolName,
                totalBytesIn: s.deltaBytesIn,
                totalBytesOut: s.deltaBytesOut,
                firstSeen: now,
                lastSeen: now
            )
        }

        let tick = SystemTick(
            ts: now,
            tier: .raw2s,
            cpuUserPct: host.cpuUserPct,
            cpuSysPct: host.cpuSysPct,
            thermalGrade: host.thermal,
            memUsedBytes: host.memUsedBytes,
            memTotalBytes: sampler.totalMemoryBytes,
            swapUsedBytes: host.swapUsedBytes,
            diskReadBps: procSnap.totalDiskReadBps,
            diskWriteBps: procSnap.totalDiskWriteBps,
            netInBps: net.totalInBps,
            netOutBps: net.totalOutBps,
            loopbackInBps: net.loopbackRxBytesPerSec,
            loopbackOutBps: net.loopbackTxBytesPerSec,
            activeAgentCount: agentInfo.count,
            activeAgentSummary: agentInfo.summary
        )

        let detectedAnomalies = anomalyDetector.evaluate(tick: tick, processes: procs, sockets: socketRecords)
        try store.recordSampleBatch(tick: tick, processes: procs, sockets: socketRecords, anomalies: detectedAnomalies)

        if enableReverseDNS {
            for s in socketRecords.filter({ !$0.isUnattributed }).prefix(8) {
                let storeRef = store
                Task {
                    await dnsResolver.resolveIfNeeded(endpoint: s.remoteEndpoint) { endpoint, host in
                        storeRef.updateHostname(for: endpoint, hostname: host)
                    }
                }
            }
        }

        tickCounter += 1
        if tickCounter % 30 == 0 {
            try? store.runRollupAndRetention(now: now)
        }

        return (tick, procSnap.livePIDs, agentInfo.recentWindows)
    }

    @discardableResult
    public func runLoop(
        interval: TimeInterval = 2.0,
        durationSeconds: TimeInterval? = nil,
        installSignalHandlers: Bool = true
    ) throws -> Int {
        let effectiveInterval = max(0.2, interval)
        var signalSources: [DispatchSourceSignal] = []

        if installSignalHandlers {
            let sigQueue = DispatchQueue(label: "io.github.zxu756.ChronoMac.recorder.signals")
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            for sig in [SIGTERM, SIGINT] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: sigQueue)
                src.setEventHandler { [weak self] in
                    self?.requestStop()
                }
                src.resume()
                signalSources.append(src)
            }
        }
        defer {
            for src in signalSources {
                src.cancel()
            }
        }

        let alignToWholeSecond = effectiveInterval >= 1.0
            && abs(effectiveInterval.rounded() - effectiveInterval) < 1e-6
        if alignToWholeSecond {
            warmBaseline(settleSeconds: 0)
            if !isStopped {
                let nowWall = Date().timeIntervalSince1970
                var targetWhole = ceil(nowWall)
                if targetWhole - nowWall < 0.12 {
                    targetWhole += 1.0
                }
                autoreleasepool {
                    _ = sampler.sampleHostState()
                }
                let settleWait = targetWhole - Date().timeIntervalSince1970
                if settleWait > 0.002 {
                    _ = wakeSemaphore.wait(timeout: .now() + settleWait)
                }
            }
        } else {
            warmBaseline(settleSeconds: min(0.25, max(0.05, effectiveInterval * 0.15)))
        }
        if isStopped {
            store.checkpointWAL()
            return 0
        }

        let startUptime = ProcessInfo.processInfo.systemUptime
        let endUptime = durationSeconds.map { startUptime + max(0.0, $0) }
        var lastRecordedEpoch: Int64 = 0
        var recordedTicks = 0
        var scheduledSteps = 0

        while !isStopped {
            var tickEpoch = Int64(Date().timeIntervalSince1970.rounded())
            if tickEpoch <= lastRecordedEpoch && effectiveInterval >= 1.0 {
                tickEpoch = lastRecordedEpoch + Int64(max(1.0, effectiveInterval.rounded()))
            }
            lastRecordedEpoch = tickEpoch

            autoreleasepool {
                do {
                    _ = try captureTick(nowOverride: tickEpoch)
                    flushPendingGaps()
                    recordedTicks += 1
                } catch {
                    recordTickFailure(ts: tickEpoch, error: error)
                }
            }
            scheduledSteps += 1

            let nextUptime = startUptime + Double(scheduledSteps) * effectiveInterval
            if let endUptime, nextUptime > endUptime + 0.05 {
                break
            }

            let remaining = nextUptime - ProcessInfo.processInfo.systemUptime
            if remaining > 0.002 {
                _ = wakeSemaphore.wait(timeout: .now() + remaining)
            }
        }

        flushPendingGaps()
        try? store.runRollupAndRetention(now: Int64(Date().timeIntervalSince1970))
        store.checkpointWAL()
        return recordedTicks
    }
}

public enum LaunchAgentPlistGenerator {
    public static let defaultLabel = "io.github.zxu756.ChronoMac.record"

    public static func renderXML(
        executablePath: String,
        databasePath: String,
        intervalSeconds: Double = 2.0,
        maxDatabaseMB: Int = 250,
        label: String = defaultLabel
    ) -> String {
        let intervalStr = intervalSeconds.truncatingRemainder(dividingBy: 1.0) == 0
            ? String(Int(intervalSeconds))
            : String(format: "%.2f", intervalSeconds)
        let args = [
            executablePath,
            "record",
            "--db",
            databasePath,
            "--interval",
            intervalStr,
            "--max-db-mb",
            String(max(1, maxDatabaseMB))
        ]
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/\(label).out.log",
            "StandardErrorPath": "/tmp/\(label).err.log"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
           let xml = String(data: data, encoding: .utf8) {
            return xml
        }
        return ""
    }
}
