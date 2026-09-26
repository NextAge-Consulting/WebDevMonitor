# Changelog

All notable changes to WebDevMonitor.

## How versioning works here

This project has **no build or deployment pipeline**. Versioning and this changelog are kept **by hand**:

1. When `server/WatchWdSessions.ps1` changes behavior, bump its version in **both** places in the script: the header comment on line 1 (`# WatchWdSessions.ps1 - vX.Y`) and the `MONITOR STARTED vX.Y ...` log line. The log line is what shows up in every server's log.
2. Add an entry at the top of this file for the new version, with the date and what changed.
3. Changes that don't touch the monitor script (docs, the analysis tool, the repo itself) go in a dated entry without bumping the monitor version.
4. Commit with `/ship-main`. Servers get the new version when someone copies `server/` over and re-runs `Install-MonitorTask.ps1`.

---

## 2026-09-26 — HTML analysis reports (monitor unchanged)

### Added
- `tools/build_report.py`: turns an analysis write-up in markdown into a standalone HTML report, using the report generator in `tools/gen-report.mjs`. The HTML is self-contained, theme-aware and suitable for attaching to an email. Stat tiles come from `<!-- stat: value | label -->` lines. Needs Node.js.
- `logs/example-analysis.html`, generated from the example write-up.

---

## v4.5 — 2026-09-26 — Fast memory check

### Added
- `memCheckIntervalMs` setting (shipped at `1000`): between full cycles, a memory-only check runs every second. It applies **only** the immediate memory threshold (`memKillImmediate`). It uses `Get-Process` alone, with no WMI query, so it's cheap. Memory bombs typically go from a normal size to multi-GB between two 5-second cycles; this catches them within about a second.
- Startup log line `CONFIG CHECK_INTERVAL:<n>ms MEM_CHECK_INTERVAL:<n>ms|off`.

### Unchanged
- CPU checks, the sustained memory threshold, `confirmSeconds`, tracking, heartbeats and forensics all still run on the full `checkIntervalMs` cycle, exactly as in v4.4.
- `KILLING` / `WOULD-KILL` line formats, so existing log analysis keeps working. A kill from the fast pass looks the same as an immediate kill from the full cycle. Its CPU value is the last full-cycle reading.
- If `memCheckIntervalMs` is missing, 0, or not less than `checkIntervalMs`, the fast pass is off and behavior is identical to v4.4. Existing installs whose `config.json` lacks the setting are unaffected until it's added.

---

## 2026-09-26 — First public release (monitor v4.4, script unchanged)

The monitor script is the same v4.4 that's been in production since March 31, 2026. This release turns the working folder into a public open-source repository.

### Added
- `README.md` rewritten for public use: what the tool does and why, install and configuration, and how to run an analysis. It credits the contributors.
- `LICENSE` (MIT).
- `tools/analyze_log.py`: parses a `wd_sessions.log` and prints the statistics used for an analysis write-up. That covers kills, memory-kill forensics, CPU kill groups with their summed CPU, daily and hourly load, and non-WebDev CPU attribution. Standard library only. Handles logs from monitor v4.0 onwards.
- `logs/example-wd_sessions.log` and `logs/example-analysis.md`: a sanitized week of real production data and the analysis written from it.
- `.gitignore`: real server logs and reports in `logs/` stay local; only the examples are tracked.
- This changelog.

### Changed
- Server files moved into `server/` (`WatchWdSessions.ps1`, `Install-MonitorTask.ps1`, `Stop-MonitorTask.ps1`, `config.json`). That folder is what gets copied to `C:\WebDevMonitor`.
- `project-documentation/windows-defender-exclusions-webdev.md` made generic (no server-specific references) and updated with a measured result: CPU dropped from 10-25% to 4-10% after the exclusions.

---

## Earlier versions

These were never formally recorded. The entries below are reconstructed from the `MONITOR STARTED` lines in production logs and from the README of the time, so the dates are when a version was first seen running, not release dates.

### v4.4 (External Config) — in production by 2026-03-31
- Non-WebDev CPU attribution: when system CPU exceeds WebDev CPU by `nonWdCpuGapPct`, logs `NON_WD_SPIKE` and the top `nonWdCpuTopN` other processes with their command lines.

### v4.3 (External Config) — in production by 2026-03-17
- Settings moved out of the script into `config.json`.
- Heartbeats include system CPU and memory alongside WebDev's share (`SYS_CPU`, `SYS_MEM`).
- Kill forensics (`detailsOnKill`): per-process ring buffer dumped as `DETAIL` / `SAMPLE` lines on every kill.

### v4.0 (Log Noise Reduction) — in production by 2026-03-05
- `logLevel` setting: `quiet` suppresses transient `FIRST-SIGHTING` / `DROPPED-BELOW` pairs; spikes are still counted in heartbeats.
