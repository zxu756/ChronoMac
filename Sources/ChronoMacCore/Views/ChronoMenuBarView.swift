import SwiftUI

public struct ChronoMenuBarView: View {
    @ObservedObject var monitor: ChronoMonitor
    @ObservedObject var localizer: AppLocalizer
    public let displayTimeZone: TimeZone
    public var onOpenDashboard: () -> Void
    public var onQuit: () -> Void

    @MainActor
    public init(
        monitor: ChronoMonitor,
        localizer: AppLocalizer? = nil,
        displayTimeZone: TimeZone = .current,
        onOpenDashboard: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.localizer = localizer ?? AppLocalizer.shared
        self.displayTimeZone = displayTimeZone
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
    }

    public var body: some View {
        let t = monitor.ticks.last
        let rangeText = monitor.selectedRange.shortLabel(in: localizer.language)
        let swapBytes = ChronoFormatter.bytes(t?.swapUsedBytes ?? 0)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(ChronoTheme.cpuAmber)
                        Text(monitor.isStaticPreview ? "ChronoMac" : localizer.L("ChronoMac Flightbox", "ChronoMac 飞行匣"))
                            .font(.system(size: 13.5, weight: .bold))
                            .tracking(localizer.isChinese ? 0 : -0.2)
                            .foregroundStyle(ChronoTheme.ink)
                            .fixedSize(horizontal: true, vertical: false)
                        if monitor.isStaticPreview {
                            Text(localizer.L("[DEMO]", "[DEMO·演示]"))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(ChronoTheme.cpuAmber)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(ChronoTheme.cpuAmber.opacity(0.14))
                                )
                        }
                    }
                    Text(
                        localizer.L(
                            "\(monitor.anomalies.count) incident bookmarks in \(rangeText)",
                            "近 \(rangeText) 内 \(monitor.anomalies.count) 条异常书签"
                        )
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.muted)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                ChronoLanguageTogglePill(localizer: localizer, compact: true)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.0f%% CPU", t?.totalCPUPct ?? 0))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(ChronoTheme.ink)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(localizer.L("Swap \(swapBytes)", "交换 \(swapBytes)"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.memCobalt)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(ChronoTheme.chassis)

            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)

            // Mini Sparkline Canvas
            Canvas { ctx, size in
                guard monitor.ticks.count >= 2 else { return }
                let minTs = monitor.ticks.first!.ts
                let maxTs = max(minTs + 1, monitor.ticks.last!.ts)
                var path = Path()
                var area = Path()
                for (idx, tk) in monitor.ticks.enumerated() {
                    let x = CGFloat(Double(tk.ts - minTs) / Double(maxTs - minTs)) * size.width
                    let y = size.height - max(2, CGFloat(tk.totalCPUPct / 100.0) * (size.height - 8)) - 4
                    if idx == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                        area.move(to: CGPoint(x: x, y: size.height))
                        area.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                        area.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(ChronoTheme.cpuAmber.opacity(0.16)))
                ctx.stroke(path, with: .color(ChronoTheme.cpuAmber), lineWidth: 1.5)
            }
            .frame(height: 52)
            .background(ChronoTheme.viewport)

            Rectangle().fill(ChronoTheme.hairline).frame(height: 1)

            // Recent Incident Bookmarks
            VStack(alignment: .leading, spacing: 0) {
                Text(localizer.L("Recent forensic bookmarks", "最近取证异常书签"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0)
                    .foregroundStyle(ChronoTheme.muted)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChronoTheme.band)

                Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

                if monitor.anomalies.isEmpty {
                    Text(localizer.L("No anomalies recorded in current window", "当前窗口内暂无异常书签"))
                        .font(.system(size: 11.5))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.muted)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                } else {
                    ForEach(monitor.anomalies.prefix(3)) { bm in
                        Button(action: {
                            monitor.jumpToAnomaly(bm)
                            onOpenDashboard()
                        }) {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(ChronoTheme.playheadRed)
                                    .frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(ChronoFormatter.clockTime(bm.ts, timeZone: displayTimeZone)) · \(bm.kind.label(in: localizer.language))")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .tracking(0)
                                            .foregroundStyle(ChronoTheme.ink)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Spacer()
                                        Text(verbatim: bm.localizedMetricBadge(in: localizer.language))
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                            .tracking(0)
                                            .foregroundStyle(ChronoTheme.playheadRed)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    Text(bm.culpritName)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(ChronoTheme.muted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8.5)
                            .background(ChronoTheme.viewport)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Text(localizer.L("Open DVR timeline", "打开 DVR 时间轴"))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.ink))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.returnToLive() }) {
                    Text(localizer.L("Live now", "回到实时"))
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5.5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.viewport))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ChronoTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text(localizer.L("Quit", "退出"))
                        .font(.system(size: 12))
                        .tracking(0)
                        .foregroundStyle(ChronoTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(ChronoTheme.chassis)
        }
        .background(ChronoTheme.viewport)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ChronoTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .preferredColorScheme(.light)
    }
}
