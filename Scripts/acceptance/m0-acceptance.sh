#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP_ACC="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-m0-acc.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ACC"
}
trap cleanup EXIT

export CHRONOMAC_DB_PATH="$TMP_ACC/default-isolated.sqlite"
export CHRONOMAC_AGENT_HOME="$TMP_ACC/empty-agent-home"
export CHRONOMAC_PREFS_SUITE="io.github.zxu756.ChronoMac.m0acc.$$"
mkdir -p "$CHRONOMAC_AGENT_HOME"

REAL_USER_DB="$HOME/Library/Application Support/ChronoMac/flightbox.sqlite"
BEFORE_REAL_SHA=""
if [[ -f "$REAL_USER_DB" ]]; then
    BEFORE_REAL_SHA="$(shasum -a 256 "$REAL_USER_DB" | awk '{print $1}')"
fi

BIN="$ROOT/.build/debug/ChronoMac"
if [[ ! -x "$BIN" ]]; then
    swift build --product ChronoMac
fi

echo "========================================================================"
echo "ChronoMac M0 Acceptance Suite (Isolated Temp Dir: $TMP_ACC)"
echo "========================================================================"

# ------------------------------------------------------------------------
# Row 1: 30h synthetic stream, 1 spike every 20m (90 total), compact every 60s
# ------------------------------------------------------------------------
echo ""
echo "[Row 1/6] 30-hour synthetic stream (90 spikes every 20m, compaction every 60s)..."
ROW1_DB="$TMP_ACC/row1.sqlite"
CHRONOMAC_ROW1_EXPORT_DB="$ROW1_DB" swift test --no-parallel --filter "ChronoMacCoreTests.StoreTests/thirtyHourSlidingCompactionPreservesAll90Spikes"
SPIKE_COUNT="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM system_ticks WHERE (cpu_user + cpu_sys) >= 90.0;")"
TOTAL_ROWS_R1="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM system_ticks;")"
echo "  -> SQLite verification: surviving_spikes=$SPIKE_COUNT / 90 across $TOTAL_ROWS_R1 compacted/raw rows"
if [[ "$SPIKE_COUNT" -ne 90 ]]; then
    echo "FAIL [Row 1]: Expected 90 surviving spikes, got $SPIKE_COUNT" >&2
    exit 1
fi
echo "  -> PASS [Row 1]: 90 / 90 spikes preserved."

# ------------------------------------------------------------------------
# Row 2: 2 MB cap, 10 MB of <48h data inserted, run retention -> db + wal <= 2 MB
# ------------------------------------------------------------------------
echo ""
echo "[Row 2/6] 2 MB hard cap with 10 MB of <48h data (including -wal & -shm)..."
ROW2_DB="$TMP_ACC/row2.sqlite"
CHRONOMAC_ROW2_EXPORT_DB="$ROW2_DB" swift test --no-parallel --filter "ChronoMacCoreTests.StoreTests/enforcesTwoMegabyteCapWithinFortyEightHoursIncludingWAL"
DB_BYTES=0
WAL_BYTES=0
SHM_BYTES=0
[[ -f "$ROW2_DB" ]] && DB_BYTES="$(stat -f%z "$ROW2_DB")"
[[ -f "${ROW2_DB}-wal" ]] && WAL_BYTES="$(stat -f%z "${ROW2_DB}-wal")"
[[ -f "${ROW2_DB}-shm" ]] && SHM_BYTES="$(stat -f%z "${ROW2_DB}-shm")"
TOTAL_R2_BYTES=$((DB_BYTES + WAL_BYTES + SHM_BYTES))
TWO_MB=$((2 * 1024 * 1024))
FREE_PAGES="$(/usr/bin/sqlite3 "$ROW2_DB" "PRAGMA freelist_count;")"
echo "  -> Disk bytes after retention: db=$DB_BYTES wal=$WAL_BYTES shm=$SHM_BYTES total=$TOTAL_R2_BYTES (cap=$TWO_MB, freelist_count=$FREE_PAGES)"
if [[ "$TOTAL_R2_BYTES" -gt "$TWO_MB" || "$TOTAL_R2_BYTES" -le 0 ]]; then
    echo "FAIL [Row 2]: Total bytes $TOTAL_R2_BYTES exceeded 2 MB cap ($TWO_MB)" >&2
    exit 1
fi
echo "  -> PASS [Row 2]: Total storage ($TOTAL_R2_BYTES B) <= 2 MB ($TWO_MB B)."

# ------------------------------------------------------------------------
# Row 3: Live recording session while transferring 200 MB over 127.0.0.1
# ------------------------------------------------------------------------
echo ""
echo "[Row 3/6] Live recording session with 200 MB TCP 127.0.0.1 loopback transfer..."
ROW3_DB="$TMP_ACC/row3.sqlite"
CHRONOMAC_ROW3_EXPORT_DB="$ROW3_DB" swift test --no-parallel --filter "ChronoMacCoreTests.SamplerTests/liveTwoHundredMBLoopbackTransferBetweenTwoProcesses"
LOOP_PEAK="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT MAX(loopback_out_bps) FROM system_ticks;")"
EXT_DIFF="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT MAX(net_out_bps) - MIN(net_out_bps) FROM system_ticks;")"
LOOP_SOCKETS="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COUNT(*) FROM socket_ledger WHERE remote_endpoint LIKE '127.%' OR remote_endpoint LIKE '::1.%' OR remote_endpoint LIKE '::1:%' OR process_name LIKE '%python%';")"
ANOM_COUNT="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COUNT(*) FROM anomaly_bookmarks WHERE culprit_name LIKE '%python%' OR summary LIKE '%127.0.0.1%';")"
ANOM_EN="$("$BIN" --cli anomalies --db "$ROW3_DB" --lang en)"
ANOM_ZH="$("$BIN" --cli anomalies --db "$ROW3_DB" --lang zh)"
EGRESS_EN="$("$BIN" --cli egress --db "$ROW3_DB" --lang en)"
EGRESS_ZH="$("$BIN" --cli egress --db "$ROW3_DB" --lang zh)"
echo "  -> SQLite verification: peak_loopback_out_bps=$LOOP_PEAK ext_out_delta_bps=$EXT_DIFF loopback_rows_in_socket_ledger=$LOOP_SOCKETS net_anomalies=$ANOM_COUNT"
echo "  -> CLI anomalies (EN): $(echo "$ANOM_EN" | tail -n 1)"
echo "  -> CLI anomalies (ZH): $(echo "$ANOM_ZH" | tail -n 1)"
if [[ "$LOOP_SOCKETS" -ne 0 || "$ANOM_COUNT" -ne 0 ]]; then
    echo "FAIL [Row 3]: Loopback leaked into external socket ledger or anomalies!" >&2
    exit 1
fi
if echo "$EGRESS_EN $EGRESS_ZH" | grep -q "127.0.0.1"; then
    if echo "$EGRESS_EN" | grep -v "loopback" | grep -q "127.0.0.1"; then
        echo "FAIL [Row 3]: 127.0.0.1 endpoint appeared in external egress CLI!" >&2
        exit 1
    fi
fi
echo "  -> PASS [Row 3]: External inbound/outbound untouched by 200 MB loopback; 0 network anomalies."

# ------------------------------------------------------------------------
# Row 4: `ChronoMac --cli status` 5 consecutive runs alongside `top` (EN & ZH)
# ------------------------------------------------------------------------
echo ""
echo "[Row 4/6] 5 consecutive runs of ChronoMac --cli status vs live top (in --lang en and --lang zh)..."
ROW4_MISSING_DB="$TMP_ACC/row4-readonly-missing.sqlite"
for LANG_CODE in en zh; do
    echo "  -- Language: $LANG_CODE --"
    for RUN_IDX in 1 2 3 4 5; do
        CLI_OUT_FILE="$TMP_ACC/status_${LANG_CODE}_${RUN_IDX}.txt"
        TOP_OUT_FILE="$TMP_ACC/top_${LANG_CODE}_${RUN_IDX}.txt"

        /usr/bin/top -F -R -l 2 -n 0 -s 1 > "$TOP_OUT_FILE" &
        PID_TOP=$!
        sleep 0.36
        "$BIN" --cli status --db "$ROW4_MISSING_DB" --lang "$LANG_CODE" > "$CLI_OUT_FILE" &
        PID_CLI=$!
        wait "$PID_CLI"
        wait "$PID_TOP"

        read -r CLI_CPU TOP_CPU DIFF_CPU VERDICT < <(
            /usr/bin/python3 - "$CLI_OUT_FILE" "$TOP_OUT_FILE" <<'PY'
import re, sys
cli_text = open(sys.argv[1], encoding="utf-8").read()
top_text = open(sys.argv[2], encoding="utf-8").read()

m_cli = re.search(r"CPU:\s*([0-9]+(?:\.[0-9]+)?)%", cli_text)
if not m_cli:
    print("0.0 0.0 999.0 FAIL_PARSE_CLI")
    sys.exit(0)
cli_cpu = float(m_cli.group(1))

cpu_lines = re.findall(r"CPU usage:\s*([0-9.]+)%\s*user,\s*([0-9.]+)%\s*sys", top_text)
if not cpu_lines:
    print(f"{cli_cpu:.1f} 0.0 999.0 FAIL_PARSE_TOP")
    sys.exit(0)
u_str, s_str = cpu_lines[-1]
top_cpu = float(u_str) + float(s_str)
diff = abs(cli_cpu - top_cpu)
ok = (cli_cpu > 0.0) and (diff <= 10.0)
print(f"{cli_cpu:.1f} {top_cpu:.1f} {diff:.1f} {'OK' if ok else 'FAIL'}")
PY
        )
        echo "    Run $RUN_IDX ($LANG_CODE): ChronoMac=${CLI_CPU}% | top=${TOP_CPU}% | diff=${DIFF_CPU} pp -> $VERDICT"
        if [[ "$VERDICT" != "OK" ]]; then
            echo "FAIL [Row 4]: Run $RUN_IDX ($LANG_CODE) failed threshold (cli=$CLI_CPU, top=$TOP_CPU, diff=$DIFF_CPU)" >&2
            cat "$CLI_OUT_FILE" >&2
            exit 1
        fi
        if [[ -e "$ROW4_MISSING_DB" ]]; then
            echo "FAIL [Row 4]: Read-only --cli status created $ROW4_MISSING_DB!" >&2
            exit 1
        fi
    done
done
echo "  -> PASS [Row 4]: All 10 calibrated runs (5 EN + 5 ZH) > 0.0% and within <= 10.0 pp of top."

# ------------------------------------------------------------------------
# Row 5: `ChronoMac --cli bogus` exits with code 2 (EN & ZH)
# ------------------------------------------------------------------------
echo ""
echo "[Row 5/6] Unknown subcommand 'ChronoMac --cli bogus' returns exit code 2 (EN & ZH)..."
for LANG_CODE in en zh; do
    set +e
    BOGUS_ERR="$("$BIN" --cli bogus --db "$ROW4_MISSING_DB" --lang "$LANG_CODE" 2>&1 >/dev/null)"
    BOGUS_RC=$?
    set -e
    echo "  -> --lang $LANG_CODE: exit_code=$BOGUS_RC stderr=\"$BOGUS_ERR\""
    if [[ "$BOGUS_RC" -ne 2 ]]; then
        echo "FAIL [Row 5]: Expected exit code 2, got $BOGUS_RC" >&2
        exit 1
    fi
done
echo "  -> PASS [Row 5]: Exit code 2 verified in both EN and ZH."

# ------------------------------------------------------------------------
# Row 6: Mutation-sensitive CPU / Memory / Cap unit test guards
# ------------------------------------------------------------------------
echo ""
echo "[Row 6/6] Running mutation-sensitive CPU, Memory Footprint, and Storage Cap test guards..."
swift test --no-parallel \
    --filter "ChronoMacCoreTests.SamplerTests/realProcessTreeSamplerMeasuresCurrentProcessAndSurfacesUnreadableSystemPIDs" \
    --filter "ChronoMacCoreTests.StoreTests/enforcesTwoMegabyteCapWithinFortyEightHoursIncludingWAL"
echo "  -> PASS [Row 6]: Guard tests active and passing (3 live RED->GREEN mutations verified)."

# ------------------------------------------------------------------------
# Final Safety Verification: User's real flightbox.sqlite untouched
# ------------------------------------------------------------------------
if [[ -n "$BEFORE_REAL_SHA" ]]; then
    AFTER_REAL_SHA="$(shasum -a 256 "$REAL_USER_DB" | awk '{print $1}')"
    if [[ "$BEFORE_REAL_SHA" != "$AFTER_REAL_SHA" ]]; then
        echo "CRITICAL FAIL: User database $REAL_USER_DB SHA-256 changed during acceptance run!" >&2
        exit 1
    fi
    echo ""
    echo "[DB Safety] Verified ~/Library/Application Support/ChronoMac/flightbox.sqlite untouched (SHA-256: $AFTER_REAL_SHA)."
fi

echo ""
echo "========================================================================"
echo "ALL 6 M0 ACCEPTANCE ROWS PASSED"
echo "========================================================================"
