"""Parse WebDev Application Server session logs and cross-reference them with a
WatchWdSessions.ps1 log. Used by analyze_log.py --webdev; standard library only.

A WebDev session log record is one tab-separated line of 15 fields:

    0 '_'   1 yyyymmddHHMMSS   2 'DYN'   3 PID   4 site   5 status
    6 'AJAX' or ''   7 page, EXIT reason or error code   8 event or URL
    9 bytes   10 client IP   11-14 site names

Status is CONNECT (a session process starts), EXIT (it ends, with a reason in
field 7), PAGEOK / BUFFEROK / FILEOK (a request served), or *ERROR* (an error
page served, code in field 7).

Only the session log is read. WebDev's error log is not needed: it holds only
*ERROR* records, each followed by the HTML page that was served, and every one
of those records is already in the session log. Error logs are recognised by
content and skipped, so a folder holding both works.

Two things make the join non-obvious:
  - Windows reuses PIDs, so a PID's history is split into session lifetimes,
    one per CONNECT.
  - The WebDev log and the monitor log can be written in different time zones
    (on the server this was built against, WebDev was one hour behind the
    monitor). The offset is measured from the data, not assumed.
"""
from __future__ import annotations

import bisect
import datetime as dt
import os
import re
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field

OK_STATUSES = {'PAGEOK', 'BUFFEROK', 'FILEOK'}
OFFSET_STEP_MIN = 15          # time zones run on quarter hours
OFFSET_RANGE_H = 14           # UTC-12 .. UTC+14 covers every zone pair
ALIVE_SLACK = dt.timedelta(seconds=60)
MIN_SCORED_HEARTBEATS = 20    # fewer than this and the offset is not trusted
RECONNECT_WINDOW = dt.timedelta(minutes=30)
AGE_RE = re.compile(r'(?:(\d+)h)?(\d+)m')


@dataclass
class Record:
    t: dt.datetime
    pid: str
    status: str
    code: str   # page for requests, reason for EXIT, error code for *ERROR*
    event: str
    ip: str


@dataclass
class Session:
    """One WebDev session process: a single lifetime of a (reusable) PID."""
    pid: str
    start: dt.datetime
    end: dt.datetime                 # EXIT time, else the last request served
    connect_seen: bool               # False when the log began mid-session
    ip: str
    requests: int = 0
    exit_reason: str | None = None
    superseded: bool = False         # a later CONNECT reused the PID with no EXIT logged


@dataclass
class WebDevData:
    files: list[str]
    first: dt.datetime | None = None
    last: dt.datetime | None = None
    records: int = 0
    skipped: list[str] = field(default_factory=list)   # error logs: not needed, not read
    sessions: dict[str, list[Session]] = field(default_factory=dict)
    connects: list[tuple[dt.datetime, str, str]] = field(default_factory=list)  # (t, ip, pid)
    kept: dict[str, list[Record]] = field(default_factory=dict)                 # full history of watched PIDs


def expand_paths(paths: Iterable[str]) -> list[str]:
    """Files as given; directories contribute every *.log file inside them."""
    files: list[str] = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, f) for f in os.listdir(p) if f.lower().endswith('.log'))
        else:
            files.append(p)
    return files


def _stamp(s: str) -> dt.datetime | None:
    if len(s) != 14 or not s.isdigit():
        return None
    try:
        return dt.datetime(int(s[:4]), int(s[4:6]), int(s[6:8]), int(s[8:10]), int(s[10:12]), int(s[12:14]))
    except ValueError:
        return None


def _records(path: str) -> Iterator[Record]:
    with open(path, encoding='utf-8-sig', errors='replace', newline='') as fh:
        for line in fh:
            f = line.rstrip('\r\n').split('\t')
            if len(f) < 11 or f[0] != '_':
                continue  # HTML body of an error page, or not a WebDev log
            t = _stamp(f[1])
            if t:
                yield Record(t, f[3], f[5], f[7], f[8], f[10])


def is_webdev_log(path: str) -> bool:
    return next(_records(path), None) is not None


def is_error_log(path: str, probe: int = 1000) -> bool:
    """An error log holds nothing but *ERROR* records; a session log has requests."""
    for i, r in enumerate(_records(path)):
        if r.status != '*ERROR*':
            return False
        if i >= probe:
            break
    return True


def parse(paths: Iterable[str], keep_pids: Iterable[str] = ()) -> WebDevData:
    """Read WebDev session logs into per-PID session lifetimes.

    keep_pids: PIDs whose every record is kept (the monitor's killed PIDs).
    """
    files = [f for f in expand_paths(paths) if is_webdev_log(f)]
    skipped = [f for f in files if is_error_log(f)]
    files = [f for f in files if f not in skipped]
    data = WebDevData(files=files, skipped=skipped)
    keep = set(keep_pids)
    data.kept = {p: [] for p in keep}
    # Order files by their first record so daily files chain correctly.
    files.sort(key=lambda f: next(_records(f)).t)
    open_: dict[str, Session] = {}
    for path in files:
        for r in _records(path):
            data.records += 1
            data.first = r.t if data.first is None else min(data.first, r.t)
            data.last = r.t if data.last is None else max(data.last, r.t)
            if r.pid in keep:
                data.kept[r.pid].append(r)
            s = open_.get(r.pid)
            if r.status == 'CONNECT':
                data.connects.append((r.t, r.ip, r.pid))
                if s:
                    s.superseded = True
                s = open_[r.pid] = Session(r.pid, r.t, r.t, True, r.ip)
                data.sessions.setdefault(r.pid, []).append(s)
            elif r.status == 'EXIT':
                if not s:
                    s = Session(r.pid, r.t, r.t, False, r.ip)
                    data.sessions.setdefault(r.pid, []).append(s)
                s.end, s.exit_reason = r.t, r.code
                open_.pop(r.pid, None)
            elif r.status in OK_STATUSES:
                if not s:  # the log began while this session was already running
                    s = open_[r.pid] = Session(r.pid, r.t, r.t, False, r.ip)
                    data.sessions.setdefault(r.pid, []).append(s)
                s.end = max(s.end, r.t)
                s.requests += 1
            # *ERROR* records neither open nor extend a session: WebDev logs them
            # against the PID the browser asked for, which may no longer exist.
    for v in data.sessions.values():
        v.sort(key=lambda s: s.start)
    for v in data.kept.values():
        v.sort(key=lambda r: r.t)
    data.connects.sort()
    return data


def session_at(data: WebDevData, pid: str, t: dt.datetime, slack: dt.timedelta = ALIVE_SLACK) -> Session | None:
    """The session lifetime of this PID that was running at WebDev time t."""
    v = data.sessions.get(pid)
    if not v:
        return None
    i = bisect.bisect_right([s.start for s in v], t + slack) - 1
    if i < 0:
        return None
    s = v[i]
    return s if t <= s.end + slack or (s.exit_reason is None and not s.superseded) else None


@dataclass
class OffsetResult:
    offset: dt.timedelta | None          # monitor time minus WebDev time
    score: float = 0.0                   # share of heartbeat PIDs found in a live session
    scored: int = 0                      # heartbeat PIDs inside the WebDev coverage
    runner_up: tuple[dt.timedelta, float] | None = None
    given: bool = False


def detect_offset(heartbeats: list[dict], data: WebDevData) -> OffsetResult:
    """Find the clock offset at which the PIDs the monitor names in its heartbeats
    (TOP_MEM, TOP_CPU) are running WebDev sessions. Those PIDs are specific, so
    the right offset scores near 100% and a wrong one falls away."""
    if not data.sessions or data.first is None or data.last is None:
        return OffsetResult(None)
    probes = [(h['t'], pid) for h in heartbeats for pid in (h.get('topmem_pid'), h.get('topcpu_pid')) if pid]
    results: list[tuple[float, int, dt.timedelta]] = []
    steps = OFFSET_RANGE_H * 60 // OFFSET_STEP_MIN
    for q in range(-steps, steps + 1):
        off = dt.timedelta(minutes=q * OFFSET_STEP_MIN)
        hit = tot = 0
        for t, pid in probes:
            w = t - off
            if data.first <= w <= data.last:
                tot += 1
                hit += session_at(data, pid, w) is not None
        if tot >= MIN_SCORED_HEARTBEATS:
            results.append((hit / tot, tot, off))
    if not results:
        return OffsetResult(None)
    results.sort(key=lambda x: -x[0])
    score, tot, off = results[0]
    # Neighbouring offsets score almost as well because sessions last a while;
    # the runner-up that matters is the best one more than an hour away.
    far = next(((o, s) for s, _, o in results[1:] if abs(o - off) > dt.timedelta(hours=1)), None)
    return OffsetResult(off, score, tot, far)


def fmt_offset(off: dt.timedelta) -> str:
    mins = int(off.total_seconds() // 60)
    return f'{"+" if mins >= 0 else "-"}{abs(mins) // 60}:{abs(mins) % 60:02d}'


def age_minutes(age: str) -> int | None:
    m = AGE_RE.fullmatch(age)
    return int(m.group(1) or 0) * 60 + int(m.group(2)) if m else None


@dataclass
class KillMatch:
    kill: dict
    covered: bool
    session: Session | None = None
    age_ok: bool | None = None           # monitor AGE agrees with the WebDev session start
    webdev_age: dt.timedelta | None = None
    last_request: Record | None = None
    next_request: Record | None = None   # the user's first request after the kill
    reconnect: dt.timedelta | None = None


def match_kills(kills: list[dict], data: WebDevData, offset: dt.timedelta) -> list[KillMatch]:
    out: list[KillMatch] = []
    for k in kills:
        w = k['t'] - offset
        if data.first is None or data.last is None or not (data.first <= w <= data.last):
            out.append(KillMatch(k, covered=False))
            continue
        s = session_at(data, k['pid'], w)
        m = KillMatch(k, covered=True, session=s)
        out.append(m)
        if not s:
            continue
        if s.connect_seen:
            m.webdev_age = seen = w - s.start
            age = age_minutes(k['age'])
            # AGE is whole minutes, rounded down; allow a few seconds of clock jitter.
            m.age_ok = age is not None and age * 60 - 5 <= seen.total_seconds() < age * 60 + 65
        recs = data.kept.get(k['pid'], [])
        m.last_request = next((r for r in reversed(recs)
                               if s.start <= r.t <= w + dt.timedelta(seconds=1) and r.status in OK_STATUSES), None)
        # A dead process serves nothing, so the user's next request is the first
        # error on this PID from the session's IP, before any reuse of the PID.
        for r in recs:
            if r.t < w or r.ip != s.ip:
                continue
            if r.status in OK_STATUSES and r.t <= w + dt.timedelta(seconds=1):
                continue  # served in the kill's own second, before the kill landed
            if r.status == '*ERROR*':
                m.next_request = r
            break
        i = bisect.bisect_right(data.connects, (w, '', ''))
        for t, ip, _ in data.connects[i:]:
            if t - w > RECONNECT_WINDOW:
                break
            if ip == s.ip:
                m.reconnect = t - w
                break
    return out
