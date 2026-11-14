#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-testsh.XXXXXX")"
cleanup() {
    rm -rf "$TMP_TEST_ROOT"
}
trap cleanup EXIT

export CHRONOMAC_DB_PATH="$TMP_TEST_ROOT/flightbox.sqlite"
export CHRONOMAC_AGENT_HOME="$TMP_TEST_ROOT/agent-home"
mkdir -p "$CHRONOMAC_AGENT_HOME"

usage() {
    cat <<'EOF' >&2
Usage:
  Scripts/test.sh scope <Module> [Module...]   # e.g. Store, Sampler, CLI, ChronoMacCoreTests
  Scripts/test.sh milestone <N> [--record]     # e.g. milestone 0 (pass --record to update reports/*.txt)
  Scripts/test.sh release [--record]           # Full unit + acceptance + README replay suite
EOF
    exit 2
}

scrub_report_file() {
    local src="$1"
    local dst="$2"
    /usr/bin/python3 - "$src" "$dst" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
u_prefix = "/" + "Users/"
u_esc_prefix = "\\/" + "Users\\/"
text = re.sub(u_prefix + r"[^/\s\"'\\]+", "$HOME", text)
text = re.sub(u_esc_prefix + r"[^/\\\s\"']+", "\\/$HOME", text)
text = re.sub(r"/private/var/folders/[^\s\"']+", "<TMP_DIR>", text)
text = re.sub(r"/var/folders/[^\s\"']+", "<TMP_DIR>", text)
open(dst, "w", encoding="utf-8").write(text)
PY
}

# Parses Swift Testing output so skipped tests are NEVER counted as passed.
parse_swift_test_counts() {
    local log_file="$1"
    /usr/bin/python3 - "$log_file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
passed = len(re.findall(r'^\s*✔\s+Test\s+"', text, flags=re.MULTILINE))
skipped = len(re.findall(r'^\s*➜\s+Test\s+".*"\s+skipped\b', text, flags=re.MULTILINE))
failed = len(re.findall(r'^\s*✘\s+Test\s+".*"\s+failed\b', text, flags=re.MULTILINE))
print(f"{passed} {skipped} {failed}")
PY
}

parse_summary_counts() {
    local log_file="$1"
    /usr/bin/python3 - "$log_file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"Summary:\s*passed=(\d+),\s*skipped=(\d+),\s*failed=(\d+)", text)
if m:
    print(f"{m.group(1)} {m.group(2)} {m.group(3)}")
else:
    print("0 0 0")
PY
}

run_swift_test_logged() {
    local log_file="$1"
    shift
    set +e
    swift test "$@" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"
shift

RECORD_REPORTS=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--record" ]]; then
        RECORD_REPORTS=1
    else
        ARGS+=("$arg")
    fi
done

case "$MODE" in
    scope)
        if [[ ${#ARGS[@]} -lt 1 ]]; then
            usage
        fi
        FILTER_ARGS=()
        NEEDS_BIN=0
        for mod in "${ARGS[@]}"; do
            case "$mod" in
                Store|store) FILTER_ARGS+=(--filter "ChronoMacCoreTests.StoreTests") ;;
                Sampler|sampler) FILTER_ARGS+=(--filter "ChronoMacCoreTests.SamplerTests") ;;
                CLI|cli)
                    FILTER_ARGS+=(--filter "ChronoMacCoreTests.CLITests")
                    NEEDS_BIN=1
                    ;;
                *)
                    FILTER_ARGS+=(--filter "$mod")
                    NEEDS_BIN=1
                    ;;
            esac
        done
        if [[ "$NEEDS_BIN" -eq 1 ]]; then
            swift build --product ChronoMac
        fi
        echo "==> [scope] Running scoped tests (${ARGS[*]}) with isolated DB"
        SCOPE_LOG="$TMP_TEST_ROOT/scope-unit.log"
        set +e
        run_swift_test_logged "$SCOPE_LOG" --no-parallel "${FILTER_ARGS[@]}"
        SCOPE_RC=$?
        set -e
        read -r U_PASS U_SKIP U_FAIL < <(parse_swift_test_counts "$SCOPE_LOG")
        echo "==> [scope summary] unit_tests: passed=$U_PASS, skipped=$U_SKIP, failed=$U_FAIL"
        exit "$SCOPE_RC"
        ;;
    milestone)
        if [[ ${#ARGS[@]} -lt 1 ]]; then
            usage
        fi
        MS="${ARGS[0]}"
        case "$MS" in
            0|m0|M0)
                echo "==> [milestone 0] Building ChronoMac debug executable..."
                swift build --product ChronoMac
                echo "==> [milestone 0] Running ChronoMac unit test suites..."
                UNIT_LOG="$TMP_TEST_ROOT/m0-unit.log"
                run_swift_test_logged "$UNIT_LOG" --no-parallel
                read -r U_PASS U_SKIP U_FAIL < <(parse_swift_test_counts "$UNIT_LOG")
                echo "==> [milestone 0] Unit test breakdown (skips excluded from pass count): passed=$U_PASS, skipped=$U_SKIP, failed=$U_FAIL"
                echo "==> [milestone 0] Running M0 acceptance suite..."
                ACC_LOG="$TMP_TEST_ROOT/m0-acceptance.raw.txt"
                "$ROOT/Scripts/acceptance/m0-acceptance.sh" | tee "$ACC_LOG"
                read -r ACC_PASS ACC_SKIP ACC_FAIL < <(parse_summary_counts "$ACC_LOG")
                echo "==> [milestone 0] Replaying README & README.zh-CN commands..."
                RM_LOG="$TMP_TEST_ROOT/readme-commands.raw.txt"
                "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$RM_LOG"
                read -r RM_PASS RM_SKIP RM_FAIL < <(parse_summary_counts "$RM_LOG")
                if [[ "$RECORD_REPORTS" -eq 1 ]]; then
                    mkdir -p "$ROOT/reports"
                    scrub_report_file "$ACC_LOG" "$ROOT/reports/m0-acceptance.txt"
                    scrub_report_file "$RM_LOG" "$ROOT/reports/readme-commands.txt"
                    echo "==> [milestone 0] Updated scrubbed reports/m0-acceptance.txt and reports/readme-commands.txt (--record)."
                fi
                echo "==> [milestone 0 summary] unit_tests: passed=$U_PASS, skipped=$U_SKIP, failed=$U_FAIL | m0_acceptance_rows: passed=$ACC_PASS, skipped=$ACC_SKIP, failed=$ACC_FAIL | readme_replay: passed=$RM_PASS, skipped=$RM_SKIP, failed=$RM_FAIL"
                ;;
            *)
                echo "Error: Milestone $MS acceptance script is not implemented yet." >&2
                exit 2
                ;;
        esac
        ;;
    release)
        echo "==> [release] Building debug executable & release ChronoMac.app bundle..."
        swift build --product ChronoMac
        "$ROOT/Scripts/build-app.sh"
        echo "==> [release] Running full unit test suite..."
        UNIT_LOG="$TMP_TEST_ROOT/release-unit.log"
        run_swift_test_logged "$UNIT_LOG" --no-parallel
        read -r U_PASS U_SKIP U_FAIL < <(parse_swift_test_counts "$UNIT_LOG")
        echo "==> [release] Unit test breakdown (skips excluded from pass count): passed=$U_PASS, skipped=$U_SKIP, failed=$U_FAIL"
        echo "==> [release] Running M0 acceptance suite..."
        ACC_LOG="$TMP_TEST_ROOT/m0-acceptance.raw.txt"
        "$ROOT/Scripts/acceptance/m0-acceptance.sh" | tee "$ACC_LOG"
        read -r ACC_PASS ACC_SKIP ACC_FAIL < <(parse_summary_counts "$ACC_LOG")
        echo "==> [release] Replaying README & README.zh-CN commands..."
        RM_LOG="$TMP_TEST_ROOT/readme-commands.raw.txt"
        "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$RM_LOG"
        read -r RM_PASS RM_SKIP RM_FAIL < <(parse_summary_counts "$RM_LOG")
        if [[ "$RECORD_REPORTS" -eq 1 ]]; then
            mkdir -p "$ROOT/reports"
            scrub_report_file "$ACC_LOG" "$ROOT/reports/m0-acceptance.txt"
            scrub_report_file "$RM_LOG" "$ROOT/reports/readme-commands.txt"
        fi
        REA_PASS=0
        REA_SKIP=0
        if [[ -f "$HOME/.agents/skills/rea-build-guard/scripts/guard.py" ]]; then
            echo "==> [release] Running rea-build-guard on build/ChronoMac.app..."
            python3 "$HOME/.agents/skills/rea-build-guard/scripts/guard.py" \
                "$ROOT/build/ChronoMac.app" \
                --out "$TMP_TEST_ROOT/build-guard"
            REA_PASS=1
        else
            echo "==> [release] rea-build-guard: SKIPPED (guard.py not installed under HOME)"
            REA_SKIP=1
        fi
        LONG_PASS=0
        LONG_SKIP=0
        if [[ "${CHRONOMAC_LONG_RUN:-0}" == "1" ]]; then
            echo "==> [release] Running long-run differential checks..."
            if [[ -x "$ROOT/Scripts/acceptance/m1-differential.sh" ]]; then
                "$ROOT/Scripts/acceptance/m1-differential.sh"
                LONG_PASS=1
            else
                echo "Error: m1-differential.sh not yet available in M0." >&2
                exit 1
            fi
        else
            echo "==> [release] Long-run 1h/7d differential checks: SKIPPED (CHRONOMAC_LONG_RUN!=1)"
            LONG_SKIP=1
        fi
        echo "==> [release summary] unit_tests: passed=$U_PASS, skipped=$U_SKIP, failed=$U_FAIL | m0_acceptance_rows: passed=$ACC_PASS, skipped=$ACC_SKIP, failed=$ACC_FAIL | readme_replay: passed=$RM_PASS, skipped=$RM_SKIP, failed=$RM_FAIL | rea_guard: passed=$REA_PASS, skipped=$REA_SKIP | long_run: passed=$LONG_PASS, skipped=$LONG_SKIP"
        ;;
    *)
        usage
        ;;
esac
