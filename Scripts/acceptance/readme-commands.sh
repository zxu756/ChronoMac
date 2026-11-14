#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP_RM="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-readme.XXXXXX")"
cleanup() {
    rm -rf "$TMP_RM"
}
trap cleanup EXIT

SEED_DB="$TMP_RM/flightbox.sqlite"
export CHRONOMAC_DB_PATH="$SEED_DB"
export CHRONOMAC_AGENT_HOME="$TMP_RM/agent-home"
export CHRONOMAC_PREFS_SUITE="io.github.zxu756.ChronoMac.readme.$$"
mkdir -p "$CHRONOMAC_AGENT_HOME"

BIN="$ROOT/.build/debug/ChronoMac"
if [[ ! -x "$BIN" ]]; then
    swift build --product ChronoMac
fi

# Seed an isolated temporary SQLite flightbox with a snapshot ~10m ago so every README command runs realistically
/usr/bin/python3 - "$SEED_DB" "$$" <<'PY'
import sqlite3, sys, time

db_path = sys.argv[1]
alive_pid = int(sys.argv[2])
now = int(time.time())
snap_ts = now - 590  # 9m50s ago -> 10s delta from `--at 10m`

conn = sqlite3.connect(db_path)
conn.executescript("""
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA journal_mode = WAL;
CREATE TABLE system_ticks (
    ts INTEGER PRIMARY KEY,
    tier INTEGER NOT NULL,
    cpu_user REAL NOT NULL,
    cpu_sys REAL NOT NULL,
    thermal_level INTEGER NOT NULL,
    mem_used_bytes INTEGER NOT NULL,
    mem_total_bytes INTEGER NOT NULL,
    swap_used_bytes INTEGER NOT NULL,
    disk_read_bps INTEGER NOT NULL,
    disk_write_bps INTEGER NOT NULL,
    net_in_bps INTEGER NOT NULL,
    net_out_bps INTEGER NOT NULL,
    loopback_in_bps INTEGER NOT NULL DEFAULT 0,
    loopback_out_bps INTEGER NOT NULL DEFAULT 0,
    active_agent_count INTEGER NOT NULL,
    active_agent_summary TEXT NOT NULL
);
CREATE TABLE process_snapshots (
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
CREATE TABLE socket_ledger (
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
CREATE TABLE anomaly_bookmarks (
    id TEXT PRIMARY KEY,
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    severity INTEGER NOT NULL,
    culprit_name TEXT NOT NULL,
    culprit_exec TEXT NOT NULL,
    metric_badge TEXT NOT NULL,
    summary TEXT NOT NULL
);
""")

conn.execute(
    "INSERT INTO system_ticks VALUES (?, 0, 74.0, 12.0, 2, 16000000000, 25769803776, 1500000000, 40000000, 15000000, 2000000, 14000000, 0, 0, 1, 'OpenCode')",
    (snap_ts,)
)
conn.executemany(
    "INSERT INTO process_snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
        (snap_ts, 999992, 1, "ephemeral-indexer", "/usr/local/bin/ephemeral-indexer", None, None, 225.4, 3800000000, 20000000, 5000000, 512000, 14000000),
        (snap_ts, alive_pid, 1, "readme-shell", "/bin/bash", None, None, 18.2, 420000000, 0, 0, 0, 0),
        (snap_ts, 1, 0, "launchd", "/sbin/launchd", None, "Apple", -1.0, 0, 0, 0, 0, 0),
    ]
)
conn.execute(
    "INSERT INTO socket_ledger VALUES (?, '/usr/local/bin/ephemeral-indexer', 'ephemeral-indexer', '54.231.194.82:443', 's3-accelerate.amazonaws.com', 'tcp4', 1200000, 64000000, ?, ?)",
    ((snap_ts // 3600) * 3600, snap_ts - 20, snap_ts)
)
conn.execute(
    "INSERT INTO anomaly_bookmarks VALUES ('bm-readme-1', ?, 'Outbound spike', 2, 'ephemeral-indexer', '/usr/local/bin/ephemeral-indexer', '13.4 MB/s up', 'ephemeral-indexer uploaded 61 MB to s3-accelerate.amazonaws.com')",
    (snap_ts,)
)
conn.commit()
conn.close()
PY

echo "========================================================================"
echo "Replaying README.md & README.zh-CN.md CLI + MCP Commands"
echo "========================================================================"

echo ""
echo "$ ChronoMac --cli status --lang en"
"$BIN" --cli status --lang en --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli status --lang zh"
"$BIN" --cli status --lang zh --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli status --json"
"$BIN" --cli status --json --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli blame --at 10m --sort cpu --lang en"
BLAME_EN="$("$BIN" --cli blame --at 10m --sort cpu --lang en --db "$SEED_DB")"
echo "$BLAME_EN"
echo "$BLAME_EN" | grep -q "Memory Footprint (phys_footprint)"
echo "$BLAME_EN" | grep -q "from requested time)"
echo "$BLAME_EN" | grep -q "exited after spike"
echo "$BLAME_EN" | grep -q "still running"
echo "$BLAME_EN" | grep -q "No permission"

echo ""
echo "$ ChronoMac --cli blame --at 10m --sort cpu --lang zh"
BLAME_ZH="$("$BIN" --cli blame --at 10m --sort cpu --lang zh --db "$SEED_DB")"
echo "$BLAME_ZH"
echo "$BLAME_ZH" | grep -q "物理内存占用 (phys_footprint)"
echo "$BLAME_ZH" | grep -q "的快照（距所查时刻差 "
echo "$BLAME_ZH" | grep -q "尖峰后已退出"
echo "$BLAME_ZH" | grep -q "仍在运行"
echo "$BLAME_ZH" | grep -q "无权限"

echo ""
echo "$ ChronoMac --cli blame --at 10m --sort memory --json"
"$BIN" --cli blame --at 10m --sort memory --json --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli anomalies --minutes 360 --lang en"
"$BIN" --cli anomalies --minutes 360 --lang en --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli anomalies --minutes 360 --lang zh"
"$BIN" --cli anomalies --minutes 360 --lang zh --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli egress --hours 24 --lang en"
"$BIN" --cli egress --hours 24 --lang en --db "$SEED_DB"

echo ""
echo "$ ChronoMac --cli egress --hours 24 --lang zh"
"$BIN" --cli egress --hours 24 --lang zh --db "$SEED_DB"

echo ""
echo "$ ChronoMac --mcp (stdio JSON-RPC: initialize, tools/list, summary, inspect, egress)"
MCP_OUT="$(
    cat <<'JSONRPC' | "$BIN" --mcp --db "$SEED_DB"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chrono_summary_window","arguments":{"minutes":360}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chrono_inspect_timestamp","arguments":{"minutes_ago":10,"sort_by":"cpu"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"chrono_top_egress_endpoints","arguments":{"hours":24}}}
JSONRPC
)"
echo "$MCP_OUT"
echo "$MCP_OUT" | grep -q "Memory Footprint (phys_footprint)"
echo "$MCP_OUT" | grep -q "exited after spike"
echo "$MCP_OUT" | grep -q "No permission"

echo ""
echo "========================================================================"
echo "ALL README & MCP COMMANDS REPLAYED SUCCESSFULLY"
echo "========================================================================"
