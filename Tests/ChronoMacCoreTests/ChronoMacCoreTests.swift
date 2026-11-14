import ChronoMacCore
import Foundation
import Testing

@Suite("ChronoMac Core Telemetry & Forensic Storage Tests", .timeLimit(.minutes(1)))
struct ChronoMacCoreTests {
    @Test("Parses sysctl vm.swapusage strings across units")
    func parseSwapUsage() {
        let mbLine = "total = 3072.00M  used = 1686.69M  free = 1385.31M  (encrypted)"
        let parsedMB = MachSystemSampler.parseSwapUsageString(mbLine)
        #expect(parsedMB > 1_760_000_000 && parsedMB < 1_775_000_000)

        let gbLine = "total = 8.00G  used = 2.50G  free = 5.50G  (encrypted)"
        #expect(MachSystemSampler.parseSwapUsageString(gbLine) == Int64(2.5 * 1024 * 1024 * 1024))

        let zeroLine = "total = 0.00M  used = 0.00M  free = 0.00M"
        #expect(MachSystemSampler.parseSwapUsageString(zeroLine) == 0)
    }

    @Test("NettopDeltaParser computes per-PID and external socket deltas while filtering loopback")
    func nettopDeltaParsing() {
        let parser = NettopDeltaParser()
        let syntheticTick1 = """
        time,state,bytes_in,bytes_out,
        claude.49201,,10000,20000,
        tcp4 192.168.1.15:54321<->160.79.104.10:443,Established,10000,20000,
        tcp4 127.0.0.1:51234<->127.0.0.1:11434,Established,500000,500000,
        """
        let base = parser.ingestCSV(syntheticTick1, now: 1_000.0)
        #expect(base.totalInBps == 0)
        #expect(base.externalSocketDeltas.isEmpty)

        let syntheticTick2 = """
        time,state,bytes_in,bytes_out,
        claude.49201,,30000,80000,
        tcp4 192.168.1.15:54321<->160.79.104.10:443,Established,30000,80000,
        tcp4 127.0.0.1:51234<->127.0.0.1:11434,Established,900000,900000,
        """
        let second = parser.ingestCSV(syntheticTick2, now: 1_002.0)
        // dt = 2.0s: dIn = 20_000 -> 10_000 B/s; dOut = 60_000 -> 30_000 B/s
        #expect(second.perPIDBytesInDelta[49201] == 10_000)
        #expect(second.perPIDBytesOutDelta[49201] == 30_000)
        #expect(second.externalSocketDeltas.count == 1)
        #expect(second.externalSocketDeltas.first?.remoteEndpoint == "160.79.104.10:443")
        #expect(second.externalSocketDeltas.first?.deltaBytesOut == 60_000)

        #expect(NettopDeltaParser.extractRemoteIP("17.57.145.41:5223") == "17.57.145.41")
        #expect(NettopDeltaParser.extractRemoteIP("2606:4700::6810:85e5.443") == "2606:4700::6810:85e5")
    }

    @Test("FlightboxStore persists batches, answers forensic queries, and compacts 3-tier rollups")
    func flightboxRoundTripAndCompaction() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbURL = tmpDir.appendingPathComponent("flightbox.sqlite")
        let store = try FlightboxStore(databaseURL: dbURL)

        let now: Int64 = 1_800_000_000
        let staleTs = now - 700_000 // > 7 days ago -> should be pruned
        let tier1SourceA = now - 10_800 // 3h ago -> compacts to 15s Tier 1
        let tier1SourceB = tier1SourceA + 2 // Same 15s bucket as A if aligned

        let alignedBase = ((now - 10_800) / 15) * 15
        let tickOld = SystemTick(
            ts: staleTs, cpuUserPct: 12, cpuSysPct: 3, memUsedBytes: 8_000_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 0, diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 0
        )
        let tickLow = SystemTick(
            ts: alignedBase + 2, cpuUserPct: 18, cpuSysPct: 4, memUsedBytes: 9_000_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 128_000_000, diskReadBps: 1000, diskWriteBps: 2000, netInBps: 500, netOutBps: 800
        )
        let tickPeak = SystemTick(
            ts: alignedBase + 6, cpuUserPct: 76, cpuSysPct: 14, thermalGrade: .serious, memUsedBytes: 14_500_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 2_400_000_000, diskReadBps: 90_000_000, diskWriteBps: 40_000_000, netInBps: 10_000, netOutBps: 12_000_000
        )
        _ = tier1SourceB

        let proc = ProcessSample(
            ts: alignedBase + 6,
            pid: 7777,
            ppid: 1,
            name: " runaway-worker",
            execPath: "/usr/local/bin/runaway-worker",
            cpuPct: 245.0,
            rssBytes: 6_000_000_000,
            netOutBps: 12_000_000
        )
        let sock = SocketFlowRecord(
            bucketHour: (alignedBase / 3600) * 3600,
            execPath: "/usr/local/bin/runaway-worker",
            processName: "runaway-worker",
            remoteEndpoint: "54.231.10.20:443",
            totalBytesIn: 40_000,
            totalBytesOut: 25_000_000,
            firstSeen: alignedBase,
            lastSeen: alignedBase + 6
        )
        let anomaly = AnomalyBookmark(
            id: "test-bm-1",
            ts: alignedBase + 6,
            kind: .swapSurge,
            severity: 3,
            culpritName: "runaway-worker",
            culpritExec: "/usr/local/bin/runaway-worker",
            metricBadge: "+2.2 GB swap",
            summary: "Test swap spike"
        )

        try store.recordSampleBatch(tick: tickOld, processes: [], sockets: [], anomalies: [])
        try store.recordSampleBatch(tick: tickLow, processes: [], sockets: [], anomalies: [])
        try store.recordSampleBatch(tick: tickPeak, processes: [proc], sockets: [sock], anomalies: [anomaly])
        store.updateHostname(for: "54.231.10.20:443", hostname: "s3.amazonaws.com")

        let (_, nearestProcs) = store.queryNearestProcesses(at: alignedBase + 8, livePIDs: [1, 2])
        #expect(nearestProcs.count == 1)
        #expect(nearestProcs.first?.pid == 7777)
        #expect(nearestProcs.first?.isAliveNow == false)

        let flows = store.querySocketFlows(sinceTs: alignedBase - 60)
        #expect(flows.first?.hostname == "s3.amazonaws.com")
        #expect(flows.first?.totalBytesOut == 25_000_000)

        // Execute compaction: staleTs (>7d) deleted; alignedBase+2 & alignedBase+6 rolled into 1 peak-preserving Tier 1 row!
        try store.runRollupAndRetention(now: now)
        let allRemaining = store.queryTicks(from: staleTs - 100, to: now)
        #expect(allRemaining.count == 1)
        #expect(allRemaining.first?.tier == .rollup15s)
        #expect(allRemaining.first?.cpuUserPct == 76)
        #expect(allRemaining.first?.swapUsedBytes == 2_400_000_000)
    }

    @Test("AnomalyDetector triggers swap surge, outbound burst, CPU saturation, and respects cooldown")
    func anomalyDetectionAndCooldown() {
        let detector = AnomalyDetector(cooldownSeconds: 120)
        let t0 = SystemTick(
            ts: 1000, cpuUserPct: 10, cpuSysPct: 2, memUsedBytes: 8_000_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 100_000_000, diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 0
        )
        #expect(detector.evaluate(tick: t0, processes: [], sockets: []).isEmpty)

        let hotProc = ProcessSample(
            ts: 1030, pid: 901, ppid: 1, name: "indexer", execPath: "/opt/indexer",
            cpuPct: 260.0, rssBytes: 5_000_000_000, netOutBps: 9_000_000
        )
        let t1 = SystemTick(
            ts: 1030, cpuUserPct: 75, cpuSysPct: 12, thermalGrade: .serious, memUsedBytes: 14_000_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 900_000_000, diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 9_000_000
        )
        let alerts = detector.evaluate(tick: t1, processes: [hotProc], sockets: [])
        let kinds = Set(alerts.map(\.kind))
        #expect(kinds.contains(.swapSurge))
        #expect(kinds.contains(.egressBurst))
        #expect(kinds.contains(.runawayCPU))
        #expect(kinds.contains(.thermalThrottle))

        // Immediate repeat within cooldown should be suppressed
        let t2 = SystemTick(
            ts: 1040, cpuUserPct: 75, cpuSysPct: 12, thermalGrade: .serious, memUsedBytes: 14_000_000_000,
            memTotalBytes: 16_000_000_000, swapUsedBytes: 1_600_000_000, diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 9_000_000
        )
        #expect(detector.evaluate(tick: t2, processes: [hotProc], sockets: []).isEmpty)
    }

    @Test("ChronoMCPServer responds to JSON-RPC initialize, tools/list, and tools/call")
    func mcpServerJSONRPC() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try FlightboxStore(databaseURL: tmpDir.appendingPathComponent("flightbox.sqlite"))
        let now = Int64(Date().timeIntervalSince1970)
        try store.recordSampleBatch(
            tick: SystemTick(
                ts: now - 30, cpuUserPct: 44.0, cpuSysPct: 8.0, memUsedBytes: 12_000_000_000,
                memTotalBytes: 24_000_000_000, swapUsedBytes: 512_000_000, diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 2_048_000
            ),
            processes: [
                ProcessSample(ts: now - 30, pid: 4242, ppid: 1, name: "claude", execPath: "/usr/local/bin/claude", cpuPct: 42.0, rssBytes: 900_000_000)
            ],
            sockets: [],
            anomalies: []
        )

        let mcp = ChronoMCPServer(store: store)
        let initResp = try #require(mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        #expect(initResp.contains("chronomac-mcp"))

        let listResp = try #require(mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(listResp.contains("chrono_inspect_timestamp"))

        let callResp = try #require(
            mcp.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chrono_inspect_timestamp","arguments":{"minutes_ago":1}}}"#)
        )
        #expect(callResp.contains("4242"))
        #expect(callResp.contains("claude"))
    }

    @Test("Exports 2x Retina marketing PNG screenshots cleanly in EN and zh-Hans")
    @MainActor
    func exportMarketingScreenshots() throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("chronomac-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outDir) }
        try ChronoScreenshotExporter.exportMarketingScreenshots(to: outDir, language: .en)
        try ChronoScreenshotExporter.exportMarketingScreenshots(to: outDir, language: .zhHans)

        let mainData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-main.png"))
        let menuData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-menubar.png"))
        let mainZhData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-main-zh.png"))
        let menuZhData = try Data(contentsOf: outDir.appendingPathComponent("screenshot-menubar-zh.png"))
        #expect(mainData.count > 40_000)
        #expect(menuData.count > 15_000)
        #expect(mainZhData.count > 40_000)
        #expect(menuZhData.count > 15_000)
    }

    @Test("AppLocalizer resolves --lang CLI, PreferenceStore, and Chinese system locale with live toggle")
    @MainActor
    func localizationResolutionAndToggle() throws {
        let prefs = InMemoryPreferenceStore()
        let key = "io.github.zxu756.ChronoMac.language"

        // 1. Auto-detects Chinese from Locale.preferredLanguages when PreferenceStore & CLI are unset
        let zhAuto = AppLocalizer(
            arguments: ["ChronoMac"],
            preferenceStore: prefs,
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            defaultsKey: key
        )
        #expect(zhAuto.language == .zhHans)
        #expect(zhAuto.language.badge == "中文")
        #expect(zhAuto.L("Live", "实时") == "实时")

        // 2. Falls back to English on non-Chinese system locale
        let enAuto = AppLocalizer(
            arguments: ["ChronoMac"],
            preferenceStore: prefs,
            preferredLanguages: ["en-US"],
            defaultsKey: key
        )
        #expect(enAuto.language == .en)
        #expect(enAuto.language.badge == "EN")
        #expect(enAuto.L("Live", "实时") == "Live")

        // 3. Toggle persists to PreferenceStore and flips zh-Hans <-> en
        enAuto.toggle()
        #expect(enAuto.language == .zhHans)
        #expect(prefs.string(forKey: key) == "zh-Hans")

        enAuto.toggle()
        #expect(enAuto.language == .en)
        #expect(prefs.string(forKey: key) == "en")

        // 4. PreferenceStore overrides system locale
        prefs.set("zh-Hans", forKey: key)
        let fromDefaults = AppLocalizer(
            arguments: ["ChronoMac"],
            preferenceStore: prefs,
            preferredLanguages: ["en-US"],
            defaultsKey: key
        )
        #expect(fromDefaults.language == .zhHans)

        // 5. CLI --lang flag overrides both PreferenceStore and system locale
        let cliOverrideEN = AppLocalizer(
            arguments: ["ChronoMac", "--lang", "en"],
            preferenceStore: prefs,
            preferredLanguages: ["zh-Hans-CN"],
            defaultsKey: key
        )
        #expect(cliOverrideEN.language == .en)

        let cliOverrideZH = AppLocalizer(
            arguments: ["ChronoMac", "--export-screenshots", "/tmp", "--lang=zh"],
            preferenceStore: prefs,
            preferredLanguages: ["en-US"],
            defaultsKey: key
        )
        #expect(cliOverrideZH.language == .zhHans)
        #expect(ThermalGrade.serious.label(in: .zhHans) == "降频限温")
        #expect(AnomalyKind.swapSurge.label(in: .zhHans) == "交换激增")
    }

    @Test("T18: AppLocalizer default init uses isolated in-memory store without touching UserDefaults.standard and Sources contain zero runtime bundle/test checks")
    @MainActor
    func appLocalizerEntryPointInjectionAndZeroEnvironmentBranching() throws {
        // 1. Static source scan across Sources/ChronoMacCore and Sources/ChronoMac: zero .app / test-runner environment checks
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesDir = repoRoot.appendingPathComponent("Sources")
        let forbiddenTokens = [
            "bundlePath",
            ".hasSuffix(\".app\")",
            "XCTest",
            "XCTestConfigurationFilePath",
            "SWIFT_TESTING"
        ]
        let enumerator = try #require(FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let relPath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for tok in forbiddenTokens where content.contains(tok) {
                violations.append("\(relPath) contains '\(tok)'")
            }
        }
        #expect(violations.isEmpty, "Forbidden runtime environment branching in Sources/: \(violations)")

        // 2. Default AppLocalizer() uses an isolated InMemoryPreferenceStore (0 writes to UserDefaults.standard)
        let testKey = "io.github.zxu756.ChronoMac.t18.verify"
        let beforeStandard = UserDefaults.standard.object(forKey: AppLocalizer.bundleLanguageKey) as? String
        let beforeCustom = UserDefaults.standard.object(forKey: testKey) as? String

        let zeroArgLoc = AppLocalizer()
        #expect(zeroArgLoc.preferenceStore is InMemoryPreferenceStore)
        zeroArgLoc.setLanguage(.zhHans)
        zeroArgLoc.setLanguage(.en)

        let defaultLoc = AppLocalizer(arguments: ["ChronoMac"], preferredLanguages: ["en-US"], defaultsKey: testKey)
        #expect(defaultLoc.preferenceStore is InMemoryPreferenceStore)
        #expect(defaultLoc.language == .en)
        defaultLoc.setLanguage(.zhHans)
        #expect(defaultLoc.language == .zhHans)
        #expect(defaultLoc.preferenceStore.string(forKey: testKey) == "zh-Hans")
        defaultLoc.setLanguage(.en)
        #expect(defaultLoc.language == .en)
        #expect(defaultLoc.preferenceStore.string(forKey: testKey) == "en")

        #expect(UserDefaults.standard.object(forKey: AppLocalizer.bundleLanguageKey) as? String == beforeStandard)
        #expect(UserDefaults.standard.object(forKey: testKey) as? String == beforeCustom)

        // 3. AppLocalizer(preferenceStore: UserDefaultsPreferenceStore(...)) persists into the injected UserDefaults instance
        let injectedDefaults = EphemeralMemoryUserDefaults()
        let udStore = UserDefaultsPreferenceStore(injectedDefaults)
        let persistedLoc = AppLocalizer(
            arguments: ["ChronoMac"],
            preferenceStore: udStore,
            preferredLanguages: ["en-US"],
            defaultsKey: testKey
        )
        #expect(persistedLoc.language == .en)
        persistedLoc.setLanguage(.zhHans)
        #expect(injectedDefaults.string(forKey: testKey) == "zh-Hans")

        let reloadedLoc = AppLocalizer(
            arguments: ["ChronoMac"],
            preferenceStore: UserDefaultsPreferenceStore(injectedDefaults),
            preferredLanguages: ["en-US"],
            defaultsKey: testKey
        )
        #expect(reloadedLoc.language == .zhHans)
    }
}

/// Pure in-memory `UserDefaults` test double so `UserDefaultsPreferenceStore` is exercised end-to-end
/// without invoking `cfprefsd` or creating `.plist` files under `~/Library/Preferences`.
private final class EphemeralMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    override init?(suiteName suitename: String?) {
        super.init(suiteName: nil)
    }

    convenience init() {
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }
}
