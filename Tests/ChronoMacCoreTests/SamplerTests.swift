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
    @Test("T3: Real nettop CSV with 200 MB loopback transfer separates loopback counter, excludes it from external rates, and triggers 0 anomalies")
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

    @Test("T3: Newly observed PID uses first-seen cumulative bytes as baseline and accumulates subsequent deltas")
    func newProcessFirstSightingUsesCumulativeBytesAsBaseline() {
        let parser = NettopDeltaParser()
        let tick0 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        """
        _ = parser.ingestCSV(tick0, now: 2_000.0)

        // PID 55555 appears for the first time at t=2002 with 50 MB cumulative bytes
        let tick1 = """
        ,interface,state,bytes_in,bytes_out,
        apsd.140,,,5000,5000,
        tcp4 192.168.1.10:50000<->17.57.145.41:5223,en0,Established,5000,5000,
        downloader.55555,,,50000000,100000,
        tcp4 192.168.1.10:50123<->104.16.132.229:443,en0,Established,50000000,100000,
        """
        let firstSight = parser.ingestCSV(tick1, now: 2_002.0)
        #expect((firstSight.perPIDBytesInDelta[55555] ?? 0) == 0)
        #expect(firstSight.externalSocketDeltas.isEmpty)

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
        let goSignalFile = tmpDir.appendingPathComponent("go.signal")
        let doneTransferFile = tmpDir.appendingPathComponent("done.signal")
        let closeSignalFile = tmpDir.appendingPathComponent("close.signal")

        // Process 1: TCP loopback receiver on 127.0.0.1:0
        let serverProc = Process()
        serverProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProc.arguments = [
            "-c",
            """
            import os, socket, sys, time
            port_file, done_file, close_file = sys.argv[1], sys.argv[2], sys.argv[3]
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 0))
            srv.listen(1)
            with open(port_file, "w") as f:
                f.write(str(srv.getsockname()[1]))
            conn, _ = srv.accept()
            total = 0
            target = 200 * 1024 * 1024 + 4096
            while total < target:
                chunk = conn.recv(1048576)
                if not chunk:
                    break
                total += len(chunk)
            with open(done_file, "w") as f:
                f.write(str(total))
            deadline = time.time() + 5.0
            while not os.path.exists(close_file) and time.time() < deadline:
                time.sleep(0.05)
            conn.close()
            srv.close()
            """,
            portFile.path,
            doneTransferFile.path,
            closeSignalFile.path
        ]
        try serverProc.run()
        defer { if serverProc.isRunning { serverProc.terminate() } }

        let waitPortDeadline = Date().addingTimeInterval(3.0)
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
            deadline = time.time() + 5.0
            while not os.path.exists(go_file) and time.time() < deadline:
                time.sleep(0.02)
            buf = b"X" * (4 * 1024 * 1024)
            for idx in range(50):
                cli.sendall(buf)
                if idx == 24:
                    time.sleep(0.35)
            deadline2 = time.time() + 5.0
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

        // Wait briefly for 4 KB handshake so the 127.0.0.1 socket is Established
        Thread.sleep(forTimeInterval: 0.15)

        let baseNow = Int64(Date().timeIntervalSince1970)
        // Tick 0: Baseline live system + both python3 loopback processes
        monitor.captureLiveTick(nowOverride: baseNow)
        let preTransferTicks = store.queryTicks(from: baseNow - 5, to: baseNow + 5)
        let baselineOutBps = preTransferTicks.last?.netOutBps ?? 0
        let baselineInBps = preTransferTicks.last?.netInBps ?? 0

        // Trigger the 200 MB transfer over 127.0.0.1
        try Data("go".utf8).write(to: goSignalFile)

        // Wait until all 200 MB have crossed 127.0.0.1 (socket remains open until closeSignalFile!)
        let transferDeadline = Date().addingTimeInterval(5.0)
        while !FileManager.default.fileExists(atPath: doneTransferFile.path) && Date() < transferDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let transferredBytes = Int64(try String(contentsOf: doneTransferFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(transferredBytes >= 200 * 1024 * 1024)

        // Tick 1 (1s later while socket is still Established with +200 MB on lo0)
        monitor.captureLiveTick(nowOverride: baseNow + 2)

        // Release both helper processes cleanly
        try Data("close".utf8).write(to: closeSignalFile)
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
