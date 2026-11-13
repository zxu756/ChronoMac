import SwiftUI

public struct ChronoDashboardView: View {
    @ObservedObject var monitor: ChronoMonitor
    @ObservedObject var localizer: AppLocalizer
    public let displayTimeZone: TimeZone

    @MainActor
    public init(
        monitor: ChronoMonitor,
        localizer: AppLocalizer = .shared,
        displayTimeZone: TimeZone = .current
    ) {
        self.monitor = monitor
        self.localizer = localizer
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

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("ChronoMac")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(ChronoTheme.ink)
                    .fixedSize(horizontal: true, vertical: false)
                Text(
                    localizer.L(
                        "7-day system flight recorder, DVR timeline & per-process network ledger",
                        "7 天系统飞行记录仪 · 五轨 DVR 时间轴与进程外联账本"
                    )
                )
                .font(.system(size: 12.5))
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
                    Text(localizer.L("Recording live (2s WAL)", "实时录制中 (2s WAL)"))
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
                    label: localizer.L("Resident RAM & swap", "常驻内存与交换"),
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
                    label: localizer.L("Outbound network", "外联上行网络"),
                    detail: localizer.L("Down: \(downText)", "下行：\(downText)"),
                    accent: (t?.netOutBps ?? 0) >= 6_291_456 ? ChronoTheme.playheadRed : ChronoTheme.netPlum
                )
                verticalHairline
                readoutCell(
                    value: localizer.L("\(agentCount) active", "\(agentCount) 个活跃"),
                    label: localizer.L("AI agent correlation", "AI 编程代理关联"),
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
                        "Zero thermal, swap, or outbound network anomalies in selected window",
                        "所选时间窗口内无温控、交换或外联网络异常"
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

    // MARK: - Bottom Split Deck: Historical Process Blame (Left) + Outbound Socket Ledger (Right)

    private var forensicSplitDeck: some View {
        HStack(spacing: 0) {
            processBlamePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(ChronoTheme.hairline)
                .frame(width: 1)

            outboundSocketPane
                .frame(width: 368)
                .frame(maxHeight: .infinity)
        }
        .background(ChronoTheme.viewport)
    }

    private var processBlamePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(
                    monitor.displayedSnapshotTs.map { ts in
                        let clock = ChronoFormatter.clockTime(ts, timeZone: displayTimeZone)
                        return localizer.L(
                            "Process blame snapshot @ \(clock)",
                            "历史进程追责快照 @ \(clock)"
                        )
                    } ?? localizer.L("Live process snapshot", "实时进程快照")
                )
                .font(.system(size: 12, weight: .bold))
                .tracking(0)
                .foregroundStyle(ChronoTheme.ink)

                Spacer()

                if monitor.selectedProcessExecPath != nil {
                    Button(action: { monitor.selectedProcessExecPath = nil }) {
                        Text(localizer.L("Clear socket filter", "清除外联筛选"))
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.memCobalt)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(
                        localizer.L(
                            "Click any process to filter remote sockets",
                            "点击任意进程以筛选远程外联连接"
                        )
                    )
                    .font(.system(size: 11))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.subtle)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8.5)
            .background(ChronoTheme.band)

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            // Column Header
            HStack(spacing: 10) {
                Text(localizer.L("Process & binary path", "进程与可执行路径"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(localizer.L("PID / State", "PID / 状态"))
                    .frame(width: 96, alignment: .leading)
                Text(localizer.L("CPU", "CPU"))
                    .frame(width: 54, alignment: .trailing)
                Text(localizer.L("Memory", "常驻内存"))
                    .frame(width: 72, alignment: .trailing)
                Text(localizer.L("Net out", "外联上行"))
                    .frame(width: 76, alignment: .trailing)
                Text(localizer.L("Action", "操作"))
                    .frame(width: 62, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
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
        let selected = monitor.selectedProcessExecPath == p.execPath
        let hot = p.cpuPct >= 150 || p.rssBytes >= 4_294_967_296 || p.netOutBps >= 5_242_880

        return Button(action: {
            monitor.selectedProcessExecPath = (selected ? nil : p.execPath)
        }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hot ? ChronoTheme.playheadRed : (p.isAliveNow ? ChronoTheme.diskPine : ChronoTheme.subtle))
                            .frame(width: 6.5, height: 6.5)
                        Text(p.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ChronoTheme.ink)
                            .lineLimit(1)
                    }
                    Text(ChronoFormatter.displayPath(p.execPath))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ChronoTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "PID \(p.pid)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChronoTheme.ink)
                    if !p.isAliveNow {
                        Text(localizer.L("Exited after spike", "峰值后已退出"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.playheadRed)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let team = p.signingTeam {
                        Text(verbatim: team == "Apple" ? localizer.L("Apple", "Apple 系统") : team)
                            .font(.system(size: 9.5, design: .monospaced))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.subtle)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: 96, alignment: .leading)

                Text(String(format: "%.1f%%", p.cpuPct))
                    .font(.system(size: 12, weight: p.cpuPct >= 100 ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(p.cpuPct >= 150 ? ChronoTheme.cpuAmber : ChronoTheme.ink)
                    .frame(width: 54, alignment: .trailing)

                Text(ChronoFormatter.bytes(p.rssBytes))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.rssBytes >= 4_294_967_296 ? ChronoTheme.playheadRed : ChronoTheme.ink)
                    .frame(width: 72, alignment: .trailing)

                Text(ChronoFormatter.rate(p.netOutBps))
                    .font(.system(size: 11.5, weight: p.netOutBps >= 5_242_880 ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(p.netOutBps >= 5_242_880 ? ChronoTheme.netPlum : ChronoTheme.muted)
                    .frame(width: 76, alignment: .trailing)

                HStack {
                    Spacer()
                    if p.isAliveNow && p.pid > 1 && p.signingTeam != "Apple" {
                        Button(action: { monitor.terminateProcess(p) }) {
                            Text(localizer.L("Stop", "终止"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0)
                                .foregroundStyle(ChronoTheme.playheadRed)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(RoundedRectangle(cornerRadius: 5).fill(ChronoTheme.playheadRed.opacity(0.09)))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChronoTheme.playheadRed.opacity(0.32), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(p.isAliveNow ? localizer.L("System", "系统") : localizer.L("Recorded", "已归档"))
                            .font(.system(size: 10.5))
                            .tracking(0)
                            .foregroundStyle(ChronoTheme.subtle)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8.5)
            .background(selected ? ChronoTheme.memCobalt.opacity(0.07) : ChronoTheme.viewport)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Pane: Process Outbound Socket & Remote Host Ledger

    private var outboundSocketPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localizer.L("External socket ledger", "外部套接字外联账本"))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.ink)
                Spacer()
                Text(localizer.L("Bytes up / down", "累计上行 / 下行"))
                    .font(.system(size: 10.5, design: .monospaced))
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
                            "Loopback 127.0.0.1 traffic is excluded automatically.",
                            "本地回环 127.0.0.1 流量已自动排除。"
                        )
                    )
                    .font(.system(size: 11))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.isStaticPreview {
                VStack(spacing: 0) {
                    ForEach(monitor.socketFlows.prefix(5)) { flow in
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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(flow.hostname ?? flow.remoteEndpoint)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(heavyUp ? ChronoTheme.playheadRed : ChronoTheme.ink)
                    .lineLimit(1)
                Spacer()
                Text("↑ \(ChronoFormatter.bytes(flow.totalBytesOut))")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(heavyUp ? ChronoTheme.playheadRed : ChronoTheme.netPlum)
            }

            HStack {
                Text("\(flow.processName) · \(flow.remoteEndpoint)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ChronoTheme.muted)
                    .lineLimit(1)
                Spacer()
                Text("↓ \(ChronoFormatter.bytes(flow.totalBytesIn))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ChronoTheme.subtle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9.5)
        .background(heavyUp ? ChronoTheme.playheadRed.opacity(0.04) : ChronoTheme.viewport)
    }
}
