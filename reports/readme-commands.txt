========================================================================
Replaying README.md & README.zh-CN.md CLI + MCP Commands
========================================================================

$ ChronoMac --cli status --lang en
ChronoMac Flightbox: /var/folders/d5/4h6nzhm94l91870kmn7p8q040000gn/T/chronomac-readme.m0KThT/flightbox.sqlite (ready · 1 samples in last 1h · Storage 68 KB)
Live Host (1.0s calibrated) | CPU: 29.0% (22.3% user, 6.7% sys) | Memory: 10.35 GB / 16.00 GB | Swap: 4.73 GB | Thermal: Nominal

$ ChronoMac --cli status --lang zh
ChronoMac 飞行记录库: /var/folders/d5/4h6nzhm94l91870kmn7p8q040000gn/T/chronomac-readme.m0KThT/flightbox.sqlite (就绪 · 最近 1 小时 1 条采样 · 磁盘占用 68 KB)
实时主机 (1.0 秒双次采样校准) | CPU: 29.3% (用户 22.2%, 系统 7.1%) | 内存: 10.43 GB / 16.00 GB | 交换: 4.73 GB | 热态: 正常

$ ChronoMac --cli status --json
{"cpuPct":27.600000000000001,"cpuSysPct":6.4000000000000004,"cpuUserPct":21.199999999999999,"dbExists":true,"dbPath":"\/var\/folders\/d5\/4h6nzhm94l91870kmn7p8q040000gn\/T\/chronomac-readme.m0KThT\/flightbox.sqlite","memTotalBytes":17179869184,"memUsedBytes":11324538880,"sampleIntervalSeconds":1,"samplesLastHour":1,"storageBytes":69632,"swapUsedBytes":5080675778,"thermal":"正常"}

$ ChronoMac --cli blame --at 10m --sort cpu --lang en
Snapshot at 2026-11-14 17:05:31 (epoch 1794629131, 7s from requested time) · Ranking: By CPU
  PID     Process                   CPU            Memory Footprint (phys_footprint)  NetOut       Status              Executable Path
  999992  ephemeral-indexer         225.4%         3.54 GB                            13.4 MB/s    exited after spike  /usr/local/bin/ephemeral-indexer
  52715   readme-shell              18.2%          401 MB                             0 KB/s       still running       /bin/bash
  1       launchd                   No permission  0 MB                               0 KB/s       still running       /sbin/launchd

$ ChronoMac --cli blame --at 10m --sort cpu --lang zh
取自 2026-11-14 17:05:31 的快照（距所查时刻差 7 秒，epoch 1794629131） · 排序：按 CPU
  PID     进程名称                  CPU           物理内存占用 (phys_footprint)   外联上行     当前状态       可执行路径
  999992  ephemeral-indexer        225.4%       3.54 GB                       13.4 MB/s   尖峰后已退出       /usr/local/bin/ephemeral-indexer
  52715   readme-shell             18.2%        401 MB                        0 KB/s      仍在运行         /bin/bash
  1       launchd                  无权限          0 MB                          0 KB/s      仍在运行         /sbin/launchd

$ ChronoMac --cli blame --at 10m --sort memory --json
{"deltaSeconds":7,"memoryMetric":"phys_footprint","processes":[{"cpuDisplay":"225.4%","cpuPct":225.40000000000001,"diskReadBps":20000000,"diskWriteBps":5000000,"execPath":"\/usr\/local\/bin\/ephemeral-indexer","isAliveNow":false,"isCPUReadable":true,"memoryFootprintBytes":3800000000,"name":"ephemeral-indexer","netInBps":512000,"netOutBps":14000000,"pid":999992,"ppid":1,"status":"尖峰后已退出"},{"cpuDisplay":"18.2%","cpuPct":18.199999999999999,"diskReadBps":0,"diskWriteBps":0,"execPath":"\/bin\/bash","isAliveNow":true,"isCPUReadable":true,"memoryFootprintBytes":420000000,"name":"readme-shell","netInBps":0,"netOutBps":0,"pid":52715,"ppid":1,"status":"仍在运行"},{"cpuDisplay":"无权限","cpuPct":null,"diskReadBps":0,"diskWriteBps":0,"execPath":"\/sbin\/launchd","isAliveNow":true,"isCPUReadable":false,"memoryFootprintBytes":0,"name":"launchd","netInBps":0,"netOutBps":0,"pid":1,"ppid":0,"status":"仍在运行"}],"requestedTimestamp":1794629124,"snapshotISO":"2026-11-14 17:05:31","snapshotTimestamp":1794629131,"sortBy":"memory"}

$ ChronoMac --cli anomalies --minutes 360 --lang en
ChronoMac Window Summary & Anomalies (last 360 min, 1 samples):
- Peak CPU: 86.0% at 17:05:31
- Peak Swap: 1.40 GB at 17:05:31
- Peak External Outbound Egress: 13.4 MB/s at 17:05:31
Recorded Anomaly Bookmarks (1):
  [2026-11-14 17:05:31] Outbound spike (13.4 MB/s up) · ephemeral-indexer — ephemeral-indexer uploaded 61 MB to s3-accelerate.amazonaws.com

$ ChronoMac --cli anomalies --minutes 360 --lang zh
ChronoMac 异常书签与窗口摘要（最近 360 分钟，共 1 条采样）：
- 峰值 CPU: 86.0%（17:05:31）
- 峰值交换: 1.40 GB（17:05:31）
- 峰值外部上行: 13.4 MB/s（17:05:31）
已记录异常书签（共 1 条）：
  [2026-11-14 17:05:31] 外联突增 (↑ 13.4 MB/s) · ephemeral-indexer — ephemeral-indexer uploaded 61 MB to s3-accelerate.amazonaws.com

$ ChronoMac --cli egress --hours 24 --lang en
Top External Socket Flows (last 24h, loopback excluded):
  ephemeral-indexer -> s3-accelerate.amazonaws.com | Out: 61.0 MB | In: 1.1 MB | Path: /usr/local/bin/ephemeral-indexer

$ ChronoMac --cli egress --hours 24 --lang zh
外部远程套接字流量账本（最近 24 小时，不含 127.0.0.1/::1 回环）：
  ephemeral-indexer -> s3-accelerate.amazonaws.com | 上行: 61.0 MB | 下行: 1.1 MB | 路径: /usr/local/bin/ephemeral-indexer

$ ChronoMac --mcp (stdio JSON-RPC: initialize, tools/list, summary, inspect, egress)
{"id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"version":"0.2.0","name":"chronomac-mcp"}},"jsonrpc":"2.0"}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"inputSchema":{"type":"object","properties":{"minutes":{"type":"integer","description":"Lookback window in minutes (default 60, max 10080)."}}},"name":"chrono_summary_window","description":"Summarize peak CPU, Swap, External Network Egress, and recorded anomaly bookmarks on this Mac over the last N minutes."},{"name":"chrono_inspect_timestamp","description":"Time-travel to a historical timestamp on this Mac and list top processes by CPU, Memory Footprint (phys_footprint), or Network, reporting snapshot delta and whether each process is still running or exited after spike.","inputSchema":{"properties":{"epoch_seconds":{"description":"Target Unix timestamp in seconds.","type":"integer"},"sort_by":{"type":"string","description":"Sort mode: cpu (default), memory, or network."},"minutes_ago":{"type":"integer","description":"Relative minutes ago if epoch_seconds is omitted."}},"type":"object"}},{"name":"chrono_top_egress_endpoints","description":"List which local processes transferred the most bytes to external remote IP\/hostname endpoints (excluding loopback) over the last N hours.","inputSchema":{"properties":{"hours":{"description":"Lookback window in hours (default 24, max 168).","type":"integer"}},"type":"object"}}]}}
{"jsonrpc":"2.0","result":{"content":[{"text":"ChronoMac Window Summary (last 360 min, 1 samples):\n- Peak CPU: 86.0% at 17:05:31\n- Peak Swap: 1.40 GB at 17:05:31\n- Peak External Outbound Egress: 13.4 MB\/s at 17:05:31\nRecorded Anomaly Bookmarks:\n  [17:05:31] Outbound spike (13.4 MB\/s up): ephemeral-indexer uploaded 61 MB to s3-accelerate.amazonaws.com","type":"text"}]},"id":3}
{"result":{"content":[{"text":"Snapshot at 2026-11-14 17:05:31 (epoch 1794629131, 7s from requested time) · Ranking: By CPU:\n  PID 999992 ephemeral-indexer CPU 225.4% Memory Footprint (phys_footprint) 3.54 GB NetOut 13.4 MB\/s [exited after spike] \/usr\/local\/bin\/ephemeral-indexer\n  PID 52715  readme-shell CPU 18.2% Memory Footprint (phys_footprint) 401 MB NetOut 0 KB\/s [still running] \/bin\/bash\n  PID 1      launchd CPU No permission Memory Footprint (phys_footprint) 0 MB NetOut 0 KB\/s [still running] \/sbin\/launchd","type":"text"}]},"id":4,"jsonrpc":"2.0"}
{"jsonrpc":"2.0","id":5,"result":{"content":[{"text":"Top External Socket Flows (last 24h, loopback excluded):\n  ephemeral-indexer (\/usr\/local\/bin\/ephemeral-indexer) -> s3-accelerate.amazonaws.com | Out: 61.0 MB | In: 1.1 MB","type":"text"}]}}

========================================================================
ALL README & MCP COMMANDS REPLAYED SUCCESSFULLY
========================================================================
