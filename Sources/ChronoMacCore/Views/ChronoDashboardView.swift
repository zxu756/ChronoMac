import SwiftUI

public struct ChronoDashboardView: View {
    @ObservedObject var monitor: ChronoMonitor
    public let displayTimeZone: TimeZone

    public init(monitor: ChronoMonitor, displayTimeZone: TimeZone = .current) {
        self.monitor = monitor
        self.displayTimeZone = displayTimeZone
    }

    public var body: some View {
        VStack(spacing: 0) {
            topMasthead
            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)
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

    // MARK: - Top Masthead & Time-Window Segmented Well

    private var topMasthead: some View {
        HStack(alignment: .center, spacing: 12) {
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
                    .tracking(-0.35)
                    .foregroundStyle(ChronoTheme.ink)
                Text("7-day system flight recorder, DVR timeline & per-process network ledger")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChronoTheme.muted)
            }

            Spacer()

            // Playhead Mode Pill
            if let scrubTs = monitor.scrubbedTimestamp {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ChronoTheme.playheadRed)
                        .frame(width: 6.5, height: 6.5)
                    Text("DVR replay · \(ChronoFormatter.clockTime(scrubTs, timeZone: displayTimeZone))")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ChronoTheme.playheadRed)
                    Button(action: { monitor.returnToLive() }) {
                        Text("Live")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChronoTheme.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(ChronoTheme.viewport))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChronoTheme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.playheadRed.opacity(0.09)))
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ChronoTheme.diskPine)
                        .frame(width: 6.5, height: 6.5)
                    Text("Recording live (2s WAL)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChronoTheme.diskPine)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }

            // Segmented Range Well
            HStack(spacing: 2) {
                ForEach(TimeRangeWindow.allCases) { range in
                    let active = monitor.selectedRange == range
                    Button(action: { monitor.selectedRange = range }) {
                        Text(range.rawValue)
                            .font(.system(size: 11.5, weight: active ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(active ? ChronoTheme.ink : ChronoTheme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
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
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChronoTheme.well))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(ChronoTheme.chassis)
    }

    // MARK: - 5-Column Instantaneous Readout + Synchronized 5-Track DVR Canvas

    private var dvrTelemetryDeck: some View {
        let t = monitor.activeTick
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                readoutCell(
                    value: String(format: "%.1f%%", t?.totalCPUPct ?? 0),
                    label: "SoC CPU & thermal",
                    detail: "State: \(t?.thermalGrade.label ?? "Nominal")",
                    accent: (t?.thermalGrade.rawValue ?? 0) >= 2 ? ChronoTheme.playheadRed : ChronoTheme.cpuAmber
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.bytes(t?.memUsedBytes ?? 0),
                    label: "Resident RAM & swap",
                    detail: "Swap: \(ChronoFormatter.bytes(t?.swapUsedBytes ?? 0))",
                    accent: (t?.swapUsedBytes ?? 0) >= 2_147_483_648 ? ChronoTheme.playheadRed : ChronoTheme.memCobalt
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.rate((t?.diskReadBps ?? 0) + (t?.diskWriteBps ?? 0)),
                    label: "Disk throughput",
                    detail: "R \(ChronoFormatter.rate(t?.diskReadBps ?? 0)) · W \(ChronoFormatter.rate(t?.diskWriteBps ?? 0))",
                    accent: ChronoTheme.diskPine
                )
                verticalHairline
                readoutCell(
                    value: ChronoFormatter.rate(t?.netOutBps ?? 0),
                    label: "Outbound network",
                    detail: "Down: \(ChronoFormatter.rate(t?.netInBps ?? 0))",
                    accent: (t?.netOutBps ?? 0) >= 6_291_456 ? ChronoTheme.playheadRed : ChronoTheme.netPlum
                )
                verticalHairline
                readoutCell(
                    value: "\(t?.activeAgentCount ?? 0) active",
                    label: "AI agent correlation",
                    detail: (t?.activeAgentSummary.isEmpty == false) ? (t?.activeAgentSummary ?? "") : "Zero active CLI harnesses",
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
                .tracking(-0.4)
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ChronoTheme.ink.opacity(0.9))
            Text(verbatim: detail)
                .font(.system(size: 10.5, design: .monospaced))
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
                Text("Incident bookmarks")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ChronoTheme.ink)
            }

            if monitor.anomalies.isEmpty {
                Text("Zero thermal, swap, or outbound network anomalies in selected window")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChronoTheme.muted)
            } else {
                ForEach(monitor.anomalies.prefix(3)) { bm in
                    let isSelected = monitor.scrubbedTimestamp == bm.ts
                    Button(action: { monitor.jumpToAnomaly(bm) }) {
                        HStack(spacing: 5) {
                            Text(ChronoFormatter.clockTime(bm.ts, timeZone: displayTimeZone))
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ChronoTheme.playheadRed)
                            Text(bm.kind.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ChronoTheme.ink)
                            Text(verbatim: bm.metricBadge)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(ChronoTheme.muted)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
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
                    monitor.displayedSnapshotTs.map {
                        "Process blame snapshot @ \(ChronoFormatter.clockTime($0, timeZone: displayTimeZone))"
                    } ?? "Live process snapshot"
                )
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChronoTheme.ink)

                Spacer()

                if monitor.selectedProcessExecPath != nil {
                    Button(action: { monitor.selectedProcessExecPath = nil }) {
                        Text("Clear socket filter")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChronoTheme.memCobalt)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Click any process to filter remote sockets")
                        .font(.system(size: 11))
                        .foregroundStyle(ChronoTheme.subtle)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8.5)
            .background(ChronoTheme.band)

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            // Column Header
            HStack(spacing: 10) {
                Text("Process & binary path")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PID / State")
                    .frame(width: 92, alignment: .leading)
                Text("CPU")
                    .frame(width: 54, alignment: .trailing)
                Text("Memory")
                    .frame(width: 72, alignment: .trailing)
                Text("Net out")
                    .frame(width: 76, alignment: .trailing)
                Text("Action")
                    .frame(width: 58, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
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
                        Text("Exited after spike")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(ChronoTheme.playheadRed)
                    } else if let team = p.signingTeam {
                        Text(verbatim: team)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(ChronoTheme.subtle)
                    }
                }
                .frame(width: 92, alignment: .leading)

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
                            Text("Stop")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(ChronoTheme.playheadRed)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(ChronoTheme.playheadRed.opacity(0.09)))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChronoTheme.playheadRed.opacity(0.32), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(p.isAliveNow ? "System" : "Recorded")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ChronoTheme.subtle)
                    }
                }
                .frame(width: 58, alignment: .trailing)
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
                Text("External socket ledger")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ChronoTheme.ink)
                Spacer()
                Text("Bytes up / down")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ChronoTheme.subtle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8.5)
            .background(ChronoTheme.band)

            Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

            if monitor.socketFlows.isEmpty {
                VStack(spacing: 5) {
                    Text("No external TCP/UDP transfers recorded")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ChronoTheme.ink)
                    Text("Loopback 127.0.0.1 traffic is excluded automatically.")
                        .font(.system(size: 11))
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
