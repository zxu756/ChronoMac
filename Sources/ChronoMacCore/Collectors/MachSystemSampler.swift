import Darwin
import Foundation

public struct HostCPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public var total: UInt64 { user + system + idle + nice }
}

public final class MachSystemSampler: @unchecked Sendable {
    private var previousTicks: HostCPUTicks?
    private let lock = NSLock()
    public let totalMemoryBytes: Int64

    public init() {
        self.totalMemoryBytes = Int64(ProcessInfo.processInfo.physicalMemory)
    }

    public func sampleHostState() -> (
        cpuUserPct: Double,
        cpuSysPct: Double,
        thermal: ThermalGrade,
        memUsedBytes: Int64,
        swapUsedBytes: Int64
    ) {
        let currentTicks = Self.readHostCPUTicks()
        var userPct = 0.0
        var sysPct = 0.0

        lock.lock()
        if let prev = previousTicks, let cur = currentTicks {
            let dUser = cur.user >= prev.user ? cur.user - prev.user : 0
            let dNice = cur.nice >= prev.nice ? cur.nice - prev.nice : 0
            let dSys = cur.system >= prev.system ? cur.system - prev.system : 0
            let dIdle = cur.idle >= prev.idle ? cur.idle - prev.idle : 0
            let dTotal = dUser + dNice + dSys + dIdle
            if dTotal > 0 {
                userPct = Double(dUser + dNice) / Double(dTotal) * 100.0
                sysPct = Double(dSys) / Double(dTotal) * 100.0
            }
        }
        if let cur = currentTicks {
            previousTicks = cur
        }
        lock.unlock()

        let memUsed = Self.readUsedMemoryBytes(totalBytes: totalMemoryBytes)
        let swapUsed = Self.readSwapUsedBytes()
        let thermal = Self.mapThermalState(ProcessInfo.processInfo.thermalState)

        return (userPct, sysPct, thermal, memUsed, swapUsed)
    }

    public static func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalGrade {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public static func readHostCPUTicks() -> HostCPUTicks? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let byteCount = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteCount)
        }

        var user: UInt64 = 0
        var sys: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        for idx in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * idx
            user += UInt64(max(0, info[base + Int(CPU_STATE_USER)]))
            sys += UInt64(max(0, info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(max(0, info[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(max(0, info[base + Int(CPU_STATE_NICE)]))
        }
        return HostCPUTicks(user: user, system: sys, idle: idle, nice: nice)
    }

    public static func readUsedMemoryBytes(totalBytes: Int64) -> Int64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 16384
        host_page_size(mach_host_self(), &pageSize)
        let ps = Int64(pageSize)
        let usedPages = Int64(vm.active_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
        return min(totalBytes, max(0, usedPages * ps))
    }

    public static func readSwapUsedBytes() -> Int64 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        proc.arguments = ["-n", "vm.swapusage"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let line = String(data: data, encoding: .utf8) else { return 0 }
            return parseSwapUsageString(line)
        } catch {
            return 0
        }
    }

    /// Parses strings like: `total = 3072.00M  used = 1686.69M  free = 1385.31M  (encrypted)`
    public static func parseSwapUsageString(_ raw: String) -> Int64 {
        guard let usedRange = raw.range(of: "used =") else { return 0 }
        let after = raw[usedRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let token = after.prefix { !$0.isWhitespace }
        guard token.count >= 2 else { return 0 }
        let unit = token.last!.uppercased()
        let numberPart = String(token.dropLast())
        guard let val = Double(numberPart), val > 0 else { return 0 }
        switch unit {
        case "G": return Int64(val * 1024.0 * 1024.0 * 1024.0)
        case "M": return Int64(val * 1024.0 * 1024.0)
        case "K": return Int64(val * 1024.0)
        default: return Int64(val)
        }
    }
}
