# WebDevMonitor Log Analysis - Example Server (one week)

<!-- stat: 7 days | monitored -->
<!-- stat: 30 | kills -->
<!-- stat: 15 | memory kills -->
<!-- stat: 15 | CPU kills -->
<!-- stat: 370 | peak sessions -->
<!-- stat: 16.5 GB | largest session at kill -->

> **Example.** This report was written from `logs/example-wd_sessions.log`, one real week of production data with application names and file paths scrubbed. Generate the stats for your own log with `python3 tools/analyze_log.py logs/<your-log>.log`, then write the findings up in this shape.

## Summary

| Metric | Value |
|--------|-------|
| Monitoring period | Mon Aug 10 00:00 - Sun Aug 16 23:55 (7.0 days) |
| Server | 8 cores, 32 GB RAM, WebDev 28 application server |
| Total heartbeats | 1,994 |
| Total spikes (heartbeat sum) | 12,612 |
| Total kills | **30** (15 CPU, 6 memory immediate, 9 memory sustained) |
| Peak process count | 370 (Tue 11:36) |
| Peak WD memory | 24.4 GB / 76.2% of 32 GB (Tue 11:36) |
| Peak individual process memory at kill | 16,472.7 MB (Thu 09:56) |
| Monitor restarts | 1 (Sun 03:31, the weekly scheduled reboot) |
| Heartbeat gaps > 15 min | 0 |
| WMI timeouts/errors | 0 |
| Monitor version | v4.4 |
| Config | kill mode, quiet logging, 3,000 MB immediate / 1,500 MB sustained, CPU 25%, 10s confirm, forensics on, NON_WD gap 20% |

## Daily Detail

| Date | Day | Max procs | Max WD mem % | Kills | Spikes | Unique PIDs | Peak process MB |
|------|-----|-----------|--------------|-------|--------|-------------|-----------------|
| Aug 10 | Mon | 312 | 65.9 | 6 (CPU) | 2,321 | 652 | 1,633 |
| Aug 11 | Tue | 370 | 76.2 | 0 | 2,824 | 698 | 2,692 |
| Aug 12 | Wed | 332 | 70.3 | 5 (4 CPU, 1 mem) | 2,666 | 676 | 5,867 |
| Aug 13 | Thu | 297 | 63.4 | 10 (5 CPU, 5 mem) | 2,777 | 684 | 16,473 |
| Aug 14 | Fri | 289 | 58.4 | 9 (mem, sustained) | 1,791 | 513 | 2,453 |
| Aug 15 | Sat | 76 | 13.1 | 0 | 135 | 83 | 249 |
| Aug 16 | Sun | 66 | 10.3 | 0 | — | — | — |

The monitor's own DAILY-SUMMARY lines agree with the kill log on every day.

## Memory Kills

**15 memory kills: 6 immediate (>3,000 MB) and 9 sustained (>1,500 MB for 10s).**

| Date | Time | Type | Before | At kill | Growth | CPU at kill | Age |
|------|------|------|--------|---------|--------|-------------|-----|
| Wed | 14:08:03 | immediate | 126.6 MB | 5,867.3 MB | 46x | 12.5% | 3h58m |
| Thu | 09:56:38 | immediate | 82.6 MB | 16,472.7 MB | 199x | 0.0% | 26m |
| Thu | 10:00:34 | immediate | 75.9 MB | 5,130.0 MB | 68x | 12.4% | 3m |
| Thu | 10:30:02 | immediate | 107.4 MB | 10,922.8 MB | 102x | 12.4% | 1h32m |
| Thu | 10:55:52 | immediate | 90.8 MB | 5,676.5 MB | 63x | 12.4% | 4m |
| Thu | 11:44:32 | immediate | 107.5 MB | 14,059.8 MB | 131x | 12.2% | 1h14m |
| Fri | 12:56-18:11 | 9 × sustained | 60-83 MB | 1,657-2,137 MB | peak ~2,440 MB each | 11.8-12.5% | 0m-17m |

### How to read a memory bomb

- **Single-sample explosion.** The forensic samples show a session sitting at a normal ~60-130 MB and then jumping to several GB between two 5-second polls. This isn't a slow leak.
- **One core pinned.** CPU at kill is ~12.5% on an 8-core server, which is exactly one core (100 ÷ 8). The runaway is a single-threaded allocation loop.
- **~16.4 GB ceiling.** A bomb that isn't caught stalls at about 16.4 GB with 0% CPU. It has hit a per-process allocation limit. Kills below that were caught while still growing.
- **Age doesn't matter.** Sessions from 3 minutes to 4 hours old blew up.
- **Clustering.** Thursday had 5 bombs between 09:56 and 11:44.

### Friday: repeated same-size allocations

Nine separate sessions, all on Friday afternoon, each allocated almost exactly **2.44 GB** and then trimmed to 1.66-2.14 GB. That sits between the 1,500 MB sustained threshold and the 3,000 MB immediate one, so they were caught by the sustained rule after its 10-second window rather than immediately. Several were killed less than a minute after launch.

## CPU Kills

| Date | Time | Kills | CPU per process | Sum of CPU | Memory | Ages |
|------|------|-------|-----------------|------------|--------|------|
| Mon | 11:24:36 | 6 | 36.1-88.1% | 350.9% | 46-84 MB | 1-4m |
| Wed | 09:43:06 | 4 | 28.9-57.1% | 166.1% | 71-83 MB | 0-5m |
| Thu | 15:09:25 | 5 | 25.6-154.5% | 296.2% | 54-88 MB | 2-5m |

CPU kills came in groups: 4-6 small (46-88 MB), young (0-5 minute) sessions killed in the same second, after holding above the 25% threshold for the 10-second confirmation window. Each group's readings add up to more than 100% of the machine. That's the pattern described under [Unexplained CPU readings](../README.md#unexplained-cpu-readings) in the README. The heartbeats show it too: Monday 11:52 reported 39 "hot" sessions totalling 7,370% WD CPU while system CPU was 5%.

## Load Profile (weekdays)

| Hour | Avg procs | Max procs | Avg WD mem % |
|------|-----------|-----------|--------------|
| 07 | 43 | 95 | 7.2 |
| 08 | 117 | 183 | 21.8 |
| 09 | 215 | 271 | 44.9 |
| 10 | 253 | 299 | 56.7 |
| **11** | **266** | **370** | **60.3** |
| 12 | 262 | 332 | 59.8 |
| 13-15 | 242-249 | 312 | 55-57 |
| 16 | 209 | 278 | 48.1 |
| 17 | 158 | 220 | 33.5 |
| 18-23 | 20-103 | 168 | 3-21 |

Ramp-up runs 08:00-09:00, then a plateau from 10:00 to 15:00 at ~250 sessions using 55-60% of RAM, and a wind-down after 16:00. Weekends peak at ~75 sessions and under 5 GB.

## Non-WD CPU (NON_WD_SPIKE)

34 events where system CPU exceeded WebDev CPU by 20% or more.

| Process | Events | Avg CPU | Max CPU | What it is |
|---------|--------|---------|---------|------------|
| WmiPrvSE | 27 | 1.2% | 2.0% | WMI provider, partly the monitor's own queries |
| MsMpEng | 21 | 2.8% | 15.6% | Windows Defender real-time scanning |
| chrome | 21 | 11.9% | 26.6% | Headless Chrome generating PDFs (`--print-to-pdf`) |
| System | 19 | 2.6% | 8.8% | Kernel |
| httpd | 16 | 0.9% | 2.0% | Apache |
| wd280admin | 10 | 1.6% | 3.4% | WebDev admin service |

About 29% of the system CPU in these events isn't attributed to any listed process. It's kernel and I/O time that per-process sampling can't see. Defender is present but modest. Before the exclusions in `project-documentation/windows-defender-exclusions-webdev.md` were applied, MsMpEng typically showed 6-26% on production servers like this one. If your log shows it that high, start there.

`wd280session` entries in NON_WD lists are sessions that started between the monitor's process snapshot and its WMI query. They're picked up on the next poll, so this isn't a monitoring gap.

## Key Observations

1. **Memory bombs are the real problem, and the monitor handles them.** Six sessions would each have consumed 5-16 GB of a 32 GB server. The immediate kill caught every one within a single poll.
2. **Friday's nine 2.44 GB allocations were caught by the sustained rule**, so each ran for at least 10 seconds before being killed. A smaller runaway gets less prompt treatment than a big one.
3. **CPU kills came in three same-second groups** (Mon, Wed, Thu), each of small, young sessions, matching the group pattern seen on other servers.
4. **Load headroom is fine for now.** At the busiest moment, system memory was 62.8% used, leaving about 12 GB free. One uncaught memory bomb (up to 16 GB) would exhaust that, which is the case for keeping the immediate memory kill on.
5. **The monitor itself was healthy.** No WMI errors, no heartbeat gaps, a clean restart after the weekly reboot, and daily summaries that match the kill log.
