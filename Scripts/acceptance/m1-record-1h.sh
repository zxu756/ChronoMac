#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DURATION=3600
INTERVAL=2
OUTPUT_REPORT=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --output-report)
            OUTPUT_REPORT="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

TMP_1H="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-m1-1h.XXXXXX")"
REC_PID=""
MON_PID=""
cleanup() {
    if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
        kill -TERM "$REC_PID" 2>/dev/null || true
    fi
    if [[ -n "$MON_PID" ]] && kill -0 "$MON_PID" 2>/dev/null; then
        kill -TERM "$MON_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_1H"
}
trap cleanup EXIT

DB_PATH="$TMP_1H/flightbox-1h.sqlite"
AGENT_HOME="$TMP_1H/agent-home"
OVERHEAD_CSV="$TMP_1H/overhead_samples.csv"
RAW_LOG="$TMP_1H/report.raw.txt"
mkdir -p "$AGENT_HOME"

export CHRONOMAC_DB_PATH="$DB_PATH"
export CHRONOMAC_AGENT_HOME="$AGENT_HOME"

# Build release ChronoMac once (unless --skip-build) and copy binary into isolated TMP_1H so concurrent builds never contend
if [[ "$SKIP_BUILD" -ne 1 ]]; then
    swift build -c release --product ChronoMac >/dev/null
fi
REL_BIN="$ROOT/.build/release/ChronoMac"
if [[ ! -x "$REL_BIN" ]]; then
    REL_BIN="$ROOT/.build/arm64-apple-macosx/release/ChronoMac"
fi
if [[ ! -x "$REL_BIN" ]]; then
    echo "FAIL: Could not locate release ChronoMac binary" >&2
    exit 1
fi
WORK_BIN="$TMP_1H/ChronoMac"
cp "$REL_BIN" "$WORK_BIN"
chmod +x "$WORK_BIN"

{
    echo "========================================================================"
    echo "ChronoMac M1 Headless Continuous Recording & Self-Overhead Verification"
    echo "========================================================================"
    echo "Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "macOS:      $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(uname -m)"
    echo "Command:    ChronoMac record --db <TMP_DIR>/flightbox-1h.sqlite --interval $INTERVAL --duration $DURATION --max-db-mb 250 --no-dns"
    echo ""

    START_EPOCH="$(date +%s)"
    "$WORK_BIN" record \
        --db "$DB_PATH" \
        --interval "$INTERVAL" \
        --duration "$DURATION" \
        --max-db-mb 250 \
        --no-dns >"$TMP_1H/recorder.stdout" 2>"$TMP_1H/recorder.stderr" &
    REC_PID=$!

    # Zero-subprocess ctypes proc_pid_rusage monitor sampling recorder CPU%, phys_footprint, and RSS every 2s
    /usr/bin/python3 - "$REC_PID" "$OVERHEAD_CSV" <<'PY' &
import ctypes, os, sys, time

pid = int(sys.argv[1])
out_csv = sys.argv[2]

lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

class MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

tb = MachTimebaseInfo()
lib.mach_timebase_info(ctypes.byref(tb))
tb_scale = (tb.numer / tb.denom) if tb.denom else 1.0

# rusage_info_v4 exact arm64/x86_64 macOS offsets:
# offset 16:  ri_user_time (uint64)
# offset 24:  ri_system_time (uint64)
# offset 64:  ri_resident_size (uint64)
# offset 72:  ri_phys_footprint (uint64)
# offset 96:  ri_child_user_time (uint64)
# offset 104: ri_child_system_time (uint64)
RUSAGE_INFO_V4 = 4
buf = (ctypes.c_uint8 * 512)()

def sample_rusage(target_pid):
    rc = lib.proc_pid_rusage(ctypes.c_int(target_pid), ctypes.c_int(RUSAGE_INFO_V4), ctypes.byref(buf))
    if rc != 0:
        return None
    raw = bytes(buf)
    user_t = int.from_bytes(raw[16:24], sys.byteorder)
    sys_t = int.from_bytes(raw[24:32], sys.byteorder)
    rss_b = int.from_bytes(raw[64:72], sys.byteorder)
    fp_b = int.from_bytes(raw[72:80], sys.byteorder)
    c_user_t = int.from_bytes(raw[96:104], sys.byteorder)
    c_sys_t = int.from_bytes(raw[104:112], sys.byteorder)
    self_ns = (user_t + sys_t) * tb_scale
    tree_ns = (user_t + sys_t + c_user_t + c_sys_t) * tb_scale
    return (self_ns, tree_ns, rss_b, fp_b)

with open(out_csv, "w", encoding="utf-8") as f:
    f.write("mono_ts,self_cpu_ns,tree_cpu_ns,self_cpu_pct,tree_cpu_pct,rss_bytes,footprint_bytes\n")
    prev = None
    while True:
        try:
            os.kill(pid, 0)
        except OSError:
            break
        now_m = time.monotonic()
        cur = sample_rusage(pid)
        if cur is not None:
            self_ns, tree_ns, rss_b, fp_b = cur
            if prev is None:
                f.write(f"{now_m:.3f},{self_ns:.0f},{tree_ns:.0f},0.0000,0.0000,{rss_b},{fp_b}\n")
                f.flush()
            else:
                dt = now_m - prev[0]
                d_self = max(0.0, self_ns - prev[1])
                d_tree = max(0.0, tree_ns - prev[2])
                self_pct = (d_self / 1e9 / dt) * 100.0 if dt > 0.05 else 0.0
                tree_pct = (d_tree / 1e9 / dt) * 100.0 if dt > 0.05 else 0.0
                f.write(f"{now_m:.3f},{self_ns:.0f},{tree_ns:.0f},{self_pct:.4f},{tree_pct:.4f},{rss_b},{fp_b}\n")
                f.flush()
            prev = (now_m, self_ns, tree_ns)
        time.sleep(2.0)
PY
    MON_PID=$!

    set +e
    wait "$REC_PID"
    REC_RC=$?
    wait "$MON_PID" 2>/dev/null
    set -e
    REC_PID=""
    MON_PID=""
    END_EPOCH="$(date +%s)"
    WALL_ELAPSED=$((END_EPOCH - START_EPOCH))

    echo "[Recorder Exit]"
    echo "  exit_code=$REC_RC, wall_elapsed_sec=${WALL_ELAPSED}s"
    cat "$TMP_1H/recorder.stdout" | sed 's/^/  stdout: /'
    if [[ -s "$TMP_1H/recorder.stderr" ]]; then
        cat "$TMP_1H/recorder.stderr" | sed 's/^/  stderr: /'
    fi
    if [[ "$REC_RC" -ne 0 ]]; then
        echo "FAIL: ChronoMac record exited with non-zero code $REC_RC" >&2
        exit 1
    fi

    echo ""
    echo "[Row 1 & Row 2 SQLite Gap & Self-Overhead Analysis]"
    /usr/bin/python3 - "$DB_PATH" "$OVERHEAD_CSV" "$DURATION" "$INTERVAL" <<'PY'
import csv, math, os, sqlite3, sys

db_path, csv_path, duration, interval = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = conn.cursor()
cur.execute("SELECT COUNT(*), COALESCE(MIN(ts), 0), COALESCE(MAX(ts), 0) FROM system_ticks;")
total_rows, min_ts, max_ts = cur.fetchone()
span_sec = max(0, max_ts - min_ts)

cur.execute("""
SELECT COALESCE(MAX(gap), 0), COALESCE(MIN(gap), 0), COALESCE(AVG(gap), 0.0),
       COALESCE(SUM(CASE WHEN gap > 10 THEN 1 ELSE 0 END), 0)
FROM (
    SELECT ts - LAG(ts) OVER (ORDER BY ts ASC) AS gap
    FROM system_ticks
)
WHERE gap IS NOT NULL;
""")
max_gap, min_gap, avg_gap, gaps_gt_10 = cur.fetchone()

cur.execute("SELECT COUNT(*) FROM process_snapshots;")
proc_rows = cur.fetchone()[0]
conn.close()

storage_bytes = 0
for suffix in ("", "-wal", "-shm"):
    p = db_path + suffix
    if os.path.exists(p):
        storage_bytes += os.path.getsize(p)

expected_min_rows = max(2, int(math.floor(duration / interval)) - 5)
expected_min_span = max(0, int(duration) - 6)

self_pcts = []
tree_pcts = []
rss_mb = []
fp_mb = []
first_sample = None
last_sample = None
if os.path.exists(csv_path):
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for idx, row in enumerate(reader):
            t_m = float(row["mono_ts"])
            s_ns = float(row["self_cpu_ns"])
            tr_ns = float(row["tree_cpu_ns"])
            s_pct = float(row["self_cpu_pct"])
            tr_pct = float(row["tree_cpu_pct"])
            rss = int(row["rss_bytes"]) / (1024.0 * 1024.0)
            fp = int(row["footprint_bytes"]) / (1024.0 * 1024.0)
            rss_mb.append(rss)
            fp_mb.append(fp)
            if first_sample is None:
                first_sample = (t_m, s_ns, tr_ns)
            else:
                self_pcts.append(s_pct)
                tree_pcts.append(tr_pct)
            last_sample = (t_m, s_ns, tr_ns)

if first_sample and last_sample and (last_sample[0] - first_sample[0]) > 0.5:
    dt_total = last_sample[0] - first_sample[0]
    cum_self_pct = ((last_sample[1] - first_sample[1]) / 1e9 / dt_total) * 100.0
    cum_tree_pct = ((last_sample[2] - first_sample[2]) / 1e9 / dt_total) * 100.0
else:
    cum_self_pct = sum(self_pcts) / len(self_pcts) if self_pcts else 0.0
    cum_tree_pct = sum(tree_pcts) / len(tree_pcts) if tree_pcts else 0.0

max_self_pct = max(self_pcts) if self_pcts else 0.0
max_tree_pct = max(tree_pcts) if tree_pcts else 0.0
p95_tree_pct = sorted(tree_pcts)[int(0.95 * (len(tree_pcts) - 1))] if tree_pcts else 0.0
mean_rss = sum(rss_mb) / len(rss_mb) if rss_mb else 0.0
max_rss = max(rss_mb) if rss_mb else 0.0
mean_fp = sum(fp_mb) / len(fp_mb) if fp_mb else 0.0
max_fp = max(fp_mb) if fp_mb else 0.0

print(f"  system_ticks_count   = {total_rows} (expected >= {expected_min_rows})")
print(f"  process_snapshots    = {proc_rows}")
print(f"  span_seconds         = {span_sec}s (min_ts={min_ts}, max_ts={max_ts}, expected >= {expected_min_span}s)")
print(f"  inter_tick_gap_sec   = min={min_gap}s, avg={avg_gap:.2f}s, max={max_gap}s, gaps_gt_10s={gaps_gt_10}")
print(f"  db_total_bytes       = {storage_bytes} ({storage_bytes / (1024*1024):.2f} MiB)")
print(f"  overhead_samples     = {len(rss_mb)}")
print(f"  recorder_self_cpu    = avg={cum_self_pct:.2f}%, max={max_self_pct:.2f}% (daemon process alone)")
print(f"  recorder_tree_cpu    = avg={cum_tree_pct:.2f}%, p95={p95_tree_pct:.2f}%, max={max_tree_pct:.2f}% (daemon + nettop/ps/netstat children)")
print(f"  recorder_rss_mib     = mean={mean_rss:.2f} MiB, max={max_rss:.2f} MiB")
print(f"  recorder_phys_fp_mib = mean={mean_fp:.2f} MiB, max={max_fp:.2f} MiB")

if total_rows < expected_min_rows:
    print(f"FAIL [Row 1]: total_rows {total_rows} < expected {expected_min_rows}", file=sys.stderr)
    sys.exit(1)
if span_sec < expected_min_span:
    print(f"FAIL [Row 1]: span_sec {span_sec} < expected {expected_min_span}", file=sys.stderr)
    sys.exit(1)
if gaps_gt_10 > 0 or max_gap > 10:
    print(f"FAIL [Row 1]: found {gaps_gt_10} gaps > 10s (max_gap={max_gap}s)", file=sys.stderr)
    sys.exit(1)
if len(rss_mb) < 2:
    print("FAIL [Row 2]: insufficient self-overhead rusage samples captured", file=sys.stderr)
    sys.exit(1)

print("")
print("[PASS] Row 1: Headless `ChronoMac record` wrote continuous 2s ticks with 0 gaps > 10s.")
print("[PASS] Row 2: Recorder self-overhead empirically measured (CPU% & phys_footprint/RSS MiB).")
print("Summary: passed=2, skipped=0, failed=0")
PY
} | tee "$RAW_LOG"

if [[ -n "$OUTPUT_REPORT" ]]; then
    mkdir -p "$(dirname "$OUTPUT_REPORT")"
    /usr/bin/python3 - "$RAW_LOG" "$OUTPUT_REPORT" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
u_prefix = "/" + "Users/"
text = re.sub(u_prefix + r"[^/\s\"'\\]+", "$HOME", text)
text = re.sub(r"/private/var/folders/[^\s\"'（()）\[\],;]+", "<TMP_DIR>", text)
text = re.sub(r"/var/folders/[^\s\"'（()）\[\],;]+", "<TMP_DIR>", text)
text = re.sub(r"/tmp/chronomac-m1-1h\.[^\s\"'（()）\[\],;]+", "<TMP_DIR>", text)
open(dst, "w", encoding="utf-8").write(text)
PY
fi
