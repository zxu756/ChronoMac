import Darwin
import Foundation

/// Asynchronous, bounded local PTR reverse-DNS resolver with zero third-party telemetry.
public actor ReverseDNSResolver {
    private var cache: [String: String] = [:]
    private var inFlight: Set<String> = []

    public init() {}

    public func cachedHostname(for endpoint: String) -> String? {
        let ip = NettopDeltaParser.extractRemoteIP(endpoint)
        return cache[ip]
    }

    public func resolveIfNeeded(endpoint: String, onResolved: @Sendable @escaping (String, String) -> Void) {
        let ip = NettopDeltaParser.extractRemoteIP(endpoint)
        if let hit = cache[ip] {
            onResolved(endpoint, hit)
            return
        }
        guard !inFlight.contains(ip) else { return }
        inFlight.insert(ip)

        Task.detached(priority: .utility) { [weak self] in
            let host = Self.lookupPTR(ip: ip)
            await self?.storeResult(ip: ip, endpoint: endpoint, host: host, onResolved: onResolved)
        }
    }

    private func storeResult(
        ip: String,
        endpoint: String,
        host: String?,
        onResolved: @Sendable @escaping (String, String) -> Void
    ) {
        inFlight.remove(ip)
        guard let host, !host.isEmpty, host != ip else { return }
        if cache.count > 2048 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[ip] = host
        onResolved(endpoint, host)
    }

    nonisolated private static func lookupPTR(ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let addr = res else { return nil }
        defer { freeaddrinfo(addr) }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let flags = NI_NAMEREQD
        let rc = getnameinfo(
            addr.pointee.ai_addr,
            addr.pointee.ai_addrlen,
            &hostBuf,
            socklen_t(hostBuf.count),
            nil,
            0,
            flags
        )
        guard rc == 0 else { return nil }
        return String(cString: hostBuf)
    }
}
