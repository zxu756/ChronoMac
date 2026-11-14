import Foundation

public struct HostStateReading: Sendable, Equatable {
    public var cpuUserPct: Double
    public var cpuSysPct: Double
    public var thermal: ThermalGrade
    public var memUsedBytes: Int64
    public var memTotalBytes: Int64
    public var swapUsedBytes: Int64

    public var totalCPUPct: Double {
        min(100.0, max(0.0, cpuUserPct + cpuSysPct))
    }

    public init(
        cpuUserPct: Double,
        cpuSysPct: Double,
        thermal: ThermalGrade,
        memUsedBytes: Int64,
        memTotalBytes: Int64,
        swapUsedBytes: Int64
    ) {
        self.cpuUserPct = max(0, cpuUserPct)
        self.cpuSysPct = max(0, cpuSysPct)
        self.thermal = thermal
        self.memUsedBytes = max(0, memUsedBytes)
        self.memTotalBytes = max(1, memTotalBytes)
        self.swapUsedBytes = max(0, swapUsedBytes)
    }
}

public struct ProcessTreeSnapshot: Sendable, Equatable {
    public var processes: [ProcessSample]
    public var totalDiskReadBps: Int64
    public var totalDiskWriteBps: Int64
    public var livePIDs: Set<Int>

    public init(
        processes: [ProcessSample],
        totalDiskReadBps: Int64,
        totalDiskWriteBps: Int64,
        livePIDs: Set<Int>
    ) {
        self.processes = processes
        self.totalDiskReadBps = max(0, totalDiskReadBps)
        self.totalDiskWriteBps = max(0, totalDiskWriteBps)
        self.livePIDs = livePIDs
    }
}

public protocol SystemSamplerProtocol: Sendable {
    var totalMemoryBytes: Int64 { get }
    func sampleHostState() -> HostStateReading
    func sampleCalibratedHostState(interval: TimeInterval) -> HostStateReading
    func sampleNetwork(now: TimeInterval) -> NettopSnapshotResult
    func sampleProcesses(
        ts: Int64,
        netInBpsByPID: [Int: Int64],
        netOutBpsByPID: [Int: Int64],
        limit: Int
    ) -> ProcessTreeSnapshot
    func resolveExecutablePath(pid: Int) -> String
    func currentLivePIDs() -> Set<Int>
    func detectAgentActivity(now: Int64) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow])
}

public final class LiveSystemSampler: SystemSamplerProtocol, @unchecked Sendable {
    public let hostSampler: MachSystemSampler
    public let procSampler: ProcessTreeSampler
    public let netSampler: NettopDeltaParser
    private let agentHomeDirectory: URL?

    public init(
        hostSampler: MachSystemSampler = MachSystemSampler(),
        procSampler: ProcessTreeSampler = ProcessTreeSampler(),
        netSampler: NettopDeltaParser = NettopDeltaParser(),
        agentHomeDirectory: URL? = nil
    ) {
        self.hostSampler = hostSampler
        self.procSampler = procSampler
        self.netSampler = netSampler
        self.agentHomeDirectory = agentHomeDirectory
    }

    public var totalMemoryBytes: Int64 {
        hostSampler.totalMemoryBytes
    }

    public func sampleHostState() -> HostStateReading {
        let s = hostSampler.sampleHostState()
        return HostStateReading(
            cpuUserPct: s.cpuUserPct,
            cpuSysPct: s.cpuSysPct,
            thermal: s.thermal,
            memUsedBytes: s.memUsedBytes,
            memTotalBytes: hostSampler.totalMemoryBytes,
            swapUsedBytes: s.swapUsedBytes
        )
    }

    public func sampleCalibratedHostState(interval: TimeInterval = 1.0) -> HostStateReading {
        hostSampler.sampleCalibratedHostState(interval: interval)
    }

    public func sampleNetwork(now: TimeInterval) -> NettopSnapshotResult {
        netSampler.sampleLiveHost(now: now)
    }

    public func sampleProcesses(
        ts: Int64,
        netInBpsByPID: [Int: Int64],
        netOutBpsByPID: [Int: Int64],
        limit: Int = 30
    ) -> ProcessTreeSnapshot {
        let res = procSampler.sampleTopProcesses(
            ts: ts,
            netInBpsByPID: netInBpsByPID,
            netOutBpsByPID: netOutBpsByPID,
            limit: limit
        )
        return ProcessTreeSnapshot(
            processes: res.processes,
            totalDiskReadBps: res.totalDiskReadBps,
            totalDiskWriteBps: res.totalDiskWriteBps,
            livePIDs: res.livePIDs
        )
    }

    public func resolveExecutablePath(pid: Int) -> String {
        ProcessTreeSampler.resolveExecutablePath(pid: pid)
    }

    public func currentLivePIDs() -> Set<Int> {
        ProcessTreeSampler.currentLivePIDs()
    }

    public func detectAgentActivity(now: Int64) -> (count: Int, summary: String, recentWindows: [AgentBurstWindow]) {
        AgentActivityBridge.detectLiveAgentSummary(now: now, homeDirectory: agentHomeDirectory)
    }
}
