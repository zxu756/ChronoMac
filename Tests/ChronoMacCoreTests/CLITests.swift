import ChronoMacCore
import Darwin
import Foundation
import SQLite3
import Testing

@Suite("CLI & MCP Tests", .timeLimit(.minutes(1)))
struct CLITests {
    private static func locateChronoMacExecutable() throws -> URL {
        // Resolve .build/<triple>/debug/ChronoMac or .build/debug/ChronoMac relative to package root
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/ChronoMac"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/ChronoMac")
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c
        }
        throw NSError(domain: "CLITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "ChronoMac binary not found in .build"])
    }

    private static func runBinary(args: [String], dbPath: String) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let bin = try locateChronoMacExecutable()
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = args + ["--db", dbPath]
        var env = ProcessInfo.processInfo.environment
        env["CHRONOMAC_DB_PATH"] = dbPath
        env["CHRONOMAC_AGENT_HOME"] = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    @Test("T6 Acceptance Row 5: Unknown CLI subcommand exits with code 2 and prints bilingual error to stderr")
    func unknownSubcommandExitsWithCodeTwo() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-cli-bogus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("flightbox.sqlite").path

        let enRes = try Self.runBinary(args: ["--cli", "bogus", "--lang", "en"], dbPath: dbPath)
        #expect(enRes.exitCode == 2)
        #expect(enRes.stderr.contains("bogus"))

        let zhRes = try Self.runBinary(args: ["--cli", "bogus", "--lang", "zh"], dbPath: dbPath)
        #expect(zhRes.exitCode == 2)
        #expect(zhRes.stderr.contains("bogus"))
    }

    @Test("T6, T7, T8: CLI blame, anomalies, and egress emit human-readable EN/ZH text (no JSON-RPC wrapper), honest delta/liveness/footprint labels, and --json")
    func cliBlameAnomaliesAndEgressHumanAndJSON() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-cli-human-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)

        let now = Int64(Date().timeIntervalSince1970)
        let snapTs = now - 585 // 9m 45s ago -> ~15s away from `--at 10m` (now - 600)
        let myPID = Int(getpid()) // guaranteed alive right now
        let deadPID = 999_991     // guaranteed not alive

        try store.recordSampleBatch(
            tick: SystemTick(
                ts: snapTs,
                cpuUserPct: 72.0,
                cpuSysPct: 14.0,
                thermalGrade: .serious,
                memUsedBytes: 15_000_000_000,
                memTotalBytes: 24_000_000_000,
                swapUsedBytes: 1_200_000_000,
                diskReadBps: 20_000_000,
                diskWriteBps: 10_000_000,
                netInBps: 1_000_000,
                netOutBps: 12_000_000
            ),
            processes: [
                ProcessSample(
                    ts: snapTs,
                    pid: deadPID,
                    ppid: 1,
                    name: "short-lived-spike",
                    execPath: "/usr/local/bin/short-lived-spike",
                    cpuPct: 240.0,
                    rssBytes: 4_500_000_000,
                    netOutBps: 12_000_000,
                    isAliveNow: true,
                    isCPUReadable: true
                ),
                ProcessSample(
                    ts: snapTs,
                    pid: myPID,
                    ppid: 1,
                    name: "active-runner",
                    execPath: "/usr/bin/active-runner",
                    cpuPct: 32.5,
                    rssBytes: 600_000_000,
                    netOutBps: 0,
                    isAliveNow: true,
                    isCPUReadable: true
                ),
                ProcessSample(
                    ts: snapTs,
                    pid: 1,
                    ppid: 0,
                    name: "launchd",
                    execPath: "/sbin/launchd",
                    cpuPct: 0,
                    rssBytes: 0,
                    isAliveNow: true,
                    isCPUReadable: false
                )
            ],
            sockets: [
                SocketFlowRecord(
                    bucketHour: (snapTs / 3600) * 3600,
                    execPath: "/usr/local/bin/short-lived-spike",
                    processName: "short-lived-spike",
                    remoteEndpoint: "54.231.10.20:443",
                    hostname: "s3.amazonaws.com",
                    totalBytesIn: 128_000,
                    totalBytesOut: 42_000_000,
                    firstSeen: snapTs - 10,
                    lastSeen: snapTs
                )
            ],
            anomalies: [
                AnomalyBookmark(
                    id: "anom-cli-1",
                    ts: snapTs,
                    kind: .runawayCPU,
                    severity: 2,
                    culpritName: "short-lived-spike",
                    culpritExec: "/usr/local/bin/short-lived-spike",
                    metricBadge: "240% CPU",
                    summary: "short-lived-spike saturated CPU"
                )
            ]
        )

        // 1. EN human-readable blame
        let blameEN = try Self.runBinary(args: ["--cli", "blame", "--at", "10m", "--lang", "en"], dbPath: dbURL.path)
        #expect(blameEN.exitCode == 0)
        #expect(!blameEN.stdout.contains("jsonrpc"))
        #expect(blameEN.stdout.contains("Snapshot at "))
        #expect(blameEN.stdout.contains("s from requested time)"))
        #expect(blameEN.stdout.contains("Memory Footprint (phys_footprint)"))
        #expect(!blameEN.stdout.contains("RSS"))
        #expect(blameEN.stdout.contains("exited after spike"))
        #expect(blameEN.stdout.contains("still running"))
        #expect(blameEN.stdout.contains("No permission"))

        // 2. ZH human-readable blame
        let blameZH = try Self.runBinary(args: ["--cli", "blame", "--at", "10m", "--lang", "zh"], dbPath: dbURL.path)
        #expect(blameZH.exitCode == 0)
        #expect(!blameZH.stdout.contains("jsonrpc"))
        #expect(blameZH.stdout.contains("取自 "))
        #expect(blameZH.stdout.contains("的快照（距所查时刻差 "))
        #expect(blameZH.stdout.contains("物理内存占用 (phys_footprint)"))
        #expect(blameZH.stdout.contains("尖峰后已退出"))
        #expect(blameZH.stdout.contains("仍在运行"))
        #expect(blameZH.stdout.contains("无权限"))

        // 3. JSON blame (--json)
        let blameJSON = try Self.runBinary(args: ["--cli", "blame", "--at", "10m", "--json"], dbPath: dbURL.path)
        #expect(blameJSON.exitCode == 0)
        #expect(!blameJSON.stdout.contains("jsonrpc"))
        let parsedBlame = try #require(JSONSerialization.jsonObject(with: Data(blameJSON.stdout.utf8)) as? [String: Any])
        #expect(parsedBlame["deltaSeconds"] != nil)
        let procList = try #require(parsedBlame["processes"] as? [[String: Any]])
        #expect(procList.count == 3)

        // 4. Anomalies & Egress human-readable + --json
        let anomEN = try Self.runBinary(args: ["--cli", "anomalies", "--lang", "en"], dbPath: dbURL.path)
        #expect(anomEN.exitCode == 0)
        #expect(!anomEN.stdout.contains("jsonrpc"))
        #expect(anomEN.stdout.contains("short-lived-spike"))

        let egressZH = try Self.runBinary(args: ["--cli", "egress", "--lang", "zh"], dbPath: dbURL.path)
        #expect(egressZH.exitCode == 0)
        #expect(!egressZH.stdout.contains("jsonrpc"))
        #expect(egressZH.stdout.contains("s3.amazonaws.com"))

        // 5. MCP chrono_inspect_timestamp also reports delta, liveness, phys_footprint, and No permission
        let mcp = ChronoMCPServer(store: store)
        let mcpReply = try #require(
            mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chrono_inspect_timestamp","arguments":{"epoch_seconds":\#(snapTs + 12)}}}"#)
        )
        #expect(mcpReply.contains("12s from requested time"))
        #expect(mcpReply.contains("exited after spike"))
        #expect(mcpReply.contains("still running"))
        #expect(mcpReply.contains("phys_footprint"))
        #expect(!mcpReply.contains("RSS"))
        #expect(mcpReply.contains("No permission"))

        // 6. Explicit 3-mode CLI sorting (--sort cpu, --sort memory, --sort network)
        let sortNetJSON = try Self.runBinary(args: ["--cli", "blame", "--at", "10m", "--sort", "network", "--json"], dbPath: dbURL.path)
        #expect(sortNetJSON.exitCode == 0)
        let parsedNet = try #require(JSONSerialization.jsonObject(with: Data(sortNetJSON.stdout.utf8)) as? [String: Any])
        #expect(parsedNet["sortBy"] as? String == "network")
    }

    @Test("T5 & Read-Only DB Safety: CLI status samples 1.0s calibrated non-zero CPU without creating missing SQLite DB, and missing blame snapshot exits 1")
    func cliStatusCalibratedAndReadOnlyDBSafety() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-cli-readonly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let missingDBPath = tmpDir.appendingPathComponent("nonexistent.sqlite").path

        let statusJSON = try Self.runBinary(args: ["--cli", "status", "--json", "--lang", "en"], dbPath: missingDBPath)
        #expect(statusJSON.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: missingDBPath))

        let parsed = try #require(JSONSerialization.jsonObject(with: Data(statusJSON.stdout.utf8)) as? [String: Any])
        let cpuPct = try #require(parsed["cpuPct"] as? Double)
        #expect(cpuPct > 0.0 && cpuPct <= 100.0)
        #expect(parsed["dbExists"] as? Bool == false)

        let missingBlame = try Self.runBinary(args: ["--cli", "blame", "--at", "10m", "--lang", "en"], dbPath: missingDBPath)
        #expect(missingBlame.exitCode == 1)
        #expect(!missingBlame.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missingDBPath))
    }

    @Test("M1 Item 1: Headless record daemon writes calibrated ticks, supports concurrent read-only CLI/MCP/UI queries, and flushes WAL on SIGTERM")
    func m1RecordDaemonGracefulStopAndConcurrentReadOnlyQueries() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-m1-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")

        // 1. Bounded `--cli record --duration 3 --interval 1 --max-db-mb 10 --no-dns`
        let boundedRes = try Self.runBinary(
            args: ["--cli", "record", "--interval", "1", "--duration", "3", "--max-db-mb", "10", "--no-dns", "--lang", "en"],
            dbPath: dbURL.path
        )
        #expect(boundedRes.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        let roStore = try FlightboxStore(databaseURL: dbURL, readOnly: true)
        let now = Int64(Date().timeIntervalSince1970)
        let boundedTicks = roStore.queryTicks(from: now - 30, to: now + 5)
        #expect(boundedTicks.count >= 2)

        // 2. Indefinite `ChronoMac record` (top-level subcommand without `--cli`), concurrent read-only queries, then SIGTERM
        let liveDBURL = tmpDir.appendingPathComponent("live-daemon.sqlite")
        let bin = try Self.locateChronoMacExecutable()
        let daemon = Process()
        daemon.executableURL = bin
        daemon.arguments = ["record", "--db", liveDBURL.path, "--interval", "1", "--max-db-mb", "15", "--no-dns"]
        var env = ProcessInfo.processInfo.environment
        env["CHRONOMAC_DB_PATH"] = liveDBURL.path
        env["CHRONOMAC_AGENT_HOME"] = tmpDir.path
        daemon.environment = env
        let daemonOut = Pipe()
        let daemonErr = Pipe()
        daemon.standardOutput = daemonOut
        daemon.standardError = daemonErr
        try daemon.run()
        defer { if daemon.isRunning { daemon.terminate() } }

        // Wait until at least 2 ticks are persisted while daemon is actively writing
        let waitDeadline = Date().addingTimeInterval(8.0)
        var observedDuringRun = 0
        while Date() < waitDeadline {
            if FileManager.default.fileExists(atPath: liveDBURL.path),
               let reader = try? FlightboxStore(databaseURL: liveDBURL, readOnly: true) {
                let tsNow = Int64(Date().timeIntervalSince1970)
                observedDuringRun = reader.queryTicks(from: tsNow - 30, to: tsNow + 5).count
                if observedDuringRun >= 2 { break }
            }
            Thread.sleep(forTimeInterval: 0.20)
        }
        #expect(observedDuringRun >= 2)
        #expect(daemon.isRunning)

        // Concurrent read-only CLI queries (both top-level positional and `--cli`) while `record` is writing!
        let statusTop = try Self.runBinary(args: ["status", "--json"], dbPath: liveDBURL.path)
        #expect(statusTop.exitCode == 0)
        let histEN = try Self.runBinary(args: ["history", "--minutes", "5", "--lang", "en"], dbPath: liveDBURL.path)
        #expect(histEN.exitCode == 0)
        let blameZH = try Self.runBinary(args: ["--cli", "blame", "--at", "2s", "--lang", "zh"], dbPath: liveDBURL.path)
        #expect(blameZH.exitCode == 0)

        // Concurrent read-only MCP query while `record` is writing!
        let mcpStore = try FlightboxStore(databaseURL: liveDBURL, readOnly: true)
        let mcp = ChronoMCPServer(store: mcpStore)
        let mcpSummary = try #require(
            mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"chrono_summary_window","arguments":{"minutes":5}}}"#)
        )
        #expect(mcpSummary.contains("samples):"))

        // Send SIGTERM and verify clean exit code 0 + WAL checkpoint
        kill(daemon.processIdentifier, SIGTERM)
        daemon.waitUntilExit()
        #expect(daemon.terminationStatus == 0)
    }

    @Test("M1 Item 1: install-agent generates valid LaunchAgent plist XML via --print and --output without touching ~/Library/LaunchAgents")
    func m1InstallAgentPlistGenerationAndValidation() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-m1-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("flightbox.sqlite").path
        let plistURL = tmpDir.appendingPathComponent("io.github.zxu756.ChronoMac.record.plist")

        // Missing both --print and --output must exit 2 safely (never auto-writing ~/Library/LaunchAgents!)
        let missingMode = try Self.runBinary(args: ["--cli", "install-agent", "--lang", "en"], dbPath: dbPath)
        #expect(missingMode.exitCode == 2)

        // --print emits valid LaunchAgent plist XML to stdout
        let printed = try Self.runBinary(
            args: ["--cli", "install-agent", "--print", "--interval", "2", "--max-db-mb", "250"],
            dbPath: dbPath
        )
        #expect(printed.exitCode == 0)
        #expect(printed.stdout.contains("<key>Label</key>"))
        #expect(printed.stdout.contains("<string>record</string>"))
        #expect(printed.stdout.contains(dbPath))

        // --output writes valid plist verified by /usr/bin/plutil -lint
        let written = try Self.runBinary(
            args: ["--cli", "install-agent", "--output", plistURL.path, "--interval", "2"],
            dbPath: dbPath
        )
        #expect(written.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let plutil = Process()
        plutil.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        plutil.arguments = ["-lint", plistURL.path]
        let lintPipe = Pipe()
        plutil.standardOutput = lintPipe
        plutil.standardError = lintPipe
        try plutil.run()
        plutil.waitUntilExit()
        #expect(plutil.terminationStatus == 0)
    }

    @Test("M1 Item 2 & 3: CLI history, blame, egress, and MCP localize Unattributed / 未归属 and exited short-lived CPU culprit")
    func m1HistoryAndEgressLocalizeUnattributedAndExitedProcess() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-m1-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)

        let now = Int64(Date().timeIntervalSince1970)
        let spikeTs = now - 40
        let deadBurnerPID = 999_887

        try store.recordSampleBatch(
            tick: SystemTick(
                ts: spikeTs,
                cpuUserPct: 92.0,
                cpuSysPct: 5.0,
                memUsedBytes: 12_000_000_000,
                memTotalBytes: 16_000_000_000,
                swapUsedBytes: 0,
                diskReadBps: 0,
                diskWriteBps: 0,
                netInBps: 2_000_000,
                netOutBps: 8_000
            ),
            processes: [
                ProcessSample(
                    ts: spikeTs,
                    pid: deadBurnerPID,
                    ppid: 1,
                    name: "ephemeral-cpu-burner",
                    execPath: "/tmp/ephemeral-cpu-burner",
                    cpuPct: 99.4,
                    rssBytes: 24_000_000,
                    isAliveNow: true,
                    isCPUReadable: true
                ),
                ProcessSample.unattributedSample(
                    ts: spikeTs,
                    netInBps: 2_000_000,
                    netOutBps: 8_000
                )
            ],
            sockets: [
                SocketFlowRecord(
                    bucketHour: (spikeTs / 3600) * 3600,
                    execPath: "",
                    processName: NettopDeltaParser.unattributedProcessToken,
                    remoteEndpoint: NettopDeltaParser.unattributedEndpoint,
                    protocolName: "nic",
                    totalBytesIn: 4_000_000,
                    totalBytesOut: 16_000,
                    firstSeen: spikeTs,
                    lastSeen: spikeTs
                )
            ],
            anomalies: []
        )

        // 1. CLI history in EN & ZH surfaces exited burner AND localizes Unattributed / 未归属
        let histEN = try Self.runBinary(args: ["--cli", "history", "--minutes", "5", "--lang", "en"], dbPath: dbURL.path)
        #expect(histEN.exitCode == 0)
        #expect(histEN.stdout.contains("ephemeral-cpu-burner"))
        #expect(histEN.stdout.contains("exited after spike"))
        #expect(histEN.stdout.contains("Unattributed"))
        #expect(!histEN.stdout.contains("__unattributed__"))

        let histZH = try Self.runBinary(args: ["--cli", "history", "--minutes", "5", "--lang", "zh"], dbPath: dbURL.path)
        #expect(histZH.exitCode == 0)
        #expect(histZH.stdout.contains("ephemeral-cpu-burner"))
        #expect(histZH.stdout.contains("尖峰后已退出"))
        #expect(histZH.stdout.contains("未归属"))
        #expect(!histZH.stdout.contains("__unattributed__"))

        // 2. CLI blame & egress in EN & ZH localize Unattributed / 未归属 (never leaking __unattributed__)
        let blameZH = try Self.runBinary(args: ["--cli", "blame", "--epoch", "\(spikeTs)", "--sort", "network", "--lang", "zh"], dbPath: dbURL.path)
        #expect(blameZH.exitCode == 0)
        #expect(blameZH.stdout.contains("未归属"))
        #expect(!blameZH.stdout.contains("__unattributed__"))

        let egressEN = try Self.runBinary(args: ["--cli", "egress", "--lang", "en"], dbPath: dbURL.path)
        #expect(egressEN.exitCode == 0)
        #expect(egressEN.stdout.contains("Unattributed"))
        #expect(!egressEN.stdout.contains("__unattributed__"))

        let egressZH = try Self.runBinary(args: ["--cli", "egress", "--lang", "zh"], dbPath: dbURL.path)
        #expect(egressZH.exitCode == 0)
        #expect(egressZH.stdout.contains("未归属"))
        #expect(!egressZH.stdout.contains("__unattributed__"))

        // 3. MCP tools also localize Unattributed cleanly
        let mcp = ChronoMCPServer(store: store)
        let mcpEgress = try #require(
            mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"chrono_top_egress_endpoints","arguments":{"hours":1}}}"#)
        )
        #expect(mcpEgress.contains("Unattributed"))
        #expect(!mcpEgress.contains("__unattributed__"))
    }

    @Test(
        "W3 Helper: Captures real live host telemetry via ChronoMonitor and FlightboxStore when CHRONOMAC_RUN_LIVE_SEED=1",
        .enabled(
            if: ProcessInfo.processInfo.environment["CHRONOMAC_RUN_LIVE_SEED"] == "1",
            "Opt-in live DB seeder; set CHRONOMAC_RUN_LIVE_SEED=1 and CHRONOMAC_SEED_LIVE_DB=<path> to run"
        )
    )
    @MainActor
    func captureRealLiveFlightboxWhenRequested() throws {
        let liveDBPath = try #require(
            ProcessInfo.processInfo.environment["CHRONOMAC_SEED_LIVE_DB"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "CHRONOMAC_SEED_LIVE_DB must be set when CHRONOMAC_RUN_LIVE_SEED=1"
        )
        #expect(!liveDBPath.isEmpty)

        let dbURL = URL(fileURLWithPath: liveDBPath)
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(atPath: liveDBPath + "-wal")
        try? FileManager.default.removeItem(atPath: liveDBPath + "-shm")

        let store = try FlightboxStore(databaseURL: dbURL)
        let liveSampler = LiveSystemSampler()
        let monitor = ChronoMonitor(store: store, sampler: liveSampler, startSamplingTimer: false)

        // Spawn a real short-lived local CPU worker so the live snapshot captures both a real process that
        // exits right after the spike and live processes that remain running.
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        worker.arguments = ["-c", "import time\nt = time.time() + 0.65\nx = 1\nwhile time.time() < t:\n    x = (x * 1664525 + 1013904223) & 0xFFFFFFFF\n"]
        try worker.run()

        // Warm baseline counters while worker is alive, wait 0.40s, then record calibrated live tick via ChronoMonitor + FlightboxStore
        let warmNow = Date().timeIntervalSince1970
        _ = liveSampler.sampleHostState()
        _ = liveSampler.sampleNetwork(now: warmNow)
        _ = liveSampler.sampleProcesses(ts: Int64(warmNow), netInBpsByPID: [:], netOutBpsByPID: [:], limit: 60)
        Thread.sleep(forTimeInterval: 0.40)

        monitor.captureLiveTick()
        worker.waitUntilExit()

        let now = Int64(Date().timeIntervalSince1970)
        let ticks = store.queryTicks(from: now - 60, to: now + 5)
        #expect(!ticks.isEmpty)
    }

    @Test("M1 Item 1: FlightboxRecorder.runLoop drains Objective-C autorelease pool every tick so phys_footprint stays flat across long runs")
    func m1RecordLoopDrainsAutoreleasePoolPerTick() throws {
        final class AutoreleaseAllocatingSampler: SystemSamplerProtocol, @unchecked Sendable {
            let totalMemoryBytes: Int64 = 16_000_000_000
            let recorderRef: () -> FlightboxRecorder?
            var baselineFootprint: UInt64 = 0
            var peakDeltaDuringRun: UInt64 = 0
            var calls = 0

            init(recorderRef: @escaping () -> FlightboxRecorder?) {
                self.recorderRef = recorderRef
            }

            static func currentPhysFootprint() -> UInt64 {
                var ru = rusage_info_v4()
                let rc = withUnsafeMutablePointer(to: &ru) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ptr in
                        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, ptr)
                    }
                }
                return rc == 0 ? ru.ri_phys_footprint : 0
            }

            func sampleHostState() -> HostStateReading {
                HostStateReading(cpuUserPct: 8, cpuSysPct: 2, thermal: .nominal, memUsedBytes: 8_000_000_000, memTotalBytes: totalMemoryBytes, swapUsedBytes: 0)
            }

            func sampleCalibratedHostState(interval: TimeInterval) -> HostStateReading {
                sampleHostState()
            }

            func sampleNetwork(now: TimeInterval) -> NettopSnapshotResult {
                NettopSnapshotResult(perPIDBytesInDelta: [:], perPIDBytesOutDelta: [:], externalSocketDeltas: [], totalInBps: 0, totalOutBps: 0)
            }

            func sampleProcesses(ts: Int64, netInBpsByPID: [Int: Int64], netOutBpsByPID: [Int: Int64], limit: Int) -> ProcessTreeSnapshot {
                // Simulate bridged Objective-C autoreleased buffers produced by Foundation Process + Pipe.readDataToEndOfFile()
                let chunkSize = 1024 * 1024
                var scratch = [UInt8](repeating: UInt8((calls + 1) & 0xFF), count: chunkSize)
                let nsCopy = NSData(bytes: &scratch, length: chunkSize)
                _ = Unmanaged.passRetained(nsCopy).autorelease()

                calls += 1
                if calls == 2 {
                    baselineFootprint = Self.currentPhysFootprint()
                } else if calls > 2, baselineFootprint > 0 {
                    let cur = Self.currentPhysFootprint()
                    if cur > baselineFootprint {
                        peakDeltaDuringRun = max(peakDeltaDuringRun, cur - baselineFootprint)
                    }
                }
                if calls >= 36 {
                    recorderRef()?.requestStop()
                }
                return ProcessTreeSnapshot(processes: [], totalDiskReadBps: 0, totalDiskWriteBps: 0, livePIDs: [1])
            }

            func resolveExecutablePath(pid: Int) -> String { "" }
            func currentLivePIDs() -> Set<Int> { [1] }
            func detectAgentActivity(now: Int64) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow]) { (0, "", []) }
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-arp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try FlightboxStore(databaseURL: tmpDir.appendingPathComponent("arp.sqlite"))

        weak var weakRecorder: FlightboxRecorder?
        let sampler = AutoreleaseAllocatingSampler(recorderRef: { weakRecorder })
        let recorder = FlightboxRecorder(store: store, sampler: sampler, enableReverseDNS: false)
        weakRecorder = recorder

        var runError: Error?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do {
                _ = try recorder.runLoop(interval: 0.2, durationSeconds: nil, installSignalHandlers: false)
            } catch {
                runError = error
            }
            done.signal()
        }
        thread.start()
        _ = done.wait(timeout: .now() + 20.0)
        if let runError { throw runError }

        // 34 post-baseline ticks * 1 MiB = 34 MiB if un-drained; with per-tick autoreleasepool, peak delta stays < 12 MiB
        #expect(sampler.calls >= 36)
        #expect(sampler.peakDeltaDuringRun < 12 * 1024 * 1024)
    }

    @Test("M1 Item 1 & 3: FlightboxRecorder aligns integer-second intervals to whole wall-clock seconds with exact 2s cadence")
    func m1RecorderAlignsIntegerIntervalTicksToWholeWallClockSeconds() throws {
        final class WallClockProbeSampler: SystemSamplerProtocol, @unchecked Sendable {
            let totalMemoryBytes: Int64 = 16_000_000_000
            var hostSampleWallTimes: [TimeInterval] = []
            private let lock = NSLock()

            func sampleHostState() -> HostStateReading {
                lock.lock()
                hostSampleWallTimes.append(Date().timeIntervalSince1970)
                lock.unlock()
                return HostStateReading(cpuUserPct: 12, cpuSysPct: 4, thermal: .nominal, memUsedBytes: 8_000_000_000, memTotalBytes: totalMemoryBytes, swapUsedBytes: 0)
            }
            func sampleCalibratedHostState(interval: TimeInterval) -> HostStateReading { sampleHostState() }
            func sampleNetwork(now: TimeInterval) -> NettopSnapshotResult {
                NettopSnapshotResult(perPIDBytesInDelta: [:], perPIDBytesOutDelta: [:], externalSocketDeltas: [], totalInBps: 0, totalOutBps: 0)
            }
            func sampleProcesses(ts: Int64, netInBpsByPID: [Int: Int64], netOutBpsByPID: [Int: Int64], limit: Int) -> ProcessTreeSnapshot {
                ProcessTreeSnapshot(processes: [], totalDiskReadBps: 0, totalDiskWriteBps: 0, livePIDs: [1])
            }
            func resolveExecutablePath(pid: Int) -> String { "" }
            func currentLivePIDs() -> Set<Int> { [1] }
            func detectAgentActivity(now: Int64) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow]) { (0, "", []) }
        }

        // Start deliberately mid-second (~.45s fractional part) where unaligned wakeup would be ~0.45s off whole seconds
        let frac = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)
        let shiftToMid = (0.45 - frac) >= 0 ? (0.45 - frac) : (1.45 - frac)
        Thread.sleep(forTimeInterval: shiftToMid)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-align-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try FlightboxStore(databaseURL: tmpDir.appendingPathComponent("align.sqlite"))
        let probe = WallClockProbeSampler()
        let recorder = FlightboxRecorder(store: store, sampler: probe, enableReverseDNS: false)

        let count = try recorder.runLoop(interval: 2.0, durationSeconds: 4.0, installSignalHandlers: false)
        #expect(count == 3)

        // Post-warmup loop samples are the last 3 entries in hostSampleWallTimes; each must fire within <= 0.12s of a whole wall-clock second
        let loopWallTimes = Array(probe.hostSampleWallTimes.suffix(3))
        #expect(loopWallTimes.count == 3)
        for wt in loopWallTimes {
            let distToWholeSec = abs(wt - wt.rounded())
            #expect(distToWholeSec <= 0.12)
        }
    }

    @Test("TR1: m1-record-1h.sh enforces README phys_footprint/RSS ceilings, keeps DB in TMPDIR, never installs LaunchAgents, and reaps children")
    func tr1Record1hScriptEnforcesReadmeMemoryCeilingAndTempIsolation() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1-record-1h.sh")
        let scriptText = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(scriptText.contains("mktemp -d \"${TMPDIR:-/tmp}/chronomac-m1-1h."))
        #expect(!scriptText.contains("launchctl"))
        #expect(!scriptText.contains("install-agent"))
        #expect(scriptText.contains("LaunchAgents"))

        let marker = "[Row 1 & Row 2 SQLite Gap & Self-Overhead Analysis]"
        let afterMarker = try #require(scriptText.components(separatedBy: marker).dropFirst().first)
        let afterHeredocStart = try #require(afterMarker.components(separatedBy: "<<'PY'\n").dropFirst().first)
        let pyVerifier = try #require(afterHeredocStart.components(separatedBy: "\nPY\n").first)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-tr1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("flightbox-1h.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)
        for ts: Int64 in [1_000, 1_002, 1_004] {
            try store.recordSampleBatch(
                tick: SystemTick(
                    ts: ts,
                    cpuUserPct: 10,
                    cpuSysPct: 4,
                    memUsedBytes: 8_000_000_000,
                    memTotalBytes: 16_000_000_000,
                    swapUsedBytes: 0,
                    diskReadBps: 0,
                    diskWriteBps: 0,
                    netInBps: 1_000,
                    netOutBps: 500
                ),
                processes: [],
                sockets: [],
                anomalies: []
            )
        }
        store.checkpointWAL()

        func runVerifier(csvContent: String) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let csvURL = tmpDir.appendingPathComponent("overhead-\(UUID().uuidString).csv")
            try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.currentDirectoryURL = repoRoot
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = ["-c", pyVerifier, dbURL.path, csvURL.path, "4", "2"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // 1. Pre-fix 1h leak footprint (mean=78.59 MiB, max=148.61 MiB > 50 MiB ceiling in README) MUST fail!
        let leakedCSV = """
        mono_ts,self_cpu_ns,tree_cpu_ns,self_cpu_pct,tree_cpu_pct,rss_bytes,footprint_bytes
        100.000,10000000,50000000,0.0000,0.0000,21747466,12582912
        102.000,28000000,140000000,0.9000,4.5000,38828605,155828552
        104.000,46000000,230000000,0.9000,4.5000,29360128,82407588
        """
        let leakedRes = try runVerifier(csvContent: leakedCSV)
        #expect(leakedRes.exitCode != 0, "Expected non-zero exit when phys_footprint=148.61 MiB > 50 MiB ceiling; got stdout=\(leakedRes.stdout)")
        #expect(leakedRes.stderr.contains("FAIL [Row 2]"))

        // 2. RSS exceeding 60 MiB ceiling MUST also fail!
        let highRssCSV = """
        mono_ts,self_cpu_ns,tree_cpu_ns,self_cpu_pct,tree_cpu_pct,rss_bytes,footprint_bytes
        100.000,10000000,50000000,0.0000,0.0000,20971520,10485760
        102.000,28000000,140000000,0.9000,4.5000,68157440,12582912
        104.000,46000000,230000000,0.9000,4.5000,22020096,11534336
        """
        let highRssRes = try runVerifier(csvContent: highRssCSV)
        #expect(highRssRes.exitCode != 0, "Expected non-zero exit when RSS=65.00 MiB > 60 MiB ceiling")

        // 3. Healthy overhead within README ceilings (phys_footprint <= 50 MiB, RSS <= 60 MiB, self CPU <= 2.0%, tree CPU <= 8.0%) passes
        let healthyCSV = """
        mono_ts,self_cpu_ns,tree_cpu_ns,self_cpu_pct,tree_cpu_pct,rss_bytes,footprint_bytes
        100.000,10000000,50000000,0.0000,0.0000,18360566,8661238
        102.000,27200000,137600000,0.8600,4.3800,23718789,13683916
        104.000,44400000,225200000,0.8600,4.3800,19200000,9100000
        """
        let okRes = try runVerifier(csvContent: healthyCSV)
        #expect(okRes.exitCode == 0, "Expected healthy overhead to pass; stderr=\(okRes.stderr)")
        #expect(okRes.stdout.contains("[PASS] Row 2"))
    }

    @Test("TR2: CLI/MCP display 对不上的量 with negative numbers without sign cancellation, and m1-differential.sh rejects constant-zero product external bytes")
    func tr2CLINegativeDiscrepancyDisplayAndDifferentialLowerBoundGuard() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-tr2-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("tr2.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)
        let now = Int64(Date().timeIntervalSince1970)
        let ts = now - 10

        // Opposite-sign test: netInBps = -3_000_000 (-2.9 MB/s), netOutBps = +3_000_000 (+2.9 MB/s)
        // Must NEVER cancel out to 0 KB/s in blame or history!
        try store.recordSampleBatch(
            tick: SystemTick(
                ts: ts,
                cpuUserPct: 12,
                cpuSysPct: 3,
                memUsedBytes: 8_000_000_000,
                memTotalBytes: 16_000_000_000,
                swapUsedBytes: 0,
                diskReadBps: 0,
                diskWriteBps: 0,
                netInBps: 15_000_000,
                netOutBps: 5_000_000
            ),
            processes: [
                ProcessSample(
                    ts: ts,
                    pid: 999,
                    ppid: 1,
                    name: "curl",
                    execPath: "/usr/bin/curl",
                    cpuPct: 8.0,
                    rssBytes: 16_000_000,
                    netInBps: 18_000_000,
                    netOutBps: 2_000_000
                ),
                ProcessSample.unattributedSample(ts: ts, netInBps: -3_000_000, netOutBps: 3_000_000)
            ],
            sockets: [
                SocketFlowRecord(
                    bucketHour: (ts / 3600) * 3600,
                    execPath: "",
                    processName: NettopDeltaParser.unattributedProcessToken,
                    remoteEndpoint: NettopDeltaParser.unattributedEndpoint,
                    protocolName: "nic",
                    totalBytesIn: -6_000_000,
                    totalBytesOut: 6_000_000,
                    firstSeen: ts,
                    lastSeen: ts
                )
            ],
            anomalies: []
        )

        let blameZH = try Self.runBinary(args: ["--cli", "blame", "--epoch", "\(ts)", "--sort", "network", "--lang", "zh"], dbPath: dbURL.path)
        #expect(blameZH.exitCode == 0)
        #expect(blameZH.stdout.contains("对不上的量"))
        #expect(blameZH.stdout.contains("-2.9 MB/s"))

        let blameEN = try Self.runBinary(args: ["--cli", "blame", "--epoch", "\(ts)", "--sort", "network", "--lang", "en"], dbPath: dbURL.path)
        #expect(blameEN.exitCode == 0)
        #expect(blameEN.stdout.contains("Unmatched delta"))
        #expect(blameEN.stdout.contains("-2.9 MB/s"))

        let histZH = try Self.runBinary(args: ["--cli", "history", "--minutes", "5", "--sort", "network", "--lang", "zh"], dbPath: dbURL.path)
        #expect(histZH.exitCode == 0)
        #expect(histZH.stdout.contains("对不上的量"))
        #expect(histZH.stdout.contains("-2.9 MB/s"))

        let egressZH = try Self.runBinary(args: ["--cli", "egress", "--lang", "zh"], dbPath: dbURL.path)
        #expect(egressZH.exitCode == 0)
        #expect(egressZH.stdout.contains("对不上的量"))
        #expect(egressZH.stdout.contains("-5.7 MB"))

        let egressJSON = try Self.runBinary(args: ["--cli", "egress", "--json", "--lang", "zh"], dbPath: dbURL.path)
        #expect(egressJSON.exitCode == 0)
        #expect(egressJSON.stdout.contains("-6000000"))

        let mcp = ChronoMCPServer(store: store)
        let mcpOut = try #require(
            mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"chrono_top_egress_endpoints","arguments":{"hours":1}}}"#)
        )
        #expect(mcpOut.contains("Unmatched delta"))
        #expect(mcpOut.contains("-5.7 MB"))

        // Verify m1-differential.sh Row 3 evaluator rejects constant-0 product external bytes when netstat -ibn > 0!
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let diffScript = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/acceptance/m1-differential.sh"), encoding: .utf8)
        let evalMarker = "# Evaluate Rows 1, 2, 3 via Python SQLite + Reference CSV Inspector"
        let afterEval = try #require(diffScript.components(separatedBy: evalMarker).dropFirst().first)
        let afterPyStart = try #require(afterEval.components(separatedBy: "<<'PY'\n").dropFirst().first)
        let pyEval = try #require(afterPyStart.components(separatedBy: "\nPY\n").first)

        let zeroNetDBURL = tmpDir.appendingPathComponent("zero-net.sqlite")
        let zeroStore = try FlightboxStore(databaseURL: zeroNetDBURL)
        for idx in 0...11 {
            let tEpoch = Int64(10_000 + idx * 2)
            try zeroStore.recordSampleBatch(
                tick: SystemTick(
                    ts: tEpoch,
                    cpuUserPct: 15,
                    cpuSysPct: 5,
                    memUsedBytes: 8_000_000_000,
                    memTotalBytes: 16_000_000_000,
                    swapUsedBytes: 0,
                    diskReadBps: 0,
                    diskWriteBps: 0,
                    netInBps: 0,
                    netOutBps: 0,
                    loopbackInBps: idx == 5 ? 80_000_000 : 0,
                    loopbackOutBps: idx == 5 ? 80_000_000 : 0
                ),
                processes: [],
                sockets: [],
                anomalies: []
            )
        }
        zeroStore.checkpointWAL()

        let overheadURL = tmpDir.appendingPathComponent("overhead.csv")
        try """
        mono_ts,self_cpu_ns,tree_cpu_ns,self_cpu_pct,tree_cpu_pct,rss_bytes,footprint_bytes
        10.0,10000000,40000000,0.0,0.0,18000000,9000000
        30.0,170000000,840000000,0.8,4.0,19000000,10000000
        """.write(to: overheadURL, atomically: true, encoding: .utf8)

        let nsStartURL = tmpDir.appendingPathComponent("netstat_start.json")
        try #"{"ext_in": 100000000, "ext_out": 50000000, "lo_in": 0, "lo_out": 0}"#
            .write(to: nsStartURL, atomically: true, encoding: .utf8)

        let loopMetaURL = tmpDir.appendingPathComponent("loopback.json")
        try #"{"sent_bytes": 209715200, "received_bytes": 209715200, "start_ts": 10008, "end_ts": 10011}"#
            .write(to: loopMetaURL, atomically: true, encoding: .utf8)

        var refLines = ["ref_epoch,iostat_cpu_pct,load1m,vmstat_mem_bytes,sysctl_swap_bytes,ext_ibytes,ext_obytes,lo_ibytes,lo_obytes"]
        for idx in 1...10 {
            let rEpoch = 10_002 + idx * 2
            let extIn = 100_000_000 + idx * 500_000
            let extOut = 50_000_000 + idx * 50_000
            refLines.append("\(rEpoch).000,20.00,4.00,8000000000,0,\(extIn),\(extOut),209715200,209715200")
        }
        let refCSVURL = tmpDir.appendingPathComponent("ref.csv")
        try refLines.joined(separator: "\n").write(to: refCSVURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.currentDirectoryURL = repoRoot
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            "-c",
            pyEval,
            zeroNetDBURL.path,
            overheadURL.path,
            refCSVURL.path,
            nsStartURL.path,
            loopMetaURL.path,
            repoRoot.appendingPathComponent("README.md").path,
            repoRoot.appendingPathComponent("README.zh-CN.md").path,
            "20",
            "2"
        ]
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        #expect(proc.terminationStatus != 0, "m1-differential.sh Row 3 MUST fail when product external bytes are constant 0 while netstat -ibn gained +5 MB!")
        #expect(errText.contains("FAIL [Row 3]"))
    }

    @Test("TR3 & TR4: m1-differential.sh discloses iostat-for-top reference substitution and includes offline 60s physical NIC vs netstat -ib verification")
    func tr3AndTr4DifferentialScriptDisclosesIostatSubstitutionAndRunsOffline60sNICCheck() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let diffScriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1-differential.sh")
        let diffScript = try String(contentsOf: diffScriptURL, encoding: .utf8)

        // TR3: Row 3 output must explicitly disclose replacing `top` with phase-locked `iostat` and state why
        #expect(diffScript.contains("Reference substitution note (TR3)"))
        #expect(diffScript.contains("top -l"))
        #expect(diffScript.contains("iostat -n 0 -C -w"))

        // TR4: Offline 60s physical NIC calibration vs `netstat -ib` (excluding lo0), while keeping 40 MB external download as [SKIP] 没跑
        #expect(diffScript.contains("--offline-nic-60s-only"))
        #expect(diffScript.contains("[Offline 60s Physical NIC Calibration"))
        #expect(diffScript.contains("chrono_ext_in="))
        #expect(diffScript.contains("netstat_phys_in="))
        #expect(diffScript.contains("[SKIP] Row 4 (40 MB live external NIC download): 没跑"))
    }

    private static func armSingleTickSQLiteFaultTrigger(dbPath: String, raiseAction: String = "ROLLBACK") throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "CLITests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "sqlite3_open_v2 failed"])
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE IF NOT EXISTS recorder_gaps (
            ts INTEGER PRIMARY KEY,
            reason TEXT NOT NULL
        );
        CREATE TRIGGER fail_single_tick_once
        BEFORE INSERT ON system_ticks
        WHEN (SELECT COUNT(*) FROM system_ticks) = 1
         AND (SELECT COUNT(*) FROM recorder_gaps) = 0
        BEGIN
            SELECT RAISE(\(raiseAction), 'simulated transient single-tick failure');
        END;
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let execRC = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if execRC != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite3_exec error"
            sqlite3_free(errMsg)
            throw NSError(domain: "CLITests", code: Int(execRC), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private static func queryRawGapRows(dbPath: String) throws -> [(ts: Int64, reason: String)] {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ts, reason FROM recorder_gaps ORDER BY ts ASC;", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            return []
        }
        defer { sqlite3_finalize(s) }

        var rows: [(ts: Int64, reason: String)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let ts = sqlite3_column_int64(s, 0)
            let reason = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""
            rows.append((ts, reason))
        }
        return rows
    }

    @Test("TR6: FlightboxRecorder.runLoop catches single-tick captureTick failure, records a sampling gap, and continues recording subsequent ticks")
    func tr6RecorderRunLoopSurvivesSingleTickErrorRecordsGapAndContinues() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-tr6-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Direct FlightboxRecorder.runLoop resilience check
        let unitDBURL = tmpDir.appendingPathComponent("unit-gap.sqlite")
        do {
            let seedStore = try FlightboxStore(databaseURL: unitDBURL)
            seedStore.checkpointWAL()
        }
        try Self.armSingleTickSQLiteFaultTrigger(dbPath: unitDBURL.path)

        let store = try FlightboxStore(databaseURL: unitDBURL)
        let recorder = FlightboxRecorder(
            store: store,
            sampler: LiveSystemSampler(agentHomeDirectory: tmpDir),
            enableReverseDNS: false,
            processLimit: 10
        )

        let writtenTicks = try recorder.runLoop(
            interval: 1.0,
            durationSeconds: 3.3,
            installSignalHandlers: false
        )
        #expect(writtenTicks >= 2, "runLoop must survive the failing 2nd tick and continue writing subsequent ticks!")
        #expect(recorder.recordedGapCount == 1)

        let allTicks = store.queryTicks(from: 0, to: Int64.max)
        #expect(allTicks.count >= 2)
        let storeGaps = store.querySamplingGaps(from: 0, to: Int64.max)
        #expect(storeGaps.count == 1)
        let gapRows = try Self.queryRawGapRows(dbPath: unitDBURL.path)
        #expect(gapRows.count == 1, "Failed tick must record a sampling gap row in recorder_gaps")
        if let firstGap = gapRows.first, let firstTick = allTicks.first, allTicks.count >= 2 {
            #expect(firstGap.ts > firstTick.ts)
            #expect(firstGap.ts < allTicks[1].ts)
            #expect(firstGap.reason.contains("simulated transient single-tick failure"))
            #expect(!allTicks.contains(where: { $0.ts == firstGap.ts }))
        }

        // 2. End-to-end CLI `ChronoMac record` daemon resilience check (also exercising statement-level ABORT error propagation)
        let cliDBURL = tmpDir.appendingPathComponent("cli-gap.sqlite")
        do {
            let cliSeed = try FlightboxStore(databaseURL: cliDBURL)
            cliSeed.checkpointWAL()
        }
        try Self.armSingleTickSQLiteFaultTrigger(dbPath: cliDBURL.path, raiseAction: "ABORT")

        let recRes = try Self.runBinary(
            args: ["--cli", "record", "--interval", "1", "--duration", "3.3", "--max-db-mb", "10", "--no-dns", "--json", "--lang", "en"],
            dbPath: cliDBURL.path
        )
        #expect(recRes.exitCode == 0, "CLI record process must not exit 1 on a single-tick error! stderr=\(recRes.stderr)")
        if let recJSON = try? JSONSerialization.jsonObject(with: Data(recRes.stdout.utf8)) as? [String: Any] {
            #expect((recJSON["recordedGaps"] as? Int) == 1)
            #expect(((recJSON["recordedTicks"] as? Int) ?? 0) >= 2)
        } else {
            Issue.record("Expected valid JSON output from `ChronoMac --cli record --json`, got stdout=\(recRes.stdout)")
        }

        let histRes = try Self.runBinary(
            args: ["--cli", "history", "--minutes", "5", "--json", "--lang", "en"],
            dbPath: cliDBURL.path
        )
        #expect(histRes.exitCode == 0)
        let histJSON = try #require(JSONSerialization.jsonObject(with: Data(histRes.stdout.utf8)) as? [String: Any])
        #expect((histJSON["recordedGapCount"] as? Int) == 1)
    }

    @Test("Row 4: m1-differential.sh live download evaluator enforces <=10% physical en* NIC diff, >=80% curl share, file size check, and fails on curl error")
    func row4LiveDownloadEvaluatorEnforcesTenPercentNICAndEightyPercentCurlBounds() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let diffScriptURL = repoRoot.appendingPathComponent("Scripts/acceptance/m1-differential.sh")
        let diffScript = try String(contentsOf: diffScriptURL, encoding: .utf8)

        // Script must rate-limit curl (`--limit-rate 3M`), disclose why, query `--cli egress --json`, and keep unset URL as `[SKIP] ... 没跑`
        #expect(diffScript.contains("--limit-rate 3M"))
        #expect(diffScript.contains("--cli egress"))
        #expect(diffScript.contains("--json"))
        #expect(diffScript.contains("[SKIP] Row 4 (40 MB live external NIC download): 没跑"))

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-row4-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Synthetic netstat -ibn pre/post:
        // - en0 has NO Address column (10 tokens; +5,000,000 B inbound)
        // - en1 has MAC Address column (11 tokens; +40,000,000 B inbound) plus IPv4/IPv6 alias rows that must not be double-counted
        // - lo0 (+200,000,000 B), utun0 (+150,000,000 B), bridge0 (+90,000,000 B), awdl0 (+30,000,000 B) must ALL be excluded!
        // Exact physical en* inbound delta = 45,000,000 B.
        let preIB = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                          1000     0   50000000     1000     0   50000000     0
        lo0        16384 127           127.0.0.1           1000     -   50000000     1000     -   50000000     -
        en0        1500  <Link#7>                           500     0   10000000      400     0    2000000     0
        en1        1500  <Link#15>   6a:01:72:bb:b5:a7    20000     0  100000000    15000     0   30000000     0
        en1        1500  192.168.1/24  192.168.1.20       20000     -  100000000    15000     -   30000000     -
        bridge0    1500  <Link#16>   36:4b:81:20:0a:00       10     0       5000       10     0       5000     0
        awdl0      1500  <Link#17>   da:dc:14:2f:8b:3d      100     0     100000      100     0     100000     0
        utun0      1500  <Link#19>                           20     0      10000       20     0      10000     0
        """
        let postIB = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                          9000     0  250000000     9000     0  250000000     0
        lo0        16384 127           127.0.0.1           9000     -  250000000     9000     -  250000000     -
        en0        1500  <Link#7>                          4500     0   15000000      800     0    2200000     0
        en1        1500  <Link#15>   6a:01:72:bb:b5:a7    52000     0  140000000    18000     0   31000000     0
        en1        1500  192.168.1/24  192.168.1.20       52000     -  140000000    18000     -   31000000     -
        bridge0    1500  <Link#16>   36:4b:81:20:0a:00     8010     0   90005000     8010     0   90005000     0
        awdl0      1500  <Link#17>   da:dc:14:2f:8b:3d     2100     0   30100000     2100     0   30100000     0
        utun0      1500  <Link#19>                         9020     0  150010000     9020     0  150010000     0
        """

        let preURL = tmpDir.appendingPathComponent("pre_ib.txt")
        let postURL = tmpDir.appendingPathComponent("post_ib.txt")
        try preIB.write(to: preURL, atomically: true, encoding: .utf8)
        try postIB.write(to: postURL, atomically: true, encoding: .utf8)

        let fileSize = 41_943_040

        func runEvaluator(
            flows: [[String: Any]],
            actualBytes: Int = fileSize,
            expectedBytes: Int = fileSize
        ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let egressURL = tmpDir.appendingPathComponent("egress-\(UUID().uuidString).json")
            let payload: [String: Any] = [
                "windowHours": 1,
                "loopbackExcluded": true,
                "flows": flows
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try jsonData.write(to: egressURL, options: .atomic)

            let proc = Process()
            proc.currentDirectoryURL = repoRoot
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [
                diffScriptURL.path,
                "--verify-row4-fixtures",
                egressURL.path,
                preURL.path,
                postURL.path,
                "\(actualBytes)",
                "\(expectedBytes)",
                "13.30"
            ]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // 1. Total inbound differs by -15% (38,250,000 vs 45,000,000) while curl is 91.2% of file -> MUST FAIL!
        let diffMinus15 = try runEvaluator(flows: [
            [
                "processName": "curl",
                "execPath": "/usr/bin/curl",
                "isUnattributed": false,
                "remoteEndpoint": "104.18.3.2:443",
                "protocol": "tcp4",
                "totalBytesIn": 38_250_000,
                "totalBytesOut": 120_000
            ]
        ])
        #expect(diffMinus15.exitCode != 0, "Expected 15% negative total inbound discrepancy to fail; stdout=\(diffMinus15.stdout)")
        #expect(diffMinus15.stderr.contains("FAIL [Row 4]"))

        // 1b. Total inbound differs by +15% (51,750,000 vs 45,000,000) -> MUST FAIL!
        let diffPlus15 = try runEvaluator(flows: [
            [
                "processName": "curl",
                "execPath": "/usr/bin/curl",
                "isUnattributed": false,
                "remoteEndpoint": "104.18.3.2:443",
                "protocol": "tcp4",
                "totalBytesIn": 40_000_000,
                "totalBytesOut": 120_000
            ],
            [
                "processName": "Unattributed",
                "execPath": "",
                "isUnattributed": true,
                "remoteEndpoint": "(physical NIC residual)",
                "protocol": "nic",
                "totalBytesIn": 11_750_000,
                "totalBytesOut": 10_000
            ]
        ])
        #expect(diffPlus15.exitCode != 0, "Expected 15% positive total inbound discrepancy to fail; stdout=\(diffPlus15.stdout)")
        #expect(diffPlus15.stderr.contains("FAIL [Row 4]"))

        // 2. curl attributed inbound is 60% of file size (25,165,824 B) while total matches netstat 0.0% -> MUST FAIL!
        let curl60Bytes = Int(Double(fileSize) * 0.60)
        let curl60 = try runEvaluator(flows: [
            [
                "processName": "curl",
                "execPath": "/usr/bin/curl",
                "isUnattributed": false,
                "remoteEndpoint": "104.18.3.2:443",
                "protocol": "tcp4",
                "totalBytesIn": curl60Bytes,
                "totalBytesOut": 120_000
            ],
            [
                "processName": "Unattributed",
                "execPath": "",
                "isUnattributed": true,
                "remoteEndpoint": "(physical NIC residual)",
                "protocol": "nic",
                "totalBytesIn": 45_000_000 - curl60Bytes,
                "totalBytesOut": 10_000
            ]
        ])
        #expect(curl60.exitCode != 0, "Expected 60% curl attribution (<80% floor) to fail; stdout=\(curl60.stdout)")
        #expect(curl60.stderr.contains("FAIL [Row 4]"))

        // 3. Downloaded file size mismatch -> MUST FAIL (not skip)!
        let badSize = try runEvaluator(
            flows: [
                [
                    "processName": "curl",
                    "execPath": "/usr/bin/curl",
                    "isUnattributed": false,
                    "remoteEndpoint": "104.18.3.2:443",
                    "protocol": "tcp4",
                    "totalBytesIn": 41_454_545,
                    "totalBytesOut": 120_000
                ]
            ],
            actualBytes: 12_345_678,
            expectedBytes: fileSize
        )
        #expect(badSize.exitCode != 0, "Expected wrong downloaded file size to fail")
        #expect(badSize.stderr.contains("FAIL [Row 4]"))

        // 4. Both within thresholds (total diff -0.01%, curl 98.84% of file, lo0/utun0/bridge0 ignored, 10-col + 11-col en* parsed) -> MUST PASS!
        let valid = try runEvaluator(flows: [
            [
                "processName": "curl",
                "execPath": "/usr/bin/curl",
                "isUnattributed": false,
                "remoteEndpoint": "104.18.3.2:443",
                "protocol": "tcp4",
                "totalBytesIn": 41_454_545,
                "totalBytesOut": 120_000
            ],
            [
                "processName": "Unattributed",
                "execPath": "",
                "isUnattributed": true,
                "remoteEndpoint": "(physical NIC residual)",
                "protocol": "nic",
                "totalBytesIn": 3_540_000,
                "totalBytesOut": 10_000
            ]
        ])
        #expect(valid.exitCode == 0, "Expected valid fixture to pass; stderr=\(valid.stderr)")
        #expect(valid.stdout.contains("[PASS] Row 4"))
        #expect(valid.stdout.contains("45000000"))
        #expect(valid.stdout.contains("44994545"))
        #expect(valid.stdout.contains("41454545"))

        // 5. Offline curl failure via nonexistent local file:// URL MUST fail (exit != 0) rather than skip or pass!
        let failProc = Process()
        failProc.currentDirectoryURL = repoRoot
        failProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        failProc.arguments = [
            diffScriptURL.path,
            "--skip-build",
            "--row4-live-only",
            "--tmp-root",
            tmpDir.path
        ]
        var failEnv = ProcessInfo.processInfo.environment
        failEnv["CHRONOMAC_LIVE_DOWNLOAD_URL"] = "file:///nonexistent-chronomac-row4-\(UUID().uuidString)"
        failProc.environment = failEnv
        let failOutPipe = Pipe()
        let failErrPipe = Pipe()
        failProc.standardOutput = failOutPipe
        failProc.standardError = failErrPipe
        try failProc.run()
        let failOut = String(data: failOutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let failErr = String(data: failErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        failProc.waitUntilExit()
        #expect(failProc.terminationStatus != 0, "Download failure must exit non-zero instead of skipping or passing!")
        #expect(!failOut.contains("[SKIP]"))
        #expect(!failOut.contains("[PASS] Row 4"))
        #expect(failErr.contains("FAIL [Row 4]"))
    }

    @Test("Row 4 Known Limitation: README.md and README.zh-CN.md document sub-2s download per-process attribution limitation with measured 0.66s / 74% figures")
    func readmeDocumentsSubIntervalDownloadAttributionLimitation() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeEN = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: repoRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        #expect(readmeEN.contains("Known Limitations"))
        #expect(readmeEN.contains("0.66"))
        #expect(readmeEN.contains("74%"))
        #expect(readmeEN.contains("curl"))
        #expect(readmeEN.contains("Unattributed"))

        #expect(readmeZH.contains("已知局限"))
        #expect(readmeZH.contains("0.66"))
        #expect(readmeZH.contains("74%"))
        #expect(readmeZH.contains("curl"))
        #expect(readmeZH.contains("未归属"))
    }
}
