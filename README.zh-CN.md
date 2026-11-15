# ChronoMac

**[English](README.md)** | **简体中文**

**macOS 用户态系统飞行记录仪（`ChronoMac record` 后台守护录制 + 只读 DVR 界面）· 五轨示波时间轴与物理网卡校准外联账本**

系统自带的「活动监视器」与 `btop` 只能看到**此时此刻**——如果你的 Mac 在编译期间突然热压降频、虚拟内存交换区暴涨数 GB，或子进程上传数百 MB 数据后在几分钟内自动退出，传统实时监视器早已忘记事发现场。

**ChronoMac**（最新已发版 `v0.2.0`；下方 M0 + M1 项均标注为 **未发布（`v0.2.0` 之后）**）在 **100% 普通用户态（免 Root、零内核扩展 `KEXT`、无需付费 `NetworkExtension` 权限）** 下，通过无界面后台录制进程 **`ChronoMac record`**（未启动外部守护进程时界面自动回退为前台采样）每 2 秒采集一次主机遥测、历史进程追责快照（含早已退出的短命子进程）、经物理网卡计数器校准的外部 TCP/UDP/QUIC 套接字增量（差额单列为 `未归属`）与本地 AI 编程代理活跃时段（`Claude Code`、`Codex CLI`、`OpenCode`），写入严格受控的 SQLite WAL 时序飞行匣（含 `-wal`/`-shm` 默认总上限 `<= 250 MB`），并原生内置 **`中文 / EN` 双语实时切换**（`⇧⌘L`）。

![ChronoMac 五轨 DVR 时间轴与进程外联网络取证界面 (DEMO)](docs/screenshot-main-zh.png)
> **`[DEMO / 演示数据]` 说明**：上方截图由确定性合成演示数据（`ChronoMac --demo` —— *未发布（`v0.2.0` 之后）* / `ChronoMonitor.preview()`）渲染生成，用于展示模拟的交换激增与外联流量异常回放效果。

---

## 已验证核心特性 (`v0.2.0` + 未发布 M0/M1)

- **无界面后台录制守护进程 (`ChronoMac record`) 与可选 `LaunchAgent` 生成器** *（未发布，`v0.2.0` 之后）* — 关闭桌面主界面后仍可通过 `ChronoMac record --db <路径> --interval 2 --max-db-mb 250` 连续采样落盘（收到 `SIGINT`/`SIGTERM` 时安全刷盘关闭 WAL），并可通过 `ChronoMac install-agent --print` / `--output <plist路径>` 生成合法 `LaunchAgent` 配置（绝不自动改动 `~/Library/LaunchAgents`）。守护进程写入期间，SwiftUI 桌面时间轴、`--cli` 与 `--mcp` 均以只读模式无锁并发查询同一份 SQLite WAL 数据库。
- **五轨同步 DVR 示波时间轴 (`TimelineScrubberCanvas`)** — 在已录制的 **1小时 / 6小时 / 24小时 / 7天** 历史窗口内拖拽回放，同屏对照芯片 CPU 与温控状态、主机内存与虚拟交换区、磁盘读写吞吐、外部网络上下行速率与 AI 编程代理会话窗口。
- **支持已退出短命子进程的历史追责与归档 (`blame` 与 `history`)** *（未发布，`v0.2.0` 之后）* — 回溯任意历史时刻（`blame --at` / `--epoch`）或检索窗口内出现过的历史进程峰值（`history --minutes <N> --process <名称>`），精准还原早已退出的短命子进程及其 CPU 尖峰（逐行标注 **`尖峰后已退出`** 或 **`仍在运行`**）与秒级时间偏差（`取自 <时间> 的快照（距所查时刻差 <Y> 秒）`），支持 **按 CPU / 按内存 / 按网络**（`--sort cpu|memory|network`）三种显式排序维度。
- **准确的 `物理内存占用 (phys_footprint)` 与非 Root 权限边界 (`T7`)** *（未发布，`v0.2.0` 之后）* — 对当前用户进程报告 Mach `ri_phys_footprint`（与 macOS「活动监视器」“内存”列一致）。对于无 `sudo` 时 `proc_pid_rusage` 返回 `EPERM` 的系统/Root 用户态进程（如 `WindowServer` UID 88、`launchd` UID 0），通过 `/bin/ps -axo pid=,pcpu=,rss=,time=` 补齐 CPU 时间/百分比与 BSD `RSS` 内存；内核任务 `kernel_task`（`PID 0`）在普通用户态下不可读取，界面与 CLI 均明确标注 **`无权限`** 而不伪造 `0.0%`（普通用户态亦无法读取跨 UID 进程的 Mach `ri_phys_footprint` 与单进程磁盘读写字节）。
- **物理网卡计数器校准的外部套接字账本与 `未归属` 差额** *（未发布，`v0.2.0` 之后）* — 将活跃物理网卡链路层累计字节增量（`/usr/sbin/netstat -ibn`，严格排除 `lo0` 回环及虚拟隧道/网桥接口）与 `/usr/bin/nettop -L 1 -n -J interface,state,bytes_in,bytes_out` 逐套接字增量对账校准：物理网卡总增量与已归属进程套接字之和的差额（如两次 2 秒轮询之间闪现即关的短连接或内核/首拍残差）如实单列为 **`未归属`**（`PID -1`），**绝不按比例平摊到其他无关进程头上**。本机回环流量（`127.0.0.0/8`、`::1`、`lo0`）单独计入回环计数器，绝不混入外部总流量或触发外联异常告警。
- **峰值无损保留的三级压缩与全局最旧优先硬上限清理** *（未发布，`v0.2.0` 之后）* — 近 2 小时保留 `2s` 原始采样；整桶跨过阈值后聚合为 `15s`（2–24 小时）与 `60s`（24 小时–7 天）单调峰值分桶（`ON CONFLICT DO UPDATE SET ... MAX(...)`）；超体积上限时按四张表全局时间戳最旧优先裁剪（不按单表一刀切误删最新异常与外联记录），配合 `PRAGMA incremental_vacuum` 与 `PRAGMA wal_checkpoint(TRUNCATE)` 严格保证 `sqlite + wal + shm <= maxDatabaseBytes`（默认 `250 MB`）。
- **双次校准采样的人类可读 CLI (`--cli`) 与只读 MCP 服务 (`--mcp`)** *（未发布，`v0.2.0` 之后）* — `ChronoMac --cli status` 以 `1.0` 秒间隔连续采样两次 Mach CPU 计数器；`status`、`blame`、`history`、`anomalies`、`egress` 输出清晰的中英文表格（`--lang zh|en`）或 `--json`，支持 `--db <path>` / `CHRONOMAC_DB_PATH` 只读数据库隔离。
- **原生 `中文 / EN` 双语界面** — 首次启动自动识别中文 macOS 系统语言，支持顶栏/菜单栏 `中文 | EN` 胶囊、`⇧⌘L` 快捷键或 `--lang zh|en` 实时切换。

<p align="center">
  <img src="docs/screenshot-menubar-zh.png" width="414" alt="ChronoMac 菜单栏飞行匣中文界面 (DEMO)" />
</p>
<p align="center"><em><code>[DEMO / 演示数据]</code> 菜单栏弹窗截图同样由合成预览数据（<code>ChronoMonitor.preview()</code>）生成。</em></p>

---

## 录制范围、自身开销与里程碑路线图

- **无界面后台守护录制 (`ChronoMac record`，未发布 M1)**：独立于 SwiftUI 窗口每 2 秒采样落盘。当外部 `ChronoMac record` 正在写入时，桌面界面以纯只读模式打开 `flightbox.sqlite` 充当历史回放器；若未运行外部守护进程，桌面界面开启期间自动回退为前台采样。
- **录制进程自身开销上限与实测数据 (`2026-11-15`，`macOS 27.0.1 (26A434)`，Apple Silicon `arm64`)**：
  - **验收强制上限**：守护进程自身平均 CPU <= 2.0%（单核口径；含每 2 秒 `nettop -L 1`、`/bin/ps`、`/usr/sbin/netstat -ibn` 子进程总平均 CPU <= 8.0%），内存占用 `phys_footprint <= 50 MiB`（`RSS <= 60 MiB`）。
  - **10 分钟实测（加每拍 `autoreleasepool` 与 `PRAGMA cache_size = -4096` 修复后，`604s`、`303` 条采样，`reports/m1-differential.txt`）**：守护进程自身 CPU `avg=0.86%`（`max=3.94%`），含采样工具子进程总 CPU `avg=4.38%`（`max=11.05%`），`phys_footprint` `mean=8.26 MiB`（`max=13.05 MiB`），`RSS` `mean=17.51 MiB`（`max=22.62 MiB`）；300 个 2 秒对齐点与 `iostat`（`max=0.96 pp`）、`vm_stat`（`max=0.30%`）、`sysctl vm.swapusage`（`max=0.00%`）联合达标率 `300/300`（`100.00%`）。
  - **1 小时无界面连续录制实测（`3,602s`、`1,801` 条采样、`96,837` 条进程快照、零 `> 10s` 空洞、`max_gap=5s`，`reports/m1-record-1h.txt`）**：守护进程自身 CPU `avg=0.93%`（`max=6.50%`），含子进程总 CPU `avg=4.64%`（`p95=6.08%`、`max=13.24%`），`RSS` `mean=20.74 MiB`（`max=37.03 MiB`）；在首轮 1 小时压测定位到 CLI 线程未逐拍释放 Objective-C `Pipe` 自动释放池之前，`phys_footprint` 曾累积至 `mean=78.59 MiB`（`max=148.61 MiB`），补齐逐拍 `autoreleasepool` 后稳定在 `mean=8.26 MiB` / `max=13.05 MiB`（由 `m1RecordLoopDrainsAutoreleasePoolPerTick` 回归锁死）。
- **当前验证覆盖范围**：已完成 1 小时无界面连续录制（`Scripts/acceptance/m1-record-1h.sh`，`1,800` 条 2 秒采样，零 `> 10s` 空洞）与 10 分钟 300 点同机对账（`Scripts/acceptance/m1-differential.sh`，对比 `iostat`、`vm_stat`、`sysctl vm.swapusage` 与 `netstat -ibn`）。连续 7 天墙钟长跑（`M1 Row 6`）与真实外网 40 MB 下载（`M1 Row 4`，受离线不联网规则约束，默认由 `CHRONOMAC_LIVE_DOWNLOAD_URL` 显式开关保护）在 `reports/` 中如实标注。
- **规划中（M2）**：在已校准的后台飞行匣之上扩展因果归因（`chronomac why`）与会话联动工作流。

详见 [docs/SPEC.md](docs/SPEC.md) 了解架构、表结构与指标口径说明。

---

## 安装指南 (`v0.2.0`)

### Homebrew Cask（macOS 14.0+，Apple Silicon）

```bash
brew tap zxu756/tap
brew install --cask chronomac
```

### 下载发行压缩包

从 Releases 下载 `ChronoMac-v0.2.0-macos-arm64.zip`，将 `ChronoMac.app` 拖入 `/Applications`，首次打开如遇隔离提示可执行：

```bash
xattr -cr /Applications/ChronoMac.app
```

### 从源码构建与测试

> 注：`./Scripts/test.sh` 为**未发布（`v0.2.0` 之后）**的源码仓库测试入口。

```bash
git clone https://github.com/zxu756/ChronoMac.git
cd ChronoMac
./Scripts/test.sh scope Store Sampler CLI
./Scripts/build-app.sh
```

---

## 命令行与 MCP 服务器用法

### 后台录制守护进程与无界面只读 CLI (`record`, `install-agent`, `--cli`)

> **版本标注（`v0.2.0` vs 未发布）**：`v0.2.0` 已包含 `--cli`（`status`、`blame --at`、`anomalies`、`egress`）、`--mcp` 与 `--lang zh|en`；后台录制 `record`、自启生成器 `install-agent`、历史归档 `history`、只读数据库路径隔离（`--db <path>`、`CHRONOMAC_DB_PATH`）、`1.0s` 双次校准 `status`、人类可读表格输出、`--json`、`--sort cpu|memory|network`、`--minutes <N>`、`--hours <N>`、`--help` 以及未知参数退出码 `2` 均为**未发布（`v0.2.0` 之后）**。

所有 `--cli` 查询子命令均以**只读模式**打开 SQLite 数据库（可通过 `--db <path>` 或环境变量 `CHRONOMAC_DB_PATH` 指定路径，默认读取 `~/Library/Application Support/ChronoMac/flightbox.sqlite`）；`ChronoMac record` 负责每 2 秒写入采样并在收到 `SIGINT`/`SIGTERM` 时安全刷盘。遇到未知子命令或非法参数时向 `stderr` 输出错误并以退出码 `2` 退出。

```bash
# 运行每 2 秒一次的无界面后台录制（省略 --duration 则持续运行直至收到 SIGINT/SIGTERM）
ChronoMac record --duration 4 --interval 2 --max-db-mb 250 --no-dns --lang zh

# 向 stdout 输出可选的 LaunchAgent plist XML（不会自动写入 ~/Library/LaunchAgents）
ChronoMac install-agent --print

# 双次采样校准（间隔 1.0 秒）的实时主机读数与飞行匣状态
ChronoMac --cli status --lang zh

# 输出结构化 JSON 状态
ChronoMac --cli status --json

# 回溯 10 分钟前的历史进程追责快照（支持按 cpu / memory / network 排序）
ChronoMac --cli blame --at 10m --sort cpu --lang zh
ChronoMac --cli blame --at 10m --sort memory --json

# 检索历史进程归档（含尖峰后已退出的短命子进程）
ChronoMac --cli history --minutes 60 --sort cpu --lang zh

# 汇总近 6 小时（360 分钟）内的窗口峰值与异常书签
ChronoMac --cli anomalies --minutes 360 --lang zh

# 列出近 24 小时累计流量最高的外部远程端点（剔除本机回环，含未归属差额）
ChronoMac --cli egress --hours 24 --lang zh
```

### Model Context Protocol (`--mcp`)

将 `ChronoMac` 以只读 stdio MCP 服务接入 Claude Code、Codex 或 OpenCode：

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

内置只读 MCP 工具：
- `chrono_summary_window` — 汇总最近 `N` 分钟内的 CPU 峰值、交换峰值、外部上行峰值及异常书签。
- `chrono_inspect_timestamp` — 查询指定 `epoch_seconds` 或 `minutes_ago` 附近的历史进程快照（支持 `sort_by`: `cpu` / `memory` / `network`），返回快照时间偏差秒数、`Memory Footprint (phys_footprint)`、系统受限进程 `No permission` 标注以及 `still running` / `exited after spike` 状态。
- `chrono_top_egress_endpoints` — 统计最近 `N` 小时内外部远程主机流量排行（已剔除本机回环流量）。

---

## 存储与本地隐私边界

- **默认数据库路径**：`~/Library/Application Support/ChronoMac/flightbox.sqlite`（测试或验收时可通过 `--db <path>` 或 `CHRONOMAC_DB_PATH` 完全隔离）。
- **100% 本地存储、零遥测上传**：所有 Mach 内存/CPU 计数器、`proc_pid_rusage` 物理内存占用、`nettop` 字节增量与本地 `getnameinfo` PTR 反向解析结果均仅保存在本机磁盘。
- **AI 编程代理本地元数据读取范围（只读透明披露）**：
  - **Claude Code (`~/.claude/projects/<slug>/*.jsonl`)**：仅读取目录项的文件修改时间戳与父目录名称标识，**绝不打开或解析 `.jsonl` 会话正文**。
  - **OpenCode (`~/.local/share/opencode/opencode.db`)**：以 `SQLITE_OPEN_READONLY` 只读查询 `session.title`（最多截取前 22 个字符作为时间轴标签）与 `time_created` / `time_updated` 时间戳。
  - **Codex CLI (`~/.codex/state_5.sqlite`)**：以 `SQLITE_OPEN_READONLY` 只读查询 `threads.cwd`（仅取末级工作目录名作为时间轴标签）与 `created_at` / `updated_at` 时间戳。
  - 任何提示词正文、模型回复内容、API 密钥或代码仓库源文件均**绝不读取**。

## 开源许可

MIT License — 详见 [LICENSE](LICENSE)。
