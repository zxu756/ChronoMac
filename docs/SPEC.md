# ChronoMac Specification & Measurement Boundaries (`v0.4.0` = M0 + M1)

## 1. Scope by Milestone

| Milestone | Status | Scope |
|---|---|---|
| **M0 (`v0.3.0` honest baseline)** | Implemented & verified | Live 2s user-space sampling; monotonic bucket-aligned 3-tier SQLite compaction (`2s` -> `15s` -> `60s`); hard on-disk storage cap (`sqlite + wal + shm <= maxDatabaseBytes`) with WAL checkpoint + page reclamation; loopback-isolated `nettop` delta parser; 1.0s two-tick calibrated `--cli status`; human-readable bilingual CLI (`--lang en\|zh`) + `--json`; honest `Memory Footprint (phys_footprint)` & `No permission` permission disclosure; injectable `SystemSamplerProtocol` with mutation-tested unit suites. |
| **M1 (`v0.4.0`)** | Implemented (1h headless + 10m 300-point differential verified; 7d wall-clock & live external 40 MB download documented honestly) | Headless background flight recorder (`ChronoMac record`) + optional `LaunchAgent` plist generator (`ChronoMac install-agent --print` / `--output`); concurrent read-only DVR UI & CLI (`--cli history`); physical NIC link-layer calibration (`/usr/sbin/netstat -ibn`) with `"Unattributed"` / `"未归属"` residual accounting; non-root `T7` `/bin/ps` CPU/RSS supplement for userland root/system processes (`WindowServer`, `launchd`) with explicit `kernel_task` (`PID 0`) boundary; global oldest-first hard-cap pruning across all 4 SQLite tables. |
| **M2 (Planned)** | Not in M1 | Causal query workflow (`chronomac why`), deeper agent session correlation, and incident export on top of the M1 flightbox. |

## 2. Telemetry Sources & Exact Metrics

1. **Host CPU, Memory & Swap (`MachSystemSampler`)**:
   - Host CPU%: `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)` delta across all logical cores (`0..100%` total host capacity scale, matching `iostat` and `top`). In `--cli status`, two samples are taken `1.0s` apart (`sampleCalibratedHostState(interval: 1.0)`) so single-shot CLI invocations never return uncalibrated boot-average readings.
   - Host Memory: `HOST_VM_INFO64` (`active + wired + compressor` pages * `vm_kernel_page_size`, matching `vm_stat`).
   - Host Swap: C `sysctlbyname("vm.swapusage", ...)` (`xsw_usage.xsu_used`, with `/usr/sbin/sysctl -n vm.swapusage` fallback).
   - Thermal state: `ProcessInfo.processInfo.thermalState`.
2. **Per-Process CPU, Footprint & Non-Root Visibility (`ProcessTreeSampler`, `T7`)**:
   - Process enumeration: `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0])` enumerates all user and root/system PIDs.
   - Executable path: `proc_pidpath`. When unavailable, `execPath` is stored as `""` (empty string), never substituted with short `pbi_comm` names.
   - Same-UID CPU & Memory Footprint: `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)` (`ri_user_time + ri_system_time` Mach timebase delta, `ri_phys_footprint`, and per-PID disk I/O bytes).
   - Non-root cross-UID supplement (`T7` empirical finding on `macOS 27.0.1`): When `proc_pid_rusage` fails with `EPERM` on processes owned by other UIDs (`_windowserver` UID 88 `WindowServer`, `root` UID 0 `launchd`), `ProcessTreeSampler` invokes `LC_ALL=C /bin/ps -axo pid=,pcpu=,rss=,time=` without `sudo` to compute cumulative CPU-time deltas (falling back to instantaneous `%cpu` on first sight) and BSD `RSS` bytes.
   - Non-root kernel & metric boundaries: `kernel_task` (`PID 0`) is a Mach kernel task not readable via `proc_pid_rusage` or `/bin/ps` without root, so `isCPUReadable` remains `false` (`-1.0` sentinel in `process_snapshots.cpu_pct`), rendered explicitly as `No permission` / `无权限`. For cross-UID processes (`WindowServer`, `launchd`), non-root cannot read Mach `ri_phys_footprint` or per-PID disk I/O bytes, so BSD `RSS` is reported as memory fallback.
   - Code-signing cache optimization: `SecCodeCopySigningInformation` runs lazily only on merged top CPU/memory/network candidate PIDs rather than every background PID on the system.
3. **Physical NIC Calibration, `"Unattributed"` Residual & Loopback Isolation (`PhysicalNICCounterReader` + `NettopDeltaParser`)**:
   - **Empirical XNU discovery (`macOS 27.0.1`, `26A434`)**: For unentitled third-party binaries, XNU truncates (`mod 2^32`) and 1-KiB-coarsens `NET_RT_IFLIST2` / `getifaddrs(AF_LINK)` `ifi_ibytes` and `ifi_obytes` link counters, whereas Apple-signed `/usr/sbin/netstat -ibn` returns exact uncoarsened 64-bit `<Link#N>` byte counters in ~3.8 ms with zero DNS and zero root privileges. `PhysicalNICCounterReader` therefore uses `/usr/sbin/netstat -ibn` as primary source (with `NET_RT_IFLIST2` fallback), summing active physical interfaces (`en*`, etc.) while strictly excluding `lo*` loopback and virtual/tunnel/bridge interfaces (`utun*`, `awdl*`, `llw*`, `bridge*`, `gif*`, `stf*`, `ap*`, `anpi*`, `vmnet*`, `feth*`, `pktap*`) to prevent double-counting traffic that traverses `en0`.
   - Per-socket attribution: `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out` attributes TCP/UDP/QUIC socket deltas to owning PIDs while isolating `lo0` / `127.0.0.0/8` / `::1` into `loopback_in_bps` and `loopback_out_bps`.
   - `"Unattributed"` / `"未归属"` residual: On every post-baseline tick, external `totalInBps` and `totalOutBps` equal the calibrated physical NIC counter rate (`nicDeltaBytes / dt`). Any positive residual `max(0, nicDeltaBytes - sum(perPIDExtBytes))` (from short-lived sockets opening and closing between 2s polls, kernel traffic, or socket reuse) is attributed to synthetic `PID -1` (`__chronomac_unattributed__` -> rendered as `Unattributed` in EN and `未归属` in ZH) in both `process_snapshots` and `socket_ledger`, and is **never proportionally distributed across unrelated processes**.
4. **Headless Daemon & Read-Only DVR Concurrency (`FlightboxRecorder` + `ChronoMonitor`)**:
   - `ChronoMac record` runs a monotonic-deadline 2s loop (`DispatchSemaphore` wait, zero busy-polling) and installs `SIGINT`/`SIGTERM` `DispatchSourceSignal` handlers that flush SQLite WAL (`PRAGMA wal_checkpoint(PASSIVE)`) before exit.
   - `ChronoMonitor` opens `flightbox.sqlite` read-only (`SQLITE_OPEN_READONLY`) when viewing recorded history and only starts an internal writer fallback if no external `ChronoMac record` daemon has written a tick within the staleness window.
5. **Local AI Agent Correlation (`AgentActivityBridge`)**:
   - Reads only file mtimes in `~/.claude/projects/<slug>/*.jsonl`, read-only `session.title` (<= 22 chars) + timestamps in `~/.local/share/opencode/opencode.db`, and read-only `threads.cwd` (basename) + timestamps in `~/.codex/state_5.sqlite`. Prompt/message bodies are never read.

## 3. SQLite Storage, Compaction & Global Oldest-First Pruning (`FlightboxStore`)

- Schema initializes `PRAGMA auto_vacuum = INCREMENTAL;` prior to `PRAGMA journal_mode = WAL;` on new databases so page reclamation works without full-DB `VACUUM` thrashing.
- Both single-tick ingestion (`insertTick`) and sliding compaction (`compactTier`) merge via `ON CONFLICT(ts) DO UPDATE SET col = MAX(system_ticks.col, excluded.col)` on completed buckets (`alignedCutoff = (cutoff / bucketSec) * bucketSec`).
- When `totalStorageBytes() = sqlite_bytes + wal_bytes + shm_bytes > maxDatabaseBytes`, `runRollupAndRetention` computes the global 20th-percentile oldest timestamp across `UNION ALL` of `process_snapshots.ts`, `system_ticks.ts`, `socket_ledger.last_seen`, and `anomaly_bookmarks.ts`, deleting only rows `<= cutoffTs` globally so brand-new anomalies and socket flows are never wiped by older process-snapshot bulk, followed by `PRAGMA incremental_vacuum;` + `PRAGMA wal_checkpoint(TRUNCATE);` (completing 10 MB -> 2 MB pruning in `< 0.8s`).
