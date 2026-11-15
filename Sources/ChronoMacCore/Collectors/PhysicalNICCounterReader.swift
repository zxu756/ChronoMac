import Darwin
import Foundation

public struct PhysicalNICInterfaceCounters: Sendable, Equatable {
    public var name: String
    public var isLoopback: Bool
    public var isPhysicalExternal: Bool
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(
        name: String,
        isLoopback: Bool,
        isPhysicalExternal: Bool,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) {
        self.name = name
        self.isLoopback = isLoopback
        self.isPhysicalExternal = isPhysicalExternal
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct PhysicalNICCounterSnapshot: Sendable, Equatable {
    public var interfaces: [String: PhysicalNICInterfaceCounters]
    public var externalBytesIn: UInt64
    public var externalBytesOut: UInt64
    public var loopbackBytesIn: UInt64
    public var loopbackBytesOut: UInt64

    public init(interfaces: [String: PhysicalNICInterfaceCounters]) {
        self.interfaces = interfaces
        var extIn: UInt64 = 0
        var extOut: UInt64 = 0
        var loopIn: UInt64 = 0
        var loopOut: UInt64 = 0
        for item in interfaces.values {
            if item.isLoopback {
                loopIn &+= item.bytesIn
                loopOut &+= item.bytesOut
            } else if item.isPhysicalExternal {
                extIn &+= item.bytesIn
                extOut &+= item.bytesOut
            }
        }
        self.externalBytesIn = extIn
        self.externalBytesOut = extOut
        self.loopbackBytesIn = loopIn
        self.loopbackBytesOut = loopOut
    }
}

/// Reads full 64-bit link-layer interface counters via `/usr/sbin/netstat -ibn` (~3.8 ms, numeric-only with zero DNS),
/// with `sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)` fallback.
/// Note: on modern macOS, XNU privacy-coarsens (1 KiB) and truncates (`mod 2^32`) `NET_RT_IFLIST2` / `getifaddrs`
/// byte counters for unentitled third-party binaries, whereas Apple-signed `/usr/sbin/netstat -ibn` returns exact
/// uncoarsened 64-bit link counters while strictly excluding `lo*` loopback and virtual/tunnel/bridge interfaces.
public enum PhysicalNICCounterReader {
    public static func classifyInterface(name: String, flags: Int32 = 0) -> (isLoopback: Bool, isPhysicalExternal: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if (flags & Int32(IFF_LOOPBACK)) != 0 || lower.hasPrefix("lo") {
            return (true, false)
        }
        // Only count hardware external interfaces (`en0`, `en1`, ... Ethernet/Wi-Fi and `pdp_ip0` cellular tether).
        // Exclude `utun*`, `ipsec*`, `bridge*`, `awdl*`, `llw*`, `ap*`, `anpi*`, `gif*`, `stf*`, `vmenet*`, `feth*`
        // so encapsulated VPN or bridged VM frames are never double-counted on top of physical NIC frames.
        if isDigitsSuffix(lower, prefix: "en") || isDigitsSuffix(lower, prefix: "pdp_ip") {
            return (false, true)
        }
        return (false, false)
    }

    private static func isDigitsSuffix(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    public static func readLiveCounters() -> PhysicalNICCounterSnapshot {
        let netstatSnap = readViaNetstatIB()
        if !netstatSnap.interfaces.isEmpty {
            return netstatSnap
        }
        return readViaSysctlIfList2() ?? PhysicalNICCounterSnapshot(interfaces: [:])
    }

    public static func readViaSysctlIfList2() -> PhysicalNICCounterSnapshot? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: len + 4096)
        var actualLen = buffer.count
        guard sysctl(&mib, 6, &buffer, &actualLen, nil, 0) == 0, actualLen > 0 else {
            return nil
        }

        var map: [String: PhysicalNICInterfaceCounters] = [:]
        let hdrSize = MemoryLayout<if_msghdr>.size
        let hdr2Size = MemoryLayout<if_msghdr2>.size
        let sdlDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8

        buffer.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset + hdrSize <= actualLen {
                var baseHdr = if_msghdr()
                memcpy(&baseHdr, base.advanced(by: offset), hdrSize)
                let msgLen = Int(baseHdr.ifm_msglen)
                if msgLen <= 0 || offset + msgLen > actualLen {
                    break
                }
                if Int32(baseHdr.ifm_type) == RTM_IFINFO2, msgLen >= hdr2Size + sdlDataOffset {
                    var hdr2 = if_msghdr2()
                    memcpy(&hdr2, base.advanced(by: offset), hdr2Size)

                    var sdl = sockaddr_dl()
                    let copySdlLen = min(MemoryLayout<sockaddr_dl>.size, msgLen - hdr2Size)
                    memcpy(&sdl, base.advanced(by: offset + hdr2Size), copySdlLen)
                    let nameLen = Int(sdl.sdl_nlen)
                    if nameLen > 0, hdr2Size + sdlDataOffset + nameLen <= msgLen {
                        let namePtr = base.advanced(by: offset + hdr2Size + sdlDataOffset)
                            .assumingMemoryBound(to: UInt8.self)
                        let nameData = Data(bytes: namePtr, count: nameLen)
                        if let ifName = String(data: nameData, encoding: .utf8), !ifName.isEmpty {
                            let cls = classifyInterface(name: ifName, flags: hdr2.ifm_flags)
                            map[ifName] = PhysicalNICInterfaceCounters(
                                name: ifName,
                                isLoopback: cls.isLoopback,
                                isPhysicalExternal: cls.isPhysicalExternal,
                                bytesIn: hdr2.ifm_data.ifi_ibytes,
                                bytesOut: hdr2.ifm_data.ifi_obytes
                            )
                        }
                    }
                }
                offset += msgLen
            }
        }
        return PhysicalNICCounterSnapshot(interfaces: map)
    }

    public static func readViaNetstatIB() -> PhysicalNICCounterSnapshot {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        proc.arguments = ["-ibn"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else {
                return PhysicalNICCounterSnapshot(interfaces: [:])
            }
            return parseNetstatIB(text)
        } catch {
            return PhysicalNICCounterSnapshot(interfaces: [:])
        }
    }

    /// Parses `/usr/sbin/netstat -ib` link-layer (`<Link#N>`) rows into 64-bit per-interface byte counters.
    public static func parseNetstatIB(_ text: String) -> PhysicalNICCounterSnapshot {
        var map: [String: PhysicalNICInterfaceCounters] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // Link-layer rows have `<Link#N>` at index 2 and either 10 tokens (no MAC) or 11 tokens (with MAC);
            // in both layouts `Ibytes` is `cols[count - 5]` and `Obytes` is `cols[count - 2]`.
            guard cols.count >= 10, cols[2].hasPrefix("<Link#") else { continue }
            let rawName = cols[0].hasSuffix("*") ? String(cols[0].dropLast()) : cols[0]
            guard let ibytes = UInt64(cols[cols.count - 5]),
                  let obytes = UInt64(cols[cols.count - 2]) else {
                continue
            }
            let cls = classifyInterface(name: rawName)
            map[rawName] = PhysicalNICInterfaceCounters(
                name: rawName,
                isLoopback: cls.isLoopback,
                isPhysicalExternal: cls.isPhysicalExternal,
                bytesIn: ibytes,
                bytesOut: obytes
            )
        }
        return PhysicalNICCounterSnapshot(interfaces: map)
    }
}
