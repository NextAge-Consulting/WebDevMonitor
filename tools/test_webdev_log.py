"""Tests for the WebDev cross-reference. Run from the repo root:

    python3 -m unittest discover -s tools

The logs are generated here from invented values, so nothing from a real
server is committed.
"""
from __future__ import annotations

import datetime as dt
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analyze_log  # noqa: E402  (needs the path above)
import webdev_log  # noqa: E402

OFFSET = dt.timedelta(hours=1)           # the monitor writes local time, WebDev one hour behind
T0 = dt.datetime(2026, 1, 5, 9, 0, 0)    # WebDev clock
IP = '203.0.113.7'
KILLED = '4242'


def wd(t: dt.datetime, pid: str, status: str, code: str = '', event: str = '', ip: str = IP,
       ajax: str = '') -> str:
    return '\t'.join(['_', t.strftime('%Y%m%d%H%M%S'), 'DYN', pid, 'MyApp', status, ajax, code, event,
                      '0', ip, '', '', 'MyApp', 'myapp']) + '\r\n'


def mon(t: dt.datetime, body: str) -> str:
    return f'{t:%Y-%m-%d %H:%M:%S} {body}\n'


def build(folder: str) -> tuple[str, str]:
    session_log: list[str] = []
    error_log: list[str] = []
    monitor: list[str] = [mon(T0 + OFFSET, 'MONITOR STARTED v4.5 (Fast Memory Check)')]
    # 30 short sessions, each named by one heartbeat while it runs.
    for i in range(30):
        pid, mid = str(1000 + i), T0 + dt.timedelta(minutes=5 * i)
        session_log += [wd(mid - dt.timedelta(minutes=2), pid, 'CONNECT', event='https://example.com/'),
                        wd(mid, pid, 'PAGEOK', 'PAGE_Home', 'PAGE_HOME.AJAXPAGE', ajax='AJAX'),
                        wd(mid + dt.timedelta(minutes=2), pid, 'EXIT', 'TIMEOUT')]
        monitor.append(mon(mid + OFFSET, f'HEARTBEAT PROCS:30 TOP_MEM:PID:{pid}/150MB TOP_CPU:PID:{pid}/1% '
                                         'TRACKING:0 SPIKES:0 KILLS:0'))
    # PID 4242 is used once and exits, then reused by the session that gets killed.
    first = T0 + dt.timedelta(minutes=10)
    session_log += [wd(first, KILLED, 'CONNECT', ip='198.51.100.9'),
                    wd(first + dt.timedelta(minutes=1), KILLED, 'EXIT', 'CODE', ip='198.51.100.9')]
    start = T0 + dt.timedelta(minutes=60)
    kill = start + dt.timedelta(minutes=3, seconds=20)
    session_log.append(wd(start, KILLED, 'CONNECT'))
    for s in range(0, 190, 10):
        session_log.append(wd(start + dt.timedelta(seconds=s), KILLED, 'PAGEOK', 'PAGE_Orders',
                              'PAGE_ORDERS.AJAXPAGE', ajax='AJAX'))
    err = wd(kill + dt.timedelta(seconds=12), KILLED, '*ERROR*', 'ERR_BAD_CONTEXT_FOUND')
    session_log += [err, wd(kill + dt.timedelta(seconds=12), '5555', 'CONNECT')]
    # WebDev's error log repeats the error record, followed by the HTML page served.
    error_log += [err, '<!DOCTYPE html>\r\n', '<html><body>Disconnected</body></html>\r\n']
    # An EXIT for a session that began before the log did.
    session_log.append(wd(start, '7777', 'EXIT', 'TIMEOUT'))
    session_log.sort(key=lambda line: line.split('\t')[1])
    monitor.append(mon(kill + OFFSET, f'KILLING PID:{KILLED} MEM:90MB DUR:10.9s CPU:40.1 REASON:CPU AGE:3m'))
    monitor.append(mon(kill + OFFSET, f'KILLED PID:{KILLED}'))

    wd_dir = os.path.join(folder, 'webdev')
    os.mkdir(wd_dir)
    with open(os.path.join(wd_dir, 'Session_20260105.log'), 'w', encoding='utf-8-sig', newline='') as fh:
        fh.writelines(session_log)
    with open(os.path.join(wd_dir, 'SessionErr_20260105.log'), 'w', encoding='utf-8-sig', newline='') as fh:
        fh.writelines(error_log)
    mon_path = os.path.join(folder, 'wd_sessions.log')
    with open(mon_path, 'w', encoding='utf-8') as fh:
        fh.writelines(monitor)
    return mon_path, wd_dir


class CrossReferenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.mon_path, self.wd_dir = build(self.tmp.name)
        self.hb, self.kills, *_ = analyze_log.parse(self.mon_path)
        self.data = webdev_log.parse([self.wd_dir], keep_pids={KILLED})

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_error_log_is_skipped(self) -> None:
        self.assertEqual([os.path.basename(f) for f in self.data.skipped], ['SessionErr_20260105.log'])
        self.assertEqual(len(self.data.files), 1)
        alone = webdev_log.parse([os.path.join(self.wd_dir, 'SessionErr_20260105.log')])
        self.assertEqual((alone.files, alone.records), ([], 0))

    def test_pid_reuse_splits_sessions(self) -> None:
        sessions = self.data.sessions[KILLED]
        self.assertEqual(len(sessions), 2)
        self.assertEqual(sessions[0].exit_reason, 'CODE')
        self.assertIsNone(sessions[1].exit_reason)

    def test_exit_without_connect_is_its_own_session(self) -> None:
        self.assertFalse(self.data.sessions['7777'][0].connect_seen)

    def test_offset_is_detected(self) -> None:
        off = webdev_log.detect_offset(self.hb, self.data)
        self.assertEqual(off.offset, OFFSET)
        self.assertGreater(off.score, 0.95)

    def test_kill_matches_the_reused_pid_session(self) -> None:
        (m,) = webdev_log.match_kills(self.kills, self.data, OFFSET)
        self.assertTrue(m.covered)
        assert m.session is not None
        self.assertEqual(m.session.start, T0 + dt.timedelta(minutes=60))
        self.assertTrue(m.age_ok)
        assert m.last_request is not None and m.next_request is not None
        self.assertEqual(m.last_request.code, 'PAGE_Orders')
        self.assertEqual(m.next_request.code, 'ERR_BAD_CONTEXT_FOUND')
        self.assertEqual(m.reconnect, dt.timedelta(seconds=12))

    def test_wrong_offset_is_exposed_by_age(self) -> None:
        # A killed session logs no EXIT, so a wrong offset can still land on it;
        # the monitor's AGE is what disagrees.
        (m,) = webdev_log.match_kills(self.kills, self.data, dt.timedelta(0))
        self.assertFalse(m.age_ok)

    def test_age_parsing(self) -> None:
        self.assertEqual(webdev_log.age_minutes('3m'), 3)
        self.assertEqual(webdev_log.age_minutes('2h5m'), 125)


if __name__ == '__main__':
    unittest.main()
