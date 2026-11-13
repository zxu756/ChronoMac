import AppKit
import ChronoMacCore
import Foundation
import SwiftUI

@main
struct ChronoMacApp: App {
    @StateObject private var monitor: ChronoMonitor
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            do {
                try MainActor.assumeIsolated {
                    try ChronoScreenshotExporter.exportMarketingScreenshots(to: outURL)
                }
                print("Exported 2x Retina screenshots to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Failed to export screenshots: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--mcp") {
            do {
                let store = try FlightboxStore()
                ChronoMCPServer(store: store).runStdioLoop()
                exit(0)
            } catch {
                fputs("ChronoMac MCP failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--cli") {
            let subcmd = (idx + 1 < args.count) ? args[idx + 1] : "status"
            Self.runHeadlessCLI(subcmd: subcmd, allArgs: args)
            exit(0)
        }

        _monitor = StateObject(wrappedValue: ChronoMonitor())
    }

    var body: some Scene {
        Window("ChronoMac", id: "main") {
            ChronoDashboardView(monitor: monitor)
        }
        .defaultSize(width: 1124, height: 736)

        MenuBarExtra {
            ChronoMenuBarView(
                monitor: monitor,
                onOpenDashboard: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .frame(width: 386, height: 334)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text(monitor.menuBarLabel)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static func runHeadlessCLI(subcmd: String, allArgs: [String]) {
        guard let store = try? FlightboxStore() else {
            fputs("Could not open ChronoMac SQLite flightbox.\n", stderr)
            exit(1)
        }
        let server = ChronoMCPServer(store: store)
        switch subcmd {
        case "anomalies":
            let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chrono_summary_window","arguments":{"minutes":360}}}"#
            if let out = server.handleJSONRPCLine(req) { print(out) }
        case "blame":
            var minutesAgo = 10
            if let atIdx = allArgs.firstIndex(of: "--at"), atIdx + 1 < allArgs.count {
                let token = allArgs[atIdx + 1].lowercased()
                let digits = token.filter(\.isNumber)
                if let parsed = Int(digits) {
                    minutesAgo = token.contains("h") ? parsed * 60 : parsed
                }
            }
            let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chrono_inspect_timestamp","arguments":{"minutes_ago":\#(minutesAgo)}}}"#
            if let out = server.handleJSONRPCLine(req) { print(out) }
        case "egress":
            let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chrono_top_egress_endpoints","arguments":{"hours":24}}}"#
            if let out = server.handleJSONRPCLine(req) { print(out) }
        case "record-once":
            let host = MachSystemSampler()
            let state = host.sampleHostState()
            print(
                String(
                    format: "Live Host | CPU: %.1f%% | RAM: %@ / %@ | Swap: %@ | Thermal: %@",
                    state.cpuUserPct + state.cpuSysPct,
                    ChronoFormatter.bytes(state.memUsedBytes),
                    ChronoFormatter.bytes(host.totalMemoryBytes),
                    ChronoFormatter.bytes(state.swapUsedBytes),
                    state.thermal.label
                )
            )
        default:
            let now = Int64(Date().timeIntervalSince1970)
            let ticks = store.queryTicks(from: now - 3600, to: now)
            print("ChronoMac Flightbox: \(store.dbPath) (\(ticks.count) samples in last 1h)")
            Self.runHeadlessCLI(subcmd: "record-once", allArgs: allArgs)
        }
    }
}
