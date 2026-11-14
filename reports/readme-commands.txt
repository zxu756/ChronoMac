========================================================================
Parsing & Replaying Fenced Code Blocks from README.md & README.zh-CN.md
========================================================================

[Step 1/3] Capturing live Flightbox snapshot via ChronoMonitor + FlightboxStore...
  -> Captured real host Flightbox: system_ticks=1, process_snapshots=51

[Step 2/3] Extracting and executing fenced bash/sh commands from README.md & README.zh-CN.md...
  -> Parity check OK: 13 shell commands + 1 MCP JSON block in each README.

--- README.md ---
  [SKIP] (README.md block #1) `brew tap zxu756/tap` — Reason: External Homebrew tap/cask install requires network and modifies host prefix
  [SKIP] (README.md block #1) `brew install --cask chronomac` — Reason: External Homebrew tap/cask install requires network and modifies host prefix
  [SKIP] (README.md block #2) `xattr -cr /Applications/ChronoMac.app` — Reason: Modifies /Applications outside workspace
  [SKIP] (README.md block #3) `git clone https://github.com/zxu756/ChronoMac.git` — Reason: External network git clone
  [SKIP] (README.md block #3) `cd ChronoMac` — Reason: Directory transition paired with skipped git clone
  [PASS] (README.md block #3) `./Scripts/test.sh scope Store Sampler CLI` -> exit=0 | Building for debugging...
  [SKIP] (README.md block #3) `./Scripts/build-app.sh` — Reason: Packages GUI .app bundle outside headless M0 verification
  [PASS] (README.md block #4) `ChronoMac --cli status --lang en` -> exit=0 | ChronoMac Flightbox: <TMP_DB>/flightbox.sqlite (ready · 1 samples in last 1h · Storage 108 KB)
  [PASS] (README.md block #4) `ChronoMac --cli status --json` -> exit=0 | JSON valid (cpuPct=23.6, dbExists=True)
  [PASS] (README.md block #4) `ChronoMac --cli blame --at 10m --sort cpu --lang en` -> exit=0 | Snapshot at 2026-11-15 09:36:11 (epoch 1794688571, 585s from requested time) · Ranking: By CPU
  [PASS] (README.md block #4) `ChronoMac --cli blame --at 10m --sort memory --json` -> exit=0 | JSON valid (sortBy=memory, memoryMetric=phys_footprint, processes=20)
  [PASS] (README.md block #4) `ChronoMac --cli anomalies --minutes 360 --lang en` -> exit=0 | ChronoMac Window Summary & Anomalies (last 360 min, 1 samples):
  [PASS] (README.md block #4) `ChronoMac --cli egress --hours 24 --lang en` -> exit=0 | Top External Socket Flows (last 24h, loopback excluded):

--- README.zh-CN.md ---
  [SKIP] (README.zh-CN.md block #1) `brew tap zxu756/tap` — Reason: External Homebrew tap/cask install requires network and modifies host prefix
  [SKIP] (README.zh-CN.md block #1) `brew install --cask chronomac` — Reason: External Homebrew tap/cask install requires network and modifies host prefix
  [SKIP] (README.zh-CN.md block #2) `xattr -cr /Applications/ChronoMac.app` — Reason: Modifies /Applications outside workspace
  [SKIP] (README.zh-CN.md block #3) `git clone https://github.com/zxu756/ChronoMac.git` — Reason: External network git clone
  [SKIP] (README.zh-CN.md block #3) `cd ChronoMac` — Reason: Directory transition paired with skipped git clone
  [PASS] (README.zh-CN.md block #3) `./Scripts/test.sh scope Store Sampler CLI` -> exit=0 | Building for debugging...
  [SKIP] (README.zh-CN.md block #3) `./Scripts/build-app.sh` — Reason: Packages GUI .app bundle outside headless M0 verification
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli status --lang zh` -> exit=0 | ChronoMac 飞行记录库: <TMP_DB>/flightbox.sqlite (就绪 · 最近 1 小时 1 条采样 · 磁盘占用 108 KB)
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli status --json` -> exit=0 | JSON valid (cpuPct=35.1, dbExists=True)
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli blame --at 10m --sort cpu --lang zh` -> exit=0 | 取自 2026-11-15 09:36:11 的快照（距所查时刻差 572 秒，epoch 1794688571） · 排序：按 CPU
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli blame --at 10m --sort memory --json` -> exit=0 | JSON valid (sortBy=memory, memoryMetric=phys_footprint, processes=20)
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli anomalies --minutes 360 --lang zh` -> exit=0 | ChronoMac 异常书签与窗口摘要（最近 360 分钟，共 1 条采样）：
  [PASS] (README.zh-CN.md block #4) `ChronoMac --cli egress --hours 24 --lang zh` -> exit=0 | 外部远程套接字流量账本（最近 24 小时，不含 127.0.0.1/::1 回环）：

[Step 3/3] Verifying MCP stdio server block from README.md & README.zh-CN.md...
  [PASS] (README.md JSON block #5) `ChronoMac --mcp` -> exit=0 | 5 JSON-RPC responses verified
  [PASS] (README.zh-CN.md JSON block #5) `ChronoMac --mcp` -> exit=0 | 5 JSON-RPC responses verified

Summary: passed=16, skipped=12, failed=0 (all skips with explicit reasons).

========================================================================
ALL PARSED README.md & README.zh-CN.md COMMANDS VERIFIED SUCCESSFULLY
========================================================================
