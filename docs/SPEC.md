# ChronoMac Specification & Measurement Boundaries (`v0.2.0` / M0)

## 1. Scope by Milestone

| Milestone | Status | Scope |
|---|---|---|
| **M0 (`v0.2.0` honest baseline)** | Implemented & verified | Live 2s user-space sampling **while the ChronoMac window/menu bar app is open**; monotonic bucket-aligned 3-tier SQLite compaction (`2s` -> `15s` -> `60s`); hard on-disk storage cap (`sqlite + wal + shm <= maxDatabaseBytes`) with WAL checkpoint + page reclamation; loopback-isolated `nettop` delta parser; 1.0s two-tick calibrated `--cli status`; human-readable bilingual CLI (`--lang en\|zh`) + `--json`; honest `Memory Footprint (phys_footprint)` & `No permission` permission disclosure; injectable `SystemSamplerProtocol` with mutation-tested unit suites. |
| **M1 (Planned)** | Not in M0 | Headless background daemon (`chronomac record`) + optional `LaunchAgent` plist (`~/Library/LaunchAgents/io.github.zxu756.chronomac.plist`), continuous 7-day unattended verification, and 1h differential validation against `powermetrics`, `vm_stat`, and `netstat -ib`. |
| **M2 (Planned)** | Not in M0 | Extended forensic export, incident correlation, and workflow automation on top of the M1 daemon. |

## 2. Telemetry Sources & Exact Metrics

1. **Host CPU & Memory (`MachSystemSampler`)**:
   - Host CPU%: `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)` delta across all logical cores. In `--cli status`, two samples are taken `1.0s` apart (`sampleCalibratedHostState(interval: 1.0)`) so single-shot CLI invocations never return uncalibrated boot-average readings.
   - Host Memory: `HOST_VM_INFO64` (`active + wired + compressor` pages * `vm_kernel_page_size`) and `sysctl vm.swapusage`.
   - Thermal state: `ProcessInfo.processInfo.thermalState`.
2. **Per-Process CPU, Footprint & Visibility (`ProcessTreeSampler`)**:
   - Process enumeration: `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0])` enumerates all user and root/system PIDs.
   - Executable path: `proc_pidpath`. When unavailable, `execPath` is stored as `""` (empty string), never substituted with short `pbi_comm` names.
   - CPU & Memory Footprint: `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)` (`ri_user_time + ri_system_time` Mach timebase delta and `ri_phys_footprint`).
   - Permission boundary: When `proc_pid_rusage` fails with `EPERM` (or PID `0` `kernel_task`), `isCPUReadable` is `false` (stored as `-1.0` sentinel in `process_snapshots.cpu_pct`) and rendered as `No permission` / `无权限`.
   - Rankings: Separate deterministic sort modes — `By CPU` (`cpu`), `By Memory` (`memory`), and `By Network` (`network`).
3. **Network & Loopback Isolation (`NettopDeltaParser`)**:
   - Invokes `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out` (uncollapsed socket mode, supporting `tcp4`, `tcp6`, `udp4`, `udp6`, `quic4`, `quic6` child rows as well as collapsed `-P` process-summary CSVs).
   - Loopback sockets (`interface == lo0`, `127.0.0.0/8`, `::1`, `fe80::1%lo0`) are accumulated exclusively into `loopbackRxBytesPerSec` / `loopbackTxBytesPerSec` (`system_ticks.loopback_in_bps` / `loopback_out_bps`) and excluded from external `net_in_bps`, `net_out_bps`, `socket_ledger`, and `AnomalyDetector`.
   - Tick 1 establishes the global baseline of all pre-existing open sockets (`delta = 0` on global baseline tick). Because `nettop` enumerates live kernel sockets via `NStatManager` (closed pre-baseline sockets carry `0` bytes into subsequent snapshots), processes and sockets newly appearing on Tick 2+ carry post-baseline bytes and are attributed on first sight rather than dropped to `0`. Residual limitations (ultra-short sockets opening and closing completely between two `2s` polls, or an unconnected UDP socket bound before Tick 1 that calls `connect()` after Tick 1) are scheduled for M1 interface differential calibration (`netstat -ib`).
4. **Local AI Agent Correlation (`AgentActivityBridge`)**:
   - Reads only file mtimes in `~/.claude/projects/<slug>/*.jsonl`, read-only `session.title` (<= 22 chars) + timestamps in `~/.local/share/opencode/opencode.db`, and read-only `threads.cwd` (basename) + timestamps in `~/.codex/state_5.sqlite`. Prompt/message bodies are never read.

## 3. SQLite Storage & Compaction Invariants (`FlightboxStore`)

- Schema initializes `PRAGMA auto_vacuum = INCREMENTAL;` prior to `PRAGMA journal_mode = WAL;` on new databases so page reclamation works natively.
- Sliding compaction (`compactTier`) only compacts buckets `[b_ts, b_ts + width)` where `b_ts + width <= cutoff` (`alignedCutoff = (cutoff / bucketSec) * bucketSec`), and merges via `ON CONFLICT(ts) DO UPDATE SET col = MAX(system_ticks.col, excluded.col)` so trailing rows can never overwrite an earlier peak.
- Retention measures `totalStorageBytes() = sqlite_bytes + wal_bytes + shm_bytes`, trims oldest rows across all tables without any 48-hour immunity window when `totalStorageBytes() > maxDatabaseBytes`, runs `VACUUM` / `PRAGMA incremental_vacuum`, and truncates WAL via `PRAGMA wal_checkpoint(TRUNCATE)`.
