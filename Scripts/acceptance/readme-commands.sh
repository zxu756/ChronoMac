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
WORK_DIR="$TMP_RM/run-cwd"
mkdir -p "$WORK_DIR" "$TMP_RM/agent-home"

export CHRONOMAC_DB_PATH="$SEED_DB"
export CHRONOMAC_AGENT_HOME="$TMP_RM/agent-home"

swift build --product ChronoMac >/dev/null
BIN_DIR="$(cd "$(dirname "$ROOT/.build/debug/ChronoMac")" && pwd)"
export PATH="$BIN_DIR:$PATH"

echo "========================================================================"
echo "Parsing & Replaying Fenced Code Blocks from README.md & README.zh-CN.md"
echo "========================================================================"

echo ""
echo "[Step 1/3] Capturing live Flightbox snapshot via ChronoMonitor + FlightboxStore..."
CHRONOMAC_RUN_LIVE_SEED=1 CHRONOMAC_SEED_LIVE_DB="$SEED_DB" swift test --no-parallel --filter "ChronoMacCoreTests.CLITests/captureRealLiveFlightboxWhenRequested" >/dev/null
if [[ ! -f "$SEED_DB" ]]; then
    echo "FAIL: ChronoMonitor live capture did not create $SEED_DB" >&2
    exit 1
fi
LIVE_TICKS="$(/usr/bin/sqlite3 "$SEED_DB" "SELECT COUNT(*) FROM system_ticks;")"
LIVE_PROCS="$(/usr/bin/sqlite3 "$SEED_DB" "SELECT COUNT(*) FROM process_snapshots;")"
echo "  -> Captured real host Flightbox: system_ticks=$LIVE_TICKS, process_snapshots=$LIVE_PROCS"

echo ""
echo "[Step 2/3] Extracting and executing fenced bash/sh commands from README.md & README.zh-CN.md..."
/usr/bin/python3 - "$ROOT" "$WORK_DIR" "$SEED_DB" <<'PY'
import json
import os
import re
import subprocess
import sys

root_dir, work_dir, seed_db = sys.argv[1], sys.argv[2], sys.argv[3]

FENCE_RE = re.compile(r"```(bash|sh|json)\s*\n(.*?)```", re.DOTALL)

def parse_readme(rel_name):
    full = os.path.join(root_dir, rel_name)
    text = open(full, encoding="utf-8").read()
    blocks = FENCE_RE.findall(text)
    shell_cmds = []
    mcp_configs = []
    for block_idx, (lang, body) in enumerate(blocks, start=1):
        if lang in ("bash", "sh"):
            for raw in body.splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                shell_cmds.append((block_idx, line))
        elif lang == "json":
            parsed = json.loads(body)
            if "mcpServers" in parsed:
                mcp_configs.append((block_idx, parsed))
    return shell_cmds, mcp_configs

en_cmds, en_mcp = parse_readme("README.md")
zh_cmds, zh_mcp = parse_readme("README.zh-CN.md")

if len(en_cmds) != len(zh_cmds) or len(en_mcp) != len(zh_mcp):
    print(f"FAIL: README parity mismatch: EN cmds={len(en_cmds)} mcp={len(en_mcp)} vs ZH cmds={len(zh_cmds)} mcp={len(zh_mcp)}", file=sys.stderr)
    sys.exit(1)
print(f"  -> Parity check OK: {len(en_cmds)} shell commands + {len(en_mcp)} MCP JSON block in each README.")

SKIP_RULES = [
    (r"^brew\s+(tap|install)\b", "External Homebrew tap/cask install requires network and modifies host prefix"),
    (r"^xattr\s+-cr\s+/Applications/", "Modifies /Applications outside workspace"),
    (r"^git\s+clone\s+https://", "External network git clone"),
    (r"^cd\s+ChronoMac$", "Directory transition paired with skipped git clone"),
    (r"^\./Scripts/build-app\.sh$", "Packages GUI .app bundle outside headless M0 verification"),
]

def skip_reason(cmd):
    for pat, reason in SKIP_RULES:
        if re.search(pat, cmd):
            return reason
    return None

def assert_tokens(cmd, doc_name, out):
    if cmd.startswith("./Scripts/test.sh"):
        assert "[scope summary] unit_tests: passed=" in out and "skipped=" in out and "failed=0" in out, f"Missing separated pass/skip summary in test.sh output for {doc_name}:\n{out}"
        return

    if "--json" in cmd:
        data = json.loads(out)
        if "status" in cmd:
            assert data.get("cpuPct", 0.0) > 0.0, f"Expected cpuPct > 0 in {cmd}: {data}"
            assert data.get("dbExists") is True, f"Expected dbExists=true in {cmd}: {data}"
        elif "blame" in cmd:
            assert data.get("sortBy") == "memory", f"Expected sortBy=memory in {cmd}: {data}"
            assert data.get("memoryMetric") == "phys_footprint", f"Expected phys_footprint in {cmd}: {data}"
            assert len(data.get("processes", [])) > 0, f"Expected non-empty processes in {cmd}"
        return

    is_zh = ("--lang zh" in cmd)
    if "status" in cmd:
        if is_zh:
            for tok in ("ChronoMac 飞行记录库:", "实时主机 (1.0 秒双次采样校准) | CPU:"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
        else:
            for tok in ("ChronoMac Flightbox:", "Live Host (1.0s calibrated) | CPU:"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
    elif "blame" in cmd:
        if is_zh:
            for tok in ("取自 ", "的快照（距所查时刻差 ", "物理内存占用 (phys_footprint)", "仍在运行", "尖峰后已退出"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
        else:
            for tok in ("Snapshot at ", "from requested time)", "Memory Footprint (phys_footprint)", "still running", "exited after spike"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
    elif "anomalies" in cmd:
        if is_zh:
            for tok in ("ChronoMac 异常书签与窗口摘要", "峰值 CPU:", "峰值交换:", "峰值外部上行:"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
        else:
            for tok in ("ChronoMac Window Summary & Anomalies", "Peak CPU:", "Peak Swap:", "Peak External Outbound Egress:"):
                assert tok in out, f"Missing '{tok}' in {cmd} output:\n{out}"
    elif "egress" in cmd:
        if is_zh:
            assert ("回环" in out), f"Missing loopback isolation notice in {cmd} output:\n{out}"
        else:
            assert ("loopback" in out.lower()), f"Missing loopback isolation notice in {cmd} output:\n{out}"
    else:
        raise AssertionError(f"Unhandled README command without output assertion: {cmd}")

executed_count = 0
skipped_count = 0

for doc_name, cmds in (("README.md", en_cmds), ("README.zh-CN.md", zh_cmds)):
    print(f"\n--- {doc_name} ---")
    for block_idx, cmd in cmds:
        reason = skip_reason(cmd)
        if reason is not None:
            skipped_count += 1
            print(f"  [SKIP] ({doc_name} block #{block_idx}) `{cmd}` — Reason: {reason}")
            continue

        run_cwd = root_dir if cmd.startswith("./Scripts/") else work_dir
        env = os.environ.copy()
        env["CHRONOMAC_DB_PATH"] = seed_db
        res = subprocess.run(
            ["/bin/bash", "-lc", cmd],
            cwd=run_cwd,
            env=env,
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            print(f"FAIL: ({doc_name} block #{block_idx}) `{cmd}` exited with {res.returncode}\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}", file=sys.stderr)
            sys.exit(1)
        assert_tokens(cmd, doc_name, res.stdout)
        executed_count += 1
        if "--json" in cmd:
            parsed_json = json.loads(res.stdout)
            if "status" in cmd:
                summary = f"JSON valid (cpuPct={parsed_json.get('cpuPct')}, dbExists={parsed_json.get('dbExists')})"
            else:
                summary = f"JSON valid (sortBy={parsed_json.get('sortBy')}, memoryMetric={parsed_json.get('memoryMetric')}, processes={len(parsed_json.get('processes', []))})"
        else:
            summary = res.stdout.strip().splitlines()[0] if res.stdout.strip() else "(empty)"
            summary = re.sub(r"/[^\s]+/flightbox\.sqlite", "<TMP_DB>/flightbox.sqlite", summary)
        print(f"  [PASS] ({doc_name} block #{block_idx}) `{cmd}` -> exit=0 | {summary}")

print("\n[Step 3/3] Verifying MCP stdio server block from README.md & README.zh-CN.md...")
for doc_name, mcp_list in (("README.md", en_mcp), ("README.zh-CN.md", zh_mcp)):
    for block_idx, cfg in mcp_list:
        srv = cfg["mcpServers"]["chronomac"]
        mcp_args = srv["args"]
        assert "--mcp" in mcp_args, f"Expected --mcp in {doc_name} JSON config"
        payload = "\n".join([
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
            '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chrono_summary_window","arguments":{"minutes":360}}}',
            '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chrono_inspect_timestamp","arguments":{"minutes_ago":10,"sort_by":"cpu"}}}',
            '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"chrono_top_egress_endpoints","arguments":{"hours":24}}}',
        ]) + "\n"
        env = os.environ.copy()
        env["CHRONOMAC_DB_PATH"] = seed_db
        res = subprocess.run(
            ["ChronoMac"] + mcp_args,
            cwd=work_dir,
            env=env,
            input=payload,
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            print(f"FAIL: ({doc_name} MCP block #{block_idx}) exited {res.returncode}\n{res.stderr}", file=sys.stderr)
            sys.exit(1)
        lines = [ln for ln in res.stdout.splitlines() if ln.strip()]
        assert len(lines) == 5, f"Expected 5 JSON-RPC responses, got {len(lines)}"
        for tok in ("chrono_inspect_timestamp", "phys_footprint", "still running", "exited after spike"):
            assert tok in res.stdout, f"Missing '{tok}' in MCP output for {doc_name}"
        executed_count += 1
        print(f"  [PASS] ({doc_name} JSON block #{block_idx}) `ChronoMac {' '.join(mcp_args)}` -> exit=0 | 5 JSON-RPC responses verified")

print(f"\nSummary: passed={executed_count}, skipped={skipped_count}, failed=0 (all skips with explicit reasons).")
PY

echo ""
echo "========================================================================"
echo "ALL PARSED README.md & README.zh-CN.md COMMANDS VERIFIED SUCCESSFULLY"
echo "========================================================================"
