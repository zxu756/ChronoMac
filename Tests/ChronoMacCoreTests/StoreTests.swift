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
        for idx in 0..<90 {
            // Deliberately vary spike position across start/middle/end of 15s & 60s buckets
            let offset = Int64((idx * 7) % 58)
            let evenOffset = (offset / 2) * 2
            spikeTimestamps.append(startTs + Int64(idx) * 1200 + evenOffset)
        }
        let spikeSet = Set(spikeTimestamps)
        #expect(spikeSet.count == 90)

        // Advance in 60-second increments (1,800 compaction runs), using unaligned cutoff (+7s)
        for minute in 0..<(Int(totalSeconds / 60)) {
            let winStart = startTs + Int64(minute * 60)
            let winEnd = winStart + 60
            var ts = winStart
            while ts < winEnd {
                let isSpike = spikeSet.contains(ts)
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
                try store.recordSampleBatch(tick: tick, processes: [], sockets: [], anomalies: [])
                ts += 2
            }
            // Trigger compaction every 60s with a sliding unaligned timestamp (+7s)
            try store.runRollupAndRetention(now: winEnd + 7)
        }

        let finalNow = startTs + totalSeconds + 7
        try store.runRollupAndRetention(now: finalNow)

        let allTicks = store.queryTicks(from: startTs - 60, to: finalNow)
        var survivingSpikes = 0
        for spikeTs in spikeTimestamps {
            let bucket60Start = (spikeTs / 60) * 60
            let hasPeak = allTicks.contains { t in
                t.ts >= bucket60Start && t.ts < bucket60Start + 60 && t.totalCPUPct >= 90.0
            }
            if hasPeak {
                survivingSpikes += 1
            }
        }
        #expect(survivingSpikes == 90)
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
