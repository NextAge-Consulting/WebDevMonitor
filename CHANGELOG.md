# Changelog

All notable changes to WebDevMonitor.

## How versioning works here

This project has **no build or deployment pipeline**. Versioning and this changelog are kept **by hand**:

1. When `server/WatchWdSessions.ps1` changes behavior, bump its version in **both** places in the script: the header comment on line 1 (`# WatchWdSessions.ps1 - v4.4`) and the `MONITOR STARTED v4.4 ...` log line. The log line is what shows up in every server's log.
2. Add an entry at the top of this file for the new version, with the date and what changed.
3. Changes that don't touch the monitor script (docs, the analysis tool, the repo itself) go in a dated entry without bumping the monitor version.
4. Commit with `/ship-main`. Servers get the new version when someone copies `server/` over and re-runs `Install-MonitorTask.ps1`.

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
