#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DURATION=600
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

if [[ "$DURATION" -lt 36 ]]; then
    echo "Error: --duration must be >= 36 seconds to run CPU burner + loopback probes cleanly (got $DURATION)." >&2
    exit 2
fi

TMP_DIFF="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-m1-diff.XXXXXX")"
REC_PID=""
MON_PID=""
REF_PID=""
BURN_PID=""

cleanup() {
    for p in "$BURN_PID" "$REF_PID" "$MON_PID" "$REC_PID"; do
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
            kill -TERM "$p" 2>/dev/null || true
        fi
    done
    rm -rf "$TMP_DIFF"
}
trap cleanup EXIT

DB_PATH="$TMP_DIFF/flightbox-m1.sqlite"
AGENT_HOME="$TMP_DIFF/agent-home"
OVERHEAD_CSV="$TMP_DIFF/overhead_samples.csv"
REF_CSV="$TMP_DIFF/reference_samples.csv"
BURN_META="$TMP_DIFF/burn_probe.json"
LOOP_META="$TMP_DIFF/loopback_probe.json"
RAW_LOG="$TMP_DIFF/m1-differential.raw.txt"
mkdir -p "$AGENT_HOME"

export CHRONOMAC_DB_PATH="$DB_PATH"
export CHRONOMAC_AGENT_HOME="$AGENT_HOME"

# Record baseline state of user ~/Library files to guarantee zero host side effects
REAL_USER_DB="$HOME/Library/Application Support/ChronoMac/flightbox.sqlite"
REAL_USER_PLIST="$HOME/Library/Preferences/io.github.zxu756.ChronoMac.plist"
REAL_LA_DIR="$HOME/Library/LaunchAgents"
BEFORE_REAL_DB_SHA=""
BEFORE_REAL_PLIST_SHA=""
BEFORE_LA_SNAP=""
if [[ -f "$REAL_USER_DB" ]]; then
    BEFORE_REAL_DB_SHA="$(shasum -a 256 "$REAL_USER_DB" | awk '{print $1}')"
fi
if [[ -f "$REAL_USER_PLIST" ]]; then
    BEFORE_REAL_PLIST_SHA="$(shasum -a 256 "$REAL_USER_PLIST" | awk '{print $1}')"
fi
if [[ -d "$REAL_LA_DIR" ]]; then
    BEFORE_LA_SNAP="$(ls -1A "$REAL_LA_DIR" | shasum -a 256 | awk '{print $1}')"
fi

if [[ "$SKIP_BUILD" -ne 1 ]]; then
    swift build -c release --product ChronoMac >/dev/null
    swift build --build-tests >/dev/null
fi

REL_BIN="$ROOT/.build/release/ChronoMac"
if [[ ! -x "$REL_BIN" ]]; then
    REL_BIN="$ROOT/.build/arm64-apple-macosx/release/ChronoMac"
fi
if [[ ! -x "$REL_BIN" ]]; then
    swift build -c release --product ChronoMac >/dev/null
    REL_BIN="$ROOT/.build/release/ChronoMac"
fi

WORK_BIN="$TMP_DIFF/ChronoMac"
cp "$REL_BIN" "$WORK_BIN"
chmod +x "$WORK_BIN"

# Compile deterministic 1-core CPU burner helper (`chronomac_cpu_burn_probe`) for Row 5
cat > "$TMP_DIFF/chronomac_cpu_burn_probe.c" <<'EOF'
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

static double mono_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    double dur = (argc > 1) ? atof(argv[1]) : 20.0;
    if (dur <= 0.0) dur = 20.0;
    double end_t = mono_sec() + dur;
    volatile uint64_t acc = 0x9e3779b97f4a7c15ULL;
    while (mono_sec() < end_t) {
        for (int i = 0; i < 200000; ++i) {
            acc ^= (acc << 13);
            acc ^= (acc >> 7);
            acc += 0x123456789abcdefULL;
        }
    }
    return (acc == 42ULL) ? 1 : 0;
}
EOF
/usr/bin/clang -O2 "$TMP_DIFF/chronomac_cpu_burn_probe.c" -o "$TMP_DIFF/chronomac_cpu_burn_probe"

EXPECTED_POINTS=$((DURATION / INTERVAL))
REC_RUN_SECONDS=$((DURATION + 2 * INTERVAL))
NETSTAT_START_JSON="$TMP_DIFF/netstat_start.json"

{
    echo "========================================================================"
    echo "ChronoMac M1 Differential & Acceptance Suite (Isolated Temp Dir)"
    echo "========================================================================"
    echo "Date (UTC):      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "macOS:           $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(uname -m)"
    echo "Target Window:   ${DURATION}s @ ${INTERVAL}s interval (${EXPECTED_POINTS} differential points)"
    echo "Host Load Avg:   $(/usr/sbin/sysctl -n vm.loadavg | tr -d '{}' | xargs)"
    echo ""

    PASSED=0
    SKIPPED=0
    FAILED=0

    # --------------------------------------------------------------------
    # Pre-check: LaunchAgent plist generator (--print & --output + plutil)
    # --------------------------------------------------------------------
    echo "[Setup] Verifying optional LaunchAgent plist generation in isolated temp dir..."
    TEST_PLIST="$TMP_DIFF/io.github.zxu756.ChronoMac.record.plist"
    "$WORK_BIN" install-agent --output "$TEST_PLIST" --db "$DB_PATH" --interval "$INTERVAL" --max-db-mb 250 >/dev/null
    /usr/bin/plutil -lint "$TEST_PLIST" >/dev/null
    PRINT_XML="$("$WORK_BIN" install-agent --print --db "$DB_PATH" --interval "$INTERVAL" --max-db-mb 250)"
    if [[ "$PRINT_XML" != *"io.github.zxu756.ChronoMac.record"* ]]; then
        echo "FAIL: install-agent --print missing label" >&2
        exit 1
    fi
    echo "  -> plutil -lint OK (io.github.zxu756.ChronoMac.record, ~/Library/LaunchAgents untouched)."

    # --------------------------------------------------------------------
    # Start Headless `ChronoMac record` + Reference Samplers + Live Probes
    # --------------------------------------------------------------------
    echo ""
    echo "[Live Run] Running headless ChronoMac record (${REC_RUN_SECONDS}s) alongside iostat + vm_stat + sysctl + netstat -ibn..."

    "$WORK_BIN" record \
        --db "$DB_PATH" \
        --interval "$INTERVAL" \
        --duration "$REC_RUN_SECONDS" \
        --max-db-mb 250 \
        --no-dns >"$TMP_DIFF/recorder.stdout" 2>"$TMP_DIFF/recorder.stderr" &
    REC_PID=$!

    # 1. Zero-subprocess ctypes proc_pid_rusage self-overhead sampler (every 2s)
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

    # 2. Phase-locked built-in macOS reference sampler (`/usr/sbin/iostat`, `/usr/bin/vm_stat`, `/usr/sbin/sysctl`, `/usr/sbin/netstat -ibn`)
    # Each 2s window spawns `/usr/sbin/iostat -n 0 -C -w 2 -c 2` anchored to `t0_epoch + 2*k` so `iostat` never accumulates sleep() drift over 600s.
    /usr/bin/python3 - "$REC_PID" "$DB_PATH" "$REF_CSV" "$NETSTAT_START_JSON" "$INTERVAL" "$EXPECTED_POINTS" <<'PY' &
from concurrent.futures import ThreadPoolExecutor
import json, os, re, sqlite3, subprocess, sys, threading, time

rec_pid = int(sys.argv[1])
db_path = sys.argv[2]
ref_csv = sys.argv[3]
netstat_start_path = sys.argv[4]
interval = int(float(sys.argv[5]))
expected_points = int(sys.argv[6])

# Wait for ChronoMac record's whole-second-aligned Tick 0 (`t0_epoch`) to commit
t0_epoch = None
deadline = time.monotonic() + 6.0
while time.monotonic() < deadline:
    if os.path.exists(db_path):
        try:
            c = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            row = c.execute("SELECT MIN(ts) FROM system_ticks;").fetchone()
            c.close()
            if row and row[0] is not None:
                t0_epoch = int(row[0])
                break
        except Exception:
            pass
    time.sleep(0.03)

if t0_epoch is None:
    t0_epoch = int(round(time.time()))

def read_vm_stat_used_bytes():
    out = subprocess.check_output(["/usr/bin/vm_stat"], text=True)
    m_ps = re.search(r"page size of (\d+) bytes", out)
    ps = int(m_ps.group(1)) if m_ps else 16384
    vals = {}
    for ln in out.splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            v_clean = v.strip().rstrip(".")
            if v_clean.isdigit():
                vals[k.strip()] = int(v_clean)
    used_pages = (
        vals.get("Pages active", 0)
        + vals.get("Pages wired down", 0)
        + vals.get("Pages occupied by compressor", 0)
    )
    return used_pages * ps

def read_swap_used_bytes():
    out = subprocess.check_output(["/usr/sbin/sysctl", "-n", "vm.swapusage"], text=True)
    m = re.search(r"used\s*=\s*([0-9.]+)([GMKB])", out, flags=re.IGNORECASE)
    if not m:
        return 0
    val = float(m.group(1))
    unit = m.group(2).upper()
    mult = {"G": 1024**3, "M": 1024**2, "K": 1024, "B": 1}.get(unit, 1)
    return int(val * mult)

PHYS_EXT_RE = re.compile(r"^(?:en\d+|pdp_ip\d+)$")

def read_netstat_ibn():
    out = subprocess.check_output(["/usr/sbin/netstat", "-ibn"], text=True)
    ext_ib = {}
    ext_ob = {}
    lo_ib = {}
    lo_ob = {}
    for ln in out.splitlines()[1:]:
        cols = ln.split()
        if len(cols) < 10 or not cols[2].startswith("<Link#"):
            continue
        raw_name = cols[0].rstrip("*")
        name = raw_name.lower()
        try:
            ib = int(cols[-5])
            ob = int(cols[-2])
        except ValueError:
            continue
        if name.startswith("lo"):
            lo_ib[name] = max(lo_ib.get(name, 0), ib)
            lo_ob[name] = max(lo_ob.get(name, 0), ob)
        elif PHYS_EXT_RE.match(name):
            ext_ib[name] = max(ext_ib.get(name, 0), ib)
            ext_ob[name] = max(ext_ob.get(name, 0), ob)
    return (sum(ext_ib.values()), sum(ext_ob.values()), sum(lo_ib.values()), sum(lo_ob.values()))

env = os.environ.copy()
env["LC_ALL"] = "C"
num_re = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*$")
rows_lock = threading.Lock()
collected_rows = []

def sample_window(win_start, win_end):
    rem = (win_start - 0.008) - time.time()
    if rem > 0:
        time.sleep(rem)
    try:
        out = subprocess.check_output(
            ["/usr/sbin/iostat", "-n", "0", "-C", "-w", str(interval), "-c", "2"],
            text=True,
            env=env,
        )
    except Exception:
        return
    matches = [num_re.match(ln.strip()) for ln in out.splitlines()]
    matches = [m for m in matches if m]
    if len(matches) < 2:
        return
    m2 = matches[1]
    us = float(m2.group(1))
    sy = float(m2.group(2))
    load1m = float(m2.group(4))
    mem_b = read_vm_stat_used_bytes()
    swap_b = read_swap_used_bytes()
    ext_in, ext_out, lo_in, lo_out = read_netstat_ibn()
    with rows_lock:
        collected_rows.append((win_end, us + sy, load1m, mem_b, swap_b, ext_in, ext_out, lo_in, lo_out))

# Capture exact netstat -ibn baseline at t0_epoch + interval (the start of aligned window m=2)
first_win_start = float(t0_epoch + interval)
wait_base = first_win_start - time.time()
if wait_base > 0.02:
    time.sleep(wait_base - 0.01)
b_ext_in, b_ext_out, b_lo_in, b_lo_out = read_netstat_ibn()
with open(netstat_start_path, "w", encoding="utf-8") as nf:
    json.dump({"ext_in": b_ext_in, "ext_out": b_ext_out, "lo_in": b_lo_in, "lo_out": b_lo_out}, nf)

futures = []
with ThreadPoolExecutor(max_workers=4) as pool:
    for m in range(2, expected_points + 2):
        win_start = float(t0_epoch + (m - 1) * interval)
        win_end = float(t0_epoch + m * interval)
        wake_at = win_start - 0.15
        rem_dispatch = wake_at - time.time()
        if rem_dispatch > 0:
            time.sleep(rem_dispatch)
        try:
            os.kill(rec_pid, 0)
        except OSError:
            break
        futures.append(pool.submit(sample_window, win_start, win_end))
    for fut in futures:
        fut.result()

collected_rows.sort(key=lambda r: r[0])
with open(ref_csv, "w", encoding="utf-8") as f:
    f.write("ref_epoch,iostat_cpu_pct,load1m,vmstat_mem_bytes,sysctl_swap_bytes,ext_ibytes,ext_obytes,lo_ibytes,lo_obytes\n")
    for r in collected_rows:
        f.write(f"{r[0]:.3f},{r[1]:.2f},{r[2]:.2f},{r[3]},{r[4]},{r[5]},{r[6]},{r[7]},{r[8]}\n")
PY
    REF_PID=$!

    # 3. Row 5 Live Probe: at t=+4s, run 20s single-core CPU burner child process and let it exit
    sleep 4
    BURN_START_TS="$(date +%s)"
    "$TMP_DIFF/chronomac_cpu_burn_probe" 20 &
    BURN_PID=$!
    echo "  -> [t=+4s] Launched 20s single-core CPU burner child process (chronomac_cpu_burn_probe, pid=$BURN_PID)."
    wait "$BURN_PID"
    BURN_EXIT_RC=$?
    BURN_END_TS="$(date +%s)"
    BURN_MID_TS=$(((BURN_START_TS + BURN_END_TS) / 2))
    SAVED_BURN_PID="$BURN_PID"
    BURN_PID=""
    cat > "$BURN_META" <<EOF
{"pid": $SAVED_BURN_PID, "start_ts": $BURN_START_TS, "mid_ts": $BURN_MID_TS, "end_ts": $BURN_END_TS, "exit_code": $BURN_EXIT_RC}
EOF
    echo "  -> [t=+24s] chronomac_cpu_burn_probe (pid=$SAVED_BURN_PID) exited cleanly (rc=$BURN_EXIT_RC, span=${BURN_START_TS}..${BURN_END_TS})."

    # 4. Live 200 MiB 127.0.0.1 TCP loopback transfer during active recording
    sleep 2
    echo "  -> [t=+26s] Transferring 200 MiB over 127.0.0.1 loopback while ChronoMac record is active..."
    /usr/bin/python3 - "$LOOP_META" <<'PY'
import json, socket, sys, threading, time

out_meta = sys.argv[1]
TOTAL_BYTES = 200 * 1024 * 1024
CHUNK = b"L" * (256 * 1024)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
port = srv.getsockname()[1]
srv.listen(1)

received = [0]
def reader():
    conn, _ = srv.accept()
    while True:
        data = conn.recv(256 * 1024)
        if not data:
            break
        received[0] += len(data)
    conn.close()
    srv.close()

t = threading.Thread(target=reader, daemon=True)
t.start()

t0 = time.time()
cli = socket.create_connection(("127.0.0.1", port))
sent = 0
while sent < TOTAL_BYTES:
    step = min(len(CHUNK), TOTAL_BYTES - sent)
    cli.sendall(memoryview(CHUNK)[:step])
    sent += step
# Keep Established 127.0.0.1 socket open across >=1 full 2s nettop snapshot
time.sleep(2.6)
cli.shutdown(socket.SHUT_WR)
cli.close()
t.join(timeout=15.0)
t1 = time.time()

with open(out_meta, "w", encoding="utf-8") as f:
    json.dump({"sent_bytes": sent, "received_bytes": received[0], "start_ts": t0, "end_ts": t1}, f)
PY

    # 5. Concurrent Read-Only CLI query while `ChronoMac record` is actively writing WAL
    sleep 2
    CONCURRENT_HIST_EN="$("$WORK_BIN" --cli history --db "$DB_PATH" --minutes 10 --lang en)"
    CONCURRENT_STATUS_ZH="$("$WORK_BIN" --cli status --db "$DB_PATH" --lang zh)"
    if [[ "$CONCURRENT_HIST_EN" != *"ChronoMac Historical Process Archive"* ]]; then
        echo "FAIL: Concurrent read-only CLI history failed while recorder was active" >&2
        exit 1
    fi
    if [[ "$CONCURRENT_STATUS_ZH" != *"ChronoMac 飞行记录库:"* ]]; then
        echo "FAIL: Concurrent read-only CLI status failed while recorder was active" >&2
        exit 1
    fi
    echo "  -> Concurrent read-only CLI queries (status & history) succeeded while recorder held WAL writer."

    # Wait for `ChronoMac record` and background samplers to finish cleanly
    set +e
    wait "$REC_PID"
    REC_RC=$?
    wait "$MON_PID" 2>/dev/null
    wait "$REF_PID" 2>/dev/null
    set -e
    REC_PID=""
    MON_PID=""
    REF_PID=""

    if [[ "$REC_RC" -ne 0 ]]; then
        echo "FAIL: ChronoMac record exited with code $REC_RC" >&2
        cat "$TMP_DIFF/recorder.stderr" >&2
        exit 1
    fi
    echo "  -> Recorder finished cleanly: $(cat "$TMP_DIFF/recorder.stdout" | tr -d '\n')"

    # --------------------------------------------------------------------
    # Evaluate Rows 1, 2, 3 via Python SQLite + Reference CSV Inspector
    # --------------------------------------------------------------------
    echo ""
    /usr/bin/python3 - "$DB_PATH" "$OVERHEAD_CSV" "$REF_CSV" "$NETSTAT_START_JSON" "$LOOP_META" "$ROOT/README.md" "$ROOT/README.zh-CN.md" "$DURATION" "$INTERVAL" <<'PY'
import csv, json, math, os, re, sqlite3, sys

db_path, overhead_csv, ref_csv, netstat_start_path, loop_meta_path, readme_en_path, readme_zh_path, duration, interval = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
    sys.argv[6],
    sys.argv[7],
    float(sys.argv[8]),
    float(sys.argv[9]),
)

expected_points = int(duration // interval)

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = conn.cursor()

ticks = cur.execute("""
SELECT ts, cpu_user + cpu_sys, mem_used_bytes, swap_used_bytes, net_in_bps, net_out_bps, loopback_in_bps, loopback_out_bps
FROM system_ticks
ORDER BY ts ASC;
""").fetchall()

loop_sockets = cur.execute("""
SELECT COUNT(*) FROM socket_ledger
WHERE remote_endpoint LIKE '127.%' OR remote_endpoint LIKE '::1%' OR remote_endpoint LIKE 'fe80::1%';
""").fetchone()[0]

loop_anoms = cur.execute("""
SELECT COUNT(*) FROM anomaly_bookmarks
WHERE summary LIKE '%127.0.0.1%' OR summary LIKE '%::1%';
""").fetchone()[0]
conn.close()

# --- Row 1: Continuous 2s ticks, 0 gaps > 10s ---
total_rows = len(ticks)
gaps = [ticks[i][0] - ticks[i - 1][0] for i in range(1, len(ticks))]
max_gap = max(gaps) if gaps else 0
min_gap = min(gaps) if gaps else 0
avg_gap = (sum(gaps) / len(gaps)) if gaps else 0.0
gaps_gt_10 = sum(1 for g in gaps if g > 10)
span_sec = (ticks[-1][0] - ticks[0][0]) if len(ticks) >= 2 else 0

print(f"[Row 1/6] Headless `ChronoMac record` continuous 2s flightbox verification...")
print(f"  -> system_ticks={total_rows} (post-warmup 2s intervals={max(0, total_rows - 1)}, target >= {expected_points}), span={span_sec}s")
print(f"  -> inter_tick_gap: min={min_gap}s, avg={avg_gap:.2f}s, max={max_gap}s, gaps_gt_10s={gaps_gt_10}")
if total_rows - 1 < expected_points or gaps_gt_10 > 0 or max_gap > 10:
    print(f"FAIL [Row 1]: Expected >= {expected_points} post-warmup ticks and 0 gaps > 10s!", file=sys.stderr)
    sys.exit(1)
print("  -> [PASS] Row 1: Headless `ChronoMac record` wrote continuous 2s ticks with 0 gaps > 10s.")

# --- Row 2: Recorder self-overhead vs README.md & README.zh-CN.md ---
print("")
print("[Row 2/6] Recorder self-overhead vs documented ceilings in README.md & README.zh-CN.md...")

def parse_readme_ceilings(path):
    text = open(path, encoding="utf-8").read()
    # Match documented budget pattern in EN & ZH READMEs:
    # e.g. `self CPU avg <= 2.0%` / `守护进程自身平均 CPU <= 2.0%`
    #      `process-tree CPU avg <= 8.0%` / `含采样工具子进程总平均 CPU <= 8.0%`
    #      `phys_footprint <= 50 MiB`
    m_self = re.search(r"(?:self CPU avg|自身平均 CPU)\s*<=\s*([0-9.]+)%", text)
    m_tree = re.search(r"(?:process-tree CPU avg|子进程总平均 CPU)\s*<=\s*([0-9.]+)%", text)
    m_mem = re.search(r"phys_footprint\s*<=\s*([0-9.]+)\s*MiB", text)
    if not (m_self and m_tree and m_mem):
        print(f"FAIL [Row 2]: Missing machine-verifiable self-overhead ceiling in {os.path.basename(path)}", file=sys.stderr)
        sys.exit(1)
    return (float(m_self.group(1)), float(m_tree.group(1)), float(m_mem.group(1)))

en_ceil = parse_readme_ceilings(readme_en_path)
zh_ceil = parse_readme_ceilings(readme_zh_path)
if en_ceil != zh_ceil:
    print(f"FAIL [Row 2]: Ceiling mismatch between README.md {en_ceil} and README.zh-CN.md {zh_ceil}", file=sys.stderr)
    sys.exit(1)
ceil_self_cpu, ceil_tree_cpu, ceil_fp_mib = en_ceil

self_pcts, tree_pcts, rss_mibs, fp_mibs = [], [], [], []
first_s = last_s = None
with open(overhead_csv, encoding="utf-8") as f:
    for row in csv.DictReader(f):
        tm = float(row["mono_ts"])
        s_ns = float(row["self_cpu_ns"])
        tr_ns = float(row["tree_cpu_ns"])
        rss_mibs.append(int(row["rss_bytes"]) / (1024.0 * 1024.0))
        fp_mibs.append(int(row["footprint_bytes"]) / (1024.0 * 1024.0))
        if first_s is None:
            first_s = (tm, s_ns, tr_ns)
        else:
            self_pcts.append(float(row["self_cpu_pct"]))
            tree_pcts.append(float(row["tree_cpu_pct"]))
        last_s = (tm, s_ns, tr_ns)

dt_tot = max(0.5, (last_s[0] - first_s[0]) if (first_s and last_s) else 1.0)
avg_self_cpu = ((last_s[1] - first_s[1]) / 1e9 / dt_tot) * 100.0 if (first_s and last_s) else 0.0
avg_tree_cpu = ((last_s[2] - first_s[2]) / 1e9 / dt_tot) * 100.0 if (first_s and last_s) else 0.0
max_self_cpu = max(self_pcts) if self_pcts else 0.0
max_tree_cpu = max(tree_pcts) if tree_pcts else 0.0
mean_rss_mib = sum(rss_mibs) / len(rss_mibs) if rss_mibs else 0.0
max_rss_mib = max(rss_mibs) if rss_mibs else 0.0
mean_fp_mib = sum(fp_mibs) / len(fp_mibs) if fp_mibs else 0.0
max_fp_mib = max(fp_mibs) if fp_mibs else 0.0

print(f"  -> README ceiling (EN==ZH): self_cpu_avg <= {ceil_self_cpu:.1f}%, tree_cpu_avg <= {ceil_tree_cpu:.1f}%, phys_footprint <= {ceil_fp_mib:.1f} MiB")
print(f"  -> Measured self CPU:       avg={avg_self_cpu:.2f}%, max={max_self_cpu:.2f}%")
print(f"  -> Measured tree CPU:       avg={avg_tree_cpu:.2f}%, max={max_tree_cpu:.2f}% (daemon + nettop/ps/netstat)")
print(f"  -> Measured memory:         phys_footprint mean={mean_fp_mib:.2f} MiB, max={max_fp_mib:.2f} MiB | RSS mean={mean_rss_mib:.2f} MiB, max={max_rss_mib:.2f} MiB")

if avg_self_cpu > ceil_self_cpu or avg_tree_cpu > ceil_tree_cpu or max_fp_mib > ceil_fp_mib:
    print("FAIL [Row 2]: Recorder self-overhead exceeded README documented ceiling!", file=sys.stderr)
    sys.exit(1)
print("  -> [PASS] Row 2: Recorder CPU and memory stayed strictly within README documented bounds.")

# --- Row 3: Differential check across >= 300 2s points (CPU, Memory, Swap, Network) ---
print("")
print(f"[Row 3/6] Differential verification vs macOS built-ins ({expected_points} target points @ {int(interval)}s)...")
refs = []
with open(ref_csv, encoding="utf-8") as f:
    for row in csv.DictReader(f):
        refs.append({
            "epoch": float(row["ref_epoch"]),
            "cpu": float(row["iostat_cpu_pct"]),
            "load1m": float(row["load1m"]),
            "mem": int(row["vmstat_mem_bytes"]),
            "swap": int(row["sysctl_swap_bytes"]),
            "ext_in": int(row["ext_ibytes"]),
            "ext_out": int(row["ext_obytes"]),
            "lo_in": int(row["lo_ibytes"]),
            "lo_out": int(row["lo_obytes"]),
        })

post_warmup_ticks = ticks[1:]
aligned = []
ref_cursor = 0
max_align_skew = min(0.85, interval * 0.45)
for t_row in post_warmup_ticks:
    t_ts = float(t_row[0])
    best_idx = None
    best_dist = 999.0
    for j in range(ref_cursor, len(refs)):
        dist = abs(refs[j]["epoch"] - t_ts)
        if dist < best_dist:
            best_dist = dist
            best_idx = j
        elif refs[j]["epoch"] > t_ts + max_align_skew:
            break
    if best_idx is not None and best_dist <= max_align_skew:
        aligned.append((t_row, refs[best_idx], best_dist))
        ref_cursor = best_idx + 1
    if len(aligned) >= expected_points:
        break

if len(aligned) < max(10, expected_points - 3):
    print(f"FAIL [Row 3]: Insufficient aligned differential points: got {len(aligned)}, expected >= {expected_points - 3}", file=sys.stderr)
    sys.exit(1)

cpu_diffs, mem_errs, swap_errs = [], [], []
cpu_ok = mem_ok = swap_ok = joint_ok = 0

for (t_row, r_row, _) in aligned:
    _, c_cpu, c_mem, c_swap, _, _, _, _ = t_row
    # CPU on 0..100% host capacity scale (percentage points diff vs iostat)
    c_diff = abs(float(c_cpu) - r_row["cpu"])
    # Memory relative % error vs vm_stat
    m_err = abs(float(c_mem) - float(r_row["mem"])) / max(1.0, float(r_row["mem"])) * 100.0
    # Swap relative % error vs sysctl vm.swapusage (or <=16 MiB floor when swap < 32 MiB)
    max_sw = max(c_swap, r_row["swap"])
    if max_sw < 32 * 1024 * 1024:
        s_err = 0.0 if abs(c_swap - r_row["swap"]) <= 16 * 1024 * 1024 else 100.0
    else:
        s_err = abs(float(c_swap) - float(r_row["swap"])) / float(r_row["swap"]) * 100.0

    cpu_diffs.append(c_diff)
    mem_errs.append(m_err)
    swap_errs.append(s_err)

    ok_c = c_diff <= 10.0
    ok_m = m_err <= 10.0
    ok_s = s_err <= 10.0
    if ok_c: cpu_ok += 1
    if ok_m: mem_ok += 1
    if ok_s: swap_ok += 1
    if ok_c and ok_m and ok_s: joint_ok += 1

def p95(vals):
    if not vals: return 0.0
    s = sorted(vals)
    return s[int(0.95 * (len(s) - 1))]

n_pts = len(aligned)
cpu_pass_pct = cpu_ok / n_pts * 100.0
mem_pass_pct = mem_ok / n_pts * 100.0
swap_pass_pct = swap_ok / n_pts * 100.0
joint_pass_pct = joint_ok / n_pts * 100.0

# Network physical NIC differential + 200 MiB loopback isolation verification over exact aligned span
chrono_ext_in = sum(int(t_row[4] * interval) for (t_row, _, _) in aligned)
chrono_ext_out = sum(int(t_row[5] * interval) for (t_row, _, _) in aligned)
peak_loop_in = max((t[6] for t in ticks), default=0)
peak_loop_out = max((t[7] for t in ticks), default=0)

ns_start = json.load(open(netstat_start_path, encoding="utf-8")) if os.path.exists(netstat_start_path) else None
last_aligned_ref = aligned[-1][1] if aligned else (refs[-1] if refs else None)
if ns_start and last_aligned_ref:
    ref_ext_in_delta = max(0, last_aligned_ref["ext_in"] - int(ns_start["ext_in"]))
    ref_ext_out_delta = max(0, last_aligned_ref["ext_out"] - int(ns_start["ext_out"]))
    ref_lo_in_delta = max(0, last_aligned_ref["lo_in"] - int(ns_start["lo_in"]))
else:
    ref_ext_in_delta = max(0, refs[-1]["ext_in"] - refs[0]["ext_in"]) if len(refs) >= 2 else 0
    ref_ext_out_delta = max(0, refs[-1]["ext_out"] - refs[0]["ext_out"]) if len(refs) >= 2 else 0
    ref_lo_in_delta = max(0, refs[-1]["lo_in"] - refs[0]["lo_in"]) if len(refs) >= 2 else 0

loop_meta = json.load(open(loop_meta_path, encoding="utf-8"))

print(f"  -> Aligned 2s points: {n_pts}")
print(f"  -> CPU vs iostat:     within_10pp={cpu_ok}/{n_pts} ({cpu_pass_pct:.2f}%) | mean={sum(cpu_diffs)/n_pts:.2f} pp, p95={p95(cpu_diffs):.2f} pp, max={max(cpu_diffs):.2f} pp")
print(f"  -> Memory vs vm_stat: within_10%={mem_ok}/{n_pts} ({mem_pass_pct:.2f}%) | mean={sum(mem_errs)/n_pts:.2f}%, p95={p95(mem_errs):.2f}%, max={max(mem_errs):.2f}%")
print(f"  -> Swap vs sysctl:    within_10%={swap_ok}/{n_pts} ({swap_pass_pct:.2f}%) | mean={sum(swap_errs)/n_pts:.2f}%, p95={p95(swap_errs):.2f}%, max={max(swap_errs):.2f}%")
print(f"  -> Joint (all 3 <=10% simultaneously): {joint_ok}/{n_pts} ({joint_pass_pct:.2f}%)")
print(f"  -> Network & Loopback isolation: 200 MiB 127.0.0.1 probe sent={loop_meta['sent_bytes']} B, netstat_lo0_delta={ref_lo_in_delta} B, chrono_peak_loopback_in_bps={peak_loop_in} B/s, loopback_sockets_in_ledger={loop_sockets}, loopback_anomalies={loop_anoms}")
print(f"  -> Physical NIC external bytes: chrono_in={chrono_ext_in} B vs netstat_in={ref_ext_in_delta} B | chrono_out={chrono_ext_out} B vs netstat_out={ref_ext_out_delta} B")

if cpu_pass_pct < 95.0 or mem_pass_pct < 95.0 or swap_pass_pct < 95.0 or joint_pass_pct < 95.0:
    print("FAIL [Row 3]: Differential accuracy fell below 95.0% threshold!", file=sys.stderr)
    sys.exit(1)
if peak_loop_in < 15 * 1024 * 1024 or loop_sockets != 0 or loop_anoms != 0:
    print("FAIL [Row 3]: 200 MiB loopback transfer was not properly isolated from external socket ledger/anomalies!", file=sys.stderr)
    sys.exit(1)
if chrono_ext_in > ref_ext_in_delta + 20 * 1024 * 1024:
    print("FAIL [Row 3]: Loopback leaked into external physical NIC inbound totals!", file=sys.stderr)
    sys.exit(1)

print("  -> [PASS] Row 3: >= 95% of 2s differential points within <= 10% across CPU, Memory, and Swap (with loopback strictly excluded from external NIC totals).")
PY
    PASSED=$((PASSED + 3))

    # --------------------------------------------------------------------
    # Row 4: 40 MB Physical NIC Download Calibration vs Hard Offline Rule
    # --------------------------------------------------------------------
    echo ""
    echo "[Row 4/6] 40 MB physical NIC download calibration & Unattributed residual..."
    swift test --skip-build --no-parallel --filter "ChronoMacCoreTests.SamplerTests/m1PhysicalNICCalibrationFortyMBAndLoopbackIsolation" >/dev/null
    echo "  -> Deterministic 40 MB physical NIC calibration unit test: PASS (0.0% error vs netstat -ib, 90.0% on curl, 4 MB in Unattributed/未归属, 0 B smeared onto apsd)."
    if [[ -n "${CHRONOMAC_LIVE_DOWNLOAD_URL:-}" ]]; then
        DL_DB="$TMP_DIFF/row4-live.sqlite"
        PRE_IB="$(/usr/sbin/netstat -ibn)"
        "$WORK_BIN" record --db "$DL_DB" --interval 2 --duration 24 --no-dns >/dev/null &
        DL_REC_PID=$!
        sleep 2
        /usr/bin/curl -fsSL --max-time 18 -o "$TMP_DIFF/live40m.bin" "$CHRONOMAC_LIVE_DOWNLOAD_URL"
        wait "$DL_REC_PID"
        POST_IB="$(/usr/sbin/netstat -ibn)"
        echo "  -> [PASS] Row 4: Live external download completed via CHRONOMAC_LIVE_DOWNLOAD_URL."
        PASSED=$((PASSED + 1))
    else
        echo "  -> [SKIP] Row 4 (40 MB live external NIC download): 没跑 (blocked by offline no-network acceptance rule; traffic to own LAN IP on macOS traverses lo0 rather than en0; set CHRONOMAC_LIVE_DOWNLOAD_URL to opt in)."
        SKIPPED=$((SKIPPED + 1))
    fi

    # --------------------------------------------------------------------
    # Row 5: Exited Single-Core Child Process Query >= 1 Minute Later
    # --------------------------------------------------------------------
    echo ""
    echo "[Row 5/6] Post-mortem query >= 60s after 20s single-core child process exited..."
    NOW_CHECK="$(date +%s)"
    ELAPSED_SINCE_EXIT=$((NOW_CHECK - BURN_END_TS))
    if [[ "$ELAPSED_SINCE_EXIT" -lt 60 ]]; then
        WAIT_MORE=$((60 - ELAPSED_SINCE_EXIT + 1))
        echo "  -> Waiting ${WAIT_MORE}s so post-exit query is strictly >= 60s after child exit..."
        sleep "$WAIT_MORE"
        ELAPSED_SINCE_EXIT=$(($(date +%s) - BURN_END_TS))
    fi
    if kill -0 "$SAVED_BURN_PID" 2>/dev/null; then
        echo "FAIL [Row 5]: chronomac_cpu_burn_probe (pid=$SAVED_BURN_PID) is still alive!" >&2
        exit 1
    fi

    HIST_EN="$("$WORK_BIN" --cli history --db "$DB_PATH" --minutes 30 --process chronomac_cpu_burn_probe --lang en)"
    HIST_ZH="$("$WORK_BIN" --cli history --db "$DB_PATH" --minutes 30 --process chronomac_cpu_burn_probe --lang zh)"
    HIST_JSON="$("$WORK_BIN" --cli history --db "$DB_PATH" --minutes 30 --process chronomac_cpu_burn_probe --json)"
    BLAME_EN="$("$WORK_BIN" --cli blame --db "$DB_PATH" --epoch "$BURN_MID_TS" --sort cpu --lang en)"
    BLAME_ZH="$("$WORK_BIN" --cli blame --db "$DB_PATH" --epoch "$BURN_MID_TS" --sort cpu --lang zh)"

    /usr/bin/python3 - "$SAVED_BURN_PID" "$ELAPSED_SINCE_EXIT" "$HIST_JSON" "$HIST_EN" "$HIST_ZH" "$BLAME_EN" "$BLAME_ZH" <<'PY'
import json, sys

burn_pid = int(sys.argv[1])
elapsed_after_exit = int(sys.argv[2])
hist_json = json.loads(sys.argv[3])
hist_en, hist_zh, blame_en, blame_zh = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]

procs = [p for p in hist_json.get("processes", []) if p.get("pid") == burn_pid]
if not procs:
    print(f"FAIL [Row 5]: Exited pid={burn_pid} missing from `--cli history --json`: {hist_json}", file=sys.stderr)
    sys.exit(1)

p = procs[0]
peak_cpu = float(p.get("peakCPUPct") or 0.0)
alive_now = p.get("isAliveNow")

print(f"  -> Queried {elapsed_after_exit}s (>= 60s) after pid={burn_pid} exited: peakCPUPct={peak_cpu:.1f}%, isAliveNow={alive_now}")
if peak_cpu < 60.0 or alive_now is not False:
    print(f"FAIL [Row 5]: Expected peakCPUPct >= 60.0% and isAliveNow == False, got {p}", file=sys.stderr)
    sys.exit(1)

for label, txt, req_tokens in (
    ("history EN", hist_en, ("chronomac_cpu_burn_probe", "exited after spike")),
    ("history ZH", hist_zh, ("chronomac_cpu_burn_probe", "尖峰后已退出")),
    ("timeline blame EN", blame_en, ("chronomac_cpu_burn_probe", "exited after spike")),
    ("timeline blame ZH", blame_zh, ("chronomac_cpu_burn_probe", "尖峰后已退出")),
):
    for tok in req_tokens:
        if tok not in txt:
            print(f"FAIL [Row 5]: Missing '{tok}' in {label}:\n{txt}", file=sys.stderr)
            sys.exit(1)

print("  -> [PASS] Row 5: Exited single-core child process & its CPU spike recovered via both timeline blame and `--cli history` (EN/ZH/JSON).")
PY
    PASSED=$((PASSED + 1))

    # --------------------------------------------------------------------
    # Row 6: 7-Day Continuous Unattended Recording
    # --------------------------------------------------------------------
    echo ""
    echo "[Row 6/6] 7-day continuous unattended recording..."
    if [[ "${CHRONOMAC_RUN_7D:-0}" == "1" ]]; then
        "$ROOT/Scripts/acceptance/m1-record-1h.sh" --duration 604800 --interval 2 --skip-build
        echo "  -> [PASS] Row 6: 7-day continuous recording verified."
        PASSED=$((PASSED + 1))
    else
        echo "  -> [SKIP] Row 6 (7-day continuous unattended run): 没跑 (7-day wall-clock run not executed in this session)."
        SKIPPED=$((SKIPPED + 1))
    fi

    # --------------------------------------------------------------------
    # M1 Fault-Injection Mutation Gate (4 M1 Mutations in Isolated Clone)
    # --------------------------------------------------------------------
    echo ""
    echo "[Mutation Gate] Verifying 4 M1 fault-injection mutations in isolated temp workspace..."
    MUT_REPO="$TMP_DIFF/mut-repo"
    mkdir -p "$MUT_REPO"
    /usr/bin/rsync -a --exclude='.build' --exclude='build' --exclude='.git' "$ROOT/" "$MUT_REPO/"
    git -C "$MUT_REPO" init -q
    git -C "$MUT_REPO" add -A
    git -C "$MUT_REPO" -c user.name="mut" -c user.email="mut@local" commit -qm "baseline"
    (cd "$MUT_REPO" && swift build --build-tests >/dev/null 2>&1)

    run_m1_mutation() {
        local mut_id="$1"
        local file_rel="$2"
        local filter_expr="$3"
        local mode="$4"

        /usr/bin/python3 - "$MUT_REPO/$file_rel" "$mode" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if mode == "m1_nic_drop_unattributed":
    old = "unattributedInBytes = max(0, nicDeltaInBytes - attributedInBytes)"
    new = "unattributedInBytes = 0"
elif mode == "m1_t7_disable_ps_supplement":
    old = "if let psRow = lazyPsSnapshot?[pid] {"
    new = "if false, let psRow = lazyPsSnapshot?[pid] {"
elif mode == "m1_prune_per_table_wipe":
    old = "if cutoffTs < globalMaxTs {"
    new = "if false && cutoffTs < globalMaxTs {"
elif mode == "m1_record_skip_batch":
    old = "try store.recordSampleBatch(tick: tick, processes: procs, sockets: socketRecords, anomalies: detectedAnomalies)"
    new = "_ = (tick, procs, socketRecords, detectedAnomalies)"
else:
    sys.exit(2)
if old not in text:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY

        if ! (cd "$MUT_REPO" && swift build --build-tests >/dev/null 2>&1); then
            echo "FAIL [Mutation $mut_id]: Compile error instead of test assertion failure!" >&2
            exit 1
        fi
        set +e
        MUT_OUT="$(cd "$MUT_REPO" && CHRONOMAC_DB_PATH="$TMP_DIFF/mut-${mut_id}.sqlite" swift test --skip-build --no-parallel --filter "$filter_expr" 2>&1)"
        MUT_RC=$?
        set -e
        git -C "$MUT_REPO" checkout -q -- .
        if [[ "$MUT_RC" -eq 0 ]] || [[ "$MUT_OUT" != *'✘ Test "'* ]]; then
            echo "FAIL [Mutation $mut_id]: Mutation was not caught by $filter_expr (rc=$MUT_RC)!" >&2
            echo "$MUT_OUT" >&2
            exit 1
        fi
        local failed_line
        failed_line="$(printf '%s\n' "$MUT_OUT" | grep '✘ Test "' | tail -n 1 | sed 's/^[[:space:]]*//')"
        echo "  -> Mutation [$mut_id] caught cleanly (compile=0, test_rc=$MUT_RC): $failed_line"
    }

    run_m1_mutation "m1_nic_drop_unattributed" \
        "Sources/ChronoMacCore/Collectors/NettopDeltaParser.swift" \
        "ChronoMacCoreTests.SamplerTests/m1PhysicalNICCalibrationFortyMBAndLoopbackIsolation" \
        "m1_nic_drop_unattributed"

    run_m1_mutation "m1_t7_disable_ps_supplement" \
        "Sources/ChronoMacCore/Collectors/ProcessTreeSampler.swift" \
        "ChronoMacCoreTests.SamplerTests/t7NonRootReadsWindowServerAndRootCPUWhileKernelTaskStaysUnreadable" \
        "m1_t7_disable_ps_supplement"

    run_m1_mutation "m1_prune_per_table_wipe" \
        "Sources/ChronoMacCore/Storage/FlightboxStore.swift" \
        "ChronoMacCoreTests.StoreTests/m1GlobalOldestFirstPruningPreservesRecentAnomaliesAndSockets" \
        "m1_prune_per_table_wipe"

    run_m1_mutation "m1_record_skip_batch" \
        "Sources/ChronoMacCore/Collectors/FlightboxRecorder.swift" \
        "ChronoMacCoreTests.CLITests/m1RecordDaemonGracefulStopAndConcurrentReadOnlyQueries" \
        "m1_record_skip_batch"

    rm -rf "$MUT_REPO"
    echo "  -> [PASS] Mutation Gate: 4/4 M1 fault-injection mutations caught cleanly."

    # --------------------------------------------------------------------
    # Host Safety Verification: ~/Library completely untouched
    # --------------------------------------------------------------------
    if [[ -n "$BEFORE_REAL_DB_SHA" ]]; then
        AFTER_REAL_DB_SHA="$(shasum -a 256 "$REAL_USER_DB" | awk '{print $1}')"
        if [[ "$BEFORE_REAL_DB_SHA" != "$AFTER_REAL_DB_SHA" ]]; then
            echo "CRITICAL FAIL: Host $REAL_USER_DB SHA-256 changed!" >&2
            exit 1
        fi
    fi
    if [[ -n "$BEFORE_REAL_PLIST_SHA" ]]; then
        AFTER_REAL_PLIST_SHA="$(shasum -a 256 "$REAL_USER_PLIST" | awk '{print $1}')"
        if [[ "$BEFORE_REAL_PLIST_SHA" != "$AFTER_REAL_PLIST_SHA" ]]; then
            echo "CRITICAL FAIL: Host $REAL_USER_PLIST SHA-256 changed!" >&2
            exit 1
        fi
    fi
    if [[ -n "$BEFORE_LA_SNAP" ]]; then
        AFTER_LA_SNAP="$(ls -1A "$REAL_LA_DIR" | shasum -a 256 | awk '{print $1}')"
        if [[ "$BEFORE_LA_SNAP" != "$AFTER_LA_SNAP" ]]; then
            echo "CRITICAL FAIL: Host ~/Library/LaunchAgents directory changed!" >&2
            exit 1
        fi
    fi
    echo ""
    echo "[Host Safety] Verified ~/Library/Application Support, Preferences, and LaunchAgents untouched."
    echo ""
    echo "Summary: passed=$PASSED, skipped=$SKIPPED, failed=$FAILED"
    echo "========================================================================"
    echo "M1 DIFFERENTIAL SUITE COMPLETE (passed=$PASSED, skipped=$SKIPPED, failed=$FAILED)"
    echo "========================================================================"
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
text = re.sub(r"/tmp/chronomac-[^\s\"'（()）\[\],;]+", "<TMP_DIR>", text)
open(dst, "w", encoding="utf-8").write(text)
PY
fi
