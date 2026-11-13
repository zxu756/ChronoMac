import SwiftUI

public struct ChronoMenuBarView: View {
    @ObservedObject var monitor: ChronoMonitor
    public let displayTimeZone: TimeZone
    public var onOpenDashboard: () -> Void
    public var onQuit: () -> Void

    public init(
        monitor: ChronoMonitor,
        displayTimeZone: TimeZone = .current,
        onOpenDashboard: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.displayTimeZone = displayTimeZone
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
    }

    public var body: some View {
        let t = monitor.ticks.last

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(ChronoTheme.cpuAmber)
                        Text("ChronoMac Flightbox")
                            .font(.system(size: 13.5, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(ChronoTheme.ink)
                    }
                    Text("\(monitor.anomalies.count) incident bookmarks in \(monitor.selectedRange.rawValue)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ChronoTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.0f%% CPU", t?.totalCPUPct ?? 0))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(ChronoTheme.ink)
                    Text("Swap \(ChronoFormatter.bytes(t?.swapUsedBytes ?? 0))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ChronoTheme.memCobalt)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
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
                Text("Recent forensic bookmarks")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ChronoTheme.muted)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChronoTheme.band)

                Rectangle().fill(ChronoTheme.rowRule).frame(height: 1)

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
                                    Text("\(ChronoFormatter.clockTime(bm.ts, timeZone: displayTimeZone)) · \(bm.kind.rawValue)")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(ChronoTheme.ink)
                                    Spacer()
                                    Text(verbatim: bm.metricBadge)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(ChronoTheme.playheadRed)
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

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Text("Open DVR timeline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.ink))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.returnToLive() }) {
                    Text("Live now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChronoTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChronoTheme.viewport))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ChronoTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundStyle(ChronoTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
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
