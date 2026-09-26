#!/usr/bin/env python3
"""Parse a WatchWdSessions.ps1 log and print the statistics used for the
logs/*-analysis.md write-ups.

Usage:
    python3 tools/analyze_log.py logs/<file>.log [--top N]

Output is a plain-text/markdown stat dump; the analysis document is written
from it. Standard library only.
"""
import argparse
import collections
import datetime as dt
import re
import statistics
import sys
from typing import Any

# SYS_CPU / SYS_MEM fields arrived after v4.0; older heartbeats lack them
HB_RE = re.compile(
    r'PROCS:(\d+) TOP_MEM:(?:PID:(\d+)/([\d.]+)MB|none) TOP_CPU:(?:PID:(\d+)/([\d.]+)%|none) '
    r'(?:SYS_CPU:(\d+)%-WD:([\d.]+)% SYS_MEM:([\d.]+)/([\d.]+)GB\(([\d.]+)%\)-WD:([\d.]+)GB\(([\d.]+)%\) )?'
    r'TRACKING:(\d+) SPIKES:(\d+) KILLS:(\d+)')
KILL_RE = re.compile(
    r'KILLING PID:(\d+) MEM:([\d.]+)MB(?: DUR:([\d.]+)s)? CPU:([\d.]+) REASON:(\w+) AGE:(\S+)( \(IMMEDIATE\))?')
SAMPLE_RE = re.compile(r'TIME:(\S+) CPU:([\d.]+)% MEM:([\d.]+)MB')
NWS_RE = re.compile(r'SYS_CPU:(\d+)% WD_CPU:([\d.]+)% GAP:([\d.]+)%')
NW_RE = re.compile(r'PID:(\d+) NAME:(.+?) CPU:([\d.]+)% MEM:([\d.]+)MB CMD:(.*)')
SUMMARY_RE = re.compile(r'DATE:(\S+) SPIKES:(\d+) KILLS:(\d+) UNIQUE_PIDS:(\d+) PEAK_MEM:(?:PID:(\d+)/([\d.]+)MB|\S+)')

def out(*parts: object) -> None:
    """Write one report line to stdout; the report IS this tool's output."""
    sys.stdout.write(' '.join(str(p) for p in parts) + '\n')


CPU_CLUSTER_SECONDS = 120   # CPU kills this close together form one event
GAP_SECONDS = 15 * 60       # heartbeat gaps longer than this are reported
BOMB_BASELINE_MB = 1000     # "before" memory = last sample under this


Record = dict[str, Any]


def parse(path: str) -> tuple[list[Record], list[Record], list[Record], list[tuple[dt.datetime, str]],
                             list[str], list[Record], list[dt.datetime]]:
    hb: list[Record] = []
    kills: list[Record] = []
    nws: list[Record] = []
    starts: list[tuple[dt.datetime, str]] = []
    configs: list[str] = []
    summaries: list[Record] = []
    wmi_timeouts: list[dt.datetime] = []
    last_kill: Record | None = None
    cur_nws: Record | None = None
    # split on \n only: command lines can hold characters str.splitlines() treats as breaks
    with open(path, encoding='utf-8', errors='replace', newline='') as fh:
        lines = fh.read().split('\n')
    for line in lines:
        line = line.rstrip('\r')
        if len(line) < 20 or not line[:4].isdigit():
            continue
        try:
            t = dt.datetime.strptime(line[:19], '%Y-%m-%d %H:%M:%S')
        except ValueError:
            continue
        body = line[20:]
        tag = body.strip().split(' ', 1)[0]
        if tag == 'HEARTBEAT':
            m = HB_RE.search(body)
            if not m:
                continue
            g = m.groups()
            hb.append(dict(t=t, procs=int(g[0]), topmem_pid=g[1], topmem=float(g[2] or 0),
                           topcpu=float(g[4] or 0), sys=int(g[5] or 0), wd=float(g[6] or 0),
                           sysmem=float(g[7] or 0), totmem=float(g[8] or 0), sysmemp=float(g[9] or 0),
                           wdmem=float(g[10] or 0), wdmemp=float(g[11] or 0), spikes=int(g[13]),
                           kills=int(g[14]), hot=0, normal=0))
        elif tag == 'DIST' and hb:
            m = re.search(r'CPU_NORMAL\(1-25%\):(\d+) CPU_HOT\(>=25%\):(\d+)', body)
            if m:
                hb[-1]['normal'], hb[-1]['hot'] = int(m.group(1)), int(m.group(2))
        elif tag == 'KILLING':
            m = KILL_RE.search(body)
            if m:
                last_kill = dict(t=t, pid=m.group(1), mem=float(m.group(2)), cpu=float(m.group(4)),
                                 reason=m.group(5), age=m.group(6), immediate=bool(m.group(7)),
                                 samples=[])
                kills.append(last_kill)
        elif tag == 'SAMPLE' and last_kill:
            m = SAMPLE_RE.search(body)
            if m:
                last_kill['samples'].append((m.group(1), float(m.group(2)), float(m.group(3))))
        elif tag == 'NON_WD_SPIKE':
            m = NWS_RE.search(body)
            if not m:
                continue
            cur_nws = dict(t=t, sys=int(m.group(1)), wd=float(m.group(2)), gap=float(m.group(3)), procs=[])
            nws.append(cur_nws)
        elif tag == 'NON_WD' and cur_nws:
            m = NW_RE.search(body)
            if m:
                cur_nws['procs'].append(dict(name=re.sub(r'#\d+$', '', m.group(2)), cpu=float(m.group(3)),
                                             mem=float(m.group(4)), cmd=m.group(5)))
        elif tag == 'MONITOR' and 'STARTED' in body:
            starts.append((t, body.strip()))
        elif tag.startswith('WMI'):
            wmi_timeouts.append(t)
        elif tag.startswith('CONFIG'):
            configs.append(body.strip())
        elif tag == 'DAILY-SUMMARY':
            m = SUMMARY_RE.search(body)
            if m:
                summaries.append(dict(date=m.group(1), spikes=int(m.group(2)), kills=int(m.group(3)),
                                      pids=int(m.group(4)), peak_pid=m.group(5),
                                      peak_mem=float(m.group(6) or 0)))
    return hb, kills, nws, starts, configs, summaries, wmi_timeouts


def fmt_t(t: dt.datetime) -> str:
    return t.strftime('%a %b %d %H:%M:%S')


def section(title: str) -> None:
    out(f'\n## {title}\n')


def report(path: str, top: int) -> None:
    hb, kills, nws, starts, configs, summaries, wmi_timeouts = parse(path)
    if not hb:
        sys.exit(f'{path}: no heartbeats found')

    section('Summary')
    span = hb[-1]['t'] - hb[0]['t']
    out(f'Log: {path}')
    out(f'Period: {fmt_t(hb[0]["t"])} -> {fmt_t(hb[-1]["t"])} ({span.total_seconds() / 86400:.1f} days)')
    out(f'Heartbeats: {len(hb)}   Spikes (heartbeat sum): {sum(h["spikes"] for h in hb):,}')
    by = collections.Counter(('CPU' if k['reason'] == 'CPU' else
                              'MEMORY-immediate' if k['immediate'] else 'MEMORY-sustained') for k in kills)
    out(f'Kills: {len(kills)}  ' + '  '.join(f'{r}:{n}' for r, n in sorted(by.items())))
    for key, label in [('procs', 'procs'), ('wdmem', 'WD mem GB'), ('sysmemp', 'SYS mem %'),
                       ('topmem', 'heartbeat TOP_MEM MB'), ('wd', 'WD CPU %')]:
        h = max(hb, key=lambda h: h[key])
        if not h[key]:
            continue  # field not recorded by this monitor version
        out(f'Peak {label}: {h[key]:,} at {fmt_t(h["t"])}'
              + (f' (WD {h["wdmemp"]}% of {h["totmem"]:g} GB)' if key == 'wdmem' else '')
              + (f' ({h["hot"]} HOT procs)' if key == 'wd' else ''))
    out(f'WMI timeouts/errors: {len(wmi_timeouts)}')
    for c in dict.fromkeys(configs):
        out(f'Config: {c}')

    section('Monitor restarts and heartbeat gaps')
    for t, body in starts:
        prev = [h for h in hb if h['t'] < t]
        before = f' (last heartbeat {prev[-1]["t"]:%H:%M:%S}, {int((t - prev[-1]["t"]).total_seconds() // 60)}m before)' if prev else ''
        out(f'{fmt_t(t)}  {body}{before}')
    gaps = [(a['t'], b['t']) for a, b in zip(hb, hb[1:]) if (b['t'] - a['t']).total_seconds() > GAP_SECONDS]
    out(f'Heartbeat gaps > {GAP_SECONDS // 60}m: {len(gaps)}')
    for a, b in gaps:
        out(f'  {fmt_t(a)} -> {fmt_t(b)} ({b - a})')

    section('Kills by month / weekday / hour')
    months = collections.defaultdict(lambda: collections.Counter())
    for k in kills:
        months[k['t'].strftime('%Y-%m')][k['reason']] += 1
    for mo in sorted(months):
        out(f'{mo}: CPU {months[mo]["CPU"]}  MEMORY {months[mo]["MEMORY"]}')
    days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
    wd = collections.Counter(k['t'].strftime('%a') for k in kills)
    wdm = collections.Counter(k['t'].strftime('%a') for k in kills if k['reason'] == 'MEMORY')
    out('Weekday (all/mem): ' + '  '.join(f'{d} {wd[d]}/{wdm[d]}' for d in days))
    hr = collections.Counter(k['t'].hour for k in kills)
    out('Hour: ' + '  '.join(f'{h:02d}:{n}' for h, n in sorted(hr.items())))

    section('CPU kill events (clustered)')
    events = []
    for k in (k for k in kills if k['reason'] == 'CPU'):
        if events and (k['t'] - events[-1][-1]['t']).total_seconds() <= CPU_CLUSTER_SECONDS:
            events[-1].append(k)
        else:
            events.append([k])
    # Per-process CPU is normalised to the whole machine (PercentProcessorTime / cores);
    # the sum shows when a group's readings add up to more than the machine has.
    out('| Date | Time | Kills | CPU range | Sum CPU | MEM range | Ages |')
    out('|---|---|---|---|---|---|---|')
    over = 0
    for e in events:
        total = sum(k['cpu'] for k in e)
        over += 0 if total <= 100 else len(e)
        out(f'| {e[0]["t"]:%a %b %d} | {e[0]["t"]:%H:%M:%S} | {len(e)} | '
              f'{min(k["cpu"] for k in e):.1f}-{max(k["cpu"] for k in e):.1f}% | {total:.1f}% | '
              f'{min(k["mem"] for k in e):.0f}-{max(k["mem"] for k in e):.0f} MB | '
              f'{",".join(sorted({k["age"] for k in e}))} |')
    sizes = collections.Counter(len(e) for e in events)
    out(f'\n{len(events)} events; size distribution: {dict(sorted(sizes.items()))}')
    n_cpu = sum(len(e) for e in events)
    out(f'CPU kills in events whose readings sum past 100% of the machine: {over} of {n_cpu}')

    section('Memory kills')
    mk = [k for k in kills if k['reason'] == 'MEMORY']
    out('| Date | Time | PID | Type | Before MB | At kill MB | Peak sampled MB | x | CPU at kill | Age |')
    out('|---|---|---|---|---|---|---|---|---|---|')
    for k in mk:
        lows = [s[2] for s in k['samples'] if s[2] < BOMB_BASELINE_MB]
        before = lows[-1] if lows else None
        peak = max([s[2] for s in k['samples']] + [k['mem']])
        mult = f'{peak / before:.0f}x' if before else '-'
        out(f'| {k["t"]:%a %b %d} | {k["t"]:%H:%M:%S} | {k["pid"]} | '
              f'{"immediate" if k["immediate"] else "sustained"} | {before if before is not None else "-"} | '
              f'{k["mem"]:,.1f} | {peak:,.1f} | {mult} | {k["cpu"]}% | {k["age"]} |')
    if mk:
        imm = [k['mem'] for k in mk if k['immediate']]
        if imm:
            out(f'\nImmediate: {len(imm)}  median {statistics.median(imm):,.0f} MB  '
                  f'>=16,000 MB: {sum(m >= 16000 for m in imm)}')
        cpus = collections.Counter(round(k['cpu'], 1) for k in mk)
        out('CPU% at memory kill: ' + '  '.join(f'{c}:{n}' for c, n in cpus.most_common()))

    section('Daily table (heartbeats + DAILY-SUMMARY)')
    per_day = collections.defaultdict(list)
    for h in hb:
        per_day[h['t'].date()].append(h)
    kday = collections.Counter(k['t'].date() for k in kills)
    summ = {s['date']: s for s in summaries}
    out('| Date | Day | Max procs | Max WD GB | Max WD % | Max SYS % | HOT HBs | Max HOT | Kills (log) | Summary spikes | Summary kills | Unique PIDs | Summary peak MB |')
    out('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    for d in sorted(per_day):
        x = per_day[d]
        s = summ.get(d.isoformat(), {})
        out(f'| {d} | {d:%a} | {max(a["procs"] for a in x)} | {max(a["wdmem"] for a in x)} | '
              f'{max(a["wdmemp"] for a in x)} | {max(a["sysmemp"] for a in x)} | '
              f'{sum(1 for a in x if a["hot"])} | {max(a["hot"] for a in x)} | {kday[d]} | '
              f'{s.get("spikes", "")} | {s.get("kills", "")} | {s.get("pids", "")} | '
              f'{s.get("peak_mem", "")} |')
    mismatch = [(d, summ[d.isoformat()]['kills'], kday[d]) for d in per_day
                if d.isoformat() in summ and summ[d.isoformat()]['kills'] != kday[d]]
    out(f'\nSummary-vs-log kill mismatches: {mismatch or "none"}')
    if summaries:
        out(f'DAILY-SUMMARY totals: spikes {sum(s["spikes"] for s in summaries):,}  '
              f'kills {sum(s["kills"] for s in summaries)}  ({len(summaries)} days)')

    section('Hourly profile (weekdays / weekends)')
    for label, wanted in [('Weekday', range(0, 5)), ('Weekend', range(5, 7))]:
        prof = collections.defaultdict(list)
        for h in hb:
            if h['t'].weekday() in wanted:
                prof[h['t'].hour].append(h)
        if not prof:
            continue
        out(f'\n{label}:\n\n| Hour | Avg procs | Max procs | Avg WD % | Max WD GB |')
        out('|---|---|---|---|---|')
        for hour in sorted(prof):
            x = prof[hour]
            out(f'| {hour:02d} | {sum(a["procs"] for a in x) / len(x):.0f} | {max(a["procs"] for a in x)} | '
                  f'{sum(a["wdmemp"] for a in x) / len(x):.1f} | {max(a["wdmem"] for a in x)} |')

    section(f'CPU_HOT heartbeats (top {top})')
    hot = [h for h in hb if h['hot']]
    out(f'{len(hot)} heartbeats with CPU_HOT > 0')
    out('| When | HOT | WD CPU % | SYS CPU % | Procs |')
    out('|---|---|---|---|---|')
    for h in sorted(hot, key=lambda h: -h['hot'])[:top]:
        out(f'| {fmt_t(h["t"])} | {h["hot"]} | {h["wd"]:,} | {h["sys"]} | {h["procs"]} |')

    if nws:
        section('Non-WD CPU attribution (NON_WD_SPIKE)')
        out(f'{len(nws)} events; WD_CPU==0 in {sum(n["wd"] == 0 for n in nws)}; '
              f'max gap {max(n["gap"] for n in nws)}%')
        unatt = [n['sys'] - n['wd'] - sum(p['cpu'] for p in n['procs']) for n in nws]
        out(f'Unattributed CPU (SYS - WD - listed procs): median {statistics.median(unatt):.1f}%')
        out('By month: ' + '  '.join(f'{k}:{v}' for k, v in sorted(collections.Counter(
            n['t'].strftime('%Y-%m') for n in nws).items())))
        out('By hour: ' + '  '.join(f'{k:02d}:{v}' for k, v in sorted(collections.Counter(
            n['t'].hour for n in nws).items())))
        seen, cpu = collections.Counter(), collections.defaultdict(list)
        for n in nws:
            names = {}
            for p in n['procs']:
                if p['cpu'] > 0:
                    names[p['name']] = names.get(p['name'], 0) + p['cpu']
            for name, c in names.items():
                seen[name] += 1
                cpu[name].append(c)
        out('\n| Process | Events (CPU>0) | Avg CPU % | Max CPU % |')
        out('|---|---|---|---|')
        for name, n in seen.most_common(top):
            out(f'| {name} | {n} | {sum(cpu[name]) / n:.1f} | {max(cpu[name]):.1f} |')
        out(f'\nLargest gaps (top {min(top, 10)}):')
        for n in sorted(nws, key=lambda n: -n['gap'])[:min(top, 10)]:
            procs = ', '.join(f'{p["name"]} {p["cpu"]}%' for p in n['procs'] if p['cpu'] > 0)
            out(f'  {fmt_t(n["t"])} SYS {n["sys"]}% WD {n["wd"]}% -> {procs or "(nothing attributed)"}')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log')
    ap.add_argument('--top', type=int, default=15, help='rows in top-N tables (default 15)')
    a = ap.parse_args()
    report(a.log, a.top)


if __name__ == '__main__':
    main()
