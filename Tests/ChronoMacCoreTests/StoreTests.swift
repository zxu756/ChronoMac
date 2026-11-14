import ChronoMacCore
import Foundation
import Testing

@Suite("Store Tests", .timeLimit(.minutes(1)))
struct StoreTests {
    private static func onDiskStorageBytes(at dbURL: URL) -> Int64 {
        let fm = FileManager.default
        let paths = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"]
        var total: Int64 = 0
        for p in paths {
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let sz = attrs[.size] as? Int64 {
                total += sz
            }
        }
        return total
    }

    @Test("T1: Sliding cutoff across 15s bucket boundary preserves 90% spike and culprit process")
    func slidingBoundaryCompactionPreservesPeak() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-t1-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)

        let bucketBase: Int64 = 1_800_000_000 // exact multiple of 60 and 15
        let spikeTick = SystemTick(
            ts: bucketBase + 2,
            cpuUserPct: 82.0,
            cpuSysPct: 8.0,
            thermalGrade: .serious,
            memUsedBytes: 14_000_000_000,
            memTotalBytes: 24_000_000_000,
            swapUsedBytes: 1_500_000_000,
            diskReadBps: 50_000_000,
            diskWriteBps: 20_000_000,
            netInBps: 1_000_000,
            netOutBps: 8_000_000
        )
        let trailingIdleTick = SystemTick(
            ts: bucketBase + 12,
            cpuUserPct: 8.0,
            cpuSysPct: 2.0,
            thermalGrade: .nominal,
            memUsedBytes: 8_000_000_000,
            memTotalBytes: 24_000_000_000,
            swapUsedBytes: 100_000_000,
            diskReadBps: 0,
            diskWriteBps: 0,
            netInBps: 0,
            netOutBps: 0
        )
        let spikeProc = ProcessSample(
            ts: bucketBase + 2,
            pid: 8888,
            ppid: 1,
            name: "spike-culprit",
            execPath: "/usr/local/bin/spike-culprit",
            cpuPct: 280.0,
            rssBytes: 4_000_000_000
        )
        let idleProc = ProcessSample(
            ts: bucketBase + 12,
            pid: 9999,
            ppid: 1,
            name: "idle-helper",
            execPath: "/usr/local/bin/idle-helper",
            cpuPct: 1.0,
            rssBytes: 20_000_000
        )

        try store.recordSampleBatch(tick: spikeTick, processes: [spikeProc], sockets: [], anomalies: [])
        try store.recordSampleBatch(tick: trailingIdleTick, processes: [idleProc], sockets: [], anomalies: [])

        // Pass 1: cutoff = bucketBase + 7 (splits [bucketBase, bucketBase + 15) in half!)
        try store.runRollupAndRetention(now: bucketBase + 7 + 7_200)
        // Pass 2: 60s later, cutoff = bucketBase + 67 (bucket completely past 2h cutoff)
        try store.runRollupAndRetention(now: bucketBase + 67 + 7_200)

        let compacted = store.queryTicks(from: bucketBase, to: bucketBase + 15)
        #expect(compacted.count == 1)
        #expect(compacted.first?.tier == .rollup15s)
        #expect(compacted.first?.totalCPUPct == 90.0)
        #expect(compacted.first?.swapUsedBytes == 1_500_000_000)

        let (_, blamed) = store.queryNearestProcesses(at: bucketBase + 2, livePIDs: [1])
        #expect(blamed.contains(where: { $0.pid == 8888 && $0.name == "spike-culprit" }))
    }

    @Test("T16: Same timestamp write high peak -> compact to Tier 1 -> write low sample preserves all metric peaks and compacted tier")
    func sameTimestampCompactedPeakPreservedAgainstLateLowSample() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-t16-same-ts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)

        let bucketBase: Int64 = 1_800_000_000 // exact multiple of 60 and 15

        // 1. Write high-value peak sample at ts == bucketBase
        let highPeakTick = SystemTick(
            ts: bucketBase,
            tier: .raw2s,
            cpuUserPct: 85.0,
            cpuSysPct: 10.0, // totalCPUPct == 95.0%
            thermalGrade: .serious,
            memUsedBytes: 18_000_000_000,
            memTotalBytes: 24_000_000_000,
            swapUsedBytes: 3_200_000_000,
            diskReadBps: 120_000_000,
            diskWriteBps: 80_000_000,
            netInBps: 45_000_000,
            netOutBps: 30_000_000,
            loopbackInBps: 200_000_000,
            loopbackOutBps: 200_000_000,
            activeAgentCount: 2,
            activeAgentSummary: "Claude Code, Codex"
        )
        try store.recordSampleBatch(tick: highPeakTick, processes: [], sockets: [], anomalies: [])

        // 2. Compact bucket [bucketBase, bucketBase + 15) into Tier 1 (rollup15s)
        try store.runRollupAndRetention(now: bucketBase + 7_200 + 30)
        let afterCompaction = store.queryTicks(from: bucketBase, to: bucketBase)
        #expect(afterCompaction.count == 1)
        #expect(afterCompaction.first?.tier == .rollup15s)
        #expect(afterCompaction.first?.totalCPUPct == 95.0)

        // 3. Write a low-value raw sample at the EXACT SAME timestamp ts == bucketBase
        let sameTsLowTick = SystemTick(
            ts: bucketBase,
            tier: .raw2s,
            cpuUserPct: 3.0,
            cpuSysPct: 1.0, // totalCPUPct == 4.0%
            thermalGrade: .nominal,
            memUsedBytes: 6_000_000_000,
            memTotalBytes: 24_000_000_000,
            swapUsedBytes: 64_000_000,
            diskReadBps: 4_096,
            diskWriteBps: 2_048,
            netInBps: 1_024,
            netOutBps: 512,
            loopbackInBps: 0,
            loopbackOutBps: 0,
            activeAgentCount: 0,
            activeAgentSummary: ""
        )
        try store.recordSampleBatch(tick: sameTsLowTick, processes: [], sockets: [], anomalies: [])

        // 4. Verify compacted tier and all peak metrics survive without overwrite
        let rows = store.queryTicks(from: bucketBase, to: bucketBase)
        let preserved = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(preserved.tier == .rollup15s)
        #expect(preserved.totalCPUPct == 95.0)
        #expect(preserved.cpuUserPct == 85.0)
        #expect(preserved.cpuSysPct == 10.0)
        #expect(preserved.thermalGrade == .serious)
        #expect(preserved.memUsedBytes == 18_000_000_000)
        #expect(preserved.swapUsedBytes == 3_200_000_000)
        #expect(preserved.diskReadBps == 120_000_000)
        #expect(preserved.diskWriteBps == 80_000_000)
        #expect(preserved.netInBps == 45_000_000)
        #expect(preserved.netOutBps == 30_000_000)
        #expect(preserved.loopbackInBps == 200_000_000)
        #expect(preserved.loopbackOutBps == 200_000_000)
        #expect(preserved.activeAgentCount == 2)
        #expect(preserved.activeAgentSummary == "Claude Code, Codex")
    }

    @Test("T1 Acceptance Row 1: 30-hour synthetic stream (90 spikes every 20m, compaction every 60s) preserves all 90 spikes")
    func thirtyHourSlidingCompactionPreservesAll90Spikes() throws {
        let exportPath = ProcessInfo.processInfo.environment["CHRONOMAC_ROW1_EXPORT_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-t1-30h-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL: URL
        if let exportPath, !exportPath.isEmpty {
            dbURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: exportPath + "-wal")
            try? FileManager.default.removeItem(atPath: exportPath + "-shm")
        } else {
            dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        }
        let store = try FlightboxStore(databaseURL: dbURL)

        let startTs: Int64 = 1_800_000_000
        let totalSeconds: Int64 = 30 * 3600 // 30 hours = 108,000s
        var spikeTimestamps: [Int64] = []
        var lateBufferedFlushesByMinute: [Int: Int64] = [:]
        for idx in 0..<90 {
            let bucket20m = startTs + Int64(idx) * 1200
            let evenOffset: Int64
            if idx % 3 == 0 {
                // Bucket-base spike (B + 0) plus a delayed idle sample arriving right after 2h Tier-1 compaction
                evenOffset = 0
                let flushMinute = (idx * 20) + 121
                if flushMinute < Int(totalSeconds / 60) {
                    lateBufferedFlushesByMinute[flushMinute] = bucket20m + 12
                }
            } else {
                // First-half mid-bucket spike in [B+16, B+22] (< B+23 half-bucket cutoff for both 15s and 60s buckets)
                evenOffset = 16 + Int64((idx % 4) * 2)
            }
            spikeTimestamps.append(bucket20m + evenOffset)
        }
        let spikeIndexByTs = Dictionary(uniqueKeysWithValues: spikeTimestamps.enumerated().map { ($1, $0) })
        #expect(spikeIndexByTs.count == 90)

        // Advance in 60-second increments (1,800 compaction runs), triggering compaction at half-bucket offset (+23s: 23%15==8, 23%60==23)
        for minute in 0..<(Int(totalSeconds / 60)) {
            let winStart = startTs + Int64(minute * 60)
            let winEnd = winStart + 60
            var ts = winStart
            while ts < winEnd {
                let spikeIdx = spikeIndexByTs[ts]
                let isSpike = (spikeIdx != nil)
                let tick = SystemTick(
                    ts: ts,
                    tier: .raw2s,
                    cpuUserPct: isSpike ? 85.0 : 12.0,
                    cpuSysPct: isSpike ? 10.0 : 3.0,
                    thermalGrade: isSpike ? .serious : .nominal,
                    memUsedBytes: isSpike ? 16_000_000_000 : 8_000_000_000,
                    memTotalBytes: 24_000_000_000,
                    swapUsedBytes: isSpike ? 2_000_000_000 : 0,
                    diskReadBps: 0,
                    diskWriteBps: 0,
                    netInBps: 0,
                    netOutBps: 0
                )
                let procs: [ProcessSample]
                if let idx = spikeIdx {
                    procs = [
                        ProcessSample(
                            ts: ts,
                            pid: 9000 + idx,
                            ppid: 1,
                            name: "spike-culprit-\(idx)",
                            execPath: "/usr/local/bin/spike-culprit",
                            cpuPct: 260.0,
                            rssBytes: 2_000_000_000
                        )
                    ]
                } else if (ts - winStart) < 30 && (minute % 20 == 0) {
                    procs = [
                        ProcessSample(
                            ts: ts,
                            pid: 100,
                            ppid: 1,
                            name: "idle-daemon",
                            execPath: "/usr/libexec/idle-daemon",
                            cpuPct: 2.0,
                            rssBytes: 40_000_000
                        )
                    ]
                } else {
                    procs = []
                }
                try store.recordSampleBatch(tick: tick, processes: procs, sockets: [], anomalies: [])
                ts += 2
            }

            if let delayedIdleTs = lateBufferedFlushesByMinute[minute] {
                let lateTick = SystemTick(
                    ts: delayedIdleTs,
                    tier: .raw2s,
                    cpuUserPct: 12.0,
                    cpuSysPct: 3.0,
                    thermalGrade: .nominal,
                    memUsedBytes: 8_000_000_000,
                    memTotalBytes: 24_000_000_000,
                    swapUsedBytes: 0,
                    diskReadBps: 0,
                    diskWriteBps: 0,
                    netInBps: 0,
                    netOutBps: 0
                )
                let lateIdleProc = ProcessSample(
                    ts: delayedIdleTs,
                    pid: 101,
                    ppid: 1,
                    name: "late-idle-flush",
                    execPath: "/usr/libexec/idle-daemon",
                    cpuPct: 1.5,
                    rssBytes: 32_000_000
                )
                try store.recordSampleBatch(tick: lateTick, processes: [lateIdleProc], sockets: [], anomalies: [])
            }

            // Trigger compaction every 60s right in the middle of both 15s (23 % 15 == 8) and 60s (23 % 60 == 23) buckets
            try store.runRollupAndRetention(now: winEnd + 23)
        }

        let finalNow = startTs + totalSeconds + 23
        try store.runRollupAndRetention(now: finalNow)

        let allTicks = store.queryTicks(from: startTs - 60, to: finalNow)
        var survivingSpikes = 0
        var survivingCulprits = 0
        for (idx, spikeTs) in spikeTimestamps.enumerated() {
            let bucket60Start = (spikeTs / 60) * 60
            let hasPeak = allTicks.contains { t in
                t.ts >= bucket60Start && t.ts < bucket60Start + 60 && t.totalCPUPct >= 90.0
            }
            if hasPeak {
                survivingSpikes += 1
            }
            let (_, blamed) = store.queryNearestProcesses(at: spikeTs, livePIDs: [1])
            if blamed.contains(where: { $0.name == "spike-culprit-\(idx)" }) {
                survivingCulprits += 1
            }
        }
        #expect(survivingSpikes == 90)
        #expect(survivingCulprits == 90)
    }

    @Test("T2 Acceptance Row 2: 2 MB storage cap trims 10 MB of <48h data including WAL and reclaims free pages")
    func enforcesTwoMegabyteCapWithinFortyEightHoursIncludingWAL() throws {
        let exportPath = ProcessInfo.processInfo.environment["CHRONOMAC_ROW2_EXPORT_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-t2-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL: URL
        if let exportPath, !exportPath.isEmpty {
            dbURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: exportPath + "-wal")
            try? FileManager.default.removeItem(atPath: exportPath + "-shm")
        } else {
            dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        }
        let twoMB: Int64 = 2 * 1024 * 1024
        let tenMB: Int64 = 10 * 1024 * 1024
        let store = try FlightboxStore(databaseURL: dbURL, maxDatabaseBytes: twoMB)

        let baseTs: Int64 = 1_800_100_000
        let paddingPath = "/Applications/HeavySuite.app/Contents/MacOS/" + String(repeating: "SubModuleWorker_", count: 14)

        var step: Int64 = 0
        var latestTs = baseTs
        while Self.onDiskStorageBytes(at: dbURL) < tenMB {
            let ts = baseTs + step * 2
            latestTs = ts
            let tick = SystemTick(
                ts: ts,
                cpuUserPct: 35.0,
                cpuSysPct: 10.0,
                memUsedBytes: 12_000_000_000,
                memTotalBytes: 24_000_000_000,
                swapUsedBytes: 256_000_000,
                diskReadBps: 4_096_000,
                diskWriteBps: 2_048_000,
                netInBps: 512_000,
                netOutBps: 256_000,
                activeAgentCount: 1,
                activeAgentSummary: "Claude Code, OpenCode"
            )
            var procs: [ProcessSample] = []
            for pIdx in 0..<24 {
                procs.append(
                    ProcessSample(
                        ts: ts,
                        pid: 10_000 + pIdx,
                        ppid: 1,
                        name: "worker-\(pIdx)",
                        execPath: "\(paddingPath)_\(pIdx)",
                        bundleID: "com.example.heavy.worker.\(pIdx)",
                        signingTeam: "TEAM123456",
                        cpuPct: Double(pIdx) * 3.5,
                        rssBytes: Int64(100_000_000 + pIdx * 5_000_000)
                    )
                )
            }
            try store.recordSampleBatch(tick: tick, processes: procs, sockets: [], anomalies: [])
            step += 1
        }

        // Verify all inserted timestamps are strictly within a <48h window before `retentionNow`
        let retentionNow = latestTs + 2
        #expect(retentionNow - baseTs < 48 * 3600)

        let beforeBytes = Self.onDiskStorageBytes(at: dbURL)
        #expect(beforeBytes >= tenMB)

        try store.runRollupAndRetention(now: retentionNow)

        let afterBytes = Self.onDiskStorageBytes(at: dbURL)
        #expect(afterBytes <= twoMB)
        #expect(store.totalStorageBytes() == afterBytes)
        #expect(afterBytes > 32 * 1024)

        let remainingTicks = store.queryTicks(from: baseTs, to: retentionNow)
        #expect(!remainingTicks.isEmpty)
        #expect(remainingTicks.last?.ts == latestTs)
    }

    @Test("DB path resolution (--db & CHRONOMAC_DB_PATH), read-only safety, and 3-way CPU/Memory/Network rankings")
    func databaseResolutionReadOnlyAndThreeWaySort() throws {
        let cliResolved = FlightboxStore.resolveDatabaseURL(
            arguments: ["ChronoMac", "--cli", "status", "--db", "/tmp/cli-override.sqlite"],
            environment: ["CHRONOMAC_DB_PATH": "/tmp/env-fallback.sqlite"]
        )
        #expect(cliResolved.path == "/tmp/cli-override.sqlite")

        let envResolved = FlightboxStore.resolveDatabaseURL(
            arguments: ["ChronoMac", "--cli", "status"],
            environment: ["CHRONOMAC_DB_PATH": "/tmp/env-override.sqlite"]
        )
        #expect(envResolved.path == "/tmp/env-override.sqlite")

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-t7-sort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let missingURL = tmpDir.appendingPathComponent("nonexistent.sqlite")

        // Read-only store on missing DB must not create files or directories
        let roMissing = try FlightboxStore(databaseURL: missingURL, readOnly: true)
        #expect(roMissing.queryTicks(from: 0, to: 9_999_999_999).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))

        let dbURL = tmpDir.appendingPathComponent("sort.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)
        let ts: Int64 = 1_800_200_000
        let cpuLeader = ProcessSample(
            ts: ts, pid: 101, ppid: 1, name: "cpu-hog", execPath: "/usr/bin/cpu-hog",
            cpuPct: 190.0, rssBytes: 20_000_000, netOutBps: 0
        )
        let memLeader = ProcessSample(
            ts: ts, pid: 102, ppid: 1, name: "mem-hog", execPath: "/usr/bin/mem-hog",
            cpuPct: 2.0, rssBytes: 6_000_000_000, netOutBps: 0
        )
        let netLeader = ProcessSample(
            ts: ts, pid: 103, ppid: 1, name: "net-hog", execPath: "/usr/bin/net-hog",
            cpuPct: 1.0, rssBytes: 12_000_000, netInBps: 5_000_000, netOutBps: 20_000_000
        )
        let rootUnreadable = ProcessSample(
            ts: ts, pid: 168, ppid: 1, name: "WindowServer", execPath: "/System/Library/WindowServer",
            cpuPct: 0, rssBytes: 0, isCPUReadable: false
        )

        try store.recordSampleBatch(
            tick: SystemTick(
                ts: ts, cpuUserPct: 50, cpuSysPct: 10, memUsedBytes: 10_000_000_000,
                memTotalBytes: 24_000_000_000, swapUsedBytes: 0, diskReadBps: 0, diskWriteBps: 0,
                netInBps: 5_000_000, netOutBps: 20_000_000, loopbackInBps: 100_000_000, loopbackOutBps: 100_000_000
            ),
            processes: [cpuLeader, memLeader, netLeader, rootUnreadable],
            sockets: [],
            anomalies: []
        )

        let (_, byCPU) = store.queryNearestProcesses(at: ts, sortBy: .cpu)
        #expect(byCPU.first?.name == "cpu-hog")
        let ws = try #require(byCPU.first(where: { $0.name == "WindowServer" }))
        #expect(ws.isCPUReadable == false)
        #expect(ws.formattedCPU(in: .en) == "No permission")
        #expect(ws.formattedCPU(in: .zhHans) == "无权限")

        let (_, byMem) = store.queryNearestProcesses(at: ts, sortBy: .memory)
        #expect(byMem.first?.name == "mem-hog")

        let (_, byNet) = store.queryNearestProcesses(at: ts, sortBy: .network)
        #expect(byNet.first?.name == "net-hog")
    }
}
