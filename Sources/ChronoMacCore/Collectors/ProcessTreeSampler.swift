import Darwin
import Foundation
import Security

public struct PsProcessReading: Sendable, Equatable {
    public var pid: Int
    public var instantCPUPct: Double
    public var rssBytes: Int64
    public var cpuTimeNanoseconds: UInt64

    public init(pid: Int, instantCPUPct: Double, rssBytes: Int64, cpuTimeNanoseconds: UInt64) {
        self.pid = pid
        self.instantCPUPct = max(0, instantCPUPct)
        self.rssBytes = max(0, rssBytes)
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
    }
}

public final class ProcessTreeSampler: @unchecked Sendable {
    private struct PrevUsage {
        var cpuTotalNs: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var sampledAt: TimeInterval
    }

    private struct SigningMeta {
        var bundleID: String?
        var teamID: String?
    }

    private static let notableSystemDaemons: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "mds_stores", "mds", "backupd", "coreaudiod"
    ]

    private var prevByPID: [Int: PrevUsage] = [:]
    private var signingCache: [String: SigningMeta] = [:]
    private let psProvider: @Sendable () -> [Int: PsProcessReading]
    private let lock = NSLock()

    public convenience init() {
        self.init(psProvider: { Self.readLivePsSnapshot() })
    }

    public init(psProvider: @escaping @Sendable () -> [Int: PsProcessReading]) {
        self.psProvider = psProvider
    }

    /// Parses `/bin/ps` cumulative CPU `time` strings (`[[DD-]HH:]MM:SS.ss` or `MMM:SS.ss`) into nanoseconds.
    public static func parsePsTimeToNanoseconds(_ raw: String) -> UInt64? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        var days: UInt64 = 0
        let rest: String
        if let dashIdx = token.firstIndex(of: "-") {
            guard let d = UInt64(token[..<dashIdx]) else { return nil }
            days = d
            rest = String(token[token.index(after: dashIdx)...])
        } else {
            rest = token
        }

        let colonParts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard colonParts.count == 2 || colonParts.count == 3 else { return nil }

        let hours: UInt64
        let minutes: UInt64
        let secToken: Substring
        if colonParts.count == 3 {
            guard let h = UInt64(colonParts[0]), let m = UInt64(colonParts[1]) else { return nil }
            hours = h
            minutes = m
            secToken = colonParts[2]
        } else {
            guard let m = UInt64(colonParts[0]) else { return nil }
            hours = 0
            minutes = m
            secToken = colonParts[1]
        }

        let dotParts = secToken.split(separator: ".", omittingEmptySubsequences: false)
        guard !dotParts.isEmpty, dotParts.count <= 2, let wholeSec = UInt64(dotParts[0]) else { return nil }
        var fracNs: UInt64 = 0
        if dotParts.count == 2 {
            let fracStr = String(dotParts[1].prefix(9))
            guard let fracVal = UInt64(fracStr) else { return nil }
            var scale: UInt64 = 1_000_000_000
            for _ in 0..<fracStr.count { scale /= 10 }
            fracNs = fracVal * scale
        }

        let totalSec = days * 86_400 + hours * 3_600 + minutes * 60 + wholeSec
        return totalSec * 1_000_000_000 + fracNs
    }

    /// Parses output of `LC_ALL=C /bin/ps -axo pid=,pcpu=,rss=,time=` into `[pid: PsProcessReading]`.
    public static func parsePsSnapshot(_ text: String) -> [Int: PsProcessReading] {
        var out: [Int: PsProcessReading] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 4,
                  let pid = Int(cols[0]),
                  pid > 0,
                  let pcpu = Double(cols[1]),
                  let rssKB = Int64(cols[2]),
                  let cpuNs = parsePsTimeToNanoseconds(String(cols[3])) else {
                continue
            }
            out[pid] = PsProcessReading(
                pid: pid,
                instantCPUPct: pcpu,
                rssBytes: max(0, rssKB) * 1024,
                cpuTimeNanoseconds: cpuNs
            )
        }
        return out
    }

    /// Reads userland process CPU time & RSS across all UIDs (including `WindowServer` UID 88 and `launchd` UID 0)
    /// without `sudo` via `/bin/ps` (`PID 0` `kernel_task` is a Mach task and remains excluded).
    public static func readLivePsSnapshot() -> [Int: PsProcessReading] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,pcpu=,rss=,time="]
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                return [:]
            }
            return parsePsSnapshot(text)
        } catch {
            return [:]
        }
    }

    /// Enumerates all live PIDs across the system via `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`,
    /// including root/system processes (`kernel_task`, `launchd`, `WindowServer`) that `proc_listallpids` omits.
    public static func currentLivePIDs() -> Set<Int> {
        let entries = enumerateAllKernelProcesses()
        if !entries.isEmpty {
            return Set(entries.map(\.pid))
        }
        let countGuess = proc_listallpids(nil, 0)
        let cap = max(512, Int(countGuess) + 128)
        var pids = [pid_t](repeating: 0, count: cap)
        let byteLen = Int32(cap * MemoryLayout<pid_t>.size)
        let actualBytes = proc_listallpids(&pids, byteLen)
        let pidCount = max(0, Int(actualBytes) / MemoryLayout<pid_t>.size)
        var out = Set<Int>()
        for i in 0..<pidCount where pids[i] >= 0 {
            out.insert(Int(pids[i]))
        }
        return out
    }

    /// Resolves full executable path via `proc_pidpath`, returning `""` (empty string) when unavailable.
    /// Never substitutes a bare process name (`p_comm` / `pbi_comm`) into `execPath`.
    public static func resolveExecutablePath(pid: Int) -> String {
        guard pid > 0 else { return "" }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid_t(pid), &pathBuf, UInt32(pathBuf.count))
        guard pathLen > 0 else { return "" }
        let resolved = String(cString: pathBuf).trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.hasPrefix("/") ? resolved : ""
    }

    private struct KernelProcEntry {
        var pid: Int
        var ppid: Int
        var uid: uid_t
        var comm: String
    }

    private static func enumerateAllKernelProcesses() -> [KernelProcEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        let estimatedCount = size / MemoryLayout<kinfo_proc>.stride + 64
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: estimatedCount)
        var actualSize = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else {
            return []
        }
        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride
        var seen = Set<Int>()
        var entries: [KernelProcEntry] = []
        entries.reserveCapacity(actualCount)

        for idx in 0..<actualCount {
            let pid = Int(procs[idx].kp_proc.p_pid)
            guard pid >= 0, seen.insert(pid).inserted else { continue }
            let ppid = Int(procs[idx].kp_eproc.e_ppid)
            let uid = procs[idx].kp_eproc.e_ucred.cr_uid
            let comm = withUnsafePointer(to: procs[idx].kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            entries.append(KernelProcEntry(pid: pid, ppid: ppid, uid: uid, comm: comm))
        }
        return entries
    }

    public func sampleTopProcesses(
        ts: Int64,
        netInBpsByPID: [Int: Int64],
        netOutBpsByPID: [Int: Int64],
        limit: Int = 30
    ) -> (processes: [ProcessSample], totalDiskReadBps: Int64, totalDiskWriteBps: Int64, livePIDs: Set<Int>) {
        let now = Date().timeIntervalSince1970
        let kernelEntries = Self.enumerateAllKernelProcesses()

        lock.lock()
        defer { lock.unlock() }

        var aliveSet = Set<Int>()
        var nextPrev: [Int: PrevUsage] = [:]
        var readableCandidates: [ProcessSample] = []
        var unreadableCandidates: [ProcessSample] = []
        var lazyPsSnapshot: [Int: PsProcessReading]?
        var hostDiskReadBps: Int64 = 0
        var hostDiskWriteBps: Int64 = 0

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(max(1, timebase.numer))
        let denom = UInt64(max(1, timebase.denom))

        for entry in kernelEntries {
            let pid = entry.pid
            aliveSet.insert(pid)

            var ppid = entry.ppid
            var fallbackName = entry.comm

            if pid > 0 {
                var bsd = proc_bsdinfo()
                let bsdLen = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
                if bsdLen == Int32(MemoryLayout<proc_bsdinfo>.size) {
                    ppid = Int(bsd.pbi_ppid)
                    let fullBsdName = withUnsafePointer(to: bsd.pbi_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
                    }
                    let shortComm = withUnsafePointer(to: bsd.pbi_comm) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
                    }
                    if !fullBsdName.isEmpty {
                        fallbackName = fullBsdName
                    } else if !shortComm.isEmpty {
                        fallbackName = shortComm
                    }
                }
            } else {
                fallbackName = "kernel_task"
            }

            let execPath = Self.resolveExecutablePath(pid: pid)
            let displayName: String
            if !execPath.isEmpty {
                let last = URL(fileURLWithPath: execPath).lastPathComponent
                displayName = last.isEmpty ? fallbackName : last
            } else {
                displayName = fallbackName.isEmpty ? "pid-\(pid)" : fallbackName
            }

            var footprintBytes: Int64 = 0
            var cpuPct: Double = 0
            var dReadBps: Int64 = 0
            var dWriteBps: Int64 = 0
            var isCPUReadable = true

            if pid == 0 {
                isCPUReadable = false
            } else {
                errno = 0
                var ru = rusage_info_v4()
                let rkr = withUnsafeMutablePointer(to: &ru) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ptr in
                        proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V4, ptr)
                    }
                }
                let err = errno

                if rkr == 0 {
                    footprintBytes = Int64(ru.ri_phys_footprint > 0 ? ru.ri_phys_footprint : ru.ri_resident_size)
                    let totalMachTicks = ru.ri_user_time &+ ru.ri_system_time
                    let cpuNs = (totalMachTicks &* numer) / denom

                    if let prev = prevByPID[pid] {
                        let dt = max(0.20, now - prev.sampledAt)
                        if cpuNs >= prev.cpuTotalNs {
                            let deltaSec = Double(cpuNs - prev.cpuTotalNs) / 1_000_000_000.0
                            cpuPct = (deltaSec / dt) * 100.0
                        }
                        if ru.ri_diskio_bytesread >= prev.diskRead {
                            dReadBps = Int64(Double(ru.ri_diskio_bytesread - prev.diskRead) / dt)
                        }
                        if ru.ri_diskio_byteswritten >= prev.diskWrite {
                            dWriteBps = Int64(Double(ru.ri_diskio_byteswritten - prev.diskWrite) / dt)
                        }
                    }
                    nextPrev[pid] = PrevUsage(
                        cpuTotalNs: cpuNs,
                        diskRead: ru.ri_diskio_bytesread,
                        diskWrite: ru.ri_diskio_byteswritten,
                        sampledAt: now
                    )
                } else if err == ESRCH {
                    aliveSet.remove(pid)
                    continue
                } else {
                    if lazyPsSnapshot == nil {
                        lazyPsSnapshot = psProvider()
                    }
                    if let psRow = lazyPsSnapshot?[pid] {
                        isCPUReadable = true
                        footprintBytes = psRow.rssBytes
                        let psCpuNs = psRow.cpuTimeNanoseconds
                        if let prev = prevByPID[pid] {
                            let dt = max(0.20, now - prev.sampledAt)
                            if psCpuNs >= prev.cpuTotalNs {
                                let deltaSec = Double(psCpuNs - prev.cpuTotalNs) / 1_000_000_000.0
                                cpuPct = (deltaSec / dt) * 100.0
                            } else {
                                cpuPct = psRow.instantCPUPct
                            }
                        } else {
                            cpuPct = psRow.instantCPUPct
                        }
                        nextPrev[pid] = PrevUsage(
                            cpuTotalNs: psCpuNs,
                            diskRead: 0,
                            diskWrite: 0,
                            sampledAt: now
                        )
                    } else {
                        isCPUReadable = false
                        var ti = proc_taskinfo()
                        if proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                            footprintBytes = Int64(ti.pti_resident_size)
                        }
                    }
                }
            }

            hostDiskReadBps += dReadBps
            hostDiskWriteBps += dWriteBps

            let nIn = netInBpsByPID[pid] ?? 0
            let nOut = netOutBpsByPID[pid] ?? 0

            if isCPUReadable {
                if footprintBytes < 4_194_304 && cpuPct < 0.1 && nIn == 0 && nOut == 0 && dReadBps == 0 && dWriteBps == 0 && !Self.notableSystemDaemons.contains(displayName) {
                    continue
                }
                readableCandidates.append(
                    ProcessSample(
                        ts: ts,
                        pid: pid,
                        ppid: ppid,
                        name: displayName,
                        execPath: execPath,
                        bundleID: nil,
                        signingTeam: nil,
                        cpuPct: cpuPct,
                        rssBytes: footprintBytes,
                        diskReadBps: dReadBps,
                        diskWriteBps: dWriteBps,
                        netInBps: nIn,
                        netOutBps: nOut,
                        isAliveNow: true,
                        isCPUReadable: true
                    )
                )
            } else if nIn > 0 || nOut > 0 || Self.notableSystemDaemons.contains(displayName) {
                unreadableCandidates.append(
                    ProcessSample(
                        ts: ts,
                        pid: pid,
                        ppid: ppid,
                        name: displayName,
                        execPath: execPath,
                        bundleID: nil,
                        signingTeam: pid == 0 ? "Apple" : nil,
                        cpuPct: 0,
                        rssBytes: footprintBytes,
                        diskReadBps: 0,
                        diskWriteBps: 0,
                        netInBps: nIn,
                        netOutBps: nOut,
                        isAliveNow: true,
                        isCPUReadable: false
                    )
                )
            }
        }

        prevByPID = nextPrev

        let unattrIn = netInBpsByPID[NettopDeltaParser.unattributedPID] ?? 0
        let unattrOut = netOutBpsByPID[NettopDeltaParser.unattributedPID] ?? 0
        let unattrSample: ProcessSample? = (unattrIn != 0 || unattrOut != 0)
            ? ProcessSample.unattributedSample(ts: ts, netInBps: unattrIn, netOutBps: unattrOut)
            : nil

        // Build top candidates from each independent dimension (CPU, Memory Footprint, Network) — no blended formula!
        let perAxisCap = max(10, limit)
        let topByCPU = readableCandidates
            .sorted { ($0.cpuPct, $0.rssBytes) > ($1.cpuPct, $1.rssBytes) }
            .prefix(perAxisCap)
        let topByMemory = readableCandidates
            .sorted { ($0.rssBytes, $0.cpuPct) > ($1.rssBytes, $1.cpuPct) }
            .prefix(perAxisCap)
        let topByNetwork = readableCandidates
            .filter { ($0.netInBps + $0.netOutBps) > 0 }
            .sorted { ($0.netInBps + $0.netOutBps) > ($1.netInBps + $1.netOutBps) }
            .prefix(perAxisCap)
        let selectedNotable = readableCandidates
            .filter { Self.notableSystemDaemons.contains($0.name) }
            .prefix(6)
        let selectedUnreadable = unreadableCandidates
            .sorted { ($0.netInBps + $0.netOutBps, -$0.pid) > ($1.netInBps + $1.netOutBps, -$1.pid) }
            .prefix(8)

        var mergedByPID: [Int: ProcessSample] = [:]
        for p in topByCPU { mergedByPID[p.pid] = p }
        for p in topByMemory { mergedByPID[p.pid] = p }
        for p in topByNetwork { mergedByPID[p.pid] = p }
        for p in selectedNotable { mergedByPID[p.pid] = p }
        for p in selectedUnreadable { mergedByPID[p.pid] = p }
        if let unattrSample {
            mergedByPID[unattrSample.pid] = unattrSample
        }

        var enriched: [ProcessSample] = []
        enriched.reserveCapacity(mergedByPID.count)
        for var p in mergedByPID.values {
            if !p.isUnattributed && !p.execPath.isEmpty {
                let meta = resolveSigningMeta(for: p.execPath)
                p.bundleID = meta.bundleID
                if let team = meta.teamID {
                    p.signingTeam = team
                }
            }
            enriched.append(p)
        }

        let ordered = Self.sortProcesses(enriched, by: .cpu)
        return (ordered, hostDiskReadBps, hostDiskWriteBps, aliveSet)
    }

    public static func sortProcesses(_ list: [ProcessSample], by order: ProcessSortOrder) -> [ProcessSample] {
        switch order {
        case .cpu:
            return list.sorted { a, b in
                if a.isCPUReadable != b.isCPUReadable {
                    return a.isCPUReadable && !b.isCPUReadable
                }
                if a.cpuPct != b.cpuPct { return a.cpuPct > b.cpuPct }
                if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
                if (a.netOutBps + a.netInBps) != (b.netOutBps + b.netInBps) {
                    return (a.netOutBps + a.netInBps) > (b.netOutBps + b.netInBps)
                }
                return a.pid < b.pid
            }
        case .memory:
            return list.sorted { a, b in
                if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
                let aCPU = a.isCPUReadable ? a.cpuPct : -1
                let bCPU = b.isCPUReadable ? b.cpuPct : -1
                if aCPU != bCPU { return aCPU > bCPU }
                return a.pid < b.pid
            }
        case .network:
            return list.sorted { a, b in
                let aNet = abs(a.netOutBps) + abs(a.netInBps)
                let bNet = abs(b.netOutBps) + abs(b.netInBps)
                if aNet != bNet { return aNet > bNet }
                if abs(a.netOutBps) != abs(b.netOutBps) { return abs(a.netOutBps) > abs(b.netOutBps) }
                if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
                return a.pid < b.pid
            }
        }
    }

    private func resolveSigningMeta(for execPath: String) -> SigningMeta {
        guard !execPath.isEmpty, execPath.hasPrefix("/") else {
            return SigningMeta(bundleID: nil, teamID: nil)
        }
        if let cached = signingCache[execPath] {
            return cached
        }
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: execPath) as CFURL
        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            let empty = SigningMeta(bundleID: nil, teamID: nil)
            signingCache[execPath] = empty
            return empty
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let dict = infoCF as? [String: Any] else {
            let empty = SigningMeta(bundleID: nil, teamID: nil)
            signingCache[execPath] = empty
            return empty
        }
        let id = dict[kSecCodeInfoIdentifier as String] as? String
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let meta = SigningMeta(bundleID: id, teamID: team)
        if signingCache.count > 1024 { signingCache.removeAll(keepingCapacity: true) }
        signingCache[execPath] = meta
        return meta
    }
}
