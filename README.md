# ChronoMac

**English** | **[简体中文](README.zh-CN.md)**

**macOS User-Space System Flight Recorder (`ChronoMac record` + Read-Only DVR UI), 5-Track Timeline & Calibrated External Socket Ledger**

`Activity Monitor` and `btop` only show *right now*—if your Mac thermal-throttles during a build, balloons into multi-gigabyte VM swap, or uploads hundreds of megabytes and the culprit child process exits minutes later, live monitors have already forgotten what happened.

**ChronoMac** (`v0.2.0` latest release; M0 + M1 work below marked **Unreleased (after `v0.2.0`)**) records host telemetry, top process blame snapshots (including short-lived processes that exit before you inspect them), physical-NIC-calibrated external TCP/UDP/QUIC socket deltas (with `"Unattributed"` residual accounting), and local AI coding agent session spans (`Claude Code`, `Codex CLI`, `OpenCode`) every 2 seconds via the headless **`ChronoMac record`** daemon (or in-app fallback when no daemon is running), storing history in a bounded SQLite WAL flightbox (`<= 250 MB` including `-wal`/`-shm`) in **100% non-root user space**—with zero kernel extensions (`KEXT`) or paid `NetworkExtension` entitlements, plus live **`中文 / EN`** bilingual switching (`⇧⌘L`).

![ChronoMac DVR Timeline & Process Socket Forensics (DEMO)](docs/screenshot-main.png)
> **`[DEMO]` Synthetic Preview Data**: The screenshot above is rendered from deterministic synthetic data (`ChronoMac --demo` — *Unreleased (after `v0.2.0`)* / `ChronoMonitor.preview()`) illustrating a simulated swap & outbound network incident.

---

## Verified Capabilities (`v0.2.0` + Unreleased M0/M1)

- **Headless `ChronoMac record` Daemon & Optional `LaunchAgent` Generator** *(Unreleased after `v0.2.0`)* — Run `ChronoMac record --db <path> --interval 2 --max-db-mb 250` continuously with the GUI closed (handling `SIGINT`/`SIGTERM` cleanly to flush SQLite WAL), or generate a `LaunchAgent` plist via `ChronoMac install-agent --print` / `--output <plist-path>` (never modifying `~/Library/LaunchAgents` implicitly). While `ChronoMac record` writes ticks, the SwiftUI DVR window, `--cli`, and `--mcp` query the SQLite WAL database read-only without lock contention.
- **Synchronized 5-Track DVR Oscilloscope (`TimelineScrubberCanvas`)** — Scrub across **1h / 6h / 24h / 7d** windows of recorded history to correlate SoC CPU & thermal state, host memory + VM swap, disk R/W throughput, external network throughput, and AI coding agent session windows.
- **Post-Mortem Process Blame & Exited-Process Archive (`blame` & `history`)** *(Unreleased after `v0.2.0`)* — Time-travel to any recorded timestamp (`blame --at` / `--epoch`) or query historical peak activity across any window (`history --minutes <N> --process <name>`), recovering short-lived child processes that already exited (`exited after spike` vs `still running`) alongside exact snapshot time offsets (`Snapshot at <ts> (<Y>s from requested time)`) and explicit **By CPU**, **By Memory**, or **By Network** (`--sort cpu|memory|network`) rankings.
- **Honest `Memory Footprint (phys_footprint)` & Non-Root Permission Boundaries (`T7`)** *(Unreleased after `v0.2.0`)* — Reports Mach `ri_phys_footprint` for same-UID processes (matching macOS Activity Monitor's *Memory* column). For userland system/root processes where `proc_pid_rusage` returns `EPERM` without `sudo` (such as `WindowServer` UID 88 and `launchd` UID 0), ChronoMac supplements CPU time/percentage and BSD `RSS` memory via `/bin/ps -axo pid=,pcpu=,rss=,time=`; `kernel_task` (`PID 0`) remains unreadable in user space and explicitly displays **`No permission`** instead of a fake `0.0%` reading (and non-root cannot read Mach `ri_phys_footprint` or per-PID disk I/O bytes for other-UID processes).
- **Physical-NIC-Calibrated External Socket Ledger & `"Unattributed"` Residual** *(Unreleased after `v0.2.0`)* — Calibrates total external inbound/outbound throughput against active physical link-layer counters (`/usr/sbin/netstat -ibn`, excluding `lo0` loopback and virtual tunnel/bridge interfaces) paired with `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out` per-socket deltas. Any positive gap between physical NIC byte deltas and attributed per-process `nettop` sockets (e.g., short-lived connections closing between 2s polls or kernel/first-tick residual) is recorded explicitly under **`Unattributed`** (`PID -1`) and **never smeared proportionally across unrelated processes**. Loopback traffic (`127.0.0.0/8`, `::1`, `lo0`) stays isolated in its own counter and never enters external totals or outbound anomaly alerts.
- **Peak-Preserving 3-Tier Compaction & Global Oldest-First Hard Cap** *(Unreleased after `v0.2.0`)* — Keeps raw `2s` ticks for 2 hours, compacts completed buckets into monotonic peak-preserving `15s` (2h–24h) and `60s` (24h–7d) rollups (`ON CONFLICT DO UPDATE SET ... MAX(...)`), and enforces `sqlite + wal + shm <= maxDatabaseBytes` (default `250 MB`) using global oldest-first timestamp pruning across all four tables (`process_snapshots`, `system_ticks`, `socket_ledger`, `anomaly_bookmarks`) with `PRAGMA incremental_vacuum` and `PRAGMA wal_checkpoint(TRUNCATE)`.
- **Calibrated Human-Readable CLI (`--cli`) & Read-Only MCP Server (`--mcp`)** *(Unreleased after `v0.2.0`)* — `ChronoMac --cli status` samples Mach CPU load ticks twice `1.0s` apart; `status`, `blame`, `history`, `anomalies`, and `egress` emit human-readable tables in English or Simplified Chinese (`--lang en|zh`) or structured JSON (`--json`), opening SQLite strictly read-only (`--db <path>` or `CHRONOMAC_DB_PATH`).
- **Live `中文 / EN` Bilingual UI** — Auto-detects Chinese macOS locale on first launch and switches instantaneously via the `中文 | EN` pill, `⇧⌘L`, or `--lang zh|en`.

<p align="center">
  <img src="docs/screenshot-menubar.png" width="414" alt="ChronoMac Menu Bar Flightbox (DEMO)" />
</p>
<p align="center"><em><code>[DEMO]</code> Menu bar popover rendered from synthetic preview telemetry (<code>ChronoMonitor.preview()</code>).</em></p>

---

## Recording Scope, Self-Overhead & Roadmap

- **Headless Background Recorder (`ChronoMac record`, Unreleased M1)**: Samples and persists 2-second ticks independently of the SwiftUI window. When `ChronoMac record` is running, the GUI opens `flightbox.sqlite` read-only as a pure DVR viewer; if no external daemon is writing new ticks, the GUI falls back to in-app sampling while open.
- **Recorder Self-Overhead Budget & Empirical Measurements (`2026-11-15`, `macOS 27.0.1 (26A434)`, Apple Silicon `arm64`)**:
  - **Enforced self-overhead ceiling**: `self CPU avg <= 2.0%` of one core (`process-tree CPU avg <= 8.0%` of one core including `nettop -L 1`, `/bin/ps`, and `/usr/sbin/netstat -ibn` child polls every 2s), memory `phys_footprint <= 50 MiB` (`RSS <= 60 MiB`).
  - **Measured 10-minute post-`autoreleasepool` run (`604s`, `303` ticks, `reports/m1-differential.txt`)**: daemon self CPU `avg=0.86%` (`max=3.94%`), total process-tree CPU `avg=4.38%` (`max=11.05%`), `phys_footprint` `mean=8.26 MiB` (`max=13.05 MiB`), `RSS` `mean=17.51 MiB` (`max=22.62 MiB`), with `300/300` (`100.00%`) aligned 2s points within `<= 10%` of `iostat` (`max=0.96 pp`), `vm_stat` (`max=0.30%`), and `sysctl vm.swapusage` (`max=0.00%`).
  - **Measured 1-hour continuous run (`3,602s`, `1,801` ticks, `96,837` process snapshots, `0` gaps `> 10s`, `max_gap=5s`, `reports/m1-record-1h.txt`)**: daemon self CPU `avg=0.93%` (`max=6.50%`), total process-tree CPU `avg=4.64%` (`p95=6.08%`, `max=13.24%`), `RSS` `mean=20.74 MiB` (`max=37.03 MiB`); before wrapping `FlightboxRecorder.runLoop` ticks in `autoreleasepool` + `PRAGMA cache_size = -4096`, un-drained Objective-C `Pipe` buffers pushed 1h `phys_footprint` to `mean=78.59 MiB` (`max=148.61 MiB`), now bounded at `mean=8.26 MiB` / `max=13.05 MiB` (verified by `m1RecordLoopDrainsAutoreleasePoolPerTick`).
- **Validation Coverage**: 1-hour continuous headless recording (`Scripts/acceptance/m1-record-1h.sh`, `1,800` ticks @ `2s`, `0` gaps `> 10s`) and 10-minute 300-point differential verification against `iostat`, `vm_stat`, `sysctl vm.swapusage`, and `netstat -ibn` (`Scripts/acceptance/m1-differential.sh`). Continuous 7-day wall-clock run (`M1 Row 6`) and live external internet 40 MB download (`M1 Row 4`, gated behind `CHRONOMAC_LIVE_DOWNLOAD_URL` under offline acceptance rules) are documented honestly in `reports/`.
- **Planned (M2)**: Extended causal attribution (`chronomac why`) and session correlation workflows on top of the M1 flightbox.

See [docs/SPEC.md](docs/SPEC.md) for architecture, schema, and measurement specifications.

---

## Install (`v0.2.0`)

### Homebrew Cask (macOS 14.0+, Apple Silicon)

```bash
brew tap zxu756/tap
brew install --cask chronomac
```

### Direct Release Archive

Download `ChronoMac-v0.2.0-macos-arm64.zip` from Releases, move `ChronoMac.app` to `/Applications`, and clear quarantine if needed:

```bash
xattr -cr /Applications/ChronoMac.app
```

### Build & Test from Source

> Note: `./Scripts/test.sh` is **Unreleased (after `v0.2.0`)** on source builds.

```bash
git clone https://github.com/zxu756/ChronoMac.git
cd ChronoMac
./Scripts/test.sh scope Store Sampler CLI
./Scripts/build-app.sh
```

---

## CLI & MCP Server Usage

### Headless Recorder & Read-Only CLI (`record`, `install-agent`, `--cli`)

> **Release note (`v0.2.0` vs Unreleased)**: `v0.2.0` introduced `--cli` (`status`, `blame --at`, `anomalies`, `egress`), `--mcp`, and `--lang en|zh`. Headless `record`, `install-agent`, `history`, read-only SQLite isolation (`--db <path>`, `CHRONOMAC_DB_PATH`), `1.0s` calibrated `status`, human-readable table formatting, `--json`, `--sort cpu|memory|network`, `--minutes <N>`, `--hours <N>`, `--help`, and exit code `2` on invalid flags/subcommands are **Unreleased (after `v0.2.0`)**.

Read-only `--cli` commands open SQLite strictly **read-only** (`--db <path>` or `CHRONOMAC_DB_PATH`, defaulting to `~/Library/Application Support/ChronoMac/flightbox.sqlite`), while `ChronoMac record` writes continuous 2s ticks and flushes WAL cleanly on `SIGINT`/`SIGTERM`. Unknown flags or subcommands print an error to `stderr` and exit with code `2`.

```bash
# Run headless 2s flight recorder (omit --duration to run continuously until SIGINT/SIGTERM)
ChronoMac record --duration 4 --interval 2 --max-db-mb 250 --no-dns --lang en

# Print optional LaunchAgent plist XML to stdout (never touches ~/Library/LaunchAgents)
ChronoMac install-agent --print

# Calibrated live host readout (two CPU ticks 1.0s apart) + flightbox status
ChronoMac --cli status --lang en

# Structured JSON host readout
ChronoMac --cli status --json

# Inspect historical process blame 10 minutes ago (ranked by CPU, memory, or network)
ChronoMac --cli blame --at 10m --sort cpu --lang en
ChronoMac --cli blame --at 10m --sort memory --json

# Query historical process archive (including short-lived processes that already exited)
ChronoMac --cli history --minutes 60 --sort cpu --lang en

# Summarize window peaks & recorded anomaly bookmarks over the last 6h (360m)
ChronoMac --cli anomalies --minutes 360 --lang en

# List top external socket endpoints over the last 24h (loopback excluded, Unattributed shown)
ChronoMac --cli egress --hours 24 --lang en
```

### Model Context Protocol (`--mcp`)

Add `ChronoMac` to Claude Code, Codex, or OpenCode so your agent can query recorded spikes read-only over stdio:

```json
{
  "mcpServers": {
    "chronomac": {
      "command": "/Applications/ChronoMac.app/Contents/MacOS/ChronoMac",
      "args": ["--mcp"]
    }
  }
}
```

Exposed read-only MCP tools:
- `chrono_summary_window` — Peak CPU, swap, external outbound egress, and anomaly bookmarks in the last `N` minutes.
- `chrono_inspect_timestamp` — Top process snapshot near `epoch_seconds` or `minutes_ago` (`sort_by`: `cpu`, `memory`, or `network`), reporting exact snapshot delta seconds, `Memory Footprint (phys_footprint)`, `No permission` for restricted system processes, and `still running` vs `exited after spike`.
- `chrono_top_egress_endpoints` — Highest-volume external remote endpoints (loopback excluded) over the last `N` hours.

---

## Storage & Privacy Architecture

- **Default database path**: `~/Library/Application Support/ChronoMac/flightbox.sqlite` (override via `--db <path>` or `CHRONOMAC_DB_PATH` for isolated testing).
- **100% local, zero network telemetry**: All Mach VM/CPU counters, `proc_pid_rusage` footprints, `nettop` deltas, and local `getnameinfo` PTR lookups remain strictly on local disk.
- **Exact AI coding agent metadata read (read-only)**:
  - **Claude Code (`~/.claude/projects/<slug>/*.jsonl`)**: Reads directory listing modification timestamps and parent folder slug only; `.jsonl` conversation files are never opened or parsed.
  - **OpenCode (`~/.local/share/opencode/opencode.db`)**: Opens SQLite with `SQLITE_OPEN_READONLY` and reads `session.title` (truncated to 22 characters) and `time_created` / `time_updated` timestamps as timeline labels.
  - **Codex CLI (`~/.codex/state_5.sqlite`)**: Opens SQLite with `SQLITE_OPEN_READONLY` and reads `threads.cwd` (last path component directory name) and `created_at` / `updated_at` timestamps as timeline labels.
  - Prompt bodies, model responses, API keys, and repository source files are **never** read.

## License

MIT License — see [LICENSE](LICENSE).
