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
echo "ChronoMac M0 Acceptance Suite (Isolated Temp Dir)"
echo "========================================================================"

# ------------------------------------------------------------------------
# Row 1: 30h synthetic stream, 1 spike every 20m (90 total), compact every 60s
# ------------------------------------------------------------------------
echo ""
echo "[Row 1/6] 30-hour synthetic stream (90 spikes every 20m, half-bucket compaction every 60s)..."
ROW1_DB="$TMP_ACC/row1.sqlite"
set +e
CHRONOMAC_ROW1_EXPORT_DB="$ROW1_DB" swift test --no-parallel --filter "ChronoMacCoreTests.StoreTests/thirtyHourSlidingCompactionPreservesAll90Spikes"
R1_TEST_RC=$?
set -e

if [[ -f "$ROW1_DB" ]]; then
    RAW_PEAK_TICKS="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM system_ticks WHERE (cpu_user + cpu_sys) >= 90.0;")"
    SPIKE_COUNT="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM system_ticks t WHERE (t.cpu_user + t.cpu_sys) >= 90.0 AND EXISTS (SELECT 1 FROM process_snapshots p WHERE (p.ts / 60) = (t.ts / 60) AND p.name LIKE 'spike-culprit-%');")"
    SPLIT_BUCKETS="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM (SELECT (ts / 15) * 15 AS b FROM system_ticks GROUP BY b HAVING COUNT(DISTINCT tier) > 1);")"
    TOTAL_ROWS_R1="$(/usr/bin/sqlite3 "$ROW1_DB" "SELECT COUNT(*) FROM system_ticks;")"
else
    RAW_PEAK_TICKS=0
    SPIKE_COUNT=0
    SPLIT_BUCKETS=0
    TOTAL_ROWS_R1=0
fi

echo "  -> SQLite verification: surviving_spikes=$SPIKE_COUNT / 90 (tick_peaks=$RAW_PEAK_TICKS, split_buckets=$SPLIT_BUCKETS, total_rows=$TOTAL_ROWS_R1)"
if [[ "$R1_TEST_RC" -ne 0 || "$SPIKE_COUNT" -ne 90 || "$RAW_PEAK_TICKS" -ne 90 || "$SPLIT_BUCKETS" -ne 0 ]]; then
    echo "FAIL [Row 1]: Expected surviving_spikes=90 / 90 and split_buckets=0 (got surviving_spikes=$SPIKE_COUNT, tick_peaks=$RAW_PEAK_TICKS, split_buckets=$SPLIT_BUCKETS, test_rc=$R1_TEST_RC)" >&2
    exit 1
fi
echo "  -> PASS [Row 1]: 90 / 90 spikes and culprit snapshots preserved across half-bucket boundaries."

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
LOOP_IN_PEAK="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COALESCE(MAX(loopback_in_bps), 0) FROM system_ticks;")"
LOOP_OUT_PEAK="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COALESCE(MAX(loopback_out_bps), 0) FROM system_ticks;")"
EXT_IN_DIFF="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COALESCE(MAX(net_in_bps) - MIN(net_in_bps), 0) FROM system_ticks;")"
EXT_OUT_DIFF="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COALESCE(MAX(net_out_bps) - MIN(net_out_bps), 0) FROM system_ticks;")"
EXT_TOTAL_IMPLIED_BYTES="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COALESCE(SUM((net_in_bps + net_out_bps) * 2), 0) FROM system_ticks;")"
LOOP_SOCKETS="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COUNT(*) FROM socket_ledger WHERE remote_endpoint LIKE '127.%' OR remote_endpoint LIKE '::1.%' OR remote_endpoint LIKE '::1:%' OR process_name LIKE '%python%';")"
ANOM_COUNT="$(/usr/bin/sqlite3 "$ROW3_DB" "SELECT COUNT(*) FROM anomaly_bookmarks WHERE culprit_name LIKE '%python%' OR summary LIKE '%127.0.0.1%';")"
ANOM_EN="$("$BIN" --cli anomalies --db "$ROW3_DB" --lang en)"
ANOM_ZH="$("$BIN" --cli anomalies --db "$ROW3_DB" --lang zh)"
EGRESS_EN="$("$BIN" --cli egress --db "$ROW3_DB" --lang en)"
EGRESS_ZH="$("$BIN" --cli egress --db "$ROW3_DB" --lang zh)"
echo "  -> SQLite verification: peak_loopback_in_bps=$LOOP_IN_PEAK peak_loopback_out_bps=$LOOP_OUT_PEAK ext_in_delta_bps=$EXT_IN_DIFF ext_out_delta_bps=$EXT_OUT_DIFF ext_total_implied_bytes=$EXT_TOTAL_IMPLIED_BYTES loopback_rows_in_socket_ledger=$LOOP_SOCKETS net_anomalies=$ANOM_COUNT"
echo "  -> CLI anomalies (EN): $(echo "$ANOM_EN" | tail -n 1)"
echo "  -> CLI anomalies (ZH): $(echo "$ANOM_ZH" | tail -n 1)"
FIFTY_MIB=$((50 * 1024 * 1024))
TWENTY_MB=20000000
if [[ "$LOOP_IN_PEAK" -lt "$FIFTY_MIB" || "$LOOP_OUT_PEAK" -lt "$FIFTY_MIB" ]]; then
    echo "FAIL [Row 3]: Loopback peak rate too low (in=$LOOP_IN_PEAK, out=$LOOP_OUT_PEAK; expected >= $FIFTY_MIB B/s)" >&2
    exit 1
fi
if [[ "$EXT_IN_DIFF" -ge "$TWENTY_MB" || "$EXT_OUT_DIFF" -ge "$TWENTY_MB" || "$EXT_TOTAL_IMPLIED_BYTES" -ge 50000000 ]]; then
    echo "FAIL [Row 3]: External network counters surged during 200 MB loopback transfer (ext_in_delta_bps=$EXT_IN_DIFF, ext_out_delta_bps=$EXT_OUT_DIFF, ext_total_implied_bytes=$EXT_TOTAL_IMPLIED_BYTES)" >&2
    exit 1
fi
if [[ "$LOOP_SOCKETS" -ne 0 || "$ANOM_COUNT" -ne 0 ]]; then
    echo "FAIL [Row 3]: Loopback leaked into external socket ledger or anomalies!" >&2
    exit 1
fi
if [[ "$EGRESS_EN $EGRESS_ZH" == *"127.0.0.1"* ]]; then
    if printf '%s\n' "$EGRESS_EN" | grep -v "loopback" | grep "127.0.0.1" >/dev/null; then
        echo "FAIL [Row 3]: 127.0.0.1 endpoint appeared in external egress CLI!" >&2
        exit 1
    fi
fi
echo "  -> PASS [Row 3]: External inbound/outbound did not jump by 200 MB (ext_in_delta_bps=$EXT_IN_DIFF, ext_out_delta_bps=$EXT_OUT_DIFF); 0 network anomalies."

# ------------------------------------------------------------------------
# Row 4: `ChronoMac --cli status` 5 consecutive runs alongside `top` (EN & ZH)
# ------------------------------------------------------------------------
echo ""
echo "[Row 4/6] 5 consecutive runs of ChronoMac --cli status vs live top (in --lang en and --lang zh)..."
ROW4_MISSING_DB="$TMP_ACC/row4-readonly-missing.sqlite"
MAX_ACCEPTED_DIFF="0.0"
MAX_OBSERVED_DIFF="0.0"
for LANG_CODE in en zh; do
    echo "  -- Language: $LANG_CODE --"
    for RUN_IDX in 1 2 3 4 5; do
        FINAL_VERDICT="FAIL"
        for ATTEMPT in 1 2 3; do
            LOADAVG="$(/usr/sbin/sysctl -n vm.loadavg | tr -d '{}' | xargs)"
            CLI_OUT_FILE="$TMP_ACC/status_${LANG_CODE}_${RUN_IDX}_a${ATTEMPT}.txt"
            TOP_OUT_FILE="$TMP_ACC/top_${LANG_CODE}_${RUN_IDX}_a${ATTEMPT}.txt"

            /usr/bin/top -F -R -l 2 -n 0 -s 1 > "$TOP_OUT_FILE" &
            PID_TOP=$!
            sleep 0.36
            "$BIN" --cli status --db "$ROW4_MISSING_DB" --lang "$LANG_CODE" > "$CLI_OUT_FILE" &
            PID_CLI=$!
            wait "$PID_CLI"
            wait "$PID_TOP"

            read -r CLI_CPU TOP_CPU DIFF_CPU VERDICT MAX_OBSERVED_DIFF < <(
                /usr/bin/python3 - "$CLI_OUT_FILE" "$TOP_OUT_FILE" "$MAX_OBSERVED_DIFF" <<'PY'
import re, sys
cli_text = open(sys.argv[1], encoding="utf-8").read()
top_text = open(sys.argv[2], encoding="utf-8").read()
prev_max = float(sys.argv[3])

m_cli = re.search(r"CPU:\s*([0-9]+(?:\.[0-9]+)?)%", cli_text)
if not m_cli:
    print(f"0.0 0.0 999.0 FAIL_PARSE_CLI {prev_max:.1f}")
    sys.exit(0)
cli_cpu = float(m_cli.group(1))

cpu_lines = re.findall(r"CPU usage:\s*([0-9.]+)%\s*user,\s*([0-9.]+)%\s*sys", top_text)
if not cpu_lines:
    print(f"{cli_cpu:.1f} 0.0 999.0 FAIL_PARSE_TOP {prev_max:.1f}")
    sys.exit(0)
u_str, s_str = cpu_lines[-1]
top_cpu = float(u_str) + float(s_str)
diff = abs(cli_cpu - top_cpu)
new_max = max(prev_max, diff)
ok = (cli_cpu > 0.0) and (diff <= 10.0)
if ok:
    verdict = "OK"
elif cli_cpu <= 0.0:
    verdict = "ZERO_CLI"
else:
    verdict = "DIFF_GT_10PP"
print(f"{cli_cpu:.1f} {top_cpu:.1f} {diff:.1f} {verdict} {new_max:.1f}")
PY
            )
            if [[ -e "$ROW4_MISSING_DB" ]]; then
                echo "FAIL [Row 4]: Read-only --cli status created $ROW4_MISSING_DB!" >&2
                exit 1
            fi
            if [[ "$VERDICT" == "OK" ]]; then
                MAX_ACCEPTED_DIFF="$(/usr/bin/python3 -c "print(f'{max(float(\"$MAX_ACCEPTED_DIFF\"), float(\"$DIFF_CPU\")):.1f}')")"
                echo "    Run $RUN_IDX ($LANG_CODE, attempt $ATTEMPT/3, loadavg=[$LOADAVG]): ChronoMac=${CLI_CPU}% | top=${TOP_CPU}% | diff=${DIFF_CPU} pp -> OK"
                FINAL_VERDICT="OK"
                break
            else
                STEP_LABEL="RETRY"
                if [[ "$ATTEMPT" -ge 3 ]]; then
                    STEP_LABEL="FAIL"
                fi
                echo "    Run $RUN_IDX ($LANG_CODE, attempt $ATTEMPT/3, loadavg=[$LOADAVG]): ChronoMac=${CLI_CPU}% | top=${TOP_CPU}% | diff=${DIFF_CPU} pp -> ${STEP_LABEL} (measured diff=${DIFF_CPU} pp, ChronoMac=${CLI_CPU}%, status=${VERDICT})"
                if [[ "$ATTEMPT" -lt 3 ]]; then
                    sleep 0.8
                fi
            fi
        done
        if [[ "$FINAL_VERDICT" != "OK" ]]; then
            echo "FAIL [Row 4]: Run $RUN_IDX ($LANG_CODE) did not satisfy (ChronoMac > 0.0% and diff <= 10.0 pp) across 3 attempts (last ChronoMac=${CLI_CPU}%, top=${TOP_CPU}%, diff=${DIFF_CPU} pp, status=${VERDICT}; uptime: $(/usr/bin/uptime | sed 's/^[[:space:]]*//'))" >&2
            cat "$CLI_OUT_FILE" >&2
            exit 1
        fi
    done
done
echo "  -> PASS [Row 4]: All 10 calibrated runs (5 EN + 5 ZH) > 0.0% and within <= 10.0 pp of top (max_accepted_diff=${MAX_ACCEPTED_DIFF} pp, max_observed_diff=${MAX_OBSERVED_DIFF} pp)."

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
# Row 6: Real Isolated Fault-Injection Mutation Harness (W1)
# ------------------------------------------------------------------------
echo ""
echo "[Row 6/6] Running real fault-injection mutations in isolated temp workspace..."
MUT_REPO="$TMP_ACC/mut-repo"
mkdir -p "$MUT_REPO"
/usr/bin/rsync -a --exclude='.build' --exclude='build' --exclude='.git' "$ROOT/" "$MUT_REPO/"
git -C "$MUT_REPO" init -q
git -C "$MUT_REPO" add -A
git -C "$MUT_REPO" -c user.name="mut" -c user.email="mut@local" commit -qm "baseline"

# Initial test build in isolated workspace
(cd "$MUT_REPO" && swift build --build-tests >/dev/null 2>&1)

run_mutation_check() {
    local mut_id="$1"
    local file_rel="$2"
    local filter_expr="$3"
    local py_patch="$4"

    /usr/bin/python3 - "$MUT_REPO/$file_rel" "$py_patch" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if mode == "cpu_zero":
    old = "cpuPct = (deltaSec / dt) * 100.0"
    new = "cpuPct = 0.0"
elif mode == "mem_zero":
    old = "footprintBytes = Int64(ru.ri_phys_footprint > 0 ? ru.ri_phys_footprint : ru.ri_resident_size)"
    new = "footprintBytes = 0"
elif mode == "cap_off":
    old = "while totalStorageBytes() > maxDatabaseBytes && guardIterations < 40 {"
    new = "while false && totalStorageBytes() > maxDatabaseBytes && guardIterations < 40 {"
elif mode == "cutoff_unaligned":
    old = "let alignedCutoff = (cutoff / bucketSec) * bucketSec"
    new = "let alignedCutoff = cutoff"
elif mode == "conflict_replace":
    anchor = text.find("private func compactTier(")
    if anchor < 0:
        sys.exit(3)
    old = "INSERT INTO system_ticks ("
    ins_idx = text.find(old, anchor)
    if ins_idx < 0:
        sys.exit(3)
    text = text[:ins_idx] + "INSERT OR REPLACE INTO system_ticks (" + text[ins_idx + len(old):]
    start_idx = text.index("ON CONFLICT(ts) DO UPDATE SET", ins_idx)
    end_idx = text.index("END;", start_idx) + len("END;")
    text = text[:start_idx] + ";" + text[end_idx:]
    open(path, "w", encoding="utf-8").write(text)
    sys.exit(0)
elif mode == "insert_tick_replace":
    anchor = text.find("private func insertTick(")
    if anchor < 0:
        sys.exit(3)
    old = "INSERT INTO system_ticks ("
    ins_idx = text.find(old, anchor)
    if ins_idx < 0:
        sys.exit(3)
    text = text[:ins_idx] + "INSERT OR REPLACE INTO system_ticks (" + text[ins_idx + len(old):]
    start_idx = text.index("ON CONFLICT(ts) DO UPDATE SET", ins_idx)
    end_idx = text.index("END;", start_idx) + len("END;")
    text = text[:start_idx] + ";" + text[end_idx:]
    open(path, "w", encoding="utf-8").write(text)
    sys.exit(0)
elif mode == "nettop_drop_new_pid":
    old = "if !isFirstBaseline {"
    new = "if !isFirstBaseline && prevSocketCounters[sockKey] != nil {"
elif mode == "t18_app_bundle_branch":
    old = "if let stored = preferenceStore?.string(forKey: defaultsKey),"
    new = "if (arguments.first ?? \"\").contains(\".app/\") || Bundle.main.bundleURL.pathExtension == \"app\", let stored = preferenceStore?.string(forKey: defaultsKey),"
else:
    sys.exit(2)

if old not in text:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY

    # 1. Must compile cleanly (NOT a compile failure!)
    if ! (cd "$MUT_REPO" && swift build --build-tests >/dev/null 2>&1); then
        echo "FAIL [Row 6 - $mut_id]: Mutation caused a compile error instead of a test assertion failure!" >&2
        exit 1
    fi

    # 2. Target test must run and fail with an explicit test failure marker
    set +e
    MUT_OUT="$(cd "$MUT_REPO" && CHRONOMAC_DB_PATH="$TMP_ACC/mut-${mut_id}.sqlite" swift test --skip-build --no-parallel --filter "$filter_expr" 2>&1)"
    MUT_RC=$?
    set -e

    git -C "$MUT_REPO" checkout -q -- .
    if [[ -n "$(git -C "$MUT_REPO" status --porcelain)" ]]; then
        echo "FAIL [Row 6 - $mut_id]: Temp workspace dirty after checkout!" >&2
        exit 1
    fi

    if [[ "$MUT_RC" -eq 0 ]]; then
        echo "FAIL [Row 6 - $mut_id]: Mutated code unexpectedly PASSED ($filter_expr)!" >&2
        exit 1
    fi
    if [[ "$MUT_OUT" != *'✘ Test "'* ]]; then
        echo "FAIL [Row 6 - $mut_id]: Non-zero exit ($MUT_RC) without specific Swift Testing case failure marker!" >&2
        echo "$MUT_OUT" >&2
        exit 1
    fi
    local failed_line
    failed_line="$(printf '%s\n' "$MUT_OUT" | grep '✘ Test "' | tail -n 1 | sed 's/^[[:space:]]*//')"
    echo "  -> Mutation [$mut_id] caught cleanly (compile=0, test_rc=$MUT_RC): $failed_line"
}

run_mutation_check "cpu_zero" \
    "Sources/ChronoMacCore/Collectors/ProcessTreeSampler.swift" \
    "ChronoMacCoreTests.SamplerTests/realProcessTreeSamplerMeasuresCurrentProcessAndSurfacesUnreadableSystemPIDs" \
    "cpu_zero"

run_mutation_check "mem_zero" \
    "Sources/ChronoMacCore/Collectors/ProcessTreeSampler.swift" \
    "ChronoMacCoreTests.SamplerTests/realProcessTreeSamplerMeasuresCurrentProcessAndSurfacesUnreadableSystemPIDs" \
    "mem_zero"

run_mutation_check "cap_off" \
    "Sources/ChronoMacCore/Storage/FlightboxStore.swift" \
    "ChronoMacCoreTests.StoreTests/enforcesTwoMegabyteCapWithinFortyEightHoursIncludingWAL" \
    "cap_off"

run_mutation_check "cutoff_unaligned" \
    "Sources/ChronoMacCore/Storage/FlightboxStore.swift" \
    "ChronoMacCoreTests.StoreTests/thirtyHourSlidingCompactionPreservesAll90Spikes" \
    "cutoff_unaligned"

run_mutation_check "conflict_replace" \
    "Sources/ChronoMacCore/Storage/FlightboxStore.swift" \
    "ChronoMacCoreTests.StoreTests/thirtyHourSlidingCompactionPreservesAll90Spikes" \
    "conflict_replace"

run_mutation_check "insert_tick_replace" \
    "Sources/ChronoMacCore/Storage/FlightboxStore.swift" \
    "ChronoMacCoreTests.StoreTests/sameTimestampCompactedPeakPreservedAgainstLateLowSample" \
    "insert_tick_replace"

run_mutation_check "nettop_drop_new_pid" \
    "Sources/ChronoMacCore/Collectors/NettopDeltaParser.swift" \
    "ChronoMacCoreTests.SamplerTests/postBaselineNewProcessTrafficAttributedNotDropped" \
    "nettop_drop_new_pid"

run_mutation_check "t18_app_bundle_branch" \
    "Sources/ChronoMacCore/Localization/AppLocalizer.swift" \
    "ChronoMacCoreTests.ChronoMacCoreTests/t18BehavioralPreferenceStoreInjectionInCLIModeWithoutBundle" \
    "t18_app_bundle_branch"

rm -rf "$MUT_REPO"
echo "  -> PASS [Row 6]: All 8 isolated code mutations compiled cleanly and failed their specific guard tests."

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
    echo "[DB Safety] Verified user flightbox.sqlite untouched (SHA-256: $AFTER_REAL_SHA)."
fi

echo ""
echo "Summary: passed=6, skipped=0, failed=0"
echo "========================================================================"
echo "ALL 6 M0 ACCEPTANCE ROWS PASSED"
echo "========================================================================"
