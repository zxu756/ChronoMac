import ChronoMacCore
import Darwin
import Foundation
import Testing

private final class StubSystemSampler: SystemSamplerProtocol, @unchecked Sendable {
    var totalMemoryBytes: Int64 = 24 * 1024 * 1024 * 1024
    var hostReading = HostStateReading(
        cpuUserPct: 42.0,
        cpuSysPct: 8.0,
        thermal: .nominal,
        memUsedBytes: 12_000_000_000,
        memTotalBytes: 24 * 1024 * 1024 * 1024,
        swapUsedBytes: 256_000_000
    )
    var netResult = NettopSnapshotResult(
        perPIDBytesInDelta: [4444: 2_000_000],
        perPIDBytesOutDelta: [4444: 5_000_000],
        perPIDLoopbackInBps: [8080: 100_000_000],
        perPIDLoopbackOutBps: [8080: 100_000_000],
        externalSocketDeltas: [
            NettopSocketDelta(
                pid: 4444,
                processName: "ephemeral-worker",
                protocolName: "tcp4",
                remoteEndpoint: "54.231.10.20:443",
                deltaBytesIn: 4_000_000,
                deltaBytesOut: 10_000_000
            )
        ],
        totalInBps: 2_000_000,
        totalOutBps: 5_000_000,
        loopbackRxBytesPerSec: 100_000_000,
        loopbackTxBytesPerSec: 100_000_000
    )
    var procSnapshot = ProcessTreeSnapshot(
        processes: [
            ProcessSample(
                ts: 10_000,
                pid: 3333,
                ppid: 1,
                name: "swift-frontend",
                execPath: "/usr/bin/swift-frontend",
                cpuPct: 185.0,
                rssBytes: 1_500_000_000
            )
        ],
        totalDiskReadBps: 8_000_000,
        totalDiskWriteBps: 4_000_000,
        livePIDs: [1, 3333]
    )
    var resolvedPaths: [Int: String] = [:]

    func sampleHostState() -> HostStateReading { hostReading }
    func sampleCalibratedHostState(interval: TimeInterval) -> HostStateReading { hostReading }
    func sampleNetwork(now: TimeInterval) -> NettopSnapshotResult { netResult }
    func sampleProcesses(
        ts: Int64,
        netInBpsByPID: [Int: Int64],
        netOutBpsByPID: [Int: Int64],
        limit: Int
    ) -> ProcessTreeSnapshot {
        procSnapshot
    }
    func resolveExecutablePath(pid: Int) -> String {
        resolvedPaths[pid] ?? ""
    }
    func currentLivePIDs() -> Set<Int> {
        procSnapshot.livePIDs
    }
    func detectAgentActivity(now: Int64) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow]) {
        (1, "OpenCode", [AgentBurstWindow(id: "oc-1", vendor: "OpenCode", workspace: "ChronoMac", startTs: now - 120, endTs: now)])
    }
}

@Suite("Sampler Tests", .timeLimit(.minutes(1)))
struct SamplerTests {
    @Test("T3: Synthetic nettop CSV with 200 MB loopback transfer separates loopback counter, excludes it from external rates, and triggers 0 anomalies")
    func loopbackTrafficExcludedFromExternalRatesAndAnomalies() {
        let parser = NettopDeltaParser()
        let tick1 = """
        ,interface,state,bytes_in,bytes_out,
        local-proxy.8080,,,1000,1000,
        tcp4 127.0.0.1:51000<->127.0.0.1:8080,lo0,Established,1000,1000,
        tcp6 ::1.52000<->::1.8081,lo0,Established,500,500,
        """
        _ = parser.ingestCSV(tick1, now: 1_000.0)

        // 200 MB transferred over 127.0.0.1 (lo0) in 2 seconds
        let twoHundredMB = 200 * 1024 * 1024
        let tick2 = """
        ,interface,state,bytes_in,bytes_out,
        local-proxy.8080,,,\(1500 + twoHundredMB),\(1500 + twoHundredMB),
        tcp4 127.0.0.1:51000<->127.0.0.1:8080,lo0,Established,\(1000 + twoHundredMB),\(1000 + twoHundredMB),
        tcp6 ::1.52000<->::1.8081,lo0,Established,500,500,
        """
        let res = parser.ingestCSV(tick2, now: 1_002.0)

        // External inbound & outbound must be strictly 0!
        #expect(res.totalInBps == 0)
        #expect(res.totalOutBps == 0)
        #expect((res.perPIDBytesInDelta[8080] ?? 0) == 0)
        #expect((res.perPIDBytesOutDelta[8080] ?? 0) == 0)
        #expect(res.externalSocketDeltas.isEmpty)

        // Dedicated loopback counter records 100 MB/s (200 MB / 2s)
        #expect(res.loopbackRxBytesPerSec == Int64(twoHundredMB / 2))
        #expect(res.loopbackTxBytesPerSec == Int64(twoHundredMB / 2))

        let detector = AnomalyDetector()
        let sysTick = SystemTick(
            ts: 1002,
            cpuUserPct: 15,
            cpuSysPct: 5,
            memUsedBytes: 8_000_000_000,
            memTotalBytes: 24_000_000_000,
            swapUsedBytes: 0,
            diskReadBps: 0,
            diskWriteBps: 0,
            netInBps: res.totalInBps,
            netOutBps: res.totalOutBps,
            loopbackInBps: res.loopbackRxBytesPerSec,
            loopbackOutBps: res.loopbackTxBytesPerSec
        )
        let anomalies = detector.evaluate(tick: sysTick, processes: [], sockets: [])
        #expect(anomalies.isEmpty)
    }

    @Test("T3 & T13: Post-baseline newly appearing PID attributes first-seen socket bytes and accumulates subsequent deltas")
    func postBaselineNewProcessFirstSightingAndSubsequentDelta() {
        let parser = NettopDeltaParser()
        let tick0 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        """
        let baseline = parser.ingestCSV(tick0, now: 2_000.0)
        // Global Tick 1 establishes baseline without attributing pre-existing socket history
        #expect(baseline.totalInBps == 0)
        #expect(baseline.externalSocketDeltas.isEmpty)

        // PID 55555 appears AFTER global baseline at t=2002 (dt=2s) with 50,000,000 B inbound / 100,000 B outbound
        let tick1 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        downloader.55555,,,50000000,100000,
        tcp4 192.168.1.10:50123<->104.16.132.229:443,en0,Established,50000000,100000,
        """
        let firstSight = parser.ingestCSV(tick1, now: 2_002.0)
        #expect(firstSight.perPIDBytesInDelta[55555] == 25_000_000)
        #expect(firstSight.perPIDBytesOutDelta[55555] == 50_000)
        #expect(firstSight.externalSocketDeltas.count == 1)
        #expect(firstSight.externalSocketDeltas.first?.deltaBytesIn == 50_000_000)
        #expect(firstSight.externalSocketDeltas.first?.deltaBytesOut == 100_000)

        // Next tick (t=2004, dt=2s): PID 55555 downloads +8,000,000 bytes -> 4,000,000 B/s
        let tick2 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        downloader.55555,,,58000000,120000,
        tcp4 192.168.1.10:50123<->104.16.132.229:443,en0,Established,58000000,120000,
        """
        let secondSight = parser.ingestCSV(tick2, now: 2_004.0)
        #expect(secondSight.perPIDBytesInDelta[55555] == 4_000_000)
        #expect(secondSight.perPIDBytesOutDelta[55555] == 10_000)
        #expect(secondSight.externalSocketDeltas.count == 1)
        #expect(secondSight.externalSocketDeltas.first?.deltaBytesIn == 8_000_000)
    }

    @Test("T13: Two-tick CSV where curl.999 newly appears on Tick 2 with 40 MB attributes 40 MB to curl.999 instead of dropping to 0")
    func postBaselineNewProcessTrafficAttributedNotDropped() {
        let fortyMB: Int64 = 40_000_000

        // Uncollapsed nettop -L 1 CSV (with socket rows, including quic/tcp)
        let parser = NettopDeltaParser()
        let tick1 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,12000,8000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,12000,8000,
        """
        let base = parser.ingestCSV(tick1, now: 5_000.0)
        #expect(base.totalInBps == 0)

        let tick2 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,12000,8000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,12000,8000,
        curl.999,,,\(fortyMB),64000,
        tcp4 192.168.1.10:54321<->151.101.1.140:443,en0,Established,\(fortyMB),64000,
        """
        let res = parser.ingestCSV(tick2, now: 5_002.0) // dt = 2.0s
        #expect(res.perPIDBytesInDelta[999] == fortyMB / 2)
        #expect(res.perPIDBytesOutDelta[999] == 32_000)
        #expect(res.totalInBps == fortyMB / 2)
        #expect(res.externalSocketDeltas.count == 1)
        #expect(res.externalSocketDeltas.first?.pid == 999)
        #expect(res.externalSocketDeltas.first?.processName == "curl")
        #expect(res.externalSocketDeltas.first?.deltaBytesIn == fortyMB)

        // Process-summary-only rows without per-socket child rows lack interface/endpoint tags and must not fabricate external traffic
        let summaryOnlyParser = NettopDeltaParser()
        let pTick1 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,12000,8000,
        """
        _ = summaryOnlyParser.ingestCSV(pTick1, now: 6_000.0)
        let pTick2 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,12000,8000,
        curl.999,,,\(fortyMB),64000,
        """
        let pRes = summaryOnlyParser.ingestCSV(pTick2, now: 6_002.0)
        #expect(pRes.totalInBps == 0)
        #expect(pRes.externalSocketDeltas.isEmpty)
    }

    @Test("T17: Empty and header-only nettop CSV ticks do not consume initial baseline")
    func emptyOrHeaderOnlyTicksDoNotConsumeInitialBaseline() {
        let parser = NettopDeltaParser()

        // Tick 1: completely empty output
        let emptyRes = parser.ingestCSV("", now: 100.0)
        #expect(emptyRes.totalInBps == 0)
        #expect(emptyRes.externalSocketDeltas.isEmpty)

        // Tick 2: header-only output (0 parsed data rows)
        let headerOnlyRes = parser.ingestCSV(",interface,state,bytes_in,bytes_out,\n", now: 102.0)
        #expect(headerOnlyRes.totalInBps == 0)
        #expect(headerOnlyRes.externalSocketDeltas.isEmpty)

        // Tick 3: first non-empty snapshot with pre-existing 40 MB socket MUST establish baseline (delta == 0)
        let firstNonEmpty = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,40000000,8000000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,40000000,8000000,
        """
        let baseRes = parser.ingestCSV(firstNonEmpty, now: 104.0)
        #expect(baseRes.totalInBps == 0)
        #expect(baseRes.totalOutBps == 0)
        #expect(baseRes.perPIDBytesInDelta.isEmpty)
        #expect(baseRes.externalSocketDeltas.isEmpty)

        // Tick 4 (dt = 2.0s): +2 MB inbound delta -> 1 MB/s
        let nextTick = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,42000000,8000000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,42000000,8000000,
        """
        let deltaRes = parser.ingestCSV(nextTick, now: 106.0)
        #expect(deltaRes.totalInBps == 1_000_000)
        #expect(deltaRes.externalSocketDeltas.count == 1)
        #expect(deltaRes.externalSocketDeltas.first?.deltaBytesIn == 2_000_000)
    }

    @Test("T17: Transiently absent socket across 1..60 ticks retains lastSeen counter without bogus cumulative spike, evicts >60 absent ticks, and handles counter reset")
    func retainedSocketWindowPreventsCumulativeInflationEvictsOldAndHandlesReset() {
        let parser = NettopDeltaParser()
        #expect(parser.maxAbsentTicks == 60)
        let fortyMB: Int64 = 40_000_000
        let fortyTwoMB: Int64 = 42_000_000

        let apsdOnly = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        """
        let withCurl40MB = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        curl.999,,,\(fortyMB),100000,
        tcp4 192.168.1.10:54321<->151.101.1.140:443,en0,Established,\(fortyMB),100000,
        """
        let withCurl42MB = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        curl.999,,,\(fortyTwoMB),100000,
        tcp4 192.168.1.10:54321<->151.101.1.140:443,en0,Established,\(fortyTwoMB),100000,
        """

        // Tick 1 (t=1000): curl.999 present at 40 MB on baseline
        var now = 1_000.0
        let t1 = parser.ingestCSV(withCurl40MB, now: now)
        #expect(t1.totalInBps == 0)
        #expect(parser.trackedSocketCount == 2)

        // Tick 2 (t=1002): curl.999 transiently absent for 1 tick -> still retained
        now += 2.0
        let t2 = parser.ingestCSV(apsdOnly, now: now)
        #expect(t2.totalInBps == 0)
        #expect(parser.trackedSocketCount == 2)

        // Tick 3 (t=1004): curl.999 reappears with same 40 MB -> delta MUST be 0 (NOT +40 MB!)
        now += 2.0
        let t3 = parser.ingestCSV(withCurl40MB, now: now)
        #expect(t3.totalInBps == 0)
        #expect((t3.perPIDBytesInDelta[999] ?? 0) == 0)
        #expect(t3.externalSocketDeltas.isEmpty)

        // Absent for 10 consecutive ticks, then reappears with 42 MB -> delta MUST be 2 MB (1 MB/s over dt=2s)
        for _ in 0..<10 {
            now += 2.0
            _ = parser.ingestCSV(apsdOnly, now: now)
        }
        #expect(parser.trackedSocketCount == 2)
        now += 2.0
        let after10Absent = parser.ingestCSV(withCurl42MB, now: now)
        #expect(after10Absent.perPIDBytesInDelta[999] == 1_000_000)
        #expect(after10Absent.totalInBps == 1_000_000)
        #expect(after10Absent.externalSocketDeltas.count == 1)
        #expect(after10Absent.externalSocketDeltas.first?.deltaBytesIn == 2_000_000)

        // Counter reset while retained (absent 2 ticks, then reappears with smaller counter 1,500,000 < 42,000,000) -> delta == current (1,500,000)
        for _ in 0..<2 {
            now += 2.0
            _ = parser.ingestCSV(apsdOnly, now: now)
        }
        now += 2.0
        let withCurlReset = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        curl.999,,,1500000,20000,
        tcp4 192.168.1.10:54321<->151.101.1.140:443,en0,Established,1500000,20000,
        """
        let resetRes = parser.ingestCSV(withCurlReset, now: now)
        #expect(resetRes.perPIDBytesInDelta[999] == 750_000)
        #expect(resetRes.perPIDBytesOutDelta[999] == 10_000)
        #expect(resetRes.externalSocketDeltas.first?.deltaBytesIn == 1_500_000)
        #expect(resetRes.externalSocketDeltas.first?.deltaBytesOut == 20_000)

        // Absent for 60 ticks (boundary of maxAbsentTicks == 60): still retained
        for _ in 0..<60 {
            now += 2.0
            _ = parser.ingestCSV(apsdOnly, now: now)
        }
        #expect(parser.trackedSocketCount == 2)

        // 61st consecutive absent tick (> maxAbsentTicks == 60): curl.999 evicted so memory stays bounded!
        now += 2.0
        _ = parser.ingestCSV(apsdOnly, now: now)
        #expect(parser.trackedSocketCount == 1)

        // Reappearing with 1,500,000 B after eviction is treated as a brand-new post-baseline connection (delta == 1,500,000)
        now += 2.0
        let afterEviction = parser.ingestCSV(withCurlReset, now: now)
        #expect(afterEviction.externalSocketDeltas.first?.deltaBytesIn == 1_500_000)
        #expect(parser.trackedSocketCount == 2)
    }

    @Test("T15 & T19: Synthetic +1 MiB loopback CSV with Listen empty cells verifies exact 524,288 B/s loopback rate")
    func syntheticLoopbackOneMiBDeltaAndEmptyListenCells() {
        let parser = NettopDeltaParser()
        // Synthetic two-tick fixture modeling +1 MiB (1,048,576 B) over 2.0s on 127.0.0.1 alongside an empty-cell Listen row
        let snap1 = """
        ,interface,state,bytes_in,bytes_out,
        Python.49642,,,0,0,
        tcp4 127.0.0.1:63002<->127.0.0.1:63003,lo0,Established,0,0,
        tcp4 127.0.0.1:63003<->127.0.0.1:63002,lo0,Established,0,0,
        tcp4 127.0.0.1:63002<->*:*,lo0,Listen,,,
        """
        _ = parser.ingestCSV(snap1, now: 3_000.0)

        let snap2 = """
        ,interface,state,bytes_in,bytes_out,
        Python.49642,,,1048576,1048576,
        tcp4 127.0.0.1:63002<->127.0.0.1:63003,lo0,Established,1048576,0,
        tcp4 127.0.0.1:63003<->127.0.0.1:63002,lo0,Established,0,1048576,
        tcp4 127.0.0.1:63002<->*:*,lo0,Listen,,,
        """
        let res = parser.ingestCSV(snap2, now: 3_002.0)
        #expect(res.totalInBps == 0)
        #expect(res.totalOutBps == 0)
        #expect(res.externalSocketDeltas.isEmpty)
        #expect(res.loopbackRxBytesPerSec == 524_288)
        #expect(res.loopbackTxBytesPerSec == 524_288)
    }

    @Test("T19: Verbatim unedited 2-tick stdout captured via /usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out")
    func verbatimUneditedConsecutiveNettopCapturesParseCleanly() {
        // 1. Two consecutive unedited snapshots captured verbatim on macOS arm64 via:
        //    `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out -p 61965`
        //    before and after sending 321,000 bytes over a local 127.0.0.1 socket (512 -> 321,512).
        let loopbackParser = NettopDeltaParser()
        let rawSnap1 = """
        ,interface,state,bytes_in,bytes_out,
        Python.61965,,,512,512,
        tcp4 127.0.0.1:52547<->127.0.0.1:52548,lo0,Established,512,0,
        tcp4 127.0.0.1:52548<->127.0.0.1:52547,lo0,Established,0,512,
        tcp4 127.0.0.1:52547<->*:*,lo0,Listen,,,
        """
        let r1 = loopbackParser.ingestCSV(rawSnap1, now: 4_000.0)
        #expect(r1.totalInBps == 0)
        #expect(r1.loopbackRxBytesPerSec == 0)

        let rawSnap2 = """
        ,interface,state,bytes_in,bytes_out,
        Python.61965,,,321512,321512,
        tcp4 127.0.0.1:52547<->127.0.0.1:52548,lo0,Established,321512,0,
        tcp4 127.0.0.1:52548<->127.0.0.1:52547,lo0,Established,0,321512,
        tcp4 127.0.0.1:52547<->*:*,lo0,Listen,,,
        """
        let r2 = loopbackParser.ingestCSV(rawSnap2, now: 4_002.0) // dt = 2.0s, delta = 321,000 B -> 160,500 B/s
        #expect(r2.totalInBps == 0)
        #expect(r2.totalOutBps == 0)
        #expect(r2.externalSocketDeltas.isEmpty)
        #expect(r2.loopbackRxBytesPerSec == 160_500)
        #expect(r2.loopbackTxBytesPerSec == 160_500)

        // 2. Two consecutive unedited snapshots captured verbatim on macOS arm64 via:
        //    `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out -p 0`
        //    verifying >32-bit Int64 cumulative byte counters (7,936,865,216 > Int32.max).
        let kernelParser = NettopDeltaParser()
        let kernelSnap1 = """
        ,interface,state,bytes_in,bytes_out,
        kernel_task.0,,,7936865216,52461484,
        tcp4 127.0.0.1:49426<->127.0.0.1:49424,lo0,Established,7936865216,52461484,
        """
        let kernelSnap2 = """
        ,interface,state,bytes_in,bytes_out,
        kernel_task.0,,,7936865216,52461484,
        tcp4 127.0.0.1:49426<->127.0.0.1:49424,lo0,Established,7936865216,52461484,
        """
        _ = kernelParser.ingestCSV(kernelSnap1, now: 4_100.0)
        let kRes = kernelParser.ingestCSV(kernelSnap2, now: 4_102.0)
        #expect(kRes.totalInBps == 0)
        #expect(kRes.loopbackRxBytesPerSec == 0)
    }

    @Test("T20: Recorded real 2-tick nettop loopback fixture file parses non-zero per-PID loopback delta with zero external inflation")
    func t20RecordedTwoTickNettopLoopbackFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/recorded_nettop_loopback_2tick_2026-11-15.txt")
        let rawText = try String(contentsOf: fixtureURL, encoding: .utf8)
        #expect(rawText.contains("2026-11-15"))
        #expect(!rawText.lowercased().contains("synthetic fixture"))

        let nonCommentLines = rawText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        let sections = nonCommentLines.components(separatedBy: "=== TICK 2 ===")
        #expect(sections.count == 2)
        let tick1 = sections[0].replacingOccurrences(of: "=== TICK 1 ===", with: "")
        let tick2 = sections[1]

        let parser = NettopDeltaParser()
        let r1 = parser.ingestCSV(tick1, now: 10_000.0)
        #expect(r1.totalInBps == 0)
        #expect(r1.loopbackRxBytesPerSec == 0)

        // Tick 1 -> Tick 2 transferred 655,360 bytes (2,048 -> 657,408) over dt = 2.0s -> 327,680 B/s on PID 9122
        let r2 = parser.ingestCSV(tick2, now: 10_002.0)
        #expect(r2.totalInBps == 0)
        #expect(r2.totalOutBps == 0)
        #expect(r2.externalSocketDeltas.isEmpty)
        #expect(r2.loopbackRxBytesPerSec == 327_680)
        #expect(r2.loopbackTxBytesPerSec == 327_680)
        #expect(r2.perPIDLoopbackInBps[9122] == 327_680)
        #expect(r2.perPIDLoopbackOutBps[9122] == 327_680)
    }

    @Test("T7 (M1): /bin/ps time parser and non-root sampler read WindowServer (UID 88) and launchd (UID 0) CPU without sudo while kernel_task (PID 0) stays No permission")
    func t7NonRootReadsWindowServerAndRootCPUWhileKernelTaskStaysUnreadable() throws {
        // 1. Unit-verify cumulative ps CPU time formats: MM:SS.ss, HHH:MM.ss, DD-HH:MM:SS.ss
        let centi5Ns: UInt64 = 50_000_000
        let min12Sec34Ns: UInt64 = UInt64(12 * 60 + 34) * 1_000_000_000 + 560_000_000
        let min2026Ns: UInt64 = UInt64(2026 * 60 + 27) * 1_000_000_000 + 280_000_000
        let twoDaysSec: UInt64 = 2 * 86_400 + 3 * 3_600 + 4 * 60 + 5
        let twoDaysNs: UInt64 = twoDaysSec * 1_000_000_000 + 250_000_000
        #expect(ProcessTreeSampler.parsePsTimeToNanoseconds("0:00.05") == centi5Ns)
        #expect(ProcessTreeSampler.parsePsTimeToNanoseconds("12:34.56") == min12Sec34Ns)
        #expect(ProcessTreeSampler.parsePsTimeToNanoseconds("2026:27.28") == min2026Ns)
        #expect(ProcessTreeSampler.parsePsTimeToNanoseconds("2-03:04:05.25") == twoDaysNs)

        let syntheticPs = """
            1   0.4  24576   14:20.10
          168  42.5  65536 2026:27.28
        """
        let parsedMap = ProcessTreeSampler.parsePsSnapshot(syntheticPs)
        #expect(parsedMap[1]?.rssBytes == Int64(25_165_824))
        #expect(parsedMap[168]?.instantCPUPct == 42.5)
        #expect(parsedMap[168]?.rssBytes == Int64(67_108_864))

        // 2. Live non-root verification on this Mac (zero sudo): launchd (PID 1) and WindowServer (if running) are readable,
        //    whereas kernel_task (PID 0) genuinely remains unreadable (isCPUReadable == false -> "No permission" / "无权限").
        #expect(geteuid() != 0)
        let sampler = ProcessTreeSampler()
        _ = sampler.sampleTopProcesses(ts: 2_000, netInBpsByPID: [:], netOutBpsByPID: [:], limit: 300)
        Thread.sleep(forTimeInterval: 0.30)
        let (procs, _, _, _) = sampler.sampleTopProcesses(ts: 2_001, netInBpsByPID: [:], netOutBpsByPID: [:], limit: 300)

        let launchdProc = try #require(procs.first(where: { $0.pid == 1 }))
        #expect(launchdProc.isCPUReadable == true)
        #expect(launchdProc.memoryFootprintBytes > 0)

        if let windowServer = procs.first(where: { $0.name == "WindowServer" }) {
            #expect(windowServer.isCPUReadable == true)
            #expect(windowServer.memoryFootprintBytes > 0)
            #expect(windowServer.formattedCPU(in: .en) != "No permission")
            #expect(windowServer.formattedCPU(in: .zhHans) != "无权限")
        }

        let kernelTask = try #require(procs.first(where: { $0.pid == 0 }))
        #expect(kernelTask.name == "kernel_task")
        #expect(kernelTask.isCPUReadable == false)
        #expect(kernelTask.formattedCPU(in: .en) == "No permission")
        #expect(kernelTask.formattedCPU(in: .zhHans) == "无权限")
    }

    @Test("M1 Item 2: Live 64-bit PhysicalNICCounterReader matches /usr/sbin/netstat -ib physical external interfaces and excludes lo0/utun/bridge")
    func m1LivePhysicalNICCounterMatchesNetstatIB() throws {
        let netstatProc = Process()
        netstatProc.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        netstatProc.arguments = ["-ib"]
        let pipe = Pipe()
        netstatProc.standardOutput = pipe
        try netstatProc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        netstatProc.waitUntilExit()
        let netstatText = try #require(String(data: data, encoding: .utf8))

        let parsedNetstat = PhysicalNICCounterReader.parseNetstatIB(netstatText)
        let liveSysctl = PhysicalNICCounterReader.readLiveCounters()

        #expect(liveSysctl.interfaces["lo0"]?.isLoopback == true)
        #expect(liveSysctl.interfaces["lo0"]?.isPhysicalExternal == false)

        // Every active en* physical interface must match netstat -ib within small live traffic tolerance (< 5 MiB)
        for (ifName, nsEntry) in parsedNetstat.interfaces where nsEntry.isPhysicalExternal {
            guard let sysEntry = liveSysctl.interfaces[ifName] else {
                Issue.record("Missing interface \(ifName) in sysctl NET_RT_IFLIST2 snapshot")
                continue
            }
            #expect(sysEntry.isPhysicalExternal == true)
            let diffIn = sysEntry.bytesIn >= nsEntry.bytesIn ? sysEntry.bytesIn - nsEntry.bytesIn : nsEntry.bytesIn - sysEntry.bytesIn
            let diffOut = sysEntry.bytesOut >= nsEntry.bytesOut ? sysEntry.bytesOut - nsEntry.bytesOut : nsEntry.bytesOut - sysEntry.bytesOut
            #expect(diffIn < 5 * 1024 * 1024)
            #expect(diffOut < 5 * 1024 * 1024)
        }
    }

    @Test("M1 Item 2: Physical NIC calibration on 200 MB loopback + 40 MB en1 download attributes >=80% to curl, puts 4 MB residual in Unattributed/未归属, and smears 0 bytes onto apsd")
    @MainActor
    func m1PhysicalNICCalibrationFortyMBAndLoopbackIsolation() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic_nic_40mb_calibration.txt")
        let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
        #expect(raw.contains("SYNTHETIC FIXTURE"))

        let clean = raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        let s1 = clean.components(separatedBy: "=== NETSTAT TICK 2 ===")
        #expect(s1.count == 2)
        let netstatTick1 = s1[0].replacingOccurrences(of: "=== NETSTAT TICK 1 ===", with: "")
        let s2 = s1[1].components(separatedBy: "=== NETTOP TICK 1 ===")
        #expect(s2.count == 2)
        let netstatTick2 = s2[0]
        let s3 = s2[1].components(separatedBy: "=== NETTOP TICK 2 ===")
        #expect(s3.count == 2)
        let nettopTick1 = s3[0]
        let nettopTick2 = s3[1]

        let nic1 = PhysicalNICCounterReader.parseNetstatIB(netstatTick1)
        let nic2 = PhysicalNICCounterReader.parseNetstatIB(netstatTick2)

        // Verify physical NIC delta vs netstat -ib: +40,000,000 B in, +80,000 B out; lo0 (+200 MiB) and utun0 (+10 MB) excluded!
        #expect(nic2.externalBytesIn - nic1.externalBytesIn == 40_000_000)
        #expect(nic2.externalBytesOut - nic1.externalBytesOut == 80_000)
        #expect(nic2.loopbackBytesIn - nic1.loopbackBytesIn == 209_715_200)

        // 1. Pure 200 MB loopback scenario (physical NIC external counters unchanged: nic1 -> nic1)
        let loopOnlyParser = NettopDeltaParser()
        _ = loopOnlyParser.ingestCSV(nettopTick1, now: 20_000.0, nicCounters: nic1)
        let loopOnlyTick2 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,12000,8000,
        tcp4 192.168.1.25:50000<->17.57.145.41:5223,en1,Established,12000,8000,
        local-loop.8080,,,209716200,209716200,
        tcp4 127.0.0.1:51000<->127.0.0.1:8080,lo0,Established,209716200,209716200,
        """
        let loopRes = loopOnlyParser.ingestCSV(loopOnlyTick2, now: 20_002.0, nicCounters: nic1)
        #expect(loopRes.totalInBps == 0)
        #expect(loopRes.totalOutBps == 0)
        #expect(loopRes.unattributedInBytes == 0)
        #expect(loopRes.unattributedOutBytes == 0)
        #expect(loopRes.loopbackRxBytesPerSec == 104_857_600)

        // 2. 40 MB physical NIC download + simultaneous 200 MiB loopback + 10 MB utun0 tunnel (dt = 2.0s)
        let calParser = NettopDeltaParser()
        let baseRes = calParser.ingestCSV(nettopTick1, now: 30_000.0, nicCounters: nic1)
        #expect(baseRes.totalInBps == 0)

        let dlRes = calParser.ingestCSV(nettopTick2, now: 30_002.0, nicCounters: nic2)
        // Calibrated total inbound: 40,000,000 B / 2.0s = 20,000,000 B/s (0.0% <= 10% error vs netstat -ib!)
        #expect(dlRes.totalInBps == 20_000_000)
        #expect(dlRes.totalOutBps == 40_000)

        // curl (PID 999) gets 36,000,000 B / 2.0s = 18,000,000 B/s (90.0% >= 80% of 40 MB!)
        #expect(dlRes.perPIDBytesInDelta[999] == 18_000_000)
        #expect(dlRes.perPIDBytesOutDelta[999] == 32_000)

        // Innocent apsd (PID 140) gets strictly 0 bytes (never smeared!)
        #expect((dlRes.perPIDBytesInDelta[140] ?? 0) == 0)
        #expect((dlRes.perPIDBytesOutDelta[140] ?? 0) == 0)

        // Remaining 4,000,000 B inbound (2,000,000 B/s) and 16,000 B outbound (8,000 B/s) go to Unattributed / 未归属!
        #expect(dlRes.unattributedInBytes == 4_000_000)
        #expect(dlRes.unattributedOutBytes == 16_000)
        #expect(dlRes.perPIDBytesInDelta[NettopDeltaParser.unattributedPID] == 2_000_000)
        #expect(dlRes.perPIDBytesOutDelta[NettopDeltaParser.unattributedPID] == 8_000)

        // Verify end-to-end persistence & EN/ZH localization in FlightboxStore + ChronoMonitor
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-nic-cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try FlightboxStore(databaseURL: tmpDir.appendingPathComponent("flightbox.sqlite"))
        let stub = StubSystemSampler()
        stub.netResult = dlRes
        stub.procSnapshot = ProcessTreeSnapshot(
            processes: [
                ProcessSample(
                    ts: 30_002, pid: 999, ppid: 1, name: "curl", execPath: "/usr/bin/curl",
                    cpuPct: 12.0, rssBytes: 18_000_000,
                    netInBps: dlRes.perPIDBytesInDelta[999] ?? 0,
                    netOutBps: dlRes.perPIDBytesOutDelta[999] ?? 0
                ),
                ProcessSample(
                    ts: 30_002, pid: 140, ppid: 1, name: "apsd", execPath: "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
                    cpuPct: 0.2, rssBytes: 12_000_000,
                    netInBps: dlRes.perPIDBytesInDelta[140] ?? 0,
                    netOutBps: dlRes.perPIDBytesOutDelta[140] ?? 0
                ),
                ProcessSample.unattributedSample(
                    ts: 30_002,
                    netInBps: dlRes.perPIDBytesInDelta[NettopDeltaParser.unattributedPID] ?? 0,
                    netOutBps: dlRes.perPIDBytesOutDelta[NettopDeltaParser.unattributedPID] ?? 0
                )
            ],
            totalDiskReadBps: 0,
            totalDiskWriteBps: 0,
            livePIDs: [1, 140, 999]
        )
        let monitor = ChronoMonitor(store: store, sampler: stub, startSamplingTimer: false)
        monitor.captureLiveTick(nowOverride: 30_002)

        let (_, storedProcs) = store.queryNearestProcesses(at: 30_002, livePIDs: [1, 140, 999], sortBy: .network)
        let unattrProc = try #require(storedProcs.first(where: { $0.pid == NettopDeltaParser.unattributedPID }))
        #expect(unattrProc.localizedName(in: .en) == "Unattributed")
        #expect(unattrProc.localizedName(in: .zhHans) == "未归属")
        #expect(unattrProc.netInBps == 2_000_000)

        let storedFlows = store.querySocketFlows(sinceTs: 29_900, limit: 20)
        let unattrFlow = try #require(storedFlows.first(where: { $0.isUnattributed }))
        #expect(unattrFlow.localizedProcessName(in: .en) == "Unattributed")
        #expect(unattrFlow.localizedProcessName(in: .zhHans) == "未归属")
        #expect(unattrFlow.totalBytesIn == 4_000_000)
        #expect(unattrFlow.totalBytesOut == 16_000)

        // Synthetic Unattributed residual must NEVER trigger a "New remote host" anomaly!
        let anomalies = store.queryAnomalies(sinceTs: 29_900, limit: 20)
        #expect(!anomalies.contains(where: { $0.kind == .newExternalHost && $0.culpritName == NettopDeltaParser.unattributedProcessToken }))
    }

    @Test("T7 & T10: Real ProcessTreeSampler measures non-zero CPU & memory footprint on current process and surfaces EPERM processes as No permission")
    func realProcessTreeSamplerMeasuresCurrentProcessAndSurfacesUnreadableSystemPIDs() {
        let sampler = ProcessTreeSampler()
        let myPID = Int(getpid())

        var dirtyBuffer = [UInt8](repeating: 0x5A, count: 16 * 1024 * 1024)
        for idx in stride(from: 0, to: dirtyBuffer.count, by: 4096) {
            dirtyBuffer[idx] = UInt8(idx & 0xFF)
        }

        _ = sampler.sampleTopProcesses(ts: 1_000, netInBpsByPID: [:], netOutBpsByPID: [:], limit: 200)

        let deadline = CFAbsoluteTimeGetCurrent() + 0.28
        var spin: UInt64 = UInt64(dirtyBuffer[0]) | 1
        while CFAbsoluteTimeGetCurrent() < deadline {
            spin = spin &* 6364136223846793005 &+ 1442695040888963407
        }
        withExtendedLifetime(dirtyBuffer) {
            #expect(spin != 0)
        }

        let (procs, _, _, livePIDs) = sampler.sampleTopProcesses(ts: 1_001, netInBpsByPID: [:], netOutBpsByPID: [:], limit: 200)

        let me = procs.first(where: { $0.pid == myPID })
        #expect(me != nil)
        #expect((me?.cpuPct ?? 0) > 15.0)
        #expect((me?.memoryFootprintBytes ?? 0) >= 16 * 1024 * 1024)
        #expect(me?.isCPUReadable == true)

        #expect(livePIDs.contains(1))
        let unreadable = procs.filter { !$0.isCPUReadable }
        #expect(!unreadable.isEmpty)
        if let firstUnreadable = unreadable.first {
            #expect(firstUnreadable.formattedCPU(in: .en) == "No permission")
            #expect(firstUnreadable.formattedCPU(in: .zhHans) == "无权限")
        }
        for p in procs where !p.execPath.isEmpty {
            #expect(p.execPath.hasPrefix("/"))
        }
    }

    @Test("T3 & T10: Injectable SystemSamplerProtocol records blank execPath when unresolved and preserves loopback separation")
    @MainActor
    func injectableSamplerBlankExecPathAndMonitorIntegration() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-inj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try FlightboxStore(databaseURL: tmpDir.appendingPathComponent("flightbox.sqlite"))
        let stub = StubSystemSampler()

        let monitor = ChronoMonitor(store: store, sampler: stub, startSamplingTimer: false)
        monitor.captureLiveTick(nowOverride: 10_000)

        let ticks = store.queryTicks(from: 9_990, to: 10_010)
        #expect(ticks.count == 1)
        #expect(ticks.first?.netOutBps == 5_000_000)
        #expect(ticks.first?.loopbackOutBps == 100_000_000)

        let flows = store.querySocketFlows(sinceTs: 9_900)
        #expect(flows.count == 1)
        // Unresolved executable path must be strictly "" (never "ephemeral-worker"!)
        #expect(flows.first?.execPath == "")
        #expect(flows.first?.processName == "ephemeral-worker")
    }

    @Test("T5: Calibrated 2-tick MachSystemSampler reads non-zero host CPU and physical memory")
    func calibratedMachHostSamplerReadsRealCPU() {
        let host = MachSystemSampler()
        // Burn light CPU concurrently so host CPU cannot be 0.0%
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let until = CFAbsoluteTimeGetCurrent() + 0.25
            var x: UInt64 = 1
            while CFAbsoluteTimeGetCurrent() < until {
                x = x &* 2862933555777941757 &+ 3037000493
            }
            if x == 0 { print("") }
            done.signal()
        }
        let calibrated = host.sampleCalibratedHostState(interval: 0.20)
        _ = done.wait(timeout: .now() + 2.0)

        #expect(calibrated.totalCPUPct > 0.1)
        #expect(calibrated.memUsedBytes > 512 * 1024 * 1024)
        #expect(calibrated.memTotalBytes >= calibrated.memUsedBytes)
    }

    @Test("T3 Acceptance Row 3: Live recording session during 200 MB TCP 127.0.0.1 transfer between two local processes leaves external totals untouched and triggers 0 anomalies")
    @MainActor
    func liveTwoHundredMBLoopbackTransferBetweenTwoProcesses() throws {
        let exportPath = ProcessInfo.processInfo.environment["CHRONOMAC_ROW3_EXPORT_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-row3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL: URL
        if let exportPath, !exportPath.isEmpty {
            dbURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: exportPath + "-wal")
            try? FileManager.default.removeItem(atPath: exportPath + "-shm")
        } else {
            dbURL = tmpDir.appendingPathComponent("row3.sqlite")
        }

        let agentHome = tmpDir.appendingPathComponent("empty-agent-home")
        try FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)

        let store = try FlightboxStore(databaseURL: dbURL)
        let sampler = LiveSystemSampler(agentHomeDirectory: agentHome)
        let monitor = ChronoMonitor(store: store, sampler: sampler, startSamplingTimer: false)

        let portFile = tmpDir.appendingPathComponent("port.txt")
        let readySignalFile = tmpDir.appendingPathComponent("ready.signal")
        let goSignalFile = tmpDir.appendingPathComponent("go.signal")
        let doneTransferFile = tmpDir.appendingPathComponent("done.signal")
        let closeSignalFile = tmpDir.appendingPathComponent("close.signal")

        // Process 1: TCP loopback receiver on 127.0.0.1:0 (uses atomic temp-file rename for all signals)
        let serverProc = Process()
        serverProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProc.arguments = [
            "-c",
            """
            import os, socket, sys, time
            port_file, ready_file, done_file, close_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
            def write_atomic(path, content):
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.write(content)
                    f.flush()
                os.replace(tmp, path)

            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 0))
            srv.listen(1)
            write_atomic(port_file, str(srv.getsockname()[1]))
            conn, _ = srv.accept()
            total = 0
            while total < 4096:
                chunk = conn.recv(4096 - total)
                if not chunk:
                    break
                total += len(chunk)
            write_atomic(ready_file, str(total))
            target = 200 * 1024 * 1024 + 4096
            while total < target:
                chunk = conn.recv(1048576)
                if not chunk:
                    break
                total += len(chunk)
            write_atomic(done_file, str(total))
            deadline = time.time() + 15.0
            while not os.path.exists(close_file) and time.time() < deadline:
                time.sleep(0.05)
            conn.close()
            srv.close()
            """,
            portFile.path,
            readySignalFile.path,
            doneTransferFile.path,
            closeSignalFile.path
        ]
        try serverProc.run()
        defer { if serverProc.isRunning { serverProc.terminate() } }

        let waitPortDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: portFile.path) && Date() < waitPortDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let portStr = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        // Process 2: TCP loopback sender connecting to 127.0.0.1:<port>, sending 4 KB handshake then 200 MB upon goSignal
        let clientProc = Process()
        clientProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        clientProc.arguments = [
            "-c",
            """
            import os, socket, sys, time
            port, go_file, close_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]
            cli = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            cli.connect(("127.0.0.1", port))
            cli.sendall(b"H" * 4096)
            deadline = time.time() + 15.0
            while not os.path.exists(go_file) and time.time() < deadline:
                time.sleep(0.02)
            buf = b"X" * (4 * 1024 * 1024)
            for idx in range(50):
                cli.sendall(buf)
                if idx == 24:
                    time.sleep(0.35)
            deadline2 = time.time() + 15.0
            while not os.path.exists(close_file) and time.time() < deadline2:
                time.sleep(0.05)
            cli.close()
            """,
            portStr,
            goSignalFile.path,
            closeSignalFile.path
        ]
        try clientProc.run()
        defer { if clientProc.isRunning { clientProc.terminate() } }

        let serverPID = Int(serverProc.processIdentifier)
        let clientPID = Int(clientProc.processIdentifier)

        // Wait deterministically until the 4 KB handshake is received so the 127.0.0.1 socket is Established
        let readyDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: readySignalFile.path) && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let baseNow = Int64(Date().timeIntervalSince1970)
        // Tick 0: Baseline live system + both python3 loopback processes
        monitor.captureLiveTick(nowOverride: baseNow)
        let preTransferTicks = store.queryTicks(from: baseNow - 5, to: baseNow + 5)
        let baselineOutBps = preTransferTicks.last?.netOutBps ?? 0
        let baselineInBps = preTransferTicks.last?.netInBps ?? 0

        // Trigger the 200 MB transfer over 127.0.0.1 atomically
        try Data("go".utf8).write(to: goSignalFile, options: .atomic)

        // Wait until all 200 MB have crossed 127.0.0.1 (doneTransferFile appears atomically via os.replace!)
        let transferDeadline = Date().addingTimeInterval(15.0)
        while !FileManager.default.fileExists(atPath: doneTransferFile.path) && Date() < transferDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let transferredBytes = Int64(try String(contentsOf: doneTransferFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(transferredBytes >= 200 * 1024 * 1024)

        // Tick 1 (while socket is still Established with +200 MB on lo0)
        monitor.captureLiveTick(nowOverride: baseNow + 2)

        // Release both helper processes cleanly
        try Data("close".utf8).write(to: closeSignalFile, options: .atomic)
        serverProc.waitUntilExit()
        clientProc.waitUntilExit()

        let recordedTicks = store.queryTicks(from: baseNow - 5, to: baseNow + 10)
        #expect(recordedTicks.count == 2)
        let postTick = try #require(recordedTicks.last)

        // Dedicated loopback counters MUST observe the 200 MB (~100 MB/s over dt=2s) transfer!
        #expect(postTick.loopbackOutBps >= 50 * 1024 * 1024)
        #expect(postTick.loopbackInBps >= 50 * 1024 * 1024)

        // External inbound/outbound MUST NOT reflect the 200 MB loopback transfer!
        #expect(postTick.netOutBps - baselineOutBps < 5 * 1024 * 1024)
        #expect(postTick.netInBps - baselineInBps < 5 * 1024 * 1024)

        // Neither loopback PID may carry external netInBps/netOutBps or appear in external socket_ledger!
        let (_, snapProcs) = store.queryNearestProcesses(at: baseNow + 2, sortBy: .network)
        for p in snapProcs where p.pid == serverPID || p.pid == clientPID {
            #expect(p.netOutBps == 0)
            #expect(p.netInBps == 0)
        }

        let externalFlows = store.querySocketFlows(sinceTs: baseNow - 60, limit: 100)
        #expect(!externalFlows.contains(where: { NettopDeltaParser.isLoopbackOrLinkLocal($0.remoteEndpoint) }))
        #expect(!externalFlows.contains(where: { $0.processName.lowercased().contains("python") }))

        // Zero anomalies triggered by the 200 MB loopback transfer!
        let anomalies = store.queryAnomalies(sinceTs: baseNow - 60, limit: 50)
        let loopbackAnomalies = anomalies.filter {
            $0.culpritName.lowercased().contains("python")
                || $0.summary.contains("127.0.0.1")
                || $0.metricBadge.contains("127.0.0.1")
        }
        #expect(loopbackAnomalies.isEmpty)
    }
}
