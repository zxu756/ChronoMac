import ChronoMacCore
import Darwin
import Foundation
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
}
