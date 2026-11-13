import Darwin
import Foundation
import Security

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

    private var prevByPID: [Int: PrevUsage] = [:]
    private var signingCache: [String: SigningMeta] = [:]
    private let lock = NSLock()

    public init() {}

    public func sampleTopProcesses(
        ts: Int64,
        netInBpsByPID: [Int: Int64],
        netOutBpsByPID: [Int: Int64],
        limit: Int = 30
    ) -> (processes: [ProcessSample], totalDiskReadBps: Int64, totalDiskWriteBps: Int64, livePIDs: Set<Int>) {
        let now = Date().timeIntervalSince1970
        let countGuess = proc_listallpids(nil, 0)
        let cap = max(512, Int(countGuess) + 128)
        var pids = [pid_t](repeating: 0, count: cap)
        let byteLen = Int32(cap * MemoryLayout<pid_t>.size)
        let actualBytes = proc_listallpids(&pids, byteLen)
        let pidCount = max(0, Int(actualBytes) / MemoryLayout<pid_t>.size)

        lock.lock()
        defer { lock.unlock() }

        var aliveSet = Set<Int>()
        var nextPrev: [Int: PrevUsage] = [:]
        var samples: [ProcessSample] = []
        var hostDiskReadBps: Int64 = 0
        var hostDiskWriteBps: Int64 = 0

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(max(1, timebase.numer))
        let denom = UInt64(max(1, timebase.denom))

        for i in 0..<pidCount {
            let pid = Int(pids[i])
            if pid <= 0 { continue }
            aliveSet.insert(pid)

            var bsd = proc_bsdinfo()
            let bsdLen = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard bsdLen == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }

            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let pathLen = proc_pidpath(pid_t(pid), &pathBuf, UInt32(pathBuf.count))
            let commName = withUnsafePointer(to: bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            let execPath = pathLen > 0 ? String(cString: pathBuf) : commName
            let displayName = pathLen > 0 ? URL(fileURLWithPath: execPath).lastPathComponent : commName

            var ru = rusage_info_v4()
            let rkr = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ptr in
                    proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V4, ptr)
                }
            }

            var rssBytes: Int64 = 0
            var cpuPct: Double = 0
            var dReadBps: Int64 = 0
            var dWriteBps: Int64 = 0

            if rkr == 0 {
                rssBytes = Int64(ru.ri_phys_footprint > 0 ? ru.ri_phys_footprint : ru.ri_resident_size)
                let totalMachTicks = ru.ri_user_time &+ ru.ri_system_time
                let cpuNs = (totalMachTicks &* numer) / denom

                if let prev = prevByPID[pid] {
                    let dt = max(0.25, now - prev.sampledAt)
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
            } else {
                var ti = proc_taskinfo()
                if proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    rssBytes = Int64(ti.pti_resident_size)
                }
            }

            hostDiskReadBps += dReadBps
            hostDiskWriteBps += dWriteBps

            let nIn = netInBpsByPID[pid] ?? 0
            let nOut = netOutBpsByPID[pid] ?? 0

            // Filter completely idle micro-processes before code-sign lookup
            if rssBytes < 8_388_608 && cpuPct < 0.2 && nIn == 0 && nOut == 0 && dReadBps == 0 && dWriteBps == 0 {
                continue
            }

            let meta = resolveSigningMeta(for: execPath)
            samples.append(
                ProcessSample(
                    ts: ts,
                    pid: pid,
                    ppid: Int(bsd.pbi_ppid),
                    name: displayName.isEmpty ? "pid-\(pid)" : displayName,
                    execPath: execPath,
                    bundleID: meta.bundleID,
                    signingTeam: meta.teamID,
                    cpuPct: cpuPct,
                    rssBytes: rssBytes,
                    diskReadBps: dReadBps,
                    diskWriteBps: dWriteBps,
                    netInBps: nIn,
                    netOutBps: nOut,
                    isAliveNow: true
                )
            )
        }

        prevByPID = nextPrev

        let ranked = samples.sorted { a, b in
            let scoreA = a.cpuPct * 25_000_000 + Double(a.rssBytes) + Double(a.netOutBps + a.netInBps) * 40
            let scoreB = b.cpuPct * 25_000_000 + Double(b.rssBytes) + Double(b.netOutBps + b.netInBps) * 40
            return scoreA > scoreB
        }

        return (Array(ranked.prefix(limit)), hostDiskReadBps, hostDiskWriteBps, aliveSet)
    }

    private func resolveSigningMeta(for execPath: String) -> SigningMeta {
        if let cached = signingCache[execPath] {
            return cached
        }
        guard execPath.hasPrefix("/") else {
            let empty = SigningMeta(bundleID: nil, teamID: nil)
            signingCache[execPath] = empty
            return empty
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
