#!/usr/bin/env python3
"""SIGKILL the real storage executable at transaction boundaries in TEMP folders.
This proves a bounded process-death recovery matrix, not power-loss durability.
Never accepts a user vault path; all data is generated inside TemporaryDirectory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import signal
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--probe', required=True, type=Path)
parser.add_argument('--report', type=Path, default=ROOT / 'Evidence/process-crash-tests.json')
parser.add_argument('--temp-parent', type=Path, default=ROOT / '.build-output/process-fixtures')
args = parser.parse_args()
probe = args.probe.resolve()
assert probe.is_file(), probe
args.temp_parent.mkdir(parents=True, exist_ok=True)
checks = []


def run(command, root, *rest):
    value = subprocess.run([str(probe), command, str(root), *rest], text=True, capture_output=True, timeout=30)
    assert value.returncode == 0, (value.args, value.stderr, value.stdout)
    return json.loads(value.stdout)


def kill_at(command, root, arguments, stage):
    child = subprocess.Popen([str(probe), command, str(root), *arguments, '--pause-at=' + stage],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        readable, _, _ = select.select([child.stdout], [], [], 20)
        assert readable, f'No transaction checkpoint reached: {stage}'
        line = child.stdout.readline().strip()
        assert line == 'PAUSED ' + stage, (line, child.stderr.read() if child.poll() is not None else '')
        child.kill()
        assert child.wait(timeout=5) == -signal.SIGKILL
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        child.stdout.close()
        child.stderr.close()


stages = ['journalSealed', 'beforeInstall', 'installed', 'metadataUpdated', 'committed']
for operation in ['create', 'save']:
    for stage in stages:
        with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-kill-test-') as folder:
            root = Path(folder)
            run('init', root)
            if operation == 'save':
                run('create', root, 'Note', 'before')
                kill_at('save', root, ['Notes/Note.md', 'after 👩🏽‍💻\nمرحبا'], stage)
            else:
                kill_at('create', root, ['Note', 'after 👩🏽‍💻\nمرحبا'], stage)
            report = run('recover', root)
            assert not report['review'], report
            value = run('read', root, 'Notes/Note.md')
            assert value['text'] == 'after 👩🏽‍💻\nمرحبا'
            assert value['revision'] == hashlib.sha256(value['text'].encode()).hexdigest()
            again = run('recover', root)
            assert not again['replayed'], again
            checks.append({'case': f'SIGKILL {operation} at {stage}', 'status': 'PASS'})

with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-conflict-test-') as folder:
    root = Path(folder)
    run('init', root)
    run('create', root, 'Note', 'before')
    kill_at('save', root, ['Notes/Note.md', 'local proposal'], 'journalSealed')
    (root / 'Notes/Note.md').write_text('external edit while Folio was down')
    recovery = run('recover', root)
    assert recovery['review'] and not recovery['replayed']
    assert (root / 'Notes/Note.md').read_text() == 'external edit while Folio was down'
    assert any(p.read_text() == 'local proposal' for p in (root / '.folio/journal').glob('*/proposal.md'))
    checks.append({'case': 'Changed external head after SIGKILL is not overwritten', 'status': 'PASS'})

with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-corrupt-test-') as folder:
    root = Path(folder)
    run('init', root)
    run('create', root, 'Note', 'before')
    kill_at('save', root, ['Notes/Note.md', 'proposal'], 'journalSealed')
    for tx in (root / '.folio/journal').iterdir():
        if not (tx / 'committed.json').exists():
            (tx / 'proposal.md').write_text('invalid replacement bytes')
    recovery = run('recover', root)
    assert recovery['review'] and not recovery['replayed']
    assert (root / 'Notes/Note.md').read_text() == 'before'
    checks.append({'case': 'Tampered proposal is rejected after process death', 'status': 'PASS'})

with tempfile.TemporaryDirectory(dir=args.temp_parent, prefix='folio-metadata-test-') as folder:
    root = Path(folder)
    run('init', root)
    run('create', root, 'Metadata', 'before')
    file = root / 'Notes/Metadata.md'
    file.chmod(0o640)
    os.setxattr(file, b'user.folio.test', b'preserve this attribute')
    initial = file.stat()
    run('save', root, 'Notes/Metadata.md', 'after')
    assert stat.S_IMODE(file.stat().st_mode) == 0o640
    assert file.stat().st_uid == initial.st_uid and file.stat().st_gid == initial.st_gid
    assert os.getxattr(file, b'user.folio.test') == b'preserve this attribute'
    checks.append({'case': 'Unix mode, ownership and extended attribute survive replacement', 'status': 'PASS'})

report = {
    'status': 'PASS', 'platform': platform.platform(),
    'test_count': len(checks), 'checks': checks,
    'scope': 'Real compiled Folio storage core; child processes killed with SIGKILL; generated temporary folders only',
    'does_not_prove': ['power-loss durability', 'macOS/APFS F_FULLFSYNC behaviour', 'AppKit UI correctness', 'large-vault performance', 'independent security audit']
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
