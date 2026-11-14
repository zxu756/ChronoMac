import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

@MainActor
public final class ChronoMonitor: ObservableObject {
    @Published public var selectedRange: TimeRangeWindow = .sixHours {
        didSet { reloadWindowFromStore() }
    }
    @Published public var selectedSortOrder: ProcessSortOrder = .cpu {
        didSet { refreshDisplayedProcesses() }
    }
    @Published public var ticks: [SystemTick] = []
    @Published public var scrubbedTimestamp: Int64?
    @Published public var displayedSnapshotTs: Int64?
    @Published public var displayedProcesses: [ProcessSample] = []
    @Published public var selectedProcessExecPath: String? {
        didSet { reloadSocketFlows() }
    }
    @Published public var socketFlows: [SocketFlowRecord] = []
    @Published public var anomalies: [AnomalyBookmark] = []
    @Published public var agentWindows: [AgentBurstWindow] = []
    @Published public var statusBanner: String?

    public let isStaticPreview: Bool
    public let store: FlightboxStore?
    public let sampler: any SystemSamplerProtocol

    private let anomalyDetector = AnomalyDetector()
    private let dnsResolver = ReverseDNSResolver()
    private var livePIDs: Set<Int> = []
    private var sampleTimer: Timer?
    private var tickCounter: Int = 0

    public init(
        store: FlightboxStore? = nil,
        sampler: any SystemSamplerProtocol = LiveSystemSampler(),
        isStaticPreview: Bool = false,
        startSamplingTimer: Bool = true,
        sampleInterval: TimeInterval = 2.0
    ) {
        self.isStaticPreview = isStaticPreview
        self.sampler = sampler
        if isStaticPreview {
            self.store = store
        } else {
            self.store = try? (store ?? FlightboxStore())
            if startSamplingTimer {
                captureLiveTick()
                self.sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.captureLiveTick()
                    }
                }
            }
        }
    }

    public func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    public var isHistoricalReplay: Bool {
        scrubbedTimestamp != nil
    }

    public var activeTick: SystemTick? {
        if let scrub = scrubbedTimestamp {
            return ticks.min(by: { abs($0.ts - scrub) < abs($1.ts - scrub) })
        }
        return ticks.last
    }

    public var menuBarLabel: String {
        menuBarLabel(in: AppLocalizer.shared.language)
    }

    public func menuBarLabel(in language: AppLanguage) -> String {
        let prefixDemo = isStaticPreview ? "[DEMO] " : ""
        guard let latest = ticks.last else {
            return prefixDemo + (language == .zhHans ? "DVR 就绪" : "DVR Ready")
        }
        if latest.swapUsedBytes >= 1_073_741_824 {
            let prefix = language == .zhHans ? "交换" : "Swap"
            return prefixDemo + String(format: "%.0f%% · %@ %@", latest.totalCPUPct, prefix, ChronoFormatter.bytes(latest.swapUsedBytes))
        }
        return prefixDemo + String(format: "%.0f%% · ↑%@", latest.totalCPUPct, ChronoFormatter.rate(latest.netOutBps))
    }

    public func scrub(to timestamp: Int64?) {
        scrubbedTimestamp = timestamp
        refreshDisplayedProcesses()
    }

    private func refreshDisplayedProcesses() {
        guard !isStaticPreview, let store else {
            if let ts = scrubbedTimestamp, let match = previewSnapshotsByTs[ts] {
                displayedSnapshotTs = ts
                displayedProcesses = ProcessTreeSampler.sortProcesses(match, by: selectedSortOrder)
            } else if scrubbedTimestamp == nil, let latestTs = ticks.last?.ts, let match = previewSnapshotsByTs[latestTs] {
                displayedSnapshotTs = latestTs
                displayedProcesses = ProcessTreeSampler.sortProcesses(match, by: selectedSortOrder)
            }
            return
        }
        let target = scrubbedTimestamp ?? Int64(Date().timeIntervalSince1970)
        let (actual, list) = store.queryNearestProcesses(
            at: target,
            livePIDs: livePIDs,
            sortBy: selectedSortOrder
        )
        displayedSnapshotTs = actual
        displayedProcesses = list
    }

    public func jumpToAnomaly(_ bookmark: AnomalyBookmark) {
        scrub(to: bookmark.ts)
        if !bookmark.culpritExec.isEmpty {
            selectedProcessExecPath = bookmark.culpritExec
        }
    }

    public func returnToLive() {
        scrub(to: nil)
    }

    public func terminateProcess(_ proc: ProcessSample) {
        guard proc.isAliveNow, proc.pid > 1 else { return }
        let loc = AppLocalizer.shared
        if kill(pid_t(proc.pid), SIGTERM) == 0 {
            statusBanner = loc.L(
                "Sent SIGTERM to \(proc.name) (PID \(proc.pid)).",
                "已向 \(proc.name) (PID \(proc.pid)) 发送 SIGTERM。"
            )
            captureLiveTick()
        } else {
            statusBanner = loc.L(
                "Could not signal PID \(proc.pid) — check process ownership.",
                "无法向 PID \(proc.pid) 发送信号，请检查进程所有权。"
            )
        }
    }

    public func captureLiveTick(nowOverride: Int64? = nil) {
        guard !isStaticPreview, let store else { return }
        let now = nowOverride ?? Int64(Date().timeIntervalSince1970)
        let host = sampler.sampleHostState()
        let net = sampler.sampleNetwork(now: TimeInterval(now))
        let procSnap = sampler.sampleProcesses(
            ts: now,
            netInBpsByPID: net.perPIDBytesInDelta,
            netOutBpsByPID: net.perPIDBytesOutDelta,
            limit: 30
        )
        let procs = procSnap.processes
        self.livePIDs = procSnap.livePIDs

        let agentInfo = sampler.detectAgentActivity(now: now)
        self.agentWindows = agentInfo.recentWindows

        var pidToExec: [Int: String] = [:]
        for p in procs where !p.execPath.isEmpty {
            pidToExec[p.pid] = p.execPath
        }

        let bucketHour = (now / 3600) * 3600
        let socketRecords: [SocketFlowRecord] = net.externalSocketDeltas.map { s in
            // Never copy processName into execPath; leave "" if path cannot be resolved!
            let resolvedExec = pidToExec[s.pid] ?? sampler.resolveExecutablePath(pid: s.pid)
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
        try? store.recordSampleBatch(tick: tick, processes: procs, sockets: socketRecords, anomalies: detectedAnomalies)

        for s in socketRecords.prefix(8) {
            let storeRef = store
            Task {
                await dnsResolver.resolveIfNeeded(endpoint: s.remoteEndpoint) { endpoint, host in
                    storeRef.updateHostname(for: endpoint, hostname: host)
                }
            }
        }

        tickCounter += 1
        if tickCounter % 30 == 0 {
            try? store.runRollupAndRetention(now: now)
        }

        reloadWindowFromStore(referenceNow: now)
    }

    private func reloadWindowFromStore(referenceNow: Int64? = nil) {
        guard !isStaticPreview, let store else { return }
        let now = referenceNow ?? Int64(Date().timeIntervalSince1970)
        let start = now - selectedRange.durationSeconds
        ticks = store.queryTicks(from: start, to: now)
        anomalies = store.queryAnomalies(sinceTs: start, limit: 25)
        if scrubbedTimestamp == nil {
            let (actual, list) = store.queryNearestProcesses(
                at: now,
                livePIDs: livePIDs,
                sortBy: selectedSortOrder
            )
            displayedSnapshotTs = actual
            displayedProcesses = list
        }
        reloadSocketFlows(referenceNow: now)
    }

    private func reloadSocketFlows(referenceNow: Int64? = nil) {
        guard !isStaticPreview, let store else { return }
        let now = referenceNow ?? Int64(Date().timeIntervalSince1970)
        let start = now - selectedRange.durationSeconds
        socketFlows = store.querySocketFlows(sinceTs: start, execPathFilter: selectedProcessExecPath, limit: 20)
    }

    // MARK: - Deterministic Forensic DVR Demo Preview (`--demo` / `--export-screenshots`)

    private var previewSnapshotsByTs: [Int64: [ProcessSample]] = [:]

    public static func preview() -> ChronoMonitor {
        let m = ChronoMonitor(isStaticPreview: true, startSamplingTimer: false)
        // Anchor at 06:00:00 UTC so 6h window spans 00:00 .. 06:00 with a synthetic 03:14:00 demo spike
        let endTs: Int64 = 1_794_549_600
        let startTs: Int64 = endTs - 21_600
        let spikeTs: Int64 = startTs + 11_640
        let memTotal: Int64 = 24 * 1024 * 1024 * 1024

        var generatedTicks: [SystemTick] = []
        let count = 96
        let step = (endTs - startTs) / Int64(count)

        for idx in 0...count {
            let ts = startTs + Int64(idx) * step
            let distSpike = abs(Double(ts - spikeTs))
            let spikeBell = exp(-(distSpike * distSpike) / (2.0 * 780.0 * 780.0))
            let secondWaveDist = abs(Double(ts - (endTs - 3400)))
            let secondWave = exp(-(secondWaveDist * secondWaveDist) / (2.0 * 620.0 * 620.0))

            let wave = sin(Double(idx) * 0.27) * 4.5 + cos(Double(idx) * 0.13) * 3.0
            let cpuUser = min(84.0, max(6.0, 14.0 + wave + spikeBell * 64.0 + secondWave * 28.0))
            let cpuSys = min(15.0, max(2.5, 4.5 + spikeBell * 11.0 + secondWave * 4.5))
            let memUsed = Int64(Double(13_400_000_000) + spikeBell * 8_900_000_000 + secondWave * 3_100_000_000)
            let swapUsed = Int64(max(0.0, 420_000_000.0 + spikeBell * 6_450_000_000.0 + (ts > spikeTs ? 980_000_000.0 : 0.0)))
            let diskRead = Int64(max(120_000.0, 2_400_000.0 + spikeBell * 184_000_000.0 + secondWave * 38_000_000.0))
            let diskWrite = Int64(max(90_000.0, 1_800_000.0 + spikeBell * 96_000_000.0))
            let netIn = Int64(max(45_000.0, 620_000.0 + secondWave * 14_500_000.0 + spikeBell * 4_200_000.0))
            let netOut = Int64(max(28_000.0, 210_000.0 + spikeBell * 19_800_000.0 + secondWave * 2_400_000.0))
            let thermal: ThermalGrade = spikeBell > 0.65 ? .serious : (secondWave > 0.7 ? .fair : .nominal)
            let agents = spikeBell > 0.35 ? 2 : (secondWave > 0.3 ? 3 : 0)

            generatedTicks.append(
                SystemTick(
                    ts: ts,
                    tier: .rollup15s,
                    cpuUserPct: cpuUser,
                    cpuSysPct: cpuSys,
                    thermalGrade: thermal,
                    memUsedBytes: min(memTotal - 512_000_000, memUsed),
                    memTotalBytes: memTotal,
                    swapUsedBytes: swapUsed,
                    diskReadBps: diskRead,
                    diskWriteBps: diskWrite,
                    netInBps: netIn,
                    netOutBps: netOut,
                    activeAgentCount: agents,
                    activeAgentSummary: agents == 2 ? "Claude Code, OpenCode" : (agents == 3 ? "Claude Code, Codex CLI, OpenCode" : "")
                )
            )
        }

        let actualSpikeTickTs = generatedTicks.min(by: { abs($0.ts - spikeTs) < abs($1.ts - spikeTs) })!.ts

        let spikeProcesses: [ProcessSample] = [
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 61842,
                ppid: 1,
                name: "mcp-vector-indexer",
                execPath: "~/.local/share/uv/mcp-indexer/bin/python3",
                bundleID: nil,
                signingTeam: nil,
                cpuPct: 312.4,
                rssBytes: 8_942_206_976,
                diskReadBps: 162_529_280,
                diskWriteBps: 88_080_384,
                netInBps: 1_240_000,
                netOutBps: 16_986_931,
                isAliveNow: false,
                isCPUReadable: true
            ),
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 19844,
                ppid: 1,
                name: "ollama-runner",
                execPath: "/opt/homebrew/bin/ollama",
                bundleID: nil,
                signingTeam: nil,
                cpuPct: 84.2,
                rssBytes: 4_724_464_025,
                diskReadBps: 6_400_000,
                diskWriteBps: 0,
                netInBps: 0,
                netOutBps: 0,
                isAliveNow: true,
                isCPUReadable: true
            ),
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 49201,
                ppid: 1204,
                name: "claude",
                execPath: "~/.local/bin/claude",
                bundleID: "com.anthropic.claude-code",
                signingTeam: "Q6L2SF6YDW",
                cpuPct: 48.6,
                rssBytes: 1_912_602_624,
                diskReadBps: 14_200_000,
                diskWriteBps: 3_100_000,
                netInBps: 2_480_000,
                netOutBps: 1_890_000,
                isAliveNow: true,
                isCPUReadable: true
            ),
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 3108,
                ppid: 1,
                name: "com.docker.backend",
                execPath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                bundleID: "com.docker.docker",
                signingTeam: "9BNSXJN65R",
                cpuPct: 19.4,
                rssBytes: 2_384_344_576,
                diskReadBps: 3_100_000,
                diskWriteBps: 4_800_000,
                netInBps: 410_000,
                netOutBps: 620_000,
                isAliveNow: true,
                isCPUReadable: true
            ),
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 52910,
                ppid: 1,
                name: "node (telemetry-sync-worker)",
                execPath: "/opt/homebrew/bin/node",
                bundleID: nil,
                signingTeam: nil,
                cpuPct: 14.8,
                rssBytes: 642_252_800,
                diskReadBps: 420_000,
                diskWriteBps: 1_250_000,
                netInBps: 88_000,
                netOutBps: 940_000,
                isAliveNow: false,
                isCPUReadable: true
            ),
            ProcessSample(
                ts: actualSpikeTickTs,
                pid: 168,
                ppid: 1,
                name: "WindowServer",
                execPath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                bundleID: "com.apple.WindowServer",
                signingTeam: "Apple",
                cpuPct: 0,
                rssBytes: 0,
                diskReadBps: 0,
                diskWriteBps: 0,
                netInBps: 0,
                netOutBps: 0,
                isAliveNow: true,
                isCPUReadable: false
            )
        ]

        m.ticks = generatedTicks
        m.selectedRange = .sixHours
        m.scrubbedTimestamp = actualSpikeTickTs
        m.displayedSnapshotTs = actualSpikeTickTs
        m.previewSnapshotsByTs[actualSpikeTickTs] = spikeProcesses
        m.displayedProcesses = ProcessTreeSampler.sortProcesses(spikeProcesses, by: m.selectedSortOrder)

        m.agentWindows = [
            AgentBurstWindow(id: "ag-1", vendor: "Claude Code", workspace: "shader-pipeline", startTs: actualSpikeTickTs - 900, endTs: actualSpikeTickTs + 1100),
            AgentBurstWindow(id: "ag-2", vendor: "Codex CLI", workspace: "kernel-bench", startTs: endTs - 4200, endTs: endTs - 2400),
            AgentBurstWindow(id: "ag-3", vendor: "OpenCode", workspace: "ChronoMac", startTs: endTs - 3600, endTs: endTs - 1800)
        ]

        m.anomalies = [
            AnomalyBookmark(
                id: "bm-1",
                ts: actualSpikeTickTs,
                kind: .swapSurge,
                severity: 3,
                culpritName: "mcp-vector-indexer (python3.12)",
                culpritExec: "~/.local/share/uv/mcp-indexer/bin/python3",
                metricBadge: "+6.02 GB swap",
                summary: "Orphaned uv worker ballooned to 8.33 GB phys_footprint & 16.2 MB/s upload before exiting 5m later."
            ),
            AnomalyBookmark(
                id: "bm-2",
                ts: actualSpikeTickTs + 120,
                kind: .egressBurst,
                severity: 2,
                culpritName: "mcp-vector-indexer (python3.12)",
                culpritExec: "~/.local/share/uv/mcp-indexer/bin/python3",
                metricBadge: "19.8 MB/s up",
                summary: "Uploaded 418 MB to s3-accelerate.amazonaws.com:443 during unattended window."
            ),
            AnomalyBookmark(
                id: "bm-3",
                ts: endTs - 3350,
                kind: .runawayCPU,
                severity: 1,
                culpritName: "swift-frontend",
                culpritExec: "/Library/Developer/CommandLineTools/usr/bin/swift-frontend",
                metricBadge: "284% CPU",
                summary: "Parallel multi-agent release build across 3 harnesses."
            )
        ]

        m.socketFlows = [
            SocketFlowRecord(
                bucketHour: actualSpikeTickTs,
                execPath: "~/.local/share/uv/mcp-indexer/bin/python3",
                processName: "mcp-vector-indexer",
                remoteEndpoint: "54.231.194.82:443",
                hostname: "s3-accelerate.amazonaws.com",
                protocolName: "tcp4",
                totalBytesIn: 14_820_000,
                totalBytesOut: 438_304_768,
                firstSeen: actualSpikeTickTs - 300,
                lastSeen: actualSpikeTickTs + 280
            ),
            SocketFlowRecord(
                bucketHour: actualSpikeTickTs,
                execPath: "~/.local/bin/claude",
                processName: "claude",
                remoteEndpoint: "160.79.104.10:443",
                hostname: "api.anthropic.com",
                protocolName: "tcp4",
                totalBytesIn: 68_420_000,
                totalBytesOut: 29_140_000,
                firstSeen: startTs + 1200,
                lastSeen: endTs - 300
            ),
            SocketFlowRecord(
                bucketHour: actualSpikeTickTs,
                execPath: "/opt/homebrew/bin/node",
                processName: "telemetry-sync-worker",
                remoteEndpoint: "34.120.52.190:443",
                hostname: "ingest.us.sentry.io",
                protocolName: "tcp4",
                totalBytesIn: 1_120_000,
                totalBytesOut: 19_480_000,
                firstSeen: actualSpikeTickTs - 180,
                lastSeen: actualSpikeTickTs + 220
            ),
            SocketFlowRecord(
                bucketHour: actualSpikeTickTs,
                execPath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                processName: "com.docker.backend",
                remoteEndpoint: "104.18.124.25:443",
                hostname: "registry-1.docker.io",
                protocolName: "tcp4",
                totalBytesIn: 152_400_000,
                totalBytesOut: 4_120_000,
                firstSeen: startTs + 3600,
                lastSeen: endTs - 900
            )
        ]
        return m
    }
}

public enum ChronoScreenshotExporter {
    @MainActor
    public static func exportMarketingScreenshots(to directory: URL, language: AppLanguage = .en) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = ChronoMonitor.preview()
        let localizer = AppLocalizer(language: language)
        let fixedTZ = TimeZone(secondsFromGMT: 0)!
        let suffix = language == .zhHans ? "-zh" : ""

        let mainView = ChronoDashboardView(
            monitor: monitor,
            localizer: localizer,
            displayTimeZone: fixedTZ
        )
        .frame(width: 1124, height: 736)
        .environment(\.colorScheme, .light)
        try renderPNG(view: mainView, to: directory.appendingPathComponent("screenshot-main\(suffix).png"))

        let menuView = ChronoMenuBarView(
            monitor: monitor,
            localizer: localizer,
            displayTimeZone: fixedTZ,
            onOpenDashboard: {},
            onQuit: {}
        )
        .frame(width: 386, height: 334)
        .padding(14)
        .background(Color(red: 0.898, green: 0.890, blue: 0.863))
        .environment(\.colorScheme, .light)
        try renderPNG(view: menuView, to: directory.appendingPathComponent("screenshot-menubar\(suffix).png"))
    }

    @MainActor
    public static func renderPNG<V: View>(view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ChronoMac.ScreenshotExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to rasterize ChronoMac SwiftUI view to 2x PNG"
            ])
        }
        try png.write(to: url, options: .atomic)
    }
}
