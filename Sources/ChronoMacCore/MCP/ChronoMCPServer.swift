import Foundation

/// Read-only Model Context Protocol (MCP) JSON-RPC 2.0 server over stdio so AI coding agents
/// can query historical system spikes, process blame snapshots, and external network flows.
public final class ChronoMCPServer: Sendable {
    private let store: FlightboxStore
    private let sampler: any SystemSamplerProtocol

    public init(store: FlightboxStore, sampler: any SystemSamplerProtocol = LiveSystemSampler()) {
        self.store = store
        self.sampler = sampler
    }

    public func runStdioLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let reply = handleJSONRPCLine(trimmed) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    public func handleJSONRPCLine(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return nil
        }

        let id = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encodeResponse(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "chronomac-mcp", "version": "0.2.0"]
            ])
        case "notifications/initialized":
            return nil
        case "tools/list":
            return encodeResponse(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let text = executeTool(name: toolName, args: args)
            return encodeResponse(id: id, result: [
                "content": [["type": "text", "text": text]]
            ])
        default:
            if id != nil {
                return encodeError(id: id, code: -32601, message: "Method not found: \(method)")
            }
            return nil
        }
    }

    private func executeTool(name: String, args: [String: Any]) -> String {
        let now = Int64(Date().timeIntervalSince1970)
        switch name {
        case "chrono_summary_window":
            let minutes = max(1, min(10_080, args["minutes"] as? Int ?? 60))
            let start = now - Int64(minutes * 60)
            let ticks = store.queryTicks(from: start, to: now)
            let anomalies = store.queryAnomalies(sinceTs: start, limit: 10)
            let peakCPU = ticks.max(by: { $0.totalCPUPct < $1.totalCPUPct })
            let peakSwap = ticks.max(by: { $0.swapUsedBytes < $1.swapUsedBytes })
            let peakOut = ticks.max(by: { $0.netOutBps < $1.netOutBps })

            var lines: [String] = [
                "ChronoMac Window Summary (last \(minutes) min, \(ticks.count) samples):",
                "- Peak CPU: \(String(format: "%.1f%%", peakCPU?.totalCPUPct ?? 0)) at \(peakCPU.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")",
                "- Peak Swap: \(ChronoFormatter.bytes(peakSwap?.swapUsedBytes ?? 0)) at \(peakSwap.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")",
                "- Peak External Outbound Egress: \(ChronoFormatter.rate(peakOut?.netOutBps ?? 0)) at \(peakOut.map { ChronoFormatter.clockTime($0.ts) } ?? "n/a")"
            ]
            if !anomalies.isEmpty {
                lines.append("Recorded Anomaly Bookmarks:")
                for a in anomalies {
                    lines.append("  [\(ChronoFormatter.clockTime(a.ts))] \(a.kind.rawValue) (\(a.metricBadge)): \(a.summary)")
                }
            }
            return lines.joined(separator: "\n")

        case "chrono_inspect_timestamp":
            let targetTs: Int64
            if let tsVal = args["epoch_seconds"] as? Int {
                targetTs = Int64(tsVal)
            } else if let tsVal64 = args["epoch_seconds"] as? Int64 {
                targetTs = tsVal64
            } else if let agoMin = args["minutes_ago"] as? Int {
                targetTs = now - Int64(agoMin * 60)
            } else {
                targetTs = now
            }
            let sortOrder = ProcessSortOrder.parse(args["sort_by"] as? String) ?? .cpu
            let livePIDs = sampler.currentLivePIDs()
            let (actualTs, procs) = store.queryNearestProcesses(
                at: targetTs,
                livePIDs: livePIDs,
                sortBy: sortOrder
            )
            guard let resolved = actualTs, !procs.isEmpty else {
                return "No recorded process snapshot near timestamp \(targetTs)."
            }
            let deltaSec = abs(resolved - targetTs)
            var lines = [
                "Snapshot at \(ChronoFormatter.isoTimestamp(resolved)) (epoch \(resolved), \(deltaSec)s from requested time) · Ranking: \(sortOrder.label(in: .en)):"
            ]
            for p in procs.prefix(12) {
                let procName = p.localizedName(in: .en)
                let cpuStr = p.formattedCPU(in: .en)
                let footprintStr = ChronoFormatter.bytes(p.memoryFootprintBytes)
                let netOutStr = ChronoFormatter.rate(p.netOutBps)
                let livenessStr = p.livenessLabel(in: .en)
                let pathStr = p.execPath.isEmpty ? "(path unavailable)" : ChronoFormatter.displayPath(p.execPath)
                lines.append(
                    String(
                        format: "  PID %-6d %-24@ CPU %-13@ Memory Footprint (phys_footprint) %-10@ NetOut %-10@ [%@] %@",
                        p.pid,
                        (procName as NSString),
                        (cpuStr as NSString),
                        (footprintStr as NSString),
                        (netOutStr as NSString),
                        (livenessStr as NSString),
                        pathStr
                    )
                )
            }
            return lines.joined(separator: "\n")

        case "chrono_top_egress_endpoints":
            let hours = max(1, min(168, args["hours"] as? Int ?? 24))
            let flows = store.querySocketFlows(sinceTs: now - Int64(hours * 3600), limit: 15)
            if flows.isEmpty {
                return "No external socket flows recorded in the last \(hours)h."
            }
            var lines = ["Top External Socket Flows (last \(hours)h, loopback excluded):"]
            for f in flows {
                let procName = f.localizedProcessName(in: .en)
                let host = f.localizedEndpoint(in: .en)
                let pathNote = f.execPath.isEmpty ? "" : " (\(ChronoFormatter.displayPath(f.execPath)))"
                lines.append("  \(procName)\(pathNote) -> \(host) | Out: \(ChronoFormatter.bytes(f.totalBytesOut)) | In: \(ChronoFormatter.bytes(f.totalBytesIn))")
            }
            return lines.joined(separator: "\n")

        default:
            return "Unknown tool: \(name)"
        }
    }

    private func encodeResponse(id: Any?, result: [String: Any]) -> String? {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String? {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static let toolDefinitions: [[String: Any]] = [
        [
            "name": "chrono_summary_window",
            "description": "Summarize peak CPU, Swap, External Network Egress, and recorded anomaly bookmarks on this Mac over the last N minutes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "Lookback window in minutes (default 60, max 10080)."]
                ]
            ]
        ],
        [
            "name": "chrono_inspect_timestamp",
            "description": "Time-travel to a historical timestamp on this Mac and list top processes by CPU, Memory Footprint (phys_footprint), or Network, reporting snapshot delta and whether each process is still running or exited after spike.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "epoch_seconds": ["type": "integer", "description": "Target Unix timestamp in seconds."],
                    "minutes_ago": ["type": "integer", "description": "Relative minutes ago if epoch_seconds is omitted."],
                    "sort_by": ["type": "string", "description": "Sort mode: cpu (default), memory, or network."]
                ]
            ]
        ],
        [
            "name": "chrono_top_egress_endpoints",
            "description": "List which local processes transferred the most bytes to external remote IP/hostname endpoints (excluding loopback) over the last N hours.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "hours": ["type": "integer", "description": "Lookback window in hours (default 24, max 168)."]
                ]
            ]
        ]
    ]
}
