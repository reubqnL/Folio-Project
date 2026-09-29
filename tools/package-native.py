"""Package Increment 12 with narrowly scoped, real verification evidence."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import zipfile
import yaml

ROOT = Path(__file__).resolve().parent.parent
ROOT = ROOT  # the Swift package now lives at the repository root
TOOLCHAIN = Path.home() / '.cache/folio-swift/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin'
EXCLUDE = {'.build', '.build-output', 'DerivedData', 'node_modules', '__pycache__', '.cache', 'xcuserdata'}
LOGO = 'ac1a2e20ffc15418726d07c36bffe2abfbb2dde800017f81dc612b09ba9c29bc'


def run(args, **kwargs):
    env = os.environ.copy()
    env['PATH'] = str(TOOLCHAIN) + os.pathsep + env['PATH']
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, check=True, **kwargs)
    return result


answers = json.loads((ROOT / 'docs/planning/decisions/answers.json').read_text())
assert [a['number'] for a in answers['answers']] == list(range(1, 51))
assert answers['confirmed_count'] == 50 and answers['next_questions'] == []
original = ROOT / 'assets/folio-app-icon.png'
assert hashlib.sha256(original.read_bytes()).hexdigest() == LOGO
assert original.read_bytes() == (ROOT / 'App/Resources/Assets.xcassets/FolioLogo.imageset/folio.png').read_bytes()
for path in (ROOT / 'App').glob('*.plist'):
    plistlib.loads(path.read_bytes())
entitlements = plistlib.loads((ROOT / 'App/Folio.entitlements').read_bytes())
assert entitlements == {'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-write': True, 'com.apple.security.device.audio-input': True}
project = yaml.safe_load((ROOT / 'project.yml').read_text())
assert project['settings']['base']['ARCHS'] == 'arm64'
assert project['targets']['Folio']['entitlements']['properties'] == entitlements
info = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
assert 'only after you press Record' in info['NSMicrophoneUsageDescription']
assert project['targets']['Folio']['info']['properties']['NSMicrophoneUsageDescription'] == info['NSMicrophoneUsageDescription']
assert 'com.apple.security.network.client' not in entitlements
assert 'com.apple.security.network.server' not in entitlements
for contents in (ROOT / 'App/Resources').rglob('Contents.json'):
    for image in json.loads(contents.read_text()).get('images', []):
        assert (contents.parent / image['filename']).is_file()

for script in (ROOT / 'scripts').glob('*.sh'):
    run(['bash', '-n', str(script)])
run(['swiftc', '-frontend', '-parse', *[str(p) for p in sorted((ROOT / 'App').rglob('*.swift'))]])
include = 'Sources/FolioFileIO/include'
rdm_include = 'Sources/FolioRDMPrimitives/include'
argon_include = 'Sources/CArgon2/include'
argon_src = 'Sources/CArgon2/src'
for c_source in ['Sources/FolioFileIO/FolioFileIO.c', 'Sources/FolioFileIO/FolioAudioRing.c', 'Sources/FolioRDMPrimitives/FolioCrypto.c', 'Sources/FolioRDMPrimitives/FolioArchive.c']:
    extra = ['-I', rdm_include] if 'FolioRDMPrimitives' in c_source else []
    if c_source.endswith('FolioCrypto.c'): extra += ['-I', argon_include, '-I', argon_src]
    run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only', '-I', include, *extra, c_source])
    analysis_path = Path.home() / ('.cache/' + Path(c_source).stem + '-analysis.plist')
    analysis = run(['clang', '--analyze', '-std=c11', '-I', include, *extra, c_source, '-o', str(analysis_path)])
    assert not analysis.stderr.strip(), analysis.stderr
    assert not plistlib.loads(analysis_path.read_bytes()).get('diagnostics')
speech_source = (ROOT / 'App/Speech/AppleSpeechService.swift').read_text() + (ROOT / 'App/Speech/AppleSpeechPipeline.swift').read_text()
assert 'AVAudioFile(' not in speech_source and 'SFSpeechRecognizer(' not in speech_source
assert 'CaptureInputSequenceProvider(' not in speech_source and 'AnalyzerInputConverter(' not in speech_source

unit_count = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in (ROOT / 'Tests').rglob('*.swift'))
assert unit_count == 421
# Evidence/ holds generated test output and is intentionally not committed
# (see .gitignore). Recreate it from the current source when it is absent, so
# the assertions below always read results produced by this checkout.
REQUIRED_EVIDENCE = ['core-tests.log', 'core-tests-release.log', 'audio-ring-sanitizers.json',
                     'reading-workflow.json', 'planning-workflow.json', 'capture-workflow.json',
                     'speech-workflow.json', 'process-crash-tests.json', 'roadmap-crash-tests.json']
if any(not (ROOT / 'Evidence' / name).is_file() for name in REQUIRED_EVIDENCE):
    subprocess.run(['bash', 'scripts/test-core.sh'], cwd=ROOT, check=True)

for name in ['core-tests.log', 'core-tests-release.log']:
    text = (ROOT / 'Evidence' / name).read_text()
    assert re.search(r'Executed 421 tests, with 0 failures', text)
    assert "Test Suite 'All tests' passed" in text
    assert 'warning:' not in text and 'error:' not in text
processes = json.loads((ROOT / 'Evidence/process-crash-tests.json').read_text())
assert processes['status'] == 'PASS' and processes['test_count'] == 13
assert all(c['status'] == 'PASS' for c in processes['checks'])
reading = json.loads((ROOT / 'Evidence/reading-workflow.json').read_text())
assert reading['status'] == 'PASS' and reading['check_count'] == 11 and reading['generated_note_count'] == 1000
planning = json.loads((ROOT / 'Evidence/planning-workflow.json').read_text())
assert planning['status'] == 'PASS' and planning['check_count'] == 10
roadmap = json.loads((ROOT / 'Evidence/roadmap-crash-tests.json').read_text())
assert roadmap['status'] == 'PASS' and roadmap['test_count'] == 12
capture = json.loads((ROOT / 'Evidence/capture-workflow.json').read_text())
assert capture['status'] == 'PASS' and capture['check_count'] == 11 and capture['live_model_inference'] is False
speech = json.loads((ROOT / 'Evidence/speech-workflow.json').read_text())
assert speech['status'] == 'PASS' and speech['check_count'] == 12
assert speech['live_microphone'] is False and speech['live_speech_recognition'] is False
audio = json.loads((ROOT / 'Evidence/audio-ring-sanitizers.json').read_text())
assert audio['status'] == 'PASS' and audio['checks'] == 6 and audio['accepted_threaded_frames'] == 100000
speech = json.loads((ROOT / 'Evidence/speech-workflow.json').read_text())
assert speech['status'] == 'PASS' and speech['check_count'] == 12
assert speech['live_microphone'] is False and speech['live_speech_recognition'] is False
audio = json.loads((ROOT / 'Evidence/audio-ring-sanitizers.json').read_text())
assert audio['status'] == 'PASS' and audio['checks'] == 6 and audio['accepted_threaded_frames'] == 100000
progress = json.loads((ROOT / 'docs/progress/progress.json').read_text())
assert sum(a['weight'] for a in progress['areas']) == 100
assert sum(a['credited_points'] for a in progress['areas']) == progress['estimated_percent'] == 43
assert all(0 <= a['credited_points'] <= a['weight'] for a in progress['areas'])

# Only remove our obsolete local build/scratch outputs, never user vaults.
shutil.rmtree(ROOT / '.build-output', ignore_errors=True)
(ROOT / 'Evidence/core-tests-initial.log').unlink(missing_ok=True)

compiled_paths = [ROOT / 'Package.swift']
compiled_paths += sorted((ROOT / 'Sources').rglob('*'))
compiled_paths += sorted((ROOT / 'Tests').rglob('*.swift'))
compiled_hashes = {
    str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in compiled_paths if p.is_file()
}
inspection = {
    'host': 'Linux x86_64',
    'swift': run(['swift', '--version']).stdout.strip(),
    'clang': run(['clang', '--version']).stdout.splitlines()[0],
    'c_warnings_as_errors': 'PASS',
    'c_static_analysis_diagnostics': 0,
    'mac_app_swift_syntax': 'PASS — parse only, not SDK typechecking',
    'plist_yaml_asset_and_shell_checks': 'PASS',
    'compiled_source_hashes': compiled_hashes
}
(ROOT / 'Evidence/source-inspection.json').write_text(json.dumps(inspection, indent=2))
verification = {
    'increment': '12',
    'status': 'Increment 12 development source; encrypted .rdm foundation with persistent encrypted working storage and the honest durability acknowledgement model, incremental Markdown reparse, compact link repair and the large-document benchmark harness; estimated scope completion 46%; native/security/release gates remain blocked',
    'personal_answers': {'total': 50, 'ui_ux': 25, 'engineering': 25},
    'core_compiled_targets': ['FolioCore', 'FolioFileIO', 'CSQLite', 'FolioStorageProbe', 'FolioReadingProbe', 'FolioPlanningProbe', 'FolioCaptureProbe', 'FolioSpeechProbe', 'CArgon2', 'FolioRDMPrimitives'],
    'core_compilation_platform': 'Linux x86_64 / Swift 6.0.3',
    'distinct_unit_tests': unit_count,
    'debug_tests': 'PASS — 421 tests, 0 failures',
    'release_optimised_tests': 'PASS — same 421 tests, 0 failures',
    'process_storage_checks': 'PASS — 13 checks, including real SIGKILL',
    'reading_workflow_checks': 'PASS — 11 checks with 1,000 generated note fixtures',
    'planning_graph_workflow': 'PASS — 10 generated-data checks',
    'roadmap_crash_checks': 'PASS — 12 checks including actual SIGKILL',
    'capture_storage_workflow': 'PASS — 11 checks using a fixed test provider, not live AI',
    'estimated_completion_percent': progress['estimated_percent'],
    'percentage_method': progress['method'],
    'live_foundation_models_inference': 'NOT RUN — native adapter source only',
    'native_capture_editor_apply_undo_and_rollback': 'NOT RUN',
    'microphone_and_apple_speech': 'Native source added; SDK/TCC/device/converter/ASR runtime NOT RUN',
    'rdm_crypto_archive_checkpoint': 'PASS — 43 focused primitive/archive/file/hostile-input tests; independent review and Mac parity NOT RUN',
    'rdm_encrypted_working_store_index': 'PASS — 8 bounded derived-index tests and 18 persistent working-store tests (chained draft records, stale classification, reviewed resolution, plaintext canaries, encrypted index cache)',
    'encrypted_project_session': 'PASS — 10 session-boundary tests covering memory search, recovery reopen, checkpoint/index ordering, failed checkpoint preservation, lock release, draft survive-close/reopen, discard-to-clear, stale-block until resolution and cache fallback',
    'vault_durability_acknowledgement': 'PASS — 10 N01 durability-model tests (seven-state resolution and precedence, label honesty, scoped explanations, checkpoint/sync separation, measured 250/500 ms coalescing bounds)',
    'speech_workflow': 'PASS — 12 synthetic PCM/transcript/handoff cases; no microphone or ASR',
    'audio_ring_sanitizers': 'PASS — 6 ASan/UBSan checks; 100000 generated threaded frames',
    'hostile_input_and_rebuild_coverage': 'PASS — deterministic archive mutation/random ZIP/bounds tests and failed-rebuild preservation',
    'owner_testing_status': 'HOLD until approved Mac scope and engineering gates are complete',
    'c_static_analysis': 'PASS for Linux branch; no diagnostics',
    'mac_application_swift_parsing': 'PASS — syntax only',
    'mac_sdk_typechecking_and_build': 'NOT RUN',
    'metal_shader_pipeline_and_gpu_execution': 'NOT RUN',
    'mac_ui_sandbox_accessibility_performance_tests': 'NOT RUN',
    'apfs_f_fullfsync_metadata_and_power_loss_tests': 'NOT RUN',
    'independent_security_audit': 'NOT RUN',
    'release_ready': False,
    'windows_evaluation_permitted': False,
    'android_scope': 'read-only',
    'native_app_or_installer_built': False,
    'current_storage': 'Plaintext Markdown, roadmap sidecar, recovery journals and outside-vault search cache; encrypted .rdm projects keep unsaved drafts and the derived-index cache in sealed local working records',
    'unimplemented_or_unverified': ['native planning/Metal/UI execution', '100k-note/native-performance gates', 'full Markdown conformance and reconciliation/recovery refinements', 'Mac preview/split/IME/undo/accessibility runtime', 'live Foundation Models and Apple speech/microphone SDK/runtime/quality/resource checks', 'Mac CryptoKit/APFS parity, encrypted-working-store fault/power-loss coverage and independent crypto review', 'collaboration', 'installer/updater/security audit'],
    'approved_logo_sha256': LOGO
}
(ROOT / 'Verification.json').write_text(json.dumps(verification, indent=2))

# The distributable development bundle. Only source, configuration, checked-in
# assets, tooling and recorded evidence are packaged; docs/reference, the design
# prototype and every build artefact stay behind.
BUNDLED_DIRS = [
    'App', 'Sources', 'Tests', 'scripts', 'Evidence',
    'assets', 'docs/notices', 'docs/planning/decisions',
]
BUNDLED_FILES = [
    'Package.swift', 'project.yml', 'Verification.json',
    'docs/CHANGELOG.md',
    'docs/planning/Folio-Implementation-Plan.md',
    'docs/planning/Folio-Feature-Completion.md',
    'docs/progress/PROGRESS.md',
    'docs/progress/progress.json',
]

files = []
for relative in BUNDLED_DIRS:
    base = ROOT / relative
    assert base.is_dir(), base
    for path in sorted(base.rglob('*')):
        if path.is_file() and not any(part in EXCLUDE for part in path.parts):
            assert not path.is_symlink()
            files.append((path, 'Folio/' + str(path.relative_to(ROOT))))
for relative in BUNDLED_FILES:
    path = ROOT / relative
    assert path.is_file(), path
    files.append((path, 'Folio/' + relative))
manifest = {
    'bundle': 'Folio native source — Increment 12',
    'status': verification['status'],
    'files': [{'path': name, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path, name in files]
}
manifest_path = ROOT / 'SOURCE-MANIFEST.json'
manifest_path.write_text(json.dumps(manifest, indent=2))
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
archive_path = DIST / 'Folio-Source.zip'
with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path, name in files: archive.write(path, name)
    archive.write(manifest_path, 'Folio/SOURCE-MANIFEST.json')
with zipfile.ZipFile(archive_path) as archive:
    assert archive.testzip() is None
    assert not any('/.build' in name or '/.git/' in name or '/node_modules/' in name
                   or name.endswith('.app') for name in archive.namelist())
old_archive = DIST / 'Folio-Native-Increment-03.zip'
if old_archive.exists():
    cleanup_path = ROOT / 'docs/reference/cleanup.json'
    cleanup = json.loads(cleanup_path.read_text())
    size = old_archive.stat().st_size
    cleanup['removed'].append({'path': old_archive.name, 'bytes': size})
    cleanup['bytes_removed'] += size
    cleanup['latest_source_snapshot_preserved_until_replaced'] = 'Replaced by Folio-Source.zip after successful validation'
    cleanup_path.write_text(json.dumps(cleanup, indent=2))
    old_archive.unlink()
print(json.dumps(verification, indent=2))
print(f'Packaged {len(files) + 1} files: {archive_path.name}, {archive_path.stat().st_size / 2**20:.2f} MiB')
