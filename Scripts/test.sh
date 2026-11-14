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
        swift test --no-parallel "${FILTER_ARGS[@]}"
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
                swift test --no-parallel
                echo "==> [milestone 0] Running M0 acceptance suite..."
                ACC_LOG="$TMP_TEST_ROOT/m0-acceptance.raw.txt"
                "$ROOT/Scripts/acceptance/m0-acceptance.sh" | tee "$ACC_LOG"
                echo "==> [milestone 0] Replaying README & README.zh-CN commands..."
                RM_LOG="$TMP_TEST_ROOT/readme-commands.raw.txt"
                "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$RM_LOG"
                if [[ "$RECORD_REPORTS" -eq 1 ]]; then
                    mkdir -p "$ROOT/reports"
                    scrub_report_file "$ACC_LOG" "$ROOT/reports/m0-acceptance.txt"
                    scrub_report_file "$RM_LOG" "$ROOT/reports/readme-commands.txt"
                    echo "==> [milestone 0] Updated scrubbed reports/m0-acceptance.txt and reports/readme-commands.txt (--record)."
                fi
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
        swift test --no-parallel
        echo "==> [release] Running M0 acceptance suite..."
        ACC_LOG="$TMP_TEST_ROOT/m0-acceptance.raw.txt"
        "$ROOT/Scripts/acceptance/m0-acceptance.sh" | tee "$ACC_LOG"
        echo "==> [release] Replaying README & README.zh-CN commands..."
        RM_LOG="$TMP_TEST_ROOT/readme-commands.raw.txt"
        "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$RM_LOG"
        if [[ "$RECORD_REPORTS" -eq 1 ]]; then
            mkdir -p "$ROOT/reports"
            scrub_report_file "$ACC_LOG" "$ROOT/reports/m0-acceptance.txt"
            scrub_report_file "$RM_LOG" "$ROOT/reports/readme-commands.txt"
        fi
        if [[ -f "$HOME/.agents/skills/rea-build-guard/scripts/guard.py" ]]; then
            echo "==> [release] Running rea-build-guard on build/ChronoMac.app..."
            python3 "$HOME/.agents/skills/rea-build-guard/scripts/guard.py" \
                "$ROOT/build/ChronoMac.app" \
                --out "$TMP_TEST_ROOT/build-guard"
        fi
        if [[ "${CHRONOMAC_LONG_RUN:-0}" == "1" ]]; then
            echo "==> [release] Running long-run differential checks..."
            if [[ -x "$ROOT/Scripts/acceptance/m1-differential.sh" ]]; then
                "$ROOT/Scripts/acceptance/m1-differential.sh"
            else
                echo "Error: m1-differential.sh not yet available in M0." >&2
                exit 1
            fi
        else
            echo "==> [release] Long-run 1h/7d differential checks: SKIPPED (CHRONOMAC_LONG_RUN!=1)"
        fi
        ;;
    *)
        usage
        ;;
esac
