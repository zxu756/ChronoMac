import Foundation

public final class AnomalyDetector: @unchecked Sendable {
    private var recentSwapBaseline: (ts: Int64, bytes: Int64)?
    private var lastAlertByKind: [AnomalyKind: Int64] = [:]
    private var seenEndpoints: Set<String> = []
    private let cooldownSeconds: Int64
    private let lock = NSLock()

    public init(cooldownSeconds: Int64 = 120) {
        self.cooldownSeconds = cooldownSeconds
    }

    public func evaluate(
        tick: SystemTick,
        processes: [ProcessSample],
        sockets: [SocketFlowRecord]
    ) -> [AnomalyBookmark] {
        lock.lock()
        defer { lock.unlock() }

        var bookmarks: [AnomalyBookmark] = []

        // 1. Swap Surge (>= 512 MB jump within 3 minutes)
        if let base = recentSwapBaseline {
            if tick.ts - base.ts > 180 {
                recentSwapBaseline = (tick.ts, tick.swapUsedBytes)
            } else {
                let jump = tick.swapUsedBytes - base.bytes
                if jump >= 512 * 1024 * 1024, canFire(.swapSurge, now: tick.ts) {
                    let topMem = processes.max(by: { $0.rssBytes < $1.rssBytes })
                    bookmarks.append(
                        AnomalyBookmark(
                            ts: tick.ts,
                            kind: .swapSurge,
                            severity: 3,
                            culpritName: topMem?.name ?? "kernel_task",
                            culpritExec: topMem?.execPath ?? "",
                            metricBadge: "+\(ChronoFormatter.bytes(jump)) swap",
                            summary: "Swap expanded by \(ChronoFormatter.bytes(jump)) to \(ChronoFormatter.bytes(tick.swapUsedBytes)); top resident consumer: \(topMem?.name ?? "system") (\(ChronoFormatter.bytes(topMem?.rssBytes ?? 0)))."
                        )
                    )
                    recentSwapBaseline = (tick.ts, tick.swapUsedBytes)
                }
            }
        } else {
            recentSwapBaseline = (tick.ts, tick.swapUsedBytes)
        }

        // 2. Outbound Network Spike (>= 6 MB/s egress)
        if tick.netOutBps >= 6 * 1024 * 1024, canFire(.egressBurst, now: tick.ts) {
            let topNet = processes.max(by: { $0.netOutBps < $1.netOutBps })
            bookmarks.append(
                AnomalyBookmark(
                    ts: tick.ts,
                    kind: .egressBurst,
                    severity: 2,
                    culpritName: topNet?.name ?? "network",
                    culpritExec: topNet?.execPath ?? "",
                    metricBadge: ChronoFormatter.rate(tick.netOutBps) + " up",
                    summary: "Sustained outbound upload burst (\(ChronoFormatter.rate(tick.netOutBps))) led by \(topNet?.name ?? "unknown")."
                )
            )
        }

        // 3. Runaway Process CPU (>= 220% multi-core saturation)
        if let hot = processes.first(where: { $0.cpuPct >= 220.0 }), canFire(.runawayCPU, now: tick.ts) {
            bookmarks.append(
                AnomalyBookmark(
                    ts: tick.ts,
                    kind: .runawayCPU,
                    severity: 2,
                    culpritName: hot.name,
                    culpritExec: hot.execPath,
                    metricBadge: String(format: "%.0f%% CPU", hot.cpuPct),
                    summary: "\(hot.name) (PID \(hot.pid)) saturated \(String(format: "%.0f%%", hot.cpuPct)) CPU across cores."
                )
            )
        }

        // 4. Thermal Throttling
        if tick.thermalGrade.rawValue >= ThermalGrade.serious.rawValue, canFire(.thermalThrottle, now: tick.ts) {
            let topCPU = processes.max(by: { $0.cpuPct < $1.cpuPct })
            bookmarks.append(
                AnomalyBookmark(
                    ts: tick.ts,
                    kind: .thermalThrottle,
                    severity: 3,
                    culpritName: topCPU?.name ?? "SoC thermal",
                    culpritExec: topCPU?.execPath ?? "",
                    metricBadge: tick.thermalGrade.label,
                    summary: "macOS entered \(tick.thermalGrade.label) thermal state while \(topCPU?.name ?? "system") was active."
                )
            )
        }

        // 5. High-volume new external endpoint (>= 5 MB transfer on unseen host)
        let isInitialSeed = seenEndpoints.isEmpty
        for s in sockets {
            let key = "\(s.execPath)|\(NettopDeltaParser.extractRemoteIP(s.remoteEndpoint))"
            let unseen = seenEndpoints.insert(key).inserted
            if !isInitialSeed && unseen && (s.totalBytesOut + s.totalBytesIn) >= 5 * 1024 * 1024 && canFire(.newExternalHost, now: tick.ts) {
                bookmarks.append(
                    AnomalyBookmark(
                        ts: tick.ts,
                        kind: .newExternalHost,
                        severity: 1,
                        culpritName: s.processName,
                        culpritExec: s.execPath,
                        metricBadge: s.hostname ?? s.remoteEndpoint,
                        summary: "\(s.processName) transferred \(ChronoFormatter.bytes(s.totalBytesOut + s.totalBytesIn)) with new endpoint \(s.hostname ?? s.remoteEndpoint)."
                    )
                )
            }
        }

        return bookmarks
    }

    private func canFire(_ kind: AnomalyKind, now: Int64) -> Bool {
        if let prev = lastAlertByKind[kind], now - prev < cooldownSeconds {
            return false
        }
        lastAlertByKind[kind] = now
        return true
    }
}
