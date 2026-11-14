import SwiftUI

enum ChronoTheme {
    // Dieter Rams Warm Titanium Oscilloscope & Flight-Recorder Palette
    static let chassis = Color(red: 0.953, green: 0.949, blue: 0.933)      // #F3F2EE warm titanium chassis
    static let viewport = Color(red: 1.000, green: 1.000, blue: 1.000)     // #FFFFFF oscilloscope viewport
    static let band = Color(red: 0.969, green: 0.965, blue: 0.953)         // #F7F6F3 subtle table header band
    static let well = Color(red: 0.906, green: 0.898, blue: 0.871)         // #E7E5DE recessed segmented track
    static let hairline = Color(red: 0.847, green: 0.835, blue: 0.796)     // #D8D5CB precision instrument rule
    static let rowRule = Color(red: 0.914, green: 0.906, blue: 0.882)      // #E9E7E1 subtle row rule
    static let graticule = Color(red: 0.890, green: 0.882, blue: 0.855)    // #E3E1DA oscilloscope grid line

    static let ink = Color(red: 0.090, green: 0.090, blue: 0.086)          // #171716 crisp carbon ink
    static let muted = Color(red: 0.388, green: 0.376, blue: 0.349)        // #636059 dial secondary ink
    static let subtle = Color(red: 0.541, green: 0.525, blue: 0.490)       // #8A867D scale tick ink

    // 5-Track Distinct Mineral Signal Traces
    static let cpuAmber = Color(red: 0.788, green: 0.357, blue: 0.118)     // #C95B1E CPU & thermal trace
    static let memCobalt = Color(red: 0.114, green: 0.337, blue: 0.651)    // #1D56A6 Memory & swap trace
    static let diskPine = Color(red: 0.086, green: 0.455, blue: 0.345)     // #167458 Disk I/O trace
    static let netPlum = Color(red: 0.357, green: 0.259, blue: 0.604)      // #5B429A Network egress/ingress trace
    static let playheadRed = Color(red: 0.808, green: 0.231, blue: 0.141)  // #CE3B24 DVR playhead & anomaly pin
}

public struct TimelineScrubberCanvas: View {
    @ObservedObject var localizer: AppLocalizer
    public let ticks: [SystemTick]
    public let anomalies: [AnomalyBookmark]
    public let agentWindows: [AgentBurstWindow]
    public let scrubbedTimestamp: Int64?
    public let spanSeconds: Int64
    public let timeZone: TimeZone
    public var onScrub: (Int64?) -> Void

    private let leftGutterWidth: CGFloat = 148
    private let rightPadding: CGFloat = 14

    @MainActor
    public init(
        ticks: [SystemTick],
        anomalies: [AnomalyBookmark],
        agentWindows: [AgentBurstWindow],
        scrubbedTimestamp: Int64?,
        spanSeconds: Int64,
        timeZone: TimeZone = .current,
        localizer: AppLocalizer? = nil,
        onScrub: @escaping (Int64?) -> Void
    ) {
        self.localizer = localizer ?? AppLocalizer.shared
        self.ticks = ticks
        self.anomalies = anomalies
        self.agentWindows = agentWindows
        self.scrubbedTimestamp = scrubbedTimestamp
        self.spanSeconds = spanSeconds
        self.timeZone = timeZone
        self.onScrub = onScrub
    }

    public var body: some View {
        GeometryReader { geo in
            let fullW = geo.size.width
            let plotX = leftGutterWidth
            let plotW = max(60, fullW - leftGutterWidth - rightPadding)
            let minTs = ticks.first?.ts ?? 0
            let maxTs = max(minTs + 1, ticks.last?.ts ?? 1)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawOscilloscope(ctx: &ctx, size: size, plotX: plotX, plotW: plotW, minTs: minTs, maxTs: maxTs)
                }

                // Track Labels on Left Gutter
                VStack(alignment: .leading, spacing: 0) {
                    trackLabelCell(
                        title: localizer.L("CPU & thermal", "CPU 与温控"),
                        subtitle: localizer.L("0–100% SoC", "0–100% 芯片负载"),
                        color: ChronoTheme.cpuAmber,
                        height: 40
                    )
                    trackLabelCell(
                        title: localizer.L("Memory & swap", "内存与交换"),
                        subtitle: localizer.L("RAM + VM swap", "物理内存 + 交换区"),
                        color: ChronoTheme.memCobalt,
                        height: 40
                    )
                    trackLabelCell(
                        title: localizer.L("Disk I/O", "磁盘读写 I/O"),
                        subtitle: localizer.L("Read + write/s", "每秒读写吞吐"),
                        color: ChronoTheme.diskPine,
                        height: 36
                    )
                    trackLabelCell(
                        title: localizer.L("Network out/in", "网络上下行"),
                        subtitle: localizer.L("Socket throughput", "套接字吞吐速率"),
                        color: ChronoTheme.netPlum,
                        height: 36
                    )
                    trackLabelCell(
                        title: localizer.L("AI agent bursts", "AI 代理活跃窗"),
                        subtitle: localizer.L("CLI session spans", "CLI 会话活跃时段"),
                        color: ChronoTheme.playheadRed,
                        height: 28
                    )
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .padding(.leading, 12)
                .frame(width: leftGutterWidth, alignment: .leading)

                // Bottom Time Axis Labels
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { i in
                        let frac = Double(i) / 4.0
                        let ts = minTs + Int64(Double(maxTs - minTs) * frac)
                        Text(ChronoFormatter.shortAxisTime(ts, spanSeconds: spanSeconds, timeZone: timeZone, language: localizer.language))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(ChronoTheme.subtle)
                        if i < 4 { Spacer() }
                    }
                }
                .padding(.leading, plotX)
                .padding(.trailing, rightPadding)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let x = min(max(val.location.x - plotX, 0), plotW)
                        let frac = Double(x / plotW)
                        let target = minTs + Int64(Double(maxTs - minTs) * frac)
                        onScrub(target)
                    }
            )
        }
        .frame(height: 210)
        .background(ChronoTheme.viewport)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ChronoTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trackLabelCell(title: String, subtitle: String, color: Color, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: height * 0.56)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChronoTheme.ink)
                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(ChronoTheme.subtle)
            }
        }
        .frame(height: height, alignment: .center)
    }

    private func drawOscilloscope(
        ctx: inout GraphicsContext,
        size: CGSize,
        plotX: CGFloat,
        plotW: CGFloat,
        minTs: Int64,
        maxTs: Int64
    ) {
        let topPad: CGFloat = 8
        let heights: [CGFloat] = [40, 40, 36, 36, 28]
        var laneRects: [CGRect] = []
        var curY = topPad
        for h in heights {
            laneRects.append(CGRect(x: plotX, y: curY, width: plotW, height: h - 5))
            curY += h
        }

        // Left gutter vertical divider
        var vLine = Path()
        vLine.move(to: CGPoint(x: plotX, y: 0))
        vLine.addLine(to: CGPoint(x: plotX, y: size.height))
        ctx.stroke(vLine, with: .color(ChronoTheme.hairline), lineWidth: 1)

        // Vertical time graticules
        for idx in 1..<4 {
            let x = plotX + plotW * (CGFloat(idx) / 4.0)
            var g = Path()
            g.move(to: CGPoint(x: x, y: topPad))
            g.addLine(to: CGPoint(x: x, y: curY - 4))
            ctx.stroke(g, with: .color(ChronoTheme.graticule), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Lane baselines
        for rect in laneRects {
            var base = Path()
            base.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            base.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.stroke(base, with: .color(ChronoTheme.graticule), lineWidth: 1)
        }

        guard ticks.count >= 2 else { return }

        let xForTs: (Int64) -> CGFloat = { ts in
            let frac = Double(ts - minTs) / Double(max(1, maxTs - minTs))
            return plotX + CGFloat(min(1.0, max(0.0, frac))) * plotW
        }

        // Track 1: CPU % (0..100)
        drawTrace(
            ctx: &ctx,
            rect: laneRects[0],
            color: ChronoTheme.cpuAmber,
            xForTs: xForTs,
            normalizedValue: { min(1.0, $0.totalCPUPct / 100.0) }
        )

        // Track 2: Memory + Swap overlay
        let maxMem = Double(max(1, ticks.first?.memTotalBytes ?? 1))
        drawTrace(
            ctx: &ctx,
            rect: laneRects[1],
            color: ChronoTheme.memCobalt,
            xForTs: xForTs,
            normalizedValue: { min(1.0, Double($0.memUsedBytes) / maxMem) }
        )
        let maxSwap = max(Double(2 * 1024 * 1024 * 1024), Double(ticks.map(\.swapUsedBytes).max() ?? 1))
        drawLineOnly(
            ctx: &ctx,
            rect: laneRects[1],
            color: ChronoTheme.playheadRed.opacity(0.85),
            xForTs: xForTs,
            normalizedValue: { min(1.0, Double($0.swapUsedBytes) / maxSwap) },
            dashed: true
        )

        // Track 3: Disk Read + Write B/s
        let maxDisk = max(Double(10 * 1024 * 1024), Double(ticks.map { $0.diskReadBps + $0.diskWriteBps }.max() ?? 1))
        drawTrace(
            ctx: &ctx,
            rect: laneRects[2],
            color: ChronoTheme.diskPine,
            xForTs: xForTs,
            normalizedValue: { min(1.0, Double($0.diskReadBps + $0.diskWriteBps) / maxDisk) }
        )

        // Track 4: Network Out + In B/s
        let maxNet = max(Double(2 * 1024 * 1024), Double(ticks.map { $0.netOutBps + $0.netInBps }.max() ?? 1))
        drawTrace(
            ctx: &ctx,
            rect: laneRects[3],
            color: ChronoTheme.netPlum,
            xForTs: xForTs,
            normalizedValue: { min(1.0, Double($0.netOutBps + $0.netInBps) / maxNet) }
        )

        // Track 5: AI Agent Burst Ribbons
        let agentRect = laneRects[4]
        for win in agentWindows {
            if win.endTs < minTs || win.startTs > maxTs { continue }
            let x1 = xForTs(max(minTs, win.startTs))
            let x2 = max(x1 + 6, xForTs(min(maxTs, win.endTs)))
            let bar = CGRect(x: x1, y: agentRect.minY + 5, width: min(agentRect.maxX - x1, x2 - x1), height: agentRect.height - 8)
            let path = Path(roundedRect: bar, cornerRadius: 3)
            ctx.fill(path, with: .color(ChronoTheme.playheadRed.opacity(0.22)))
            ctx.stroke(path, with: .color(ChronoTheme.playheadRed.opacity(0.75)), lineWidth: 1)
        }

        // Anomaly Bookmark Diamonds on top rail
        for bm in anomalies where bm.ts >= minTs && bm.ts <= maxTs {
            let ax = xForTs(bm.ts)
            var tri = Path()
            tri.move(to: CGPoint(x: ax, y: topPad + 7))
            tri.addLine(to: CGPoint(x: ax - 4.5, y: topPad + 1))
            tri.addLine(to: CGPoint(x: ax + 4.5, y: topPad + 1))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(ChronoTheme.playheadRed))
        }

        // Scrubbed Playhead Shuttle Needle
        let activeTs = scrubbedTimestamp ?? maxTs
        let px = xForTs(activeTs)
        let highlightBand = CGRect(x: max(plotX, px - 10), y: topPad, width: 20, height: curY - topPad - 4)
        ctx.fill(Path(highlightBand), with: .color(ChronoTheme.playheadRed.opacity(scrubbedTimestamp != nil ? 0.08 : 0.03)))

        var needle = Path()
        needle.move(to: CGPoint(x: px, y: topPad))
        needle.addLine(to: CGPoint(x: px, y: curY - 4))
        ctx.stroke(needle, with: .color(ChronoTheme.playheadRed), lineWidth: 1.5)

        let capRect = CGRect(x: px - 4, y: topPad - 2, width: 8, height: 8)
        ctx.fill(Path(ellipseIn: capRect), with: .color(ChronoTheme.playheadRed))
    }

    private func drawTrace(
        ctx: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        xForTs: (Int64) -> CGFloat,
        normalizedValue: (SystemTick) -> Double
    ) {
        var line = Path()
        var area = Path()
        for (idx, t) in ticks.enumerated() {
            let x = xForTs(t.ts)
            let v = CGFloat(normalizedValue(t))
            let y = rect.maxY - max(1.0, v * (rect.height - 3))
            if idx == 0 {
                line.move(to: CGPoint(x: x, y: y))
                area.move(to: CGPoint(x: x, y: rect.maxY))
                area.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                area.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if let last = ticks.last {
            area.addLine(to: CGPoint(x: xForTs(last.ts), y: rect.maxY))
            area.closeSubpath()
        }
        ctx.fill(area, with: .color(color.opacity(0.14)))
        ctx.stroke(line, with: .color(color), lineWidth: 1.5)
    }

    private func drawLineOnly(
        ctx: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        xForTs: (Int64) -> CGFloat,
        normalizedValue: (SystemTick) -> Double,
        dashed: Bool
    ) {
        var line = Path()
        for (idx, t) in ticks.enumerated() {
            let x = xForTs(t.ts)
            let v = CGFloat(normalizedValue(t))
            let y = rect.maxY - max(1.0, v * (rect.height - 3))
            if idx == 0 {
                line.move(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
            }
        }
        let style = dashed ? StrokeStyle(lineWidth: 1.2, dash: [4, 2.5]) : StrokeStyle(lineWidth: 1.2)
        ctx.stroke(line, with: .color(color), style: style)
    }
}
