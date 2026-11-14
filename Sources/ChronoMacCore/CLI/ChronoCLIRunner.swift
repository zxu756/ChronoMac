import Foundation

public enum ChronoCLIRunner {
    public struct ParsedOptions {
        public var subcommand: String = "status"
        public var language: AppLanguage
        public var jsonOutput: Bool = false
        public var showHelp: Bool = false
        public var databaseURL: URL
        public var atSpec: String?
        public var epochOverride: Int64?
        public var minutes: Int = 360
        public var hours: Int = 24
        public var sortOrder: ProcessSortOrder = .cpu
    }

    public static func run(
        arguments: [String] = CommandLine.arguments,
        sampler: any SystemSamplerProtocol = LiveSystemSampler(),
        nowProvider: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) -> Int32 {
        var stdoutText = ""
        var stderrText = ""
        let code = execute(
            arguments: arguments,
            sampler: sampler,
            nowProvider: nowProvider,
            stdout: &stdoutText,
            stderr: &stderrText
        )
        if !stdoutText.isEmpty {
            FileHandle.standardOutput.write(Data(stdoutText.utf8))
        }
        if !stderrText.isEmpty {
            FileHandle.standardError.write(Data(stderrText.utf8))
        }
        return code
    }

    public static func execute(
        arguments: [String],
        sampler: any SystemSamplerProtocol = LiveSystemSampler(),
        nowProvider: () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        stdout: inout String,
        stderr: inout String
    ) -> Int32 {
        let initialLanguage = AppLocalizer.resolveLanguage(arguments: arguments)
        let parsedResult = parseOptions(arguments: arguments, fallbackLanguage: initialLanguage)
        let options: ParsedOptions
        switch parsedResult {
        case .success(let opts):
            options = opts
        case .failure(let err):
            stderr += err.message + "\n"
            return err.exitCode
        }

        if options.showHelp || options.subcommand == "help" {
            stdout += usageText(in: options.language) + "\n"
            return 0
        }

        let lang = options.language
        let store: FlightboxStore
        do {
            store = try FlightboxStore(databaseURL: options.databaseURL, readOnly: true)
        } catch {
            let msg = lang == .zhHans
                ? "错误：无法只读打开 ChronoMac 飞行记录库 (\(options.databaseURL.path))：\(error.localizedDescription)"
                : "Error: Could not open ChronoMac SQLite flightbox read-only (\(options.databaseURL.path)): \(error.localizedDescription)"
            stderr += msg + "\n"
            return 1
        }

        let now = nowProvider()

        switch options.subcommand {
        case "status":
            return runStatus(options: options, store: store, sampler: sampler, now: now, stdout: &stdout)

        case "blame":
            return runBlame(options: options, store: store, sampler: sampler, now: now, stdout: &stdout, stderr: &stderr)

        case "anomalies":
            return runAnomalies(options: options, store: store, now: now, stdout: &stdout)

        case "egress":
            return runEgress(options: options, store: store, now: now, stdout: &stdout)

        default:
            let msg = lang == .zhHans
                ? "错误：未知 CLI 子命令 '\(options.subcommand)'。支持的子命令：status、blame、anomalies、egress（使用 --help 查看用法）。"
                : "Error: Unknown CLI subcommand '\(options.subcommand)'. Supported subcommands: status, blame, anomalies, egress (use --help for usage)."
            stderr += msg + "\n"
            return 2
        }
    }

    // MARK: - Subcommands

    private static func runStatus(
        options: ParsedOptions,
        store: FlightboxStore,
        sampler: any SystemSamplerProtocol,
        now: Int64,
        stdout: inout String
    ) -> Int32 {
        let lang = options.language
        let dbExists = FileManager.default.fileExists(atPath: store.dbPath)
        let ticks = store.queryTicks(from: now - 3600, to: now)
        let storageBytes = store.totalStorageBytes()
        let host = sampler.sampleCalibratedHostState(interval: 1.0)
        let totalCPU = host.totalCPUPct

        if options.jsonOutput {
            let obj: [String: Any] = [
                "dbPath": store.dbPath,
                "dbExists": dbExists,
                "samplesLastHour": ticks.count,
                "storageBytes": storageBytes,
                "sampleIntervalSeconds": 1.0,
                "cpuPct": roundToTenth(totalCPU),
                "cpuUserPct": roundToTenth(host.cpuUserPct),
                "cpuSysPct": roundToTenth(host.cpuSysPct),
                "memUsedBytes": host.memUsedBytes,
                "memTotalBytes": host.memTotalBytes,
                "swapUsedBytes": host.swapUsedBytes,
                "thermal": host.thermal.label(in: lang)
            ]
            stdout += encodeJSON(obj) + "\n"
            return 0
        }

        if lang == .zhHans {
            let dbState = dbExists ? "就绪" : "尚未初始化（打开 ChronoMac 窗口即可录制）"
            stdout += "ChronoMac 飞行记录库: \(store.dbPath) (\(dbState) · 最近 1 小时 \(ticks.count) 条采样 · 磁盘占用 \(ChronoFormatter.bytes(storageBytes)))\n"
            stdout += String(
                format: "实时主机 (1.0 秒双次采样校准) | CPU: %.1f%% (用户 %.1f%%, 系统 %.1f%%) | 内存: %@ / %@ | 交换: %@ | 热态: %@\n",
                totalCPU,
                host.cpuUserPct,
                host.cpuSysPct,
                ChronoFormatter.bytes(host.memUsedBytes),
                ChronoFormatter.bytes(host.memTotalBytes),
                ChronoFormatter.bytes(host.swapUsedBytes),
                host.thermal.label(in: .zhHans)
            )
        } else {
            let dbState = dbExists ? "ready" : "not initialized (open ChronoMac app to record)"
            stdout += "ChronoMac Flightbox: \(store.dbPath) (\(dbState) · \(ticks.count) samples in last 1h · Storage \(ChronoFormatter.bytes(storageBytes)))\n"
            stdout += String(
                format: "Live Host (1.0s calibrated) | CPU: %.1f%% (%.1f%% user, %.1f%% sys) | Memory: %@ / %@ | Swap: %@ | Thermal: %@\n",
                totalCPU,
                host.cpuUserPct,
                host.cpuSysPct,
                ChronoFormatter.bytes(host.memUsedBytes),
                ChronoFormatter.bytes(host.memTotalBytes),
                ChronoFormatter.bytes(host.swapUsedBytes),
                host.thermal.label(in: .en)
            )
        }
        return 0
    }

    private static func runBlame(
        options: ParsedOptions,
        store: FlightboxStore,
        sampler: any SystemSamplerProtocol,
        now: Int64,
        stdout: inout String,
        stderr: inout String
    ) -> Int32 {
        let lang = options.language
        let targetTs: Int64
        if let epoch = options.epochOverride {
            targetTs = epoch
        } else if let spec = options.atSpec {
            guard let resolved = parseAtSpec(spec, now: now) else {
                let msg = lang == .zhHans
                    ? "错误：无效的时间参数 '--at \(spec)'。示例：10m、2h、30s 或 Unix 秒级时间戳。"
                    : "Error: Invalid '--at \(spec)' value. Examples: 10m, 2h, 30s, or Unix epoch seconds."
                stderr += msg + "\n"
                return 2
            }
            targetTs = resolved
        } else {
            targetTs = now - 600
        }

        let livePIDs = sampler.currentLivePIDs()
        let (actualTs, procs) = store.queryNearestProcesses(
            at: targetTs,
            livePIDs: livePIDs,
            sortBy: options.sortOrder
        )

        guard let resolvedTs = actualTs, !procs.isEmpty else {
            let msg = lang == .zhHans
                ? "未找到所查时刻 \(ChronoFormatter.isoTimestamp(targetTs)) (epoch \(targetTs)) 附近 60 分钟内的进程快照。"
                : "No recorded process snapshot within 60m of requested timestamp \(ChronoFormatter.isoTimestamp(targetTs)) (epoch \(targetTs))."
            stderr += msg + "\n"
            return 1
        }

        let deltaSec = abs(resolvedTs - targetTs)

        if options.jsonOutput {
            let procDicts: [[String: Any]] = procs.prefix(20).map { p in
                var d: [String: Any] = [
                    "pid": p.pid,
                    "ppid": p.ppid,
                    "name": p.name,
                    "execPath": p.execPath,
                    "isCPUReadable": p.isCPUReadable,
                    "cpuDisplay": p.formattedCPU(in: lang),
                    "memoryFootprintBytes": p.memoryFootprintBytes,
                    "diskReadBps": p.diskReadBps,
                    "diskWriteBps": p.diskWriteBps,
                    "netInBps": p.netInBps,
                    "netOutBps": p.netOutBps,
                    "isAliveNow": p.isAliveNow,
                    "status": p.livenessLabel(in: lang)
                ]
                d["cpuPct"] = p.isCPUReadable ? roundToTenth(p.cpuPct) : NSNull()
                return d
            }
            let payload: [String: Any] = [
                "requestedTimestamp": targetTs,
                "snapshotTimestamp": resolvedTs,
                "snapshotISO": ChronoFormatter.isoTimestamp(resolvedTs),
                "deltaSeconds": deltaSec,
                "sortBy": options.sortOrder.rawValue,
                "memoryMetric": "phys_footprint",
                "processes": procDicts
            ]
            stdout += encodeJSON(payload) + "\n"
            return 0
        }

        var lines: [String] = []
        if lang == .zhHans {
            lines.append(
                "取自 \(ChronoFormatter.isoTimestamp(resolvedTs)) 的快照（距所查时刻差 \(deltaSec) 秒，epoch \(resolvedTs)） · 排序：\(options.sortOrder.label(in: .zhHans))"
            )
            lines.append(
                "  PID     进程名称                  CPU           物理内存占用 (phys_footprint)   外联上行     当前状态       可执行路径"
            )
            for p in procs.prefix(15) {
                let cpuCol = padRight(p.formattedCPU(in: .zhHans), width: 12)
                let memCol = padRight(ChronoFormatter.bytes(p.memoryFootprintBytes), width: 29)
                let netCol = padRight(ChronoFormatter.rate(p.netOutBps), width: 11)
                let stateCol = padRight(p.livenessLabel(in: .zhHans), width: 12)
                let pathCol = p.execPath.isEmpty ? "（路径不可用）" : ChronoFormatter.displayPath(p.execPath)
                let pidCol = padRight(String(p.pid), width: 7)
                let nameCol = padRight(p.name, width: 24)
                lines.append("  \(pidCol) \(nameCol) \(cpuCol) \(memCol) \(netCol) \(stateCol) \(pathCol)")
            }
        } else {
            lines.append(
                "Snapshot at \(ChronoFormatter.isoTimestamp(resolvedTs)) (epoch \(resolvedTs), \(deltaSec)s from requested time) · Ranking: \(options.sortOrder.label(in: .en))"
            )
            lines.append(
                "  PID     Process                   CPU            Memory Footprint (phys_footprint)  NetOut       Status              Executable Path"
            )
            for p in procs.prefix(15) {
                let pidCol = padRight(String(p.pid), width: 7)
                let nameCol = padRight(p.name, width: 25)
                let cpuCol = padRight(p.formattedCPU(in: .en), width: 14)
                let memCol = padRight(ChronoFormatter.bytes(p.memoryFootprintBytes), width: 34)
                let netCol = padRight(ChronoFormatter.rate(p.netOutBps), width: 12)
                let stateCol = padRight(p.livenessLabel(in: .en), width: 19)
                let pathCol = p.execPath.isEmpty ? "(path unavailable)" : ChronoFormatter.displayPath(p.execPath)
                lines.append("  \(pidCol) \(nameCol) \(cpuCol) \(memCol) \(netCol) \(stateCol) \(pathCol)")
            }
        }

        stdout += lines.joined(separator: "\n") + "\n"
        return 0
    }

    private static func runAnomalies(
        options: ParsedOptions,
        store: FlightboxStore,
        now: Int64,
        stdout: inout String
    ) -> Int32 {
        let lang = options.language
        let minutes = max(1, min(10_080, options.minutes))
        let start = now - Int64(minutes * 60)
        let ticks = store.queryTicks(from: start, to: now)
        let anomalies = store.queryAnomalies(sinceTs: start, limit: 25)
        let peakCPU = ticks.max(by: { $0.totalCPUPct < $1.totalCPUPct })
        let peakSwap = ticks.max(by: { $0.swapUsedBytes < $1.swapUsedBytes })
        let peakOut = ticks.max(by: { $0.netOutBps < $1.netOutBps })

        if options.jsonOutput {
            let items: [[String: Any]] = anomalies.map { a in
                [
                    "id": a.id,
                    "ts": a.ts,
                    "isoTimestamp": ChronoFormatter.isoTimestamp(a.ts),
                    "kind": a.kind.label(in: lang),
                    "severity": a.severity,
                    "culpritName": a.culpritName,
                    "culpritExec": a.culpritExec,
                    "metricBadge": a.localizedMetricBadge(in: lang),
                    "summary": a.summary
                ]
            }
            let payload: [String: Any] = [
                "windowMinutes": minutes,
                "sampleCount": ticks.count,
                "peakCPUPct": roundToTenth(peakCPU?.totalCPUPct ?? 0),
                "peakSwapBytes": peakSwap?.swapUsedBytes ?? 0,
                "peakExternalOutBps": peakOut?.netOutBps ?? 0,
                "anomalies": items
            ]
            stdout += encodeJSON(payload) + "\n"
            return 0
        }

        var lines: [String] = []
        if lang == .zhHans {
            lines.append("ChronoMac 异常书签与窗口摘要（最近 \(minutes) 分钟，共 \(ticks.count) 条采样）：")
            lines.append("- 峰值 CPU: \(String(format: "%.1f%%", peakCPU?.totalCPUPct ?? 0))（\(peakCPU.map { ChronoFormatter.clockTime($0.ts) } ?? "无")）")
            lines.append("- 峰值交换: \(ChronoFormatter.bytes(peakSwap?.swapUsedBytes ?? 0))（\(peakSwap.map { ChronoFormatter.clockTime($0.ts) } ?? "无")）")
            lines.append("- 峰值外部上行: \(ChronoFormatter.rate(peakOut?.netOutBps ?? 0))（\(peakOut.map { ChronoFormatter.clockTime($0.ts) } ?? "无")）")
            if anomalies.isEmpty {
                lines.append("窗口内未检测到异常书签。")
            } else {
                lines.append("已记录异常书签（共 \(anomalies.count) 条）：")
                for a in anomalies {
                    lines.append("  [\(ChronoFormatter.isoTimestamp(a.ts))] \(a.kind.label(in: .zhHans)) (\(a.localizedMetricBadge(in: .zhHans))) · \(a.culpritName) — \(a.summary)")
                }
            }
        } else {
            lines.append("ChronoMac Window Summary & Anomalies (last \(minutes) min, \(ticks.count) samples):")
            lines.append("- Peak CPU: \(String(format: "%.1f%%", peakCPU?.totalCPUPct ?? 0)) at \(peakCPU.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")")
            lines.append("- Peak Swap: \(ChronoFormatter.bytes(peakSwap?.swapUsedBytes ?? 0)) at \(peakSwap.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")")
            lines.append("- Peak External Outbound Egress: \(ChronoFormatter.rate(peakOut?.netOutBps ?? 0)) at \(peakOut.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")")
            if anomalies.isEmpty {
                lines.append("No anomaly bookmarks recorded in this window.")
            } else {
                lines.append("Recorded Anomaly Bookmarks (\(anomalies.count)):")
                for a in anomalies {
                    lines.append("  [\(ChronoFormatter.isoTimestamp(a.ts))] \(a.kind.label(in: .en)) (\(a.metricBadge)) · \(a.culpritName) — \(a.summary)")
                }
            }
        }
        stdout += lines.joined(separator: "\n") + "\n"
        return 0
    }

    private static func runEgress(
        options: ParsedOptions,
        store: FlightboxStore,
        now: Int64,
        stdout: inout String
    ) -> Int32 {
        let lang = options.language
        let hours = max(1, min(168, options.hours))
        let flows = store.querySocketFlows(sinceTs: now - Int64(hours * 3600), limit: 25)

        if options.jsonOutput {
            let items: [[String: Any]] = flows.map { f in
                [
                    "processName": f.processName,
                    "execPath": f.execPath,
                    "remoteEndpoint": f.remoteEndpoint,
                    "hostname": f.hostname ?? NSNull(),
                    "protocol": f.protocolName,
                    "totalBytesOut": f.totalBytesOut,
                    "totalBytesIn": f.totalBytesIn,
                    "firstSeen": f.firstSeen,
                    "lastSeen": f.lastSeen
                ]
            }
            let payload: [String: Any] = [
                "windowHours": hours,
                "loopbackExcluded": true,
                "flows": items
            ]
            stdout += encodeJSON(payload) + "\n"
            return 0
        }

        if flows.isEmpty {
            if lang == .zhHans {
                stdout += "最近 \(hours) 小时内未记录到外部远程套接字流量（本机回环流量已单独隔离）。\n"
            } else {
                stdout += "No external socket flows recorded in the last \(hours)h (loopback traffic excluded).\n"
            }
            return 0
        }

        var lines: [String] = []
        if lang == .zhHans {
            lines.append("外部远程套接字流量账本（最近 \(hours) 小时，不含 127.0.0.1/::1 回环）：")
            for f in flows {
                let host = f.hostname ?? f.remoteEndpoint
                let pathLabel = f.execPath.isEmpty ? "（路径不可用）" : ChronoFormatter.displayPath(f.execPath)
                lines.append(
                    "  \(f.processName) -> \(host) | 上行: \(ChronoFormatter.bytes(f.totalBytesOut)) | 下行: \(ChronoFormatter.bytes(f.totalBytesIn)) | 路径: \(pathLabel)"
                )
            }
        } else {
            lines.append("Top External Socket Flows (last \(hours)h, loopback excluded):")
            for f in flows {
                let host = f.hostname ?? f.remoteEndpoint
                let pathLabel = f.execPath.isEmpty ? "(path unavailable)" : ChronoFormatter.displayPath(f.execPath)
                lines.append(
                    "  \(f.processName) -> \(host) | Out: \(ChronoFormatter.bytes(f.totalBytesOut)) | In: \(ChronoFormatter.bytes(f.totalBytesIn)) | Path: \(pathLabel)"
                )
            }
        }
        stdout += lines.joined(separator: "\n") + "\n"
        return 0
    }

    // MARK: - Option Parsing & Helpers

    private struct CLIParseError: Error {
        let exitCode: Int32
        let message: String
    }

    private static func parseOptions(
        arguments: [String],
        fallbackLanguage: AppLanguage
    ) -> Result<ParsedOptions, CLIParseError> {
        var opts = ParsedOptions(
            language: fallbackLanguage,
            databaseURL: FlightboxStore.resolveDatabaseURL(arguments: arguments)
        )

        var positional: [String] = []
        var idx = 1 // skip executable path
        while idx < arguments.count {
            let arg = arguments[idx]
            switch arg {
            case "--cli":
                idx += 1
            case "--json":
                opts.jsonOutput = true
                idx += 1
            case "--help", "-h":
                opts.showHelp = true
                idx += 1
            case "--db":
                guard idx + 1 < arguments.count else {
                    return .failure(CLIParseError(exitCode: 2, message: missingValueError("--db", in: opts.language)))
                }
                opts.databaseURL = URL(fileURLWithPath: (arguments[idx + 1] as NSString).expandingTildeInPath)
                idx += 2
            case _ where arg.hasPrefix("--db="):
                let val = String(arg.dropFirst("--db=".count))
                guard !val.isEmpty else {
                    return .failure(CLIParseError(exitCode: 2, message: missingValueError("--db", in: opts.language)))
                }
                opts.databaseURL = URL(fileURLWithPath: (val as NSString).expandingTildeInPath)
                idx += 1
            case "--lang":
                guard idx + 1 < arguments.count, let parsed = AppLanguage.parse(arguments[idx + 1]) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--lang", in: opts.language)))
                }
                opts.language = parsed
                idx += 2
            case _ where arg.hasPrefix("--lang="):
                let val = String(arg.dropFirst("--lang=".count))
                guard let parsed = AppLanguage.parse(val) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--lang", in: opts.language)))
                }
                opts.language = parsed
                idx += 1
            case "--at":
                guard idx + 1 < arguments.count else {
                    return .failure(CLIParseError(exitCode: 2, message: missingValueError("--at", in: opts.language)))
                }
                opts.atSpec = arguments[idx + 1]
                idx += 2
            case _ where arg.hasPrefix("--at="):
                opts.atSpec = String(arg.dropFirst("--at=".count))
                idx += 1
            case "--epoch":
                guard idx + 1 < arguments.count, let v = Int64(arguments[idx + 1]) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--epoch", in: opts.language)))
                }
                opts.epochOverride = v
                idx += 2
            case _ where arg.hasPrefix("--epoch="):
                let val = String(arg.dropFirst("--epoch=".count))
                guard let v = Int64(val) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--epoch", in: opts.language)))
                }
                opts.epochOverride = v
                idx += 1
            case "--minutes":
                guard idx + 1 < arguments.count, let v = Int(arguments[idx + 1]), v > 0 else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--minutes", in: opts.language)))
                }
                opts.minutes = v
                idx += 2
            case _ where arg.hasPrefix("--minutes="):
                let val = String(arg.dropFirst("--minutes=".count))
                guard let v = Int(val), v > 0 else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--minutes", in: opts.language)))
                }
                opts.minutes = v
                idx += 1
            case "--hours":
                guard idx + 1 < arguments.count, let v = Int(arguments[idx + 1]), v > 0 else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--hours", in: opts.language)))
                }
                opts.hours = v
                idx += 2
            case _ where arg.hasPrefix("--hours="):
                let val = String(arg.dropFirst("--hours=".count))
                guard let v = Int(val), v > 0 else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--hours", in: opts.language)))
                }
                opts.hours = v
                idx += 1
            case "--sort":
                guard idx + 1 < arguments.count, let s = ProcessSortOrder.parse(arguments[idx + 1]) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--sort", in: opts.language)))
                }
                opts.sortOrder = s
                idx += 2
            case _ where arg.hasPrefix("--sort="):
                let val = String(arg.dropFirst("--sort=".count))
                guard let s = ProcessSortOrder.parse(val) else {
                    return .failure(CLIParseError(exitCode: 2, message: invalidValueError("--sort", in: opts.language)))
                }
                opts.sortOrder = s
                idx += 1
            case _ where arg.hasPrefix("-"):
                let msg = opts.language == .zhHans
                    ? "错误：未知选项 '\(arg)'（使用 --help 查看用法）。"
                    : "Error: Unknown option '\(arg)' (use --help for usage)."
                return .failure(CLIParseError(exitCode: 2, message: msg))
            default:
                positional.append(arg)
                idx += 1
            }
        }

        if let first = positional.first {
            opts.subcommand = first
            if positional.count > 1 {
                let extra = positional.dropFirst().joined(separator: " ")
                let msg = opts.language == .zhHans
                    ? "错误：子命令 '\(first)' 后存在多余参数 '\(extra)'。"
                    : "Error: Unexpected argument '\(extra)' after subcommand '\(first)'."
                return .failure(CLIParseError(exitCode: 2, message: msg))
            }
        }
        return .success(opts)
    }

    private static func parseAtSpec(_ raw: String, now: Int64) -> Int64? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return nil }
        if token == "now" { return now }
        if let plain = Int64(token) {
            if plain >= 1_000_000_000 {
                return plain
            } else if plain >= 0 {
                return now - plain * 60
            }
            return nil
        }
        if token.hasSuffix("s"), let sec = Int64(token.dropLast()), sec >= 0 {
            return now - sec
        }
        if token.hasSuffix("m"), let min = Int64(token.dropLast()), min >= 0 {
            return now - min * 60
        }
        if token.hasSuffix("h"), let hr = Int64(token.dropLast()), hr >= 0 {
            return now - hr * 3600
        }
        if token.hasSuffix("d"), let day = Int64(token.dropLast()), day >= 0 {
            return now - day * 86_400
        }
        return nil
    }

    private static func missingValueError(_ flag: String, in language: AppLanguage) -> String {
        language == .zhHans
            ? "错误：选项 '\(flag)' 缺少参数值。"
            : "Error: Missing value for option '\(flag)'."
    }

    private static func invalidValueError(_ flag: String, in language: AppLanguage) -> String {
        language == .zhHans
            ? "错误：选项 '\(flag)' 的参数值无效。"
            : "Error: Invalid value for option '\(flag)'."
    }

    private static func roundToTenth(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }

    private static func padRight(_ text: String, width: Int) -> String {
        if text.count >= width { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func encodeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    public static func usageText(in language: AppLanguage) -> String {
        if language == .zhHans {
            return """
            用法: ChronoMac --cli <status|blame|anomalies|egress> [选项]

            子命令:
              status      双次采样（间隔 1.0 秒）输出实时主机 CPU/内存/交换/热态与飞行记录库状态
              blame       回溯指定时刻的进程快照（含时间偏差秒数、物理内存占用 phys_footprint 与进程存活状态）
              anomalies   输出窗口内的峰值摘要与异常书签
              egress      输出外部远程网络流量账本（不含本机回环）

            选项:
              --db <path>                 指定 SQLite 数据库路径（只读查询；也可用 CHRONOMAC_DB_PATH）
              --lang <en|zh>              输出语言（默认跟随系统语言）
              --json                      输出结构化 JSON（默认输出人类可读文本）
              --at <10m|2h|30s|epoch>     blame 查询目标时间（默认 10m）
              --sort <cpu|memory|network> blame 排序维度（默认 cpu）
              --minutes <N>               anomalies 回溯分钟数（默认 360）
              --hours <N>                 egress 回溯小时数（默认 24）
            """
        } else {
            return """
            Usage: ChronoMac --cli <status|blame|anomalies|egress> [options]

            Subcommands:
              status      Sample host CPU twice 1.0s apart and report live CPU/Memory/Swap/Thermal & flightbox status
              blame       Inspect historical process snapshot (with delta seconds, Memory Footprint phys_footprint & liveness)
              anomalies   Summarize window peaks and recorded anomaly bookmarks
              egress      List external remote socket flows (loopback excluded)

            Options:
              --db <path>                 SQLite database path (opened read-only; overrides CHRONOMAC_DB_PATH)
              --lang <en|zh>              Output language (defaults to system locale)
              --json                      Emit structured JSON instead of human-readable text
              --at <10m|2h|30s|epoch>     Target lookback or timestamp for blame (default: 10m)
              --sort <cpu|memory|network> Ranking mode for blame (default: cpu)
              --minutes <N>               Lookback window in minutes for anomalies (default: 360)
              --hours <N>                 Lookback window in hours for egress (default: 24)
            """
        }
    }
}
