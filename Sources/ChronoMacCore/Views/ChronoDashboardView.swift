import SwiftUI

public struct ChronoDashboardView: View {
    @ObservedObject var monitor: ChronoMonitor
    @ObservedObject var localizer: AppLocalizer
    public let displayTimeZone: TimeZone

    @MainActor
    public init(
        monitor: ChronoMonitor,
        localizer: AppLocalizer? = nil,
        displayTimeZone: TimeZone = .current
    ) {
        self.monitor = monitor
        self.localizer = localizer ?? AppLocalizer.shared
        self.displayTimeZone = displayTimeZone
    }

    public var body: some View {
        VStack(spacing: 0) {
            topMasthead
            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)
            if let banner = monitor.statusBanner {
                statusBannerStrip(banner)
                Rectangle().fill(ChronoTheme.hairline).frame(height: 1)
            }
            dvrTelemetryDeck
            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)
            anomalyBookmarkRibbon
            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)
            forensicSplitDeck
        }
        .background(ChronoTheme.chassis)
        .foregroundStyle(ChronoTheme.ink)
        .preferredColorScheme(.light)
    }

    private func statusBannerStrip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ChronoTheme.memCobalt)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ChronoTheme.ink)
            Spacer()
            Button(action: { monitor.statusBanner = nil }) {
                Text(localizer.L("Dismiss", "关闭"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChronoTheme.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .background(ChronoTheme.band)
    }

    // MARK: - Top Masthead & Time-Window Segmented Well

    private var topMasthead: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ChronoTheme.ink)
                    .frame(width: 28, height: 28)
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChronoTheme.chassis)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("ChronoMac")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(ChronoTheme.ink)
                    .fixedSize(horizontal: true, vertical: false)

                if monitor.isStaticPreview {
                    Text(localizer.L("[DEMO]", "[DEMO · 演示数据]"))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(ChronoTheme.cpuAmber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(ChronoTheme.cpuAmber.opacity(0.14))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(ChronoTheme.cpuAmber.opacity(0.45), lineWidth: 1)
                        )
                }

                Text(
                    localizer.L(
                        "Read-only DVR (`ChronoMac record` daemon) · calibrated NIC sockets",
                        "只读 DVR 视图（由 `ChronoMac record` 录制）· 物理网卡校准外联账本"
                    )
                )
                .font(.system(size: 12))
                .tracking(0)
                .foregroundStyle(ChronoTheme.muted)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Playhead Mode Pill
            if let scrubTs = monitor.scrubbedTimestamp {
                let clock = ChronoFormatter.clockTime(scrubTs, timeZone: displayTimeZone)
                HStack(spacing: 6) {
                    Circle()
                        .fill(ChronoTheme.playheadRed)
                        .frame(width: 6.5, height: 6.5)
                    Text(
                        localizer.L(
                            "DVR replay · \(clock)",
                            "DVR 回放 · \(clock)"
                        )
                    )
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.playheadRed)
                    .fixedSize(horizontal: true, vertical: false)

                    Button(action: { monitor.returnToLive() }) {
                        Text(localizer.L("Live", "返回实时"))
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(RoundedRectangle(cornerRadius: 4).fill(ChronoTheme.viewport))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChronoTheme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.playheadRed.opacity(0.09)))
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ChronoTheme.diskPine)
                        .frame(width: 6.5, height: 6.5)
                    Text(localizer.L("Read-only Flightbox (2s WAL)", "只读飞行匣 (2s WAL)"))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.diskPine)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }

            // Segmented Range Well
            HStack(spacing: 2) {
                ForEach(TimeRangeWindow.allCases) { range in
                    let active = monitor.selectedRange == range
                    Button(action: { monitor.selectedRange = range }) {
                        Text(range.shortLabel(in: localizer.language))
                            .font(.system(size: 11.5, weight: active ? .semibold : .regular, design: .monospaced))
                            .tracking(0)
                            .foregroundStyle(active ? ChronoTheme.ink : ChronoTheme.muted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(active ? ChronoTheme.viewport : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(active ? ChronoTheme.hairline : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .fixedSize(horizontal: true, vertical: false)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChronoTheme.well))

            ChronoLanguageTogglePill(localizer: localizer)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(ChronoTheme.chassis)
    }

    // MARK: - 5-Column Instantaneous Readout + Synchronized 5-Track DVR Canvas

    private var dvrTelemetryDeck: some View {
        let t = monitor.activeTick
        let thermalText = (t?.thermalGrade ?? .nominal).label(in: localizer.language)
        let rRate = ChronoFormatter.rate(t?.diskReadBps ?? 0)
        let wRate = ChronoFormatter.rate(t?.diskWriteBps ?? 0)
        let swapText = ChronoFormatter.bytes(t?.swapUsedBytes ?? 0)
        let downText = ChronoFormatter.rate(t?.netInBps ?? 0)
        let agentCount = t?.activeAgentCount ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                readoutCell(
                    value: String(format: "%.1f%%", t?.totalCPUPct ?? 0),
                    label: localizer.L("SoC CPU & thermal", "芯片 CPU 与温控"),
                    detail: localizer.L("State: \(thermalText)", "状态：\(thermalText)"),
                    accent: (t?.thermalGrade.rawValue ?? 0) >= 2 ? ChronoTheme.playheadRed : ChronoTheme.cpuAmber
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.bytes(t?.memUsedBytes ?? 0),
                    label: localizer.L("Host memory & swap", "主机内存与交换"),
                    detail: localizer.L("Swap: \(swapText)", "交换：\(swapText)"),
                    accent: (t?.swapUsedBytes ?? 0) >= 2_147_483_648 ? ChronoTheme.playheadRed : ChronoTheme.memCobalt
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.rate((t?.diskReadBps ?? 0) + (t?.diskWriteBps ?? 0)),
                    label: localizer.L("Disk throughput", "磁盘吞吐速率"),
                    detail: localizer.L("R \(rRate) · W \(wRate)", "读 \(rRate) · 写 \(wRate)"),
                    accent: ChronoTheme.diskPine
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.rate(t?.netOutBps ?? 0),
                    label: localizer.L("External outbound", "外部上行网络"),
                    detail: localizer.L("Down: \(downText)", "下行：\(downText)"),
                    accent: (t?.netOutBps ?? 0) >= 6_291_456 ? ChronoTheme.playheadRed : ChronoTheme.netPlum
                )
                verticalHairline
                readoutCell(
                    value: localizer.L("\(agentCount) active", "\(agentCount) 个活跃"),
                    label: localizer.L("AI agent metadata", "AI 编程代理会话"),
                    detail: (t?.activeAgentSummary.isEmpty == false)
                        ? (t?.activeAgentSummary ?? "")
                        : localizer.L("Zero active CLI harnesses", "当前无活跃 CLI 代理"),
                    accent: ChronoTheme.ink
                )
            }

            TimelineScrubberCanvas(
                ticks: monitor.ticks,
                anomalies: monitor.anomalies,
                agentWindows: monitor.agentWindows,
                scrubbedTimestamp: monitor.scrubbedTimestamp,
                spanSeconds: monitor.selectedRange.durationSeconds,
                timeZone: displayTimeZone,
                localizer: localizer,
                onScrub: { ts in monitor.scrub(to: ts) }
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(ChronoTheme.chassis)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(ChronoTheme.hairline)
            .frame(width: 1, height: 42)
            .padding(.horizontal, 14)
    }

    private func readoutCell(value: String, label: String, detail: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .tracking(localizer.isChinese ? 0 : -0.4)
                .foregroundStyle(accent)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0)
                .foregroundStyle(ChronoTheme.ink.opacity(0.9))
                .lineLimit(1)
            Text(verbatim: detail)
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(0)
                .foregroundStyle(ChronoTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recorded Incident Bookmark Strip

    private var anomalyBookmarkRibbon: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ChronoTheme.playheadRed)
                Text(localizer.L("Incident bookmarks", "异常事件书签"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.ink)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if monitor.anomalies.isEmpty {
                Text(
                    localizer.L(
                        "Zero thermal, swap, or external outbound network anomalies in selected window",
                        "所选时间窗口内无温控、交换或外部网络上行异常"
                    )
                )
                .font(.system(size: 11.5))
                .tracking(0)
                .foregroundStyle(ChronoTheme.muted)
            } else {
                ForEach(monitor.anomalies.prefix(3)) { bm in
                    let isSelected = monitor.scrubbedTimestamp == bm.ts
                    Button(action: { monitor.jumpToAnomaly(bm) }) {
                        HStack(spacing: 5) {
                            Text(ChronoFormatter.clockTime(bm.ts, timeZone: displayTimeZone))
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ChronoTheme.playheadRed)
                            Text(bm.kind.label(in: localizer.language))
                                .font(.system(size: 11, weight: .medium))
                                .tracking(0)
                                .foregroundStyle(ChronoTheme.ink)
                            Text(verbatim: bm.localizedMetricBadge(in: localizer.language))
                                .font(.system(size: 10.5, design: .monospaced))
                                .tracking(0)
                                .foregroundStyle(ChronoTheme.muted)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? ChronoTheme.playheadRed.opacity(0.11) : ChronoTheme.viewport)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? ChronoTheme.playheadRed.opacity(0.45) : ChronoTheme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(ChronoTheme.band)
    }

    // MARK: - Bottom Split Deck: Historical Process Blame (Left) + External Socket Ledger (Right)

    private var forensicSplitDeck: some View {
        HStack(spacing: 0) {
            processBlamePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(ChronoTheme.hairline)
                .frame(width: 1)

            outboundSocketPane
                .frame(width: 348)
                .frame(maxHeight: .infinity)
        }
        .background(ChronoTheme.viewport)
    }

    private var snapshotTitleText: String {
        guard let ts = monitor.displayedSnapshotTs else {
            return localizer.L("Live process snapshot", "实时进程快照")
        }
        let clock = ChronoFormatter.clockTime(ts, timeZone: displayTimeZone)
        if let requested = monitor.scrubbedTimestamp {
            let delta = abs(ts - requested)
            return localizer.L(
                "Snapshot at \(clock) (\(delta)s from requested time)",
                "取自 \(clock) 的快照（距所查时刻差 \(delta) 秒）"
            )
        }
        return localizer.L("Live process snapshot @ \(clock)", "实时进程快照 @ \(clock)")
    }

    private var processBlamePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(snapshotTitleText)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if monitor.selectedProcessExecPath != nil {
                    Button(action: { monitor.selectedProcessExecPath = nil }) {
                        Text(localizer.L("Clear filter", "清除筛选"))
                            .font(.system(size: 10.5, weight: .medium))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.memCobalt)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }

                // Explicit 3-Mode Ranking Selector (By CPU / By Memory / By Network)
                HStack(spacing: 2) {
                    ForEach(ProcessSortOrder.allCases) { mode in
                        let active = monitor.selectedSortOrder == mode
                        Button(action: { monitor.selectedSortOrder = mode }) {
                            Text(mode.label(in: localizer.language))
                                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                                .tracking(0)
                                .foregroundStyle(active ? ChronoTheme.ink : ChronoTheme.muted)
                                .padding(.horizontal, 7.5)
                                .padding(.vertical, 3)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(active ? ChronoTheme.viewport : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(active ? ChronoTheme.hairline : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .fixedSize(horizontal: true, vertical: false)
                .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(ChronoTheme.well))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7.5)
            .background(ChronoTheme.band)

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            // Column Header
            HStack(spacing: 8) {
                Text(localizer.L("Process & binary path", "进程与可执行路径"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(localizer.L("PID / Status", "PID / 状态"))
                    .frame(width: 108, alignment: .leading)
                Text(localizer.L("CPU", "CPU"))
                    .frame(width: 92, alignment: .trailing)
                Text(localizer.L("Memory Footprint (phys_footprint)", "物理内存占用 (phys_footprint)"))
                    .frame(width: 184, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                Text(localizer.L("Net out", "外联上行"))
                    .frame(width: 72, alignment: .trailing)
                Text(localizer.L("Action", "操作"))
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0)
            .foregroundStyle(ChronoTheme.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(ChronoTheme.band.opacity(0.6))

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            if monitor.isStaticPreview {
                VStack(spacing: 0) {
                    ForEach(monitor.displayedProcesses.prefix(6)) { p in
                        processRow(p)
                        Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.displayedProcesses) { p in
                            processRow(p)
                            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func processRow(_ p: ProcessSample) -> some View {
        let selected = !p.execPath.isEmpty && monitor.selectedProcessExecPath == p.execPath
        let hot = (p.isCPUReadable && p.cpuPct >= 150) || p.rssBytes >= 4_294_967_296 || p.netOutBps >= 5_242_880
        let displayedPath = p.hasNegativeNICDiscrepancy
            ? localizer.L("Unmatched delta: per-PID socket sum exceeded physical NIC delta", "对不上的量：逐进程套接字之和超出物理网卡增量")
            : (p.isUnattributed
                ? localizer.L("Physical NIC delta minus per-PID sockets (non-root kernel_task PID 0 CPU requires root)", "物理网卡总表减进程套接字差额（非 root 下 kernel_task PID 0 CPU 无权限）")
                : (p.execPath.isEmpty
                    ? localizer.L("(path unavailable · non-root kernel_task PID 0 CPU requires root)", "（路径不可用 · 非 root 下 kernel_task PID 0 CPU 需 root 权限）")
                    : ChronoFormatter.displayPath(p.execPath)))

        return Button(action: {
            guard !p.execPath.isEmpty else { return }
            monitor.selectedProcessExecPath = (selected ? nil : p.execPath)
        }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(p.isUnattributed ? ChronoTheme.netPlum : (hot ? ChronoTheme.playheadRed : (p.isAliveNow ? ChronoTheme.diskPine : ChronoTheme.subtle)))
                            .frame(width: 6.5, height: 6.5)
                        Text(p.localizedName(in: localizer.language))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ChronoTheme.ink)
                            .lineLimit(1)
                    }
                    Text(displayedPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(p.execPath.isEmpty ? ChronoTheme.subtle : ChronoTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: p.isUnattributed ? "NIC Δ" : "PID \(p.pid)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChronoTheme.ink)
                    Text(p.livenessLabel(in: localizer.language))
                        .font(.system(size: 9.5, weight: !p.isAliveNow ? .semibold : .medium))
                        .tracking(0)
                        .foregroundStyle(p.isUnattributed ? ChronoTheme.netPlum : (!p.isAliveNow ? ChronoTheme.playheadRed : ChronoTheme.diskPine))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(width: 108, alignment: .leading)

                Text(p.formattedCPU(in: localizer.language))
                    .font(.system(size: p.isCPUReadable ? 11.5 : 10, weight: (p.isCPUReadable && p.cpuPct >= 100) ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(!p.isCPUReadable ? ChronoTheme.subtle : (p.cpuPct >= 150 ? ChronoTheme.cpuAmber : ChronoTheme.ink))
                    .frame(width: 92, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)

                Text(p.isUnattributed ? "—" : (p.rssBytes > 0 || p.isCPUReadable ? ChronoFormatter.bytes(p.memoryFootprintBytes) : "—"))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.rssBytes >= 4_294_967_296 ? ChronoTheme.playheadRed : ChronoTheme.ink)
                    .frame(width: 184, alignment: .trailing)

                Text(p.formattedNetworkRate(outboundOnlyForProcesses: true))
                    .font(.system(size: 11, weight: abs(p.netOutBps) >= 5_242_880 || p.hasNegativeNICDiscrepancy ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(p.hasNegativeNICDiscrepancy ? ChronoTheme.playheadRed : (p.netOutBps >= 5_242_880 ? ChronoTheme.netPlum : ChronoTheme.muted))
                    .frame(width: 72, alignment: .trailing)

                HStack {
                    Spacer()
                    if p.isAliveNow && p.pid > 1 && p.signingTeam != "Apple" && p.isCPUReadable {
                        Button(action: { monitor.terminateProcess(p) }) {
                            Text(localizer.L("Stop", "终止"))
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0)
                                .foregroundStyle(ChronoTheme.playheadRed)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(RoundedRectangle(cornerRadius: 5).fill(ChronoTheme.playheadRed.opacity(0.09)))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChronoTheme.playheadRed.opacity(0.32), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(p.isAliveNow ? localizer.L("System", "系统") : localizer.L("Archived", "已归档"))
                            .font(.system(size: 10))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.subtle)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6.5)
            .background(selected ? ChronoTheme.memCobalt.opacity(0.07) : ChronoTheme.viewport)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Pane: Process External Socket & Remote Host Ledger

    private var outboundSocketPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localizer.L("External socket ledger", "外部套接字外联账本"))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.ink)
                Spacer()
                Text(localizer.L("Loopback excluded", "不含本机回环"))
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.subtle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8.5)
            .background(ChronoTheme.band)

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            if monitor.socketFlows.isEmpty {
                VStack(spacing: 5) {
                    Text(localizer.L("No external TCP/UDP transfers recorded", "暂无外部 TCP/UDP 传输记录"))
                        .font(.system(size: 12.5, weight: .medium))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.ink)
                    Text(
                        localizer.L(
                            "Loopback (127.0.0.1 / ::1 / lo0) traffic is tracked separately.",
                            "本地回环 (127.0.0.1 / ::1 / lo0) 流量已独立隔离。"
                        )
                    )
                    .font(.system(size: 11))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.isStaticPreview {
                VStack(spacing: 0) {
                    ForEach(monitor.socketFlows.prefix(4)) { flow in
                        socketFlowRow(flow)
                        Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.socketFlows) { flow in
                            socketFlowRow(flow)
                            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func socketFlowRow(_ flow: SocketFlowRecord) -> some View {
        let heavyUp = flow.totalBytesOut >= 100 * 1024 * 1024
        let subtitleEndpoint = flow.isUnattributed
            ? localizer.L("netstat -ibn minus nettop", "网卡总表减 nettop")
            : flow.remoteEndpoint
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(flow.localizedEndpoint(in: localizer.language))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(heavyUp ? ChronoTheme.playheadRed : ChronoTheme.ink)
                    .lineLimit(1)
                Spacer()
                Text("↑ \(ChronoFormatter.bytes(flow.totalBytesOut))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(heavyUp ? ChronoTheme.playheadRed : ChronoTheme.netPlum)
            }

            HStack {
                Text("\(flow.localizedProcessName(in: localizer.language)) · \(subtitleEndpoint)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ChronoTheme.muted)
                    .lineLimit(1)
                Spacer()
                Text("↓ \(ChronoFormatter.bytes(flow.totalBytesIn))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ChronoTheme.subtle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(heavyUp ? ChronoTheme.playheadRed.opacity(0.04) : ChronoTheme.viewport)
    }
}
