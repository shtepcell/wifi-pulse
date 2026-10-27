#!/usr/bin/env python3
"""Live integration test. Sends ICMP only to the automatically discovered local router."""
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/wifi-analyzer').resolve())
with tempfile.TemporaryDirectory(prefix='wifi-analyzer-smoke-') as tmp:
    session = Path(tmp) / 'recording'
    p = subprocess.Popen([binary, 'record', '--duration', '4', '--output', str(session)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(1)
        p.stdin.write('Integration lag marker\n')
        p.stdin.flush()
        time.sleep(1.5)
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=12)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
    assert p.returncode == 0, (out, err)
    events = [json.loads(line) for line in (session / 'events.jsonl').read_text().splitlines()]
    sends = sorted((e for e in events if e['kind'] == 'send'), key=lambda e: e['t'])
    replies = [e for e in events if e['kind'] == 'reply']
    assert len(sends) >= 25, len(sends)
    assert sends[0]['t'] < 0.5, f"Ping output was buffered: first send t={sends[0]['t']}"
    gaps = [b['t'] - a['t'] for a, b in zip(sends, sends[1:])]
    median = statistics.median(gaps)
    assert 0.015 < median < 0.15, f'Invalid collection cadence: {median}'
    markers = [e for e in events if e['kind'] == 'marker']
    assert len(markers) == 1 and markers[0]['message'] == 'Integration lag marker', markers
    assert 0.7 < markers[0]['t'] < 1.5, markers
    stops = [e for e in events if e['kind'] == 'stopping']
    assert len(stops) == 1, 'The recording needs an explicit observation cutoff'
    sent_times = {e['id']: e['t'] for e in sends}
    for event in events:
        if event['kind'] == 'timeout':
            assert sent_times[event['id']] <= stops[0]['t'] - 1, 'Stop must not turn an unresolved probe into a false loss'
    assert events[-1]['kind'] == 'end'
    assert isinstance(events[-1]['pending'], int)
    assert all('schemaVersion' in e and e['t'] >= 0 for e in events)
    assert (session / 'report.html').stat().st_size > 10000
    assert (session / 'ping.log').stat().st_size > 100
    assert any(e['kind'] == 'metrics' and 'awdlUp' in e['values'] for e in events)
    subprocess.run([binary, 'report', str(session)], check=True, capture_output=True)
    again = subprocess.run([binary, 'record', '--duration', '1', '--output', str(session)], capture_output=True)
    assert again.returncode != 0, 'Existing recording must not be overwritten'
    print(f'PASS live recording: {len(sends)} sends, {len(replies)} replies, median interval {median*1000:.2f} ms; marker, Ctrl+C, regeneration and overwrite protection verified')
