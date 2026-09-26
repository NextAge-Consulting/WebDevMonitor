# WebDevMonitor

A watchdog for **PC SOFT WebDev Application Server (WAS)** on Windows. It watches every WebDev session process (`WD<ver>Session.exe`), kills the ones that run away with memory or CPU before they take the whole server down, and writes a log you can analyze to understand what your server is actually doing.

WebDevMonitor is open source, written by **Pete Halsted**, formerly of WXperts. I no longer do WebDev work, but this tool kept production servers alive. It's free for anyone still running WebDev WAS servers to use **at their own risk** (see [LICENSE](LICENSE)).

**Contributors:** Gavin Webb and Alan Cochran ran the monitor on their production servers, supplied the logs, and tested the fixes. Much of what's below was learned on their servers.

---

## 1. What It Does and Why

### The problem

A WebDev application server runs one `WD<ver>Session.exe` process per user session, often 300+ at once on a busy server during business hours. Occasionally one of those sessions **runs away**:

- **Memory bombs.** A session sitting at a normal 60-150 MB suddenly allocates gigabytes. It can go from 76 MB to 5 GB between two 5-second checks and keep going to ~16 GB. On a 32 GB server with 300 other sessions already using 60-75% of RAM, a single bomb pushes the whole machine into paging and every user suffers.
- **CPU runaways.** A session stays small in memory but gets stuck spinning, holding one or more cores as if it's in a loop.

Either way, **every user on the server feels it.** Pages slow down or the site appears to hang until the runaway ends or someone kills it.

The runaways are **intermittent and impossible to reproduce on demand**. They've been seen on multiple WebDev versions (25 and 28 at least) and on different servers running completely different applications. The fault is in the WebDev session binaries themselves, which no WebDev developer can see into or fix. Neither we nor PC SOFT support could reproduce them.

### How this started

WebDev WAS has no built-in guard against runaway sessions. The original fix was manual: notice the server is slow, open Task Manager, find the bloated session and kill it. On one occasion a user's session reached almost 4 GB. It was killed, the user came back 30 seconds later, and it shot up to several GB again. It took four kills before it stopped.

WebDev's session IDs are just operating-system process IDs, so the manual fix can be automated. An earlier PowerShell process-killer for WAS already cleaned up abandoned processes. WebDevMonitor grew out of that idea, starting as *"not a fix but at least a band-aid"*: kill any session that goes over a sane memory limit. It then grew thresholds, confirmation windows, forensics and system-wide telemetry.

**It treats the symptom, because the disease isn't ours to treat.** The defect lives in PC SOFT's binaries, so the monitor's job is to limit the damage: kill the runaway before it drags down the server for everyone else, and log enough (when, how big, how fast, what else was running) to see how often it happens and how much it costs.

### What the monitor does

`WatchWdSessions.ps1` runs as a Windows scheduled task under SYSTEM and, every 5 seconds:

1. Lists all `WD*Session` processes and their memory (working set) and CPU.
2. **Memory, two tiers:**
   - **Immediate:** a session at or above `memKillImmediate` (3,000 MB) is killed on the spot, with no waiting. Nothing legitimate gets that big. This check also runs **every second** between the 5-second cycles (`memCheckIntervalMs`). It only reads memory, which is cheap, so a memory bomb is caught seconds sooner.
   - **Sustained:** a session above `memKillSustained` (1,500 MB) for `confirmSeconds` (10s) is killed.
3. **CPU:** a session at or above `cpuThresholdPct` (25% of the whole machine) for `confirmSeconds` is killed.
4. Before each kill, dumps the last 5 minutes of that process's CPU and memory samples to the log, so you can see exactly how it failed.
5. Every 5 minutes, writes a **heartbeat** with session count, total and WebDev CPU and memory, and how many sessions are idle, busy or hot. That shows whether pressure comes from one rogue process or from hundreds of ordinary sessions.
6. When system CPU is much higher than WebDev's share, logs the **top non-WebDev processes** and their command lines, so you can see what else is eating the server.
7. At midnight, writes a **daily summary** of spikes, kills, unique sessions and peak memory.

In `monitor` mode it logs what it **would** kill (`WOULD-KILL`) without killing anything, so you can see what it would do before turning kills on.

### What we learned running it

Across several production servers and months of logs:

- **Memory bombs are real and frequent.** One server averaged more than one a day, each heading for ~16 GB. They blow up within a single 5-second poll, typically with one core busy (12.5% CPU on an 8-core server). That points to a sudden runaway allocation rather than a slow leak. The immediate kill caught every one.
- **Windows Defender was quietly eating the servers.** The non-WebDev CPU logging showed Defender (`MsMpEng`) consuming 6-26% CPU on a busy server, because it scans session and static-file I/O. Excluding the WebDev executables and site folders dropped one server's CPU from **10-25% to 4-10%**. See [Windows Defender exclusions](project-documentation/windows-defender-exclusions-webdev.md).
- **Load follows the business day.** Sessions ramp up 08:00-09:00, plateau 10:00-15:00 and wind down after 16:00. That makes the heartbeats useful for capacity planning, too.

### Unexplained CPU readings

Now and then the Windows performance counters (`Win32_PerfFormattedData_PerfProc_Process`) report CPU readings for a group of sessions at the same moment that add up to more than the whole machine has. They also show up as heartbeats with a WebDev CPU total far above 100%. We investigated this but never found the cause. The analysis tool shows the summed CPU of each group of CPU kills so you can see when it happens.

---

## 2. Install and Configure (on the WebDev server)

### Install

1. Copy the **`server/`** folder to the server as `C:\WebDevMonitor`. It holds `WatchWdSessions.ps1`, `Install-MonitorTask.ps1`, `Stop-MonitorTask.ps1` and `config.json`. Nothing else in this repo is needed on the server.
2. Edit `C:\WebDevMonitor\config.json` (settings below). The shipped config is in **`kill` mode** with the settings used in production. To watch first without killing anything, set `"mode": "monitor"`.
3. Test it by hand from an **admin** PowerShell:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File C:\WebDevMonitor\WatchWdSessions.ps1
   ```

   Press Ctrl+C to stop, then check `C:\WebDevMonitor\wd_sessions.log`.
4. Install it as a scheduled task that starts at boot under SYSTEM and restarts itself if it dies:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File C:\WebDevMonitor\Install-MonitorTask.ps1
   ```

5. Verify in Task Scheduler (`taskschd.msc`): look for **WebDevSessionMonitor**.
6. If you started in `monitor` mode, let it run for a few business days and [analyze the log](#3-run-an-analysis). When you're happy with what it would kill, set `"mode": "kill"` and re-run `Install-MonitorTask.ps1`.

### Configuration (`config.json`)

| Setting | Shipped value | Description |
|---|---|---|
| `processPattern` | `WD*Session` | Process-name wildcard. Matches WD280Session, WD310Session, etc. |
| `basePath` | `C:\WebDevMonitor` | Folder for `wd_sessions.log` |
| `mode` | `monitor` | `monitor` = log only (`WOULD-KILL`), `kill` = log and terminate |
| `logLevel` | `quiet` | `quiet` = actionable events only, `detail` = every transient spike too |
| `memKillImmediate` | `3000` | MB at which a session is killed immediately (0 disables) |
| `memKillSustained` | `1500` | MB a session must stay above for `confirmSeconds` (0 disables) |
| `cpuThresholdPct` | `25` | % of the whole machine, as Task Manager shows it (0 disables) |
| `confirmSeconds` | `10` | How long a sustained violation must last before action |
| `checkIntervalMs` | `5000` | Full-cycle interval in milliseconds: memory, CPU (WMI), sustained thresholds, tracking |
| `memCheckIntervalMs` | `1000` | Fast memory-only check between full cycles, applying only the immediate threshold. Must be less than `checkIntervalMs`. Missing or 0 turns it off, giving v4.4 behavior |
| `staleMinutes` | `10` | Drop tracking entries older than this |
| `wmiTimeoutSec` | `3` | Timeout for the WMI CPU query, so a hung query can't stall the monitor |
| `heartbeatMinutes` | `5` | Heartbeat interval (0 disables) |
| `logMaxMB` | `10` | Log size at which `wd_sessions.log` rotates to `wd_sessions.log.bak` (0 disables) |
| `dailySummary` | `true` | Write a `DAILY-SUMMARY` line at midnight |
| `detailsOnKill` | `true` | Keep a per-process ring buffer and dump it on every kill or would-kill |
| `nonWdCpuGapPct` | `20` | Log the top non-WebDev processes when system CPU exceeds WebDev CPU by this many points (0 disables) |
| `nonWdCpuTopN` | `10` | How many non-WebDev processes to log per spike |

Every setting must be present: the script has no built-in defaults, and a missing number reads as 0 (disabled).

**Common setups:**

| Goal | Settings |
|---|---|
| Production | `mode: kill`, `logLevel: quiet` |
| Observation | `mode: monitor`, `logLevel: quiet` |
| Debugging | `mode: monitor`, `logLevel: detail` |
| Catch memory bombs sooner | Lower `memKillImmediate`, e.g. `2000` |

### Updating and uninstalling

To update, copy the new files over and **re-run `Install-MonitorTask.ps1`**. It stops the running monitor before re-registering the task. Don't just replace the script and restart the task, because the old process keeps running alongside the new one and you get duplicate log lines. `Stop-MonitorTask.ps1` stops the monitor if you need it down while you copy files.

To uninstall, from an admin PowerShell:

```powershell
Unregister-ScheduledTask -TaskName "WebDevSessionMonitor" -Confirm:$false
```

Then delete `C:\WebDevMonitor`.

### Reading the log

Every line is `yyyy-MM-dd HH:mm:ss EVENT KEY:VALUE ...`.

| Event | Meaning |
|---|---|
| `MONITOR STARTED` / `CONFIG` | Startup: version and the settings in effect |
| `HEARTBEAT` | Every `heartbeatMinutes`: session count, top memory and CPU session, `SYS_CPU`/`SYS_MEM` with WebDev's share, tracked count, spikes and kills since the last heartbeat |
| `DIST` | With each heartbeat: sessions that are idle (<1%), normal, or hot (≥ CPU threshold) |
| `FIRST-SIGHTING` / `DROPPED-BELOW` | A session crossed or fell back under a threshold (`detail` log level only) |
| `WOULD-KILL` / `RECOVERED` | Monitor mode: a session sustained a violation / later dropped back |
| `KILLING` / `KILLED` / `KILL-FAILED` | Kill mode: the kill, with memory, CPU, reason and process `AGE` |
| `DETAIL` / `SAMPLE` | The dumped ring buffer for a killed or would-kill session (`detailsOnKill`) |
| `PROCESS-GONE` | A tracked session exited on its own |
| `NON_WD_SPIKE` / `NON_WD` | System CPU far above WebDev CPU, followed by the top other processes and their command lines |
| `DAILY-SUMMARY` | Midnight totals: spikes, kills, unique sessions, peak memory |
| `WMI-TIMEOUT` / `WMI-ERROR` / `NON_WD_QUERY_ERROR` | A WMI query failed. Memory monitoring carries on |
| `NOTE` | A threshold is disabled |
| `FATAL-ERROR` | Unhandled error. The monitor logs it and exits. If the log goes quiet afterwards, re-run `Install-MonitorTask.ps1` |

A memory bomb caught in the act (sample lines trimmed):

```
2026-08-13 10:00:34 KILLING PID:11556 MEM:5130MB CPU:12.4 REASON:MEMORY AGE:3m (IMMEDIATE)
2026-08-13 10:00:34   DETAIL PID:11556 SAMPLES:43 SPIKES:3 PEAK_CPU:% PEAK_MEM:MB
2026-08-13 10:00:34   SAMPLE PID:11556 TIME:10:00:23 CPU:0% MEM:75.7MB
2026-08-13 10:00:34   SAMPLE PID:11556 TIME:10:00:29 CPU:0% MEM:75.9MB
2026-08-13 10:00:34   SAMPLE PID:11556 TIME:10:00:34 CPU:12.4% MEM:5130MB
2026-08-13 10:00:34 KILLED PID:11556
```

A heartbeat, and a non-WebDev CPU spike:

```
2026-08-10 12:02:05 HEARTBEAT PROCS:266 TOP_MEM:PID:14140/163.7MB TOP_CPU:PID:1404/1.2% SYS_CPU:49%-WD:1.8% SYS_MEM:17.9/32GB(55.9%)-WD:20.2GB(63.1%) TRACKING:0 SPIKES:35 KILLS:0
2026-08-10 12:02:05   DIST CPU_IDLE(<1%):265 CPU_NORMAL(1-25%):1 CPU_HOT(>=25%):0
2026-08-10 12:02:05   NON_WD_SPIKE SYS_CPU:49% WD_CPU:1.8% GAP:47.2%
2026-08-10 12:02:05   NON_WD PID:4 NAME:System CPU:8.8% MEM:0MB CMD:
2026-08-10 12:02:05   NON_WD PID:3580 NAME:MsMpEng CPU:4.6% MEM:198.3MB CMD:
```

(`PEAK_CPU:% PEAK_MEM:MB` printing empty is a known cosmetic bug in the `DETAIL` line. The `SAMPLE` lines carry the real values.)

---

## 3. Run an Analysis (on your own machine)

The analysis tool is a single Python script with no dependencies. It needs Python 3.9 or newer.

1. Copy `C:\WebDevMonitor\wd_sessions.log` off the server, and `wd_sessions.log.bak` if it exists (the previous 10 MB), into this repo's **`logs/`** folder. Give it a name that says which server and when, e.g. `logs/myserver-20260924.log`.
2. Run the tool:

   ```bash
   python3 tools/analyze_log.py logs/myserver-20260924.log > logs/myserver-20260924-stats.md
   ```

   `--top N` changes how many rows the top-N tables show (default 15).
3. Write the findings up as `logs/<date>-<server>-analysis.md`, using **[`logs/example-analysis.md`](logs/example-analysis.md)** as the model. It was written from **[`logs/example-wd_sessions.log`](logs/example-wd_sessions.log)**, a real week of production data with names and paths scrubbed. Run the tool on the example log to see the whole workflow end to end.
4. Turn the write-up into a standalone HTML report to share:

   ```bash
   python3 tools/build_report.py logs/<date>-<server>-analysis.md
   ```

   This writes `logs/<date>-<server>-analysis.html` next to the markdown: one self-contained file with no external assets, light and dark themes, and readable on a phone, ready to attach to an email. Add stat tiles to the top by putting lines like `<!-- stat: 222 | kills -->` in the markdown; they're invisible when the markdown itself is viewed. It needs Node.js, and uses the report generator in `tools/gen-report.mjs`. See [`logs/example-analysis.html`](logs/example-analysis.html) for the result.

**Everything in `logs/` is git-ignored except the example files**, so real server logs and reports never get committed by accident.

### What the tool reports

- **Summary:** period, heartbeats, kills by type, peaks (sessions, memory, CPU), config, WMI errors.
- **Restarts and gaps:** every monitor start (weekly reboots, crashes) and any heartbeat gap over 15 minutes.
- **Kills by month, weekday and hour.**
- **CPU kill events:** simultaneous kills grouped into events, with the summed CPU of each event.
- **Memory kills:** before and after memory from the forensic samples, growth multiple, CPU at kill and age.
- **Daily table:** heartbeat peaks next to the monitor's own `DAILY-SUMMARY`, with any mismatch called out.
- **Hourly load profile:** weekdays and weekends separately.
- **CPU_HOT heartbeats and non-WebDev CPU attribution:** which other processes (Defender, Chrome PDF rendering, Apache, and so on) take the CPU, and how much is unattributed.

### Reading the numbers

- **Memory kill at ~12.5% CPU** (8 cores): exactly one core pinned, the single-threaded runaway. At **0% CPU and ~16.4 GB**, the bomb had already hit the per-process ceiling and stalled.
- **Several memory bombs in one morning**: bombs often come in clusters. The kill times show when the server was under the most strain.
- **`wd<ver>session` listed as a non-WebDev process:** a session that started between the monitor's two queries. It's picked up on the next poll.
- **High `MsMpEng`** in non-WebDev spikes: apply the [Defender exclusions](project-documentation/windows-defender-exclusions-webdev.md).

---

## Repository Layout

```
server/                   Copy to C:\WebDevMonitor on the WebDev server
tools/analyze_log.py      Log analysis (runs on your machine)
tools/build_report.py     Markdown write-up -> standalone HTML report
logs/                     Drop logs here (git-ignored), plus the example log and report
project-documentation/    Windows Defender exclusions guide
```

The `.github/` and `.gemini/` folders, `.commitlintrc.json` and `.semgrepignore` configure CI and pull-request review for this repository. They aren't needed to run the monitor or the analysis.

## License

[MIT](LICENSE). Free to use, modify and share, with no warranty. You run it on your servers at your own risk.
