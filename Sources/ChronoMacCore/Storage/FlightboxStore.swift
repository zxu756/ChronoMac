import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class FlightboxStore: @unchecked Sendable {
    public let dbPath: String
    public let maxDatabaseBytes: Int64
    public let isReadOnly: Bool
    private var db: OpaquePointer?
    private var hasLoopbackColumns: Bool = true
    private var hasProcessNameInSocketPK: Bool = true
    private let lock = NSLock()

    public static var defaultDatabaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ChronoMac/flightbox.sqlite")
    }

    public static func parseCLIDatabasePath(_ arguments: [String]) -> String? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--db", idx + 1 < arguments.count {
                let val = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            } else if arg.hasPrefix("--db=") {
                let val = String(arg.dropFirst("--db=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    public static func resolveDatabaseURL(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let cliPath = parseCLIDatabasePath(arguments) {
            return URL(fileURLWithPath: (cliPath as NSString).expandingTildeInPath)
        }
        if let envPath = environment["CHRONOMAC_DB_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath)
        }
        return defaultDatabaseURL
    }

    public init(
        databaseURL: URL? = nil,
        maxDatabaseBytes: Int64 = 250 * 1024 * 1024,
        readOnly: Bool = false
    ) throws {
        let resolvedURL = databaseURL ?? Self.resolveDatabaseURL()
        self.dbPath = resolvedURL.path
        self.maxDatabaseBytes = maxDatabaseBytes
        self.isReadOnly = readOnly

        if readOnly {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                self.db = nil
                return
            }
            var handle: OpaquePointer?
            let rc = sqlite3_open_v2(
                dbPath,
                &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard rc == SQLITE_OK, let opened = handle else {
                let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite read-only open failed"
                if let handle { sqlite3_close(handle) }
                throw NSError(domain: "ChronoMac.FlightboxStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
            }
            self.db = opened
            sqlite3_busy_timeout(opened, 2000)
            self.hasLoopbackColumns = Self.tableHasColumn(db: opened, table: "system_ticks", column: "loopback_in_bps")
            return
        }

        let dir = resolvedURL.deletingLastPathComponent()
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

    private static func tableHasColumn(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return false
        }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(s, 1),
               String(cString: namePtr) == column {
                return true
            }
        }
        return false
    }

    private static func socketPKIncludesProcessName(db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(socket_ledger);", -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return false
        }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(s, 1),
               String(cString: namePtr) == "process_name" {
                return sqlite3_column_int(s, 5) > 0
            }
        }
        return false
    }

    private func bootstrapSchema() throws {
        guard let db else { return }
        // IMPORTANT: auto_vacuum = INCREMENTAL must precede journal_mode = WAL on new databases
        // so page 1 is initialized with incremental pointer-map support.
        let ddl = """
        PRAGMA auto_vacuum = INCREMENTAL;
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        PRAGMA cache_size = -4096;

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
            loopback_in_bps INTEGER NOT NULL DEFAULT 0,
            loopback_out_bps INTEGER NOT NULL DEFAULT 0,
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
            PRIMARY KEY (bucket_hour, exec_path, process_name, remote_endpoint)
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

        CREATE TABLE IF NOT EXISTS recorder_gaps (
            ts INTEGER PRIMARY KEY,
            reason TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_recorder_gaps_ts ON recorder_gaps(ts DESC);
        """
        try execRaw(ddl)

        if !Self.tableHasColumn(db: db, table: "system_ticks", column: "loopback_in_bps") {
            try execRaw("ALTER TABLE system_ticks ADD COLUMN loopback_in_bps INTEGER NOT NULL DEFAULT 0;")
        }
        if !Self.tableHasColumn(db: db, table: "system_ticks", column: "loopback_out_bps") {
            try execRaw("ALTER TABLE system_ticks ADD COLUMN loopback_out_bps INTEGER NOT NULL DEFAULT 0;")
        }
        self.hasLoopbackColumns = true
        self.hasProcessNameInSocketPK = Self.socketPKIncludesProcessName(db: db)
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

    private func prepareChecked(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite prepare error \(rc)"
            if let stmt { sqlite3_finalize(stmt) }
            throw NSError(domain: "ChronoMac.FlightboxStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return prepared
    }

    private func stepDoneChecked(_ stmt: OpaquePointer, db: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite step error \(rc)"
            throw NSError(domain: "ChronoMac.FlightboxStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func querySingleInt64(_ sql: String) -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : 0
    }

    public func totalStorageBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for path in [dbPath, dbPath + "-wal", dbPath + "-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let sz = attrs[.size] as? Int64 {
                total += sz
            }
        }
        return total
    }

    private func walFileBytes() -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal"),
           let sz = attrs[.size] as? Int64 {
            return sz
        }
        return 0
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
        guard let db, !isReadOnly else { return }

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
            if sqlite3_get_autocommit(db) == 0 {
                try? execRaw("ROLLBACK;")
            }
            throw error
        }
    }

    public func recordSamplingGap(ts: Int64, reason: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !isReadOnly else { return }

        let sql = """
        INSERT INTO recorder_gaps (ts, reason)
        VALUES (?, ?)
        ON CONFLICT(ts) DO UPDATE SET reason = excluded.reason;
        """
        let s = try prepareChecked(sql, db: db)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, ts)
        sqlite3_bind_text(s, 2, reason, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        try stepDoneChecked(s, db: db)
    }

    private func insertTick(_ t: SystemTick, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO system_ticks (
            ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
            swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
            loopback_in_bps, loopback_out_bps, active_agent_count, active_agent_summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(ts) DO UPDATE SET
            tier = MAX(system_ticks.tier, excluded.tier),
            cpu_user = MAX(system_ticks.cpu_user, excluded.cpu_user),
            cpu_sys = MAX(system_ticks.cpu_sys, excluded.cpu_sys),
            thermal_level = MAX(system_ticks.thermal_level, excluded.thermal_level),
            mem_used_bytes = MAX(system_ticks.mem_used_bytes, excluded.mem_used_bytes),
            mem_total_bytes = MAX(system_ticks.mem_total_bytes, excluded.mem_total_bytes),
            swap_used_bytes = MAX(system_ticks.swap_used_bytes, excluded.swap_used_bytes),
            disk_read_bps = MAX(system_ticks.disk_read_bps, excluded.disk_read_bps),
            disk_write_bps = MAX(system_ticks.disk_write_bps, excluded.disk_write_bps),
            net_in_bps = MAX(system_ticks.net_in_bps, excluded.net_in_bps),
            net_out_bps = MAX(system_ticks.net_out_bps, excluded.net_out_bps),
            loopback_in_bps = MAX(system_ticks.loopback_in_bps, excluded.loopback_in_bps),
            loopback_out_bps = MAX(system_ticks.loopback_out_bps, excluded.loopback_out_bps),
            active_agent_count = MAX(system_ticks.active_agent_count, excluded.active_agent_count),
            active_agent_summary = CASE
                WHEN LENGTH(excluded.active_agent_summary) >= LENGTH(system_ticks.active_agent_summary)
                THEN excluded.active_agent_summary
                ELSE system_ticks.active_agent_summary
            END;
        """
        let s = try prepareChecked(sql, db: db)
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
        sqlite3_bind_int64(s, 13, t.loopbackInBps)
        sqlite3_bind_int64(s, 14, t.loopbackOutBps)
        sqlite3_bind_int(s, 15, Int32(t.activeAgentCount))
        sqlite3_bind_text(s, 16, t.activeAgentSummary, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        try stepDoneChecked(s, db: db)
    }

    private func insertProcess(_ p: ProcessSample, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO process_snapshots (
            ts, pid, ppid, name, exec_path, bundle_id, signing_team,
            cpu_pct, rss_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let s = try prepareChecked(sql, db: db)
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
        let encodedCPU = p.isCPUReadable ? p.cpuPct : -1.0
        sqlite3_bind_double(s, 8, encodedCPU)
        sqlite3_bind_int64(s, 9, p.rssBytes)
        sqlite3_bind_int64(s, 10, p.diskReadBps)
        sqlite3_bind_int64(s, 11, p.diskWriteBps)
        sqlite3_bind_int64(s, 12, p.netInBps)
        sqlite3_bind_int64(s, 13, p.netOutBps)
        try stepDoneChecked(s, db: db)
    }

    private func upsertSocket(_ rec: SocketFlowRecord, db: OpaquePointer) throws {
        let conflictCols = hasProcessNameInSocketPK
            ? "bucket_hour, exec_path, process_name, remote_endpoint"
            : "bucket_hour, exec_path, remote_endpoint"
        let sql = """
        INSERT INTO socket_ledger (
            bucket_hour, exec_path, process_name, remote_endpoint, hostname, proto,
            total_bytes_in, total_bytes_out, first_seen, last_seen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(\(conflictCols)) DO UPDATE SET
            total_bytes_in = socket_ledger.total_bytes_in + excluded.total_bytes_in,
            total_bytes_out = socket_ledger.total_bytes_out + excluded.total_bytes_out,
            hostname = COALESCE(excluded.hostname, socket_ledger.hostname),
            last_seen = MAX(socket_ledger.last_seen, excluded.last_seen);
        """
        let s = try prepareChecked(sql, db: db)
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
        try stepDoneChecked(s, db: db)
    }

    private func insertAnomaly(_ a: AnomalyBookmark, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO anomaly_bookmarks (
            id, ts, kind, severity, culprit_name, culprit_exec, metric_badge, summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let s = try prepareChecked(sql, db: db)
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, a.id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(s, 2, a.ts)
        sqlite3_bind_text(s, 3, a.kind.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(s, 4, Int32(a.severity))
        sqlite3_bind_text(s, 5, a.culpritName, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 6, a.culpritExec, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 7, a.metricBadge, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 8, a.summary, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        try stepDoneChecked(s, db: db)
    }

    public func updateHostname(for remoteEndpoint: String, hostname: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !isReadOnly else { return }
        let sql = "UPDATE socket_ledger SET hostname = ? WHERE remote_endpoint = ? AND hostname IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, hostname, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 2, remoteEndpoint, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(s)
    }

    public func checkpointWAL() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReadOnly, db != nil else { return }
        try? execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - 3-Tier Peak-Preserving Rollup & Hard Storage Cap

    /// Compacts completed Tier 0 buckets (< now-2h) into 15s buckets, completed Tier 1 buckets (< now-24h)
    /// into 60s buckets, prunes data older than 7 days, reclaims free pages, and enforces `maxDatabaseBytes`
    /// globally oldest-first across `.sqlite` + `-wal` + `-shm` without any 48-hour immunity window.
    public func runRollupAndRetention(now: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isReadOnly, db != nil else { return }

        let twoHoursAgo = now - 7_200
        let dayAgo = now - 86_400
        let sevenDaysAgo = now - 604_800

        try execRaw("BEGIN IMMEDIATE TRANSACTION;")
        do {
            // Tier 0 -> Tier 1 (15s peak-preserving rollup; only fully elapsed buckets)
            try compactTier(fromTier: 0, toTier: 1, bucketSec: 15, olderThan: twoHoursAgo)
            // Tier 1 -> Tier 2 (60s peak-preserving rollup; only fully elapsed buckets)
            try compactTier(fromTier: 1, toTier: 2, bucketSec: 60, olderThan: dayAgo)

            // Prune > 7 days
            try execRaw("""
            DELETE FROM system_ticks WHERE ts < \(sevenDaysAgo);
            DELETE FROM process_snapshots WHERE ts < \(sevenDaysAgo);
            DELETE FROM socket_ledger WHERE last_seen < \(sevenDaysAgo);
            DELETE FROM anomaly_bookmarks WHERE ts < \(sevenDaysAgo);
            DELETE FROM recorder_gaps WHERE ts < \(sevenDaysAgo);
            """)
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }

        // Reclaim free pages or oversized WAL before checking hard cap
        let walThreshold = max(256 * 1024, maxDatabaseBytes / 4)
        let freePages = querySingleInt64("PRAGMA freelist_count;")
        let totalPages = max(1, querySingleInt64("PRAGMA page_count;"))
        if totalStorageBytes() > maxDatabaseBytes || walFileBytes() >= walThreshold || (freePages > 128 && freePages * 4 > totalPages) {
            reclaimStoragePages()
        }

        // Enforce hard storage ceiling (sqlite + wal + shm <= maxDatabaseBytes), globally oldest-first, no 48h immunity
        var guardIterations = 0
        while totalStorageBytes() > maxDatabaseBytes && guardIterations < 40 {
            guardIterations += 1
            let procCount = querySingleInt64("SELECT COUNT(*) FROM process_snapshots;")
            let tickCount = querySingleInt64("SELECT COUNT(*) FROM system_ticks;")
            let sockCount = querySingleInt64("SELECT COUNT(*) FROM socket_ledger;")
            let anomCount = querySingleInt64("SELECT COUNT(*) FROM anomaly_bookmarks;")
            let gapCount = querySingleInt64("SELECT COUNT(*) FROM recorder_gaps;")
            let totalRows = procCount + tickCount + sockCount + anomCount + gapCount

            if totalRows == 0 {
                try execRaw("VACUUM;")
                try execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
                break
            }

            let offsetIdx = max(0, totalRows / 5 - 1)
            let cutoffTs = querySingleInt64("""
            SELECT ts FROM (
                SELECT ts FROM process_snapshots
                UNION ALL
                SELECT ts FROM system_ticks
                UNION ALL
                SELECT last_seen AS ts FROM socket_ledger
                UNION ALL
                SELECT ts FROM anomaly_bookmarks
                UNION ALL
                SELECT ts FROM recorder_gaps
            )
            ORDER BY ts ASC
            LIMIT 1 OFFSET \(offsetIdx);
            """)
            let globalMaxTs = querySingleInt64("""
            SELECT MAX(ts) FROM (
                SELECT MAX(ts) AS ts FROM process_snapshots
                UNION ALL
                SELECT MAX(ts) AS ts FROM system_ticks
                UNION ALL
                SELECT MAX(last_seen) AS ts FROM socket_ledger
                UNION ALL
                SELECT MAX(ts) AS ts FROM anomaly_bookmarks
                UNION ALL
                SELECT MAX(ts) AS ts FROM recorder_gaps
            );
            """)

            try execRaw("BEGIN IMMEDIATE TRANSACTION;")
            do {
                if cutoffTs < globalMaxTs {
                    try execRaw("""
                    DELETE FROM process_snapshots WHERE ts <= \(cutoffTs);
                    DELETE FROM system_ticks WHERE ts <= \(cutoffTs);
                    DELETE FROM socket_ledger WHERE last_seen <= \(cutoffTs);
                    DELETE FROM anomaly_bookmarks WHERE ts <= \(cutoffTs);
                    DELETE FROM recorder_gaps WHERE ts <= \(cutoffTs);
                    """)
                } else {
                    let procTrim = procCount > 0 ? max(1, procCount / 5) : 0
                    let tickTrim = tickCount > 0 ? max(1, tickCount / 5) : 0
                    let sockTrim = sockCount > 0 ? max(1, sockCount / 5) : 0
                    let anomTrim = anomCount > 0 ? max(1, anomCount / 5) : 0
                    let gapTrim = gapCount > 0 ? max(1, gapCount / 5) : 0
                    if procTrim > 0 {
                        try execRaw("DELETE FROM process_snapshots WHERE rowid IN (SELECT rowid FROM process_snapshots ORDER BY ts ASC, rowid ASC LIMIT \(procTrim));")
                    }
                    if tickTrim > 0 {
                        try execRaw("DELETE FROM system_ticks WHERE rowid IN (SELECT rowid FROM system_ticks ORDER BY ts ASC, rowid ASC LIMIT \(tickTrim));")
                    }
                    if sockTrim > 0 {
                        try execRaw("DELETE FROM socket_ledger WHERE rowid IN (SELECT rowid FROM socket_ledger ORDER BY last_seen ASC, rowid ASC LIMIT \(sockTrim));")
                    }
                    if anomTrim > 0 {
                        try execRaw("DELETE FROM anomaly_bookmarks WHERE rowid IN (SELECT rowid FROM anomaly_bookmarks ORDER BY ts ASC, rowid ASC LIMIT \(anomTrim));")
                    }
                    if gapTrim > 0 {
                        try execRaw("DELETE FROM recorder_gaps WHERE rowid IN (SELECT rowid FROM recorder_gaps ORDER BY ts ASC, rowid ASC LIMIT \(gapTrim));")
                    }
                }
                try execRaw("COMMIT;")
            } catch {
                try? execRaw("ROLLBACK;")
                throw error
            }

            reclaimStoragePages(forceFallbackVacuumIfUnchanged: true)
        }
    }

    private func reclaimStoragePages(forceFallbackVacuumIfUnchanged: Bool = false) {
        let beforeBytes = totalStorageBytes()
        let autoVacMode = querySingleInt64("PRAGMA auto_vacuum;")
        if autoVacMode == 2 {
            try? execRaw("PRAGMA incremental_vacuum;")
            try? execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
            if forceFallbackVacuumIfUnchanged && totalStorageBytes() >= beforeBytes {
                try? execRaw("VACUUM;")
                try? execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
            }
        } else {
            try? execRaw("VACUUM;")
            try? execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    private func compactTier(fromTier: Int, toTier: Int, bucketSec: Int64, olderThan cutoff: Int64) throws {
        guard cutoff > 0 else { return }
        // Only compact a bucket [b_ts, b_ts + bucketSec) once the ENTIRE bucket has strictly passed cutoff.
        let alignedCutoff = (cutoff / bucketSec) * bucketSec
        guard alignedCutoff > 0 else { return }

        // Check fast via index whether any source-tier rows exist before alignedCutoff
        let candidateCount = querySingleInt64(
            "SELECT COUNT(*) FROM system_ticks WHERE tier = \(fromTier) AND ts < \(alignedCutoff) LIMIT 1;"
        )
        guard candidateCount > 0 else { return }

        let minCandidateTs = querySingleInt64(
            "SELECT MIN(ts) FROM system_ticks WHERE tier = \(fromTier) AND ts < \(alignedCutoff);"
        )
        let alignedStart = (minCandidateTs / bucketSec) * bucketSec
        let peakSpan: Int64 = (fromTier == 0) ? 1 : 15

        let sql = """
        DELETE FROM process_snapshots
        WHERE ts >= \(alignedStart) AND ts < \(alignedCutoff)
          AND NOT EXISTS (
              SELECT 1 FROM (
                  SELECT ts AS peak_ts,
                         ROW_NUMBER() OVER (
                             PARTITION BY (ts / \(bucketSec)) * \(bucketSec)
                             ORDER BY (cpu_user + cpu_sys) DESC, mem_used_bytes DESC, (net_in_bps + net_out_bps) DESC, ts ASC
                         ) AS rn
                  FROM system_ticks
                  WHERE ts >= \(alignedStart) AND ts < \(alignedCutoff)
              ) peaks
              WHERE peaks.rn = 1
                AND process_snapshots.ts >= peaks.peak_ts
                AND process_snapshots.ts < peaks.peak_ts + \(peakSpan)
          );

        INSERT INTO system_ticks (
            ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
            swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
            loopback_in_bps, loopback_out_bps, active_agent_count, active_agent_summary
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
            MAX(loopback_in_bps),
            MAX(loopback_out_bps),
            MAX(active_agent_count),
            MAX(active_agent_summary)
        FROM system_ticks
        WHERE tier = \(fromTier) AND ts >= \(alignedStart) AND ts < \(alignedCutoff)
        GROUP BY b_ts
        ON CONFLICT(ts) DO UPDATE SET
            tier = MAX(system_ticks.tier, excluded.tier),
            cpu_user = MAX(system_ticks.cpu_user, excluded.cpu_user),
            cpu_sys = MAX(system_ticks.cpu_sys, excluded.cpu_sys),
            thermal_level = MAX(system_ticks.thermal_level, excluded.thermal_level),
            mem_used_bytes = MAX(system_ticks.mem_used_bytes, excluded.mem_used_bytes),
            mem_total_bytes = MAX(system_ticks.mem_total_bytes, excluded.mem_total_bytes),
            swap_used_bytes = MAX(system_ticks.swap_used_bytes, excluded.swap_used_bytes),
            disk_read_bps = MAX(system_ticks.disk_read_bps, excluded.disk_read_bps),
            disk_write_bps = MAX(system_ticks.disk_write_bps, excluded.disk_write_bps),
            net_in_bps = MAX(system_ticks.net_in_bps, excluded.net_in_bps),
            net_out_bps = MAX(system_ticks.net_out_bps, excluded.net_out_bps),
            loopback_in_bps = MAX(system_ticks.loopback_in_bps, excluded.loopback_in_bps),
            loopback_out_bps = MAX(system_ticks.loopback_out_bps, excluded.loopback_out_bps),
            active_agent_count = MAX(system_ticks.active_agent_count, excluded.active_agent_count),
            active_agent_summary = CASE
                WHEN LENGTH(excluded.active_agent_summary) >= LENGTH(system_ticks.active_agent_summary)
                THEN excluded.active_agent_summary
                ELSE system_ticks.active_agent_summary
            END;

        DELETE FROM system_ticks
        WHERE tier = \(fromTier) AND ts >= \(alignedStart) AND ts < \(alignedCutoff);
        """
        try execRaw(sql)
    }

    // MARK: - Forensic Queries

    public func queryTicks(from startTs: Int64, to endTs: Int64) -> [SystemTick] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if hasLoopbackColumns {
            sql = """
            SELECT ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
                   swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
                   loopback_in_bps, loopback_out_bps, active_agent_count, active_agent_summary
            FROM system_ticks
            WHERE ts >= ? AND ts <= ?
            ORDER BY ts ASC;
            """
        } else {
            sql = """
            SELECT ts, tier, cpu_user, cpu_sys, thermal_level, mem_used_bytes, mem_total_bytes,
                   swap_used_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps,
                   0, 0, active_agent_count, active_agent_summary
            FROM system_ticks
            WHERE ts >= ? AND ts <= ?
            ORDER BY ts ASC;
            """
        }
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
                    loopbackInBps: sqlite3_column_int64(s, 12),
                    loopbackOutBps: sqlite3_column_int64(s, 13),
                    activeAgentCount: Int(sqlite3_column_int(s, 14)),
                    activeAgentSummary: sqlite3_column_text(s, 15).map { String(cString: $0) } ?? ""
                )
            )
        }
        return out
    }

    public func queryNearestProcesses(
        at targetTs: Int64,
        livePIDs: Set<Int>? = nil,
        sortBy: ProcessSortOrder = .cpu
    ) -> (actualTs: Int64?, processes: [ProcessSample]) {
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

        let orderClause: String
        switch sortBy {
        case .cpu:
            orderClause = """
            CASE WHEN cpu_pct >= 0 THEN 0 ELSE 1 END ASC,
            cpu_pct DESC,
            rss_bytes DESC,
            (net_out_bps + net_in_bps) DESC,
            pid ASC
            """
        case .memory:
            orderClause = """
            rss_bytes DESC,
            CASE WHEN cpu_pct >= 0 THEN cpu_pct ELSE 0 END DESC,
            (net_out_bps + net_in_bps) DESC,
            pid ASC
            """
        case .network:
            orderClause = """
            (ABS(net_out_bps) + ABS(net_in_bps)) DESC,
            ABS(net_out_bps) DESC,
            rss_bytes DESC,
            pid ASC
            """
        }

        let procSQL = """
        SELECT ts, pid, ppid, name, exec_path, bundle_id, signing_team,
               cpu_pct, rss_bytes, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps
        FROM process_snapshots
        WHERE ts = ?
        ORDER BY \(orderClause);
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
            let alive = (pid == NettopDeltaParser.unattributedPID) ? true : (livePIDs.map { $0.contains(pid) } ?? true)
            let rawCPU = sqlite3_column_double(s, 7)
            let cpuReadable = rawCPU >= 0.0
            list.append(
                ProcessSample(
                    ts: sqlite3_column_int64(s, 0),
                    pid: pid,
                    ppid: Int(sqlite3_column_int(s, 2)),
                    name: sqlite3_column_text(s, 3).map { String(cString: $0) } ?? "unknown",
                    execPath: sqlite3_column_text(s, 4).map { String(cString: $0) } ?? "",
                    bundleID: sqlite3_column_text(s, 5).map { String(cString: $0) },
                    signingTeam: sqlite3_column_text(s, 6).map { String(cString: $0) },
                    cpuPct: cpuReadable ? rawCPU : 0.0,
                    rssBytes: sqlite3_column_int64(s, 8),
                    diskReadBps: sqlite3_column_int64(s, 9),
                    diskWriteBps: sqlite3_column_int64(s, 10),
                    netInBps: sqlite3_column_int64(s, 11),
                    netOutBps: sqlite3_column_int64(s, 12),
                    isAliveNow: alive,
                    isCPUReadable: cpuReadable
                )
            )
        }
        return (resolvedTs, list)
    }

    public func queryHistoricalProcesses(
        from startTs: Int64,
        to endTs: Int64,
        livePIDs: Set<Int>? = nil,
        sortBy: ProcessSortOrder = .cpu,
        nameFilter: String? = nil,
        limit: Int = 25
    ) -> [ProcessSample] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let orderClause: String
        switch sortBy {
        case .cpu:
            orderClause = """
            CASE WHEN MAX(cpu_pct) >= 0 THEN 0 ELSE 1 END ASC,
            MAX(cpu_pct) DESC,
            MAX(rss_bytes) DESC,
            MAX(net_out_bps + net_in_bps) DESC,
            pid ASC
            """
        case .memory:
            orderClause = """
            MAX(rss_bytes) DESC,
            CASE WHEN MAX(cpu_pct) >= 0 THEN MAX(cpu_pct) ELSE 0 END DESC,
            MAX(net_out_bps + net_in_bps) DESC,
            pid ASC
            """
        case .network:
            orderClause = """
            (MAX(ABS(net_out_bps)) + MAX(ABS(net_in_bps))) DESC,
            MAX(ABS(net_out_bps)) DESC,
            MAX(rss_bytes) DESC,
            pid ASC
            """
        }

        let trimmedFilter = nameFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasFilter = !trimmedFilter.isEmpty
        let filterClause = hasFilter
            ? "AND (LOWER(name) LIKE ? OR LOWER(exec_path) LIKE ?)"
            : ""

        let sql = """
        SELECT MAX(ts), pid, MAX(ppid), name, exec_path, MAX(bundle_id), MAX(signing_team),
               MAX(cpu_pct), MAX(rss_bytes), MAX(disk_read_bps), MAX(disk_write_bps),
               CASE WHEN MIN(net_in_bps) < 0 THEN MIN(net_in_bps) ELSE MAX(net_in_bps) END,
               CASE WHEN MIN(net_out_bps) < 0 THEN MIN(net_out_bps) ELSE MAX(net_out_bps) END
        FROM process_snapshots
        WHERE ts >= ? AND ts <= ? \(filterClause)
        GROUP BY pid, name, exec_path
        ORDER BY \(orderClause)
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_int64(s, 1, startTs)
        sqlite3_bind_int64(s, 2, endTs)
        if hasFilter {
            let pattern = "%" + trimmedFilter.lowercased() + "%"
            sqlite3_bind_text(s, 3, pattern, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(s, 4, pattern, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(s, 5, Int32(limit))
        } else {
            sqlite3_bind_int(s, 3, Int32(limit))
        }

        var list: [ProcessSample] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let pid = Int(sqlite3_column_int(s, 1))
            let alive = (pid == NettopDeltaParser.unattributedPID) ? true : (livePIDs.map { $0.contains(pid) } ?? true)
            let rawCPU = sqlite3_column_double(s, 7)
            let cpuReadable = rawCPU >= 0.0
            list.append(
                ProcessSample(
                    ts: sqlite3_column_int64(s, 0),
                    pid: pid,
                    ppid: Int(sqlite3_column_int(s, 2)),
                    name: sqlite3_column_text(s, 3).map { String(cString: $0) } ?? "unknown",
                    execPath: sqlite3_column_text(s, 4).map { String(cString: $0) } ?? "",
                    bundleID: sqlite3_column_text(s, 5).map { String(cString: $0) },
                    signingTeam: sqlite3_column_text(s, 6).map { String(cString: $0) },
                    cpuPct: cpuReadable ? rawCPU : 0.0,
                    rssBytes: sqlite3_column_int64(s, 8),
                    diskReadBps: sqlite3_column_int64(s, 9),
                    diskWriteBps: sqlite3_column_int64(s, 10),
                    netInBps: sqlite3_column_int64(s, 11),
                    netOutBps: sqlite3_column_int64(s, 12),
                    isAliveNow: alive,
                    isCPUReadable: cpuReadable
                )
            )
        }
        return list
    }

    public func querySocketFlows(sinceTs: Int64, execPathFilter: String? = nil, limit: Int = 25) -> [SocketFlowRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if execPathFilter != nil {
            sql = """
            SELECT MAX(bucket_hour), exec_path, process_name, remote_endpoint, MAX(hostname), MAX(proto),
                   SUM(total_bytes_in), SUM(total_bytes_out), MIN(first_seen), MAX(last_seen)
            FROM socket_ledger
            WHERE last_seen >= ? AND exec_path = ?
            GROUP BY exec_path, process_name, remote_endpoint
            ORDER BY (ABS(SUM(total_bytes_out)) + ABS(SUM(total_bytes_in))) DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT MAX(bucket_hour), exec_path, process_name, remote_endpoint, MAX(hostname), MAX(proto),
                   SUM(total_bytes_in), SUM(total_bytes_out), MIN(first_seen), MAX(last_seen)
            FROM socket_ledger
            WHERE last_seen >= ?
            GROUP BY exec_path, process_name, remote_endpoint
            ORDER BY (ABS(SUM(total_bytes_out)) + ABS(SUM(total_bytes_in))) DESC
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

    public func querySamplingGaps(from startTs: Int64, to endTs: Int64) -> [SamplingGapRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql = """
        SELECT ts, reason
        FROM recorder_gaps
        WHERE ts >= ? AND ts <= ?
        ORDER BY ts ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, startTs)
        sqlite3_bind_int64(s, 2, endTs)

        var gaps: [SamplingGapRecord] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let ts = sqlite3_column_int64(s, 0)
            let reason = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""
            gaps.append(SamplingGapRecord(ts: ts, reason: reason))
        }
        return gaps
    }
}
