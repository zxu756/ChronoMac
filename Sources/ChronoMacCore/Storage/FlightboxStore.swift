import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class FlightboxStore: @unchecked Sendable {
    public let dbPath: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let maxDatabaseBytes: Int64

    public static var defaultDatabaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ChronoMac/flightbox.sqlite")
    }

    public init(databaseURL: URL = FlightboxStore.defaultDatabaseURL, maxDatabaseBytes: Int64 = 250 * 1024 * 1024) throws {
        self.dbPath = databaseURL.path
        self.maxDatabaseBytes = maxDatabaseBytes

        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            dbPath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite open failed"
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "ChronoMac.FlightboxStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = opened
        sqlite3_busy_timeout(opened, 2000)
        try bootstrapSchema()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func bootstrapSchema() throws {
        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        PRAGMA auto_vacuum = INCREMENTAL;

        CREATE TABLE IF NOT EXISTS system_ticks (
            ts INTEGER PRIMARY KEY,
            tier INTEGER NOT NULL DEFAULT 0,
            cpu_user REAL NOT NULL,
            cpu_sys REAL NOT NULL,
            thermal_level INTEGER NOT NULL DEFAULT 0,
            mem_used_bytes INTEGER NOT NULL,
            mem_total_bytes INTEGER NOT NULL,
            swap_used_bytes INTEGER NOT NULL,
            disk_read_bps INTEGER NOT NULL,
            disk_write_bps INTEGER NOT NULL,
            net_in_bps INTEGER NOT NULL,
            net_out_bps INTEGER NOT NULL,
            active_agent_count INTEGER NOT NULL DEFAULT 0,
            active_agent_summary TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_ticks_tier_ts ON system_ticks(tier, ts);

        CREATE TABLE IF NOT EXISTS process_snapshots (
            ts INTEGER NOT NULL,
            pid INTEGER NOT NULL,
            ppid INTEGER NOT NULL,
            name TEXT NOT NULL,
            exec_path TEXT NOT NULL,
            bundle_id TEXT,
            signing_team TEXT,
            cpu_pct REAL NOT NULL,
            rss_bytes INTEGER NOT NULL,
            disk_read_bps INTEGER NOT NULL,
            disk_write_bps INTEGER NOT NULL,
            net_in_bps INTEGER NOT NULL,
            net_out_bps INTEGER NOT NULL,
            PRIMARY KEY (ts, pid)
        );
        CREATE INDEX IF NOT EXISTS idx_proc_ts ON process_snapshots(ts);
        CREATE INDEX IF NOT EXISTS idx_proc_exec ON process_snapshots(exec_path, ts);

        CREATE TABLE IF NOT EXISTS socket_ledger (
            bucket_hour INTEGER NOT NULL,
            exec_path TEXT NOT NULL,
            process_name TEXT NOT NULL,
            remote_endpoint TEXT NOT NULL,
            hostname TEXT,
            proto TEXT NOT NULL,
            total_bytes_in INTEGER NOT NULL,
            total_bytes_out INTEGER NOT NULL,
            first_seen INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            PRIMARY KEY (bucket_hour, exec_path, remote_endpoint)
        );
        CREATE INDEX IF NOT EXISTS idx_socket_last_seen ON socket_ledger(last_seen DESC);

        CREATE TABLE IF NOT EXISTS anomaly_bookmarks (
            id TEXT PRIMARY KEY,
            ts INTEGER NOT NULL,
            kind TEXT NOT NULL,
            severity INTEGER NOT NULL,
            culprit_name TEXT NOT NULL,
            culprit_exec TEXT NOT NULL,
            metric_badge TEXT NOT NULL,
            summary TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_anomaly_ts ON anomaly_bookmarks(ts DESC);
        """
        try execRaw(ddl)
    }

    private func execRaw(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "ChronoMac.FlightboxStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Write Path

    public func recordSampleBatch(
        tick: SystemTick,
        processes: [ProcessSample],
        sockets: [SocketFlowRecord],
        anomalies: [AnomalyBookmark]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        try execRaw("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try insertTick(tick, db: db)
            for p in processes {
                try insertProcess(p, db: db)
            }
            for s in sockets {
                try upsertSocket(s, db: db)
            }
            for a in anomalies {
                try insertAnomaly(a, db: db)
            }
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }
    }

    private func insertTick(_ t: SystemTick, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO system_ticks (
            ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
            swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
            active_agent_count, active_agent_summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, t.ts)
        sqlite3_bind_int(s, 2, Int32(t.tier.rawValue))
        sqlite3_bind_double(s, 3, t.cpuUserPct)
        sqlite3_bind_double(s, 4, t.cpuSysPct)
        sqlite3_bind_int(s, 5, Int32(t.thermalGrade.rawValue))
        sqlite3_bind_int64(s, 6, t.memUsedBytes)
        sqlite3_bind_int64(s, 7, t.memTotalBytes)
        sqlite3_bind_int64(s, 8, t.swapUsedBytes)
        sqlite3_bind_int64(s, 9, t.diskReadBps)
        sqlite3_bind_int64(s, 10, t.diskWriteBps)
        sqlite3_bind_int64(s, 11, t.netInBps)
        sqlite3_bind_int64(s, 12, t.netOutBps)
        sqlite3_bind_int(s, 13, Int32(t.activeAgentCount))
        sqlite3_bind_text(s, 14, t.activeAgentSummary, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(s)
    }

    private func insertProcess(_ p: ProcessSample, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO process_snapshots (
            ts, pid, ppid, name, exec_path, bundle_id, signing_team,
            cpu_pct, rss_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, p.ts)
        sqlite3_bind_int(s, 2, Int32(p.pid))
        sqlite3_bind_int(s, 3, Int32(p.ppid))
        sqlite3_bind_text(s, 4, p.name, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 5, p.execPath, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let bid = p.bundleID {
            sqlite3_bind_text(s, 6, bid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(s, 6)
        }
        if let team = p.signingTeam {
            sqlite3_bind_text(s, 7, team, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(s, 7)
        }
        sqlite3_bind_double(s, 8, p.cpuPct)
        sqlite3_bind_int64(s, 9, p.rssBytes)
        sqlite3_bind_int64(s, 10, p.diskReadBps)
        sqlite3_bind_int64(s, 11, p.diskWriteBps)
        sqlite3_bind_int64(s, 12, p.netInBps)
        sqlite3_bind_int64(s, 13, p.netOutBps)
        _ = sqlite3_step(s)
    }

    private func upsertSocket(_ rec: SocketFlowRecord, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO socket_ledger (
            bucket_hour, exec_path, process_name, remote_endpoint, hostname, proto,
            total_bytes_in, total_bytes_out, first_seen, last_seen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bucket_hour, exec_path, remote_endpoint) DO UPDATE SET
            total_bytes_in = socket_ledger.total_bytes_in + excluded.total_bytes_in,
            total_bytes_out = socket_ledger.total_bytes_out + excluded.total_bytes_out,
            hostname = COALESCE(excluded.hostname, socket_ledger.hostname),
            last_seen = MAX(socket_ledger.last_seen, excluded.last_seen);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, rec.bucketHour)
        sqlite3_bind_text(s, 2, rec.execPath, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 3, rec.processName, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 4, rec.remoteEndpoint, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let h = rec.hostname {
            sqlite3_bind_text(s, 5, h, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(s, 5)
        }
        sqlite3_bind_text(s, 6, rec.protocolName, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(s, 7, rec.totalBytesIn)
        sqlite3_bind_int64(s, 8, rec.totalBytesOut)
        sqlite3_bind_int64(s, 9, rec.firstSeen)
        sqlite3_bind_int64(s, 10, rec.lastSeen)
        _ = sqlite3_step(s)
    }

    private func insertAnomaly(_ a: AnomalyBookmark, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO anomaly_bookmarks (
            id, ts, kind, severity, culprit_name, culprit_exec, metric_badge, summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, a.id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(s, 2, a.ts)
        sqlite3_bind_text(s, 3, a.kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(s, 4, Int32(a.severity))
        sqlite3_bind_text(s, 5, a.culpritName, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 6, a.culpritExec, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 7, a.metricBadge, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 8, a.summary, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(s)
    }

    public func updateHostname(for remoteEndpoint: String, hostname: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let sql = "UPDATE socket_ledger SET hostname = ? WHERE remote_endpoint = ? AND hostname IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, hostname, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 2, remoteEndpoint, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(s)
    }

    // MARK: - 3-Tier Peak-Preserving Rollup & Retention Cap

    /// Compacts Tier 0 (< now-2h) into 15s buckets, Tier 1 (< now-24h) into 60s buckets,
    /// prunes data older than 7 days, and enforces the 250 MB hard cap.
    public func runRollupAndRetention(now: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        let twoHoursAgo = now - 7_200
        let dayAgo = now - 86_400
        let sevenDaysAgo = now - 604_800

        try execRaw("BEGIN IMMEDIATE TRANSACTION;")
        do {
            // Tier 0 -> Tier 1 (15s peak-preserving rollup)
            try compactTier(fromTier: 0, toTier: 1, bucketSec: 15, olderThan: twoHoursAgo)
            // Tier 1 -> Tier 2 (60s peak-preserving rollup)
            try compactTier(fromTier: 1, toTier: 2, bucketSec: 60, olderThan: dayAgo)

            // Prune > 7 days
            try execRaw("""
            DELETE FROM system_ticks WHERE ts < \(sevenDaysAgo);
            DELETE FROM process_snapshots WHERE ts < \(sevenDaysAgo);
            DELETE FROM socket_ledger WHERE last_seen < \(sevenDaysAgo);
            DELETE FROM anomaly_bookmarks WHERE ts < \(sevenDaysAgo);
            """)
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }

        // Enforce 250 MB ceiling
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64,
           size > maxDatabaseBytes {
            let trimCut = now - 172_800 // Keep recent 48h if exceeding ceiling
            try execRaw("""
            DELETE FROM process_snapshots WHERE ts < \(trimCut);
            DELETE FROM system_ticks WHERE ts < \(trimCut) AND tier > 0;
            PRAGMA incremental_vacuum(2048);
            """)
        }
    }

    private func compactTier(fromTier: Int, toTier: Int, bucketSec: Int64, olderThan cutoff: Int64) throws {
        let sql = """
        INSERT OR REPLACE INTO system_ticks (
            ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
            swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
            active_agent_count, active_agent_summary
        )
        SELECT
            (ts / \(bucketSec)) * \(bucketSec) AS b_ts,
            \(toTier),
            MAX(cpu_user),
            MAX(cpu_sys),
            MAX(thermal_level),
            MAX(mem_used_bytes),
            MAX(mem_total_bytes),
            MAX(swap_used_bytes),
            MAX(disk_read_bps),
            MAX(disk_write_bps),
            MAX(net_in_bps),
            MAX(net_out_bps),
            MAX(active_agent_count),
            MAX(active_agent_summary)
        FROM system_ticks
        WHERE tier = \(fromTier) AND ts < \(cutoff)
        GROUP BY b_ts;

        DELETE FROM system_ticks
        WHERE tier = \(fromTier) AND ts < \(cutoff);

        DELETE FROM process_snapshots
        WHERE ts < \(cutoff) AND (ts % \(bucketSec)) != 0
          AND ts NOT IN (SELECT (ts / \(bucketSec)) * \(bucketSec) FROM system_ticks WHERE tier = \(toTier));
        """
        try execRaw(sql)
    }

    // MARK: - Forensic Queries

    public func queryTicks(from startTs: Int64, to endTs: Int64) -> [SystemTick] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql = """
        SELECT ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
               swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
               active_agent_count, active_agent_summary
        FROM system_ticks
        WHERE ts >= ? AND ts <= ?
        ORDER BY ts ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, startTs)
        sqlite3_bind_int64(s, 2, endTs)

        var out: [SystemTick] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(
                SystemTick(
                    ts: sqlite3_column_int64(s, 0),
                    tier: SampleTier(rawValue: Int(sqlite3_column_int(s, 1))) ?? .raw2s,
                    cpuUserPct: sqlite3_column_double(s, 2),
                    cpuSysPct: sqlite3_column_double(s, 3),
                    thermalGrade: ThermalGrade(rawValue: Int(sqlite3_column_int(s, 4))) ?? .nominal,
                    memUsedBytes: sqlite3_column_int64(s, 5),
                    memTotalBytes: sqlite3_column_int64(s, 6),
                    swapUsedBytes: sqlite3_column_int64(s, 7),
                    diskReadBps: sqlite3_column_int64(s, 8),
                    diskWriteBps: sqlite3_column_int64(s, 9),
                    netInBps: sqlite3_column_int64(s, 10),
                    netOutBps: sqlite3_column_int64(s, 11),
                    activeAgentCount: Int(sqlite3_column_int(s, 12)),
                    activeAgentSummary: sqlite3_column_text(s, 13).map { String(cString: $0) } ?? ""
                )
            )
        }
        return out
    }

    public func queryNearestProcesses(at targetTs: Int64, livePIDs: Set<Int> = []) -> (actualTs: Int64?, processes: [ProcessSample]) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return (nil, []) }

        let nearestSQL = """
        SELECT ts FROM process_snapshots
        WHERE ts BETWEEN ? AND ?
        ORDER BY ABS(ts - ?) ASC
        LIMIT 1;
        """
        var findStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nearestSQL, -1, &findStmt, nil) == SQLITE_OK, let fs = findStmt else {
            return (nil, [])
        }
        sqlite3_bind_int64(fs, 1, targetTs - 3600)
        sqlite3_bind_int64(fs, 2, targetTs + 3600)
        sqlite3_bind_int64(fs, 3, targetTs)
        let actualTs: Int64? = sqlite3_step(fs) == SQLITE_ROW ? sqlite3_column_int64(fs, 0) : nil
        sqlite3_finalize(fs)

        guard let resolvedTs = actualTs else { return (nil, []) }

        let procSQL = """
        SELECT ts, pid, ppid, name, exec_path, bundle_id, signing_team,
               cpu_pct, rss_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps
        FROM process_snapshots
        WHERE ts = ?
        ORDER BY (cpu_pct * 25000000.0 + rss_bytes + (net_in_bps + net_out_bps) * 40.0) DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, procSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return (resolvedTs, [])
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, resolvedTs)

        var list: [ProcessSample] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let pid = Int(sqlite3_column_int(s, 1))
            let alive = livePIDs.isEmpty ? true : livePIDs.contains(pid)
            list.append(
                ProcessSample(
                    ts: sqlite3_column_int64(s, 0),
                    pid: pid,
                    ppid: Int(sqlite3_column_int(s, 2)),
                    name: sqlite3_column_text(s, 3).map { String(cString: $0) } ?? "unknown",
                    execPath: sqlite3_column_text(s, 4).map { String(cString: $0) } ?? "",
                    bundleID: sqlite3_column_text(s, 5).map { String(cString: $0) },
                    signingTeam: sqlite3_column_text(s, 6).map { String(cString: $0) },
                    cpuPct: sqlite3_column_double(s, 7),
                    rssBytes: sqlite3_column_int64(s, 8),
                    diskReadBps: sqlite3_column_int64(s, 9),
                    diskWriteBps: sqlite3_column_int64(s, 10),
                    netInBps: sqlite3_column_int64(s, 11),
                    netOutBps: sqlite3_column_int64(s, 12),
                    isAliveNow: alive
                )
            )
        }
        return (resolvedTs, list)
    }

    public func querySocketFlows(sinceTs: Int64, execPathFilter: String? = nil, limit: Int = 25) -> [SocketFlowRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if execPathFilter != nil {
            sql = """
            SELECT MAX(bucket_hour), exec_path, MAX(process_name), remote_endpoint, MAX(hostname), MAX(proto),
                   SUM(total_bytes_in), SUM(total_bytes_out), MIN(first_seen), MAX(last_seen)
            FROM socket_ledger
            WHERE last_seen >= ? AND exec_path = ?
            GROUP BY exec_path, remote_endpoint
            ORDER BY (SUM(total_bytes_out) + SUM(total_bytes_in)) DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT MAX(bucket_hour), exec_path, MAX(process_name), remote_endpoint, MAX(hostname), MAX(proto),
                   SUM(total_bytes_in), SUM(total_bytes_out), MIN(first_seen), MAX(last_seen)
            FROM socket_ledger
            WHERE last_seen >= ?
            GROUP BY exec_path, remote_endpoint
            ORDER BY (SUM(total_bytes_out) + SUM(total_bytes_in)) DESC
            LIMIT ?;
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, sinceTs)
        if let filter = execPathFilter {
            sqlite3_bind_text(s, 2, filter, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(s, 3, Int32(limit))
        } else {
            sqlite3_bind_int(s, 2, Int32(limit))
        }

        var rows: [SocketFlowRecord] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(
                SocketFlowRecord(
                    bucketHour: sqlite3_column_int64(s, 0),
                    execPath: sqlite3_column_text(s, 1).map { String(cString: $0) } ?? "",
                    processName: sqlite3_column_text(s, 2).map { String(cString: $0) } ?? "",
                    remoteEndpoint: sqlite3_column_text(s, 3).map { String(cString: $0) } ?? "",
                    hostname: sqlite3_column_text(s, 4).map { String(cString: $0) },
                    protocolName: sqlite3_column_text(s, 5).map { String(cString: $0) } ?? "tcp4",
                    totalBytesIn: sqlite3_column_int64(s, 6),
                    totalBytesOut: sqlite3_column_int64(s, 7),
                    firstSeen: sqlite3_column_int64(s, 8),
                    lastSeen: sqlite3_column_int64(s, 9)
                )
            )
        }
        return rows
    }

    public func queryAnomalies(sinceTs: Int64, limit: Int = 30) -> [AnomalyBookmark] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql = """
        SELECT id, ts, kind, severity, culprit_name, culprit_exec, metric_badge, summary
        FROM anomaly_bookmarks
        WHERE ts >= ?
        ORDER BY ts DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, sinceTs)
        sqlite3_bind_int(s, 2, Int32(limit))

        var out: [AnomalyBookmark] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let kindStr = sqlite3_column_text(s, 2).map { String(cString: $0) } ?? ""
            out.append(
                AnomalyBookmark(
                    id: sqlite3_column_text(s, 0).map { String(cString: $0) } ?? UUID().uuidString,
                    ts: sqlite3_column_int64(s, 1),
                    kind: AnomalyKind(rawValue: kindStr) ?? .runawayCPU,
                    severity: Int(sqlite3_column_int(s, 3)),
                    culpritName: sqlite3_column_text(s, 4).map { String(cString: $0) } ?? "",
                    culpritExec: sqlite3_column_text(s, 5).map { String(cString: $0) } ?? "",
                    metricBadge: sqlite3_column_text(s, 6).map { String(cString: $0) } ?? "",
                    summary: sqlite3_column_text(s, 7).map { String(cString: $0) } ?? ""
                )
            )
        }
        return out
    }
}
