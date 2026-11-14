import AppKit
import ChronoMacCore
import Foundation
import SwiftUI

@main
struct ChronoMacApp: App {
    @StateObject private var monitor: ChronoMonitor
    @StateObject private var localizer: AppLocalizer
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLanguage.parseCLIArguments(args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try ChronoScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Failed to export screenshots: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--mcp") {
            do {
                let dbURL = FlightboxStore.resolveDatabaseURL(arguments: args)
                let store = try FlightboxStore(databaseURL: dbURL, readOnly: true)
                ChronoMCPServer(store: store).runStdioLoop()
                exit(0)
            } catch {
                fputs("ChronoMac MCP failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--cli") {
            let exitCode = ChronoCLIRunner.run(arguments: args)
            exit(exitCode)
        }

        let isDemoMode = args.contains("--demo")
        let appLocalizer = AppLocalizer.configureShared(
            arguments: args,
            preferenceStore: UserDefaultsPreferenceStore(.standard)
        )
        _localizer = StateObject(wrappedValue: appLocalizer)
        if isDemoMode {
            _monitor = StateObject(wrappedValue: ChronoMonitor.preview())
        } else {
            let dbURL = FlightboxStore.resolveDatabaseURL(arguments: args)
            let customStore = try? FlightboxStore(databaseURL: dbURL)
            _monitor = StateObject(wrappedValue: ChronoMonitor(store: customStore))
        }
    }

    var body: some Scene {
        Window("ChronoMac", id: "main") {
            ChronoDashboardView(monitor: monitor, localizer: localizer)
        }
        .defaultSize(width: 1124, height: 736)
        .commands {
            CommandMenu(localizer.L("Language", "语言")) {
                Button(localizer.L("Toggle Language (中文 / EN)", "切换语言 / Toggle Language")) {
                    localizer.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                ForEach(AppLanguage.allCases) { item in
                    Button {
                        localizer.setLanguage(item)
                    } label: {
                        HStack {
                            Text("\(item.displayName) (\(item.badge))")
                            if localizer.language == item {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra {
            ChronoMenuBarView(
                monitor: monitor,
                localizer: localizer,
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
                Text(monitor.menuBarLabel(in: localizer.language))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
