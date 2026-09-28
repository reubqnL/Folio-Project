#!/usr/bin/env python3
"""SIGKILL the real roadmap store only in newly generated temporary projects."""
import argparse
import json
import platform
import select
import signal
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--probe', required=True, type=Path)
parser.add_argument('--temp-parent', type=Path, default=ROOT / '.build-output/planning-fixtures')
parser.add_argument('--report', type=Path, default=ROOT / 'Evidence/roadmap-crash-tests.json')
args = parser.parse_args()
args.temp_parent.mkdir(parents=True, exist_ok=True)
probe = args.probe.resolve()
checks = []


def run(command, root, *rest):
    result = subprocess.run([str(probe), command, str(root), *rest], text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, (result.args, result.stderr, result.stdout)
    return json.loads(result.stdout)


def kill_at(root, stage):
    child = subprocess.Popen([str(probe), 'write', str(root), 'New revision', '--pause-at=' + stage],
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        ready, _, _ = select.select([child.stdout], [], [], 20)
        assert ready, 'Roadmap checkpoint not reached'
        line = child.stdout.readline().strip()
        assert line == 'PAUSED ' + stage, line
        child.kill()
        assert child.wait(timeout=5) == -signal.SIGKILL
    finally:
        if child.poll() is None:
            child.kill(); child.wait(timeout=5)
        child.stdout.close(); child.stderr.close()


for existing in [False, True]:
    for stage in ['journalSealed', 'beforeInstall', 'installed', 'metadataUpdated', 'committed']:
        with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-plan-kill-') as directory:
            root = Path(directory)
            run('init', root)
            if existing:
                run('write', root, 'Previous revision')
            kill_at(root, stage)
            recovery = run('recover', root)
            assert not recovery['review'], recovery
            assert run('read', root)['titles'] == ['New revision']
            assert not run('recover', root)['replayed']
            checks.append({'case': ('update' if existing else 'create') + ' SIGKILL at ' + stage, 'status': 'PASS'})

with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-plan-conflict-') as directory:
    root = Path(directory)
    run('init', root); run('write', root, 'Original')
    kill_at(root, 'journalSealed')
    path = root / '.folio/roadmap.json'
    value = json.loads(path.read_text())
    value['items'][0]['title'] = 'External edit during downtime'
    path.write_text(json.dumps(value))
    original = path.read_bytes()
    recovery = run('recover', root)
    assert recovery['review'] and path.read_bytes() == original
    checks.append({'case': 'External roadmap head survives interrupted-write recovery', 'status': 'PASS'})

with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-plan-corrupt-') as directory:
    root = Path(directory)
    run('init', root); run('write', root, 'Original')
    kill_at(root, 'journalSealed')
    path = root / '.folio/roadmap.json'; original = path.read_bytes()
    for transaction in (root / '.folio/roadmap-journal').iterdir():
        if not (transaction / 'committed.json').exists():
            (transaction / 'proposed.json').write_text('corrupted data')
    recovery = run('recover', root)
    assert recovery['review'] and path.read_bytes() == original
    checks.append({'case': 'Corrupt proposed roadmap is not installed', 'status': 'PASS'})

report = {
    'status': 'PASS', 'platform': platform.platform(), 'test_count': len(checks), 'checks': checks,
    'scope': 'Real compiled roadmap store; actual SIGKILL; generated disposable project directories',
    'not_proven': ['power-loss durability', 'APFS and Mac sandbox behaviour', 'native planning/Metal UI', 'release security']
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
