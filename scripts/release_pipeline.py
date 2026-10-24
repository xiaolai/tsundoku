#!/usr/bin/env python3
"""Build, verify, draft and publish explicit, audited release inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import privacy_audit

REPO = 'xiaolai/tsundoku'
ROOT = Path(__file__).resolve().parents[1]
PRIVATE_LOG = None


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition: raise ReleaseError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n'); temporary.replace(path)


def command(args, cwd=ROOT, env=None):
    process = subprocess.run([str(a) for a in args], cwd=cwd, env=env, capture_output=True)
    if PRIVATE_LOG is not None:
        with PRIVATE_LOG.open('ab') as log:
            log.write(('\nTOOL ' + Path(args[0]).name + '\n').encode())
            log.write(process.stdout + b'\n' + process.stderr)
    require(process.returncode == 0, f'{Path(args[0]).name} failed; inspect the private tool.log before retrying.')
    return process.stdout.decode()


def json_command(args):
    try: return json.loads(command(args))
    except (ValueError, UnicodeError): raise ReleaseError('Tool returned an invalid JSON receipt.')


def asset_names(version):
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Version must be MAJOR.MINOR.PATCH.')
    return [f'Tsundoku-{version}.dmg', 'release-provenance.json', 'SHA256SUMS']


def check_download(path, digest):
    require(re.fullmatch(r'[a-f0-9]{64}', digest) and sha256(path) == digest, 'Artifact checksum mismatch.')


def validate_manifest(manifest):
    require(manifest.get('schema') == 1, 'Unsupported release receipt.')
    asset_names(manifest.get('version', ''))
    for name in ['commit', 'tree', 'driver_commit']:
        require(re.fullmatch(r'[a-f0-9]{40}', manifest.get(name, '')), 'Invalid source object ID in release receipt.')
    require(re.fullmatch(r'[1-9][0-9]*', manifest.get('build', '')), 'Invalid receipt build number.')
    require(manifest.get('tag') == 'v' + manifest['version'], 'Receipt tag/version mismatch.')
    require(manifest.get('app_notarized') is True and manifest.get('dmg_notarized') is True, 'Receipt is not notarized.')


def verify_public_metadata(directory, manifest):
    expected = {k: manifest[k] for k in ['schema', 'commit', 'tree', 'driver_commit', 'version', 'tag', 'build', 'app_notarized', 'dmg_notarized']}
    expected['dmg_sha256'] = manifest['assets'][asset_names(manifest['version'])[0]]
    require(json.loads((directory / 'release-provenance.json').read_text()) == expected, 'Public provenance contains different or unapproved fields.')
    expected_checksums = ''.join(sha256(directory / n) + '  ' + n + '\n' for n in asset_names(manifest['version'])[:2])
    require((directory / 'SHA256SUMS').read_text() == expected_checksums, 'Checksum document contains unapproved data.')


def verify_assets(directory, manifest):
    names = asset_names(manifest['version'])
    require(set(manifest['assets']) == set(names), 'Public asset allowlist mismatch.')
    for name in names:
        path = directory / name
        require(path.is_file() and not path.is_symlink(), 'Missing or linked release asset.')
        check_download(path, manifest['assets'][name])


def notarize(artifact, profile, directory, runner=json_command):
    """A known ID resumes waiting. An ambiguous upload is never automatically sent twice."""
    record = directory / (artifact.name + '.notary.json')
    digest = sha256(artifact)
    state = json.loads(record.read_text()) if record.exists() else {'sha256': digest}
    require(state['sha256'] == digest, 'Notary receipt belongs to different bytes.')
    if state.get('status') == 'Accepted': return
    require(state.get('status') not in ['Invalid', 'Rejected'], 'Apple rejected these exact bytes.')
    if not state.get('id'):
        require(not state.get('submitted'), 'Upload outcome unknown. Reconcile it with notarytool history before continuing.')
        state['submitted'] = True; save(record, state)
        response = runner(['xcrun', 'notarytool', 'submit', str(artifact), '--keychain-profile', profile, '--output-format', 'json'])
        require(response.get('id'), 'Apple returned no submission ID; reconcile the upload before retrying.')
        state['id'] = response['id']; save(record, state)
    response = runner(['xcrun', 'notarytool', 'wait', state['id'], '--keychain-profile', profile, '--output-format', 'json'])
    state['status'] = response.get('status', 'Unknown'); save(record, state)
    require(state['status'] == 'Accepted', 'Notarization is not Accepted; inspect the saved submission ID with notarytool.')


def source_state(clean=True):
    commit = command(['git', 'rev-parse', 'HEAD']).strip()
    tree = command(['git', 'rev-parse', 'HEAD^{tree}']).strip()
    if clean:
        require(not command(['git', 'status', '--porcelain', '--untracked-files=all']).strip(), 'Commit the exact source tree first.')
    require(command(['git', 'config', '-f', '.gitmodules', '--get', 'submodule.vendor/kindle-toolkit.url']).strip() == 'https://github.com/xiaolai/kindle-toolkit.git', 'Driver origin is not the reviewed private dependency.')
    entry = command(['git', 'ls-tree', 'HEAD', 'vendor/kindle-toolkit']).split()
    require(len(entry) >= 3 and entry[0] == '160000', 'Private driver submodule is not pinned in HEAD.')
    driver = ROOT / 'vendor/kindle-toolkit'
    require((driver / '.git').is_file() and not driver.is_symlink(), 'Initialize the private driver submodule first.')
    require(command(['git', 'rev-parse', 'HEAD'], cwd=driver).strip() == entry[2], 'Driver checkout does not match its pin.')
    require(not command(['git', 'status', '--porcelain'], cwd=driver).strip(), 'Driver checkout is dirty.')
    version = (ROOT / 'VERSION').read_text().strip(); asset_names(version)
    return {'commit': commit, 'tree': tree, 'driver_commit': entry[2], 'version': version, 'tag': 'v' + version}


def audit(directory):
    report = privacy_audit.repository_report(ROOT)
    save(directory / 'privacy-audit.json', report)
    require(report['passed'], 'Privacy audit blocked publication. Inspect the redacted private report.')


def verify_signature(app):
    command(['codesign', '--verify', '--deep', '--strict', app])
    details = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True).stderr.decode()
    require('Authority=Developer ID Application:' in details and 'Timestamp=' in details and 'runtime' in details,
            'App must have a timestamped Developer ID hardened-runtime signature.')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', '-', str(app)], capture_output=True).stdout
    require(b'get-task-allow' not in entitlements, 'Release enables debugger attachment.')
    report = privacy_audit.artifact_report(app, run_gitleaks=True)
    require(report['passed'], 'App contains private build paths, identifiers or escaping symlinks.')


def gatekeeper(path, image=False):
    command(['xcrun', 'stapler', 'validate', path])
    args = ['spctl', '-a', '-vvv', '-t', 'open' if image else 'exec']
    if image: args += ['--context', 'context:primary-signature']
    process = subprocess.run([*args, str(path)], capture_output=True)
    require(process.returncode == 0 and b'source=Notarized Developer ID' in process.stderr + process.stdout,
            'Gatekeeper did not accept Notarized Developer ID.')


def build(directory, state, args):
    require(args.profile, 'Pass --profile with an existing notarytool Keychain profile.')
    audit(directory)
    command(['xcrun', 'notarytool', 'history', '--keychain-profile', args.profile])
    env = dict(os.environ, TSUNDOKU_APP_PATH=str(directory / 'Tsundoku.app'), TSUNDOKU_BUILD_NUMBER=args.build,
               TSUNDOKU_SOURCE_COMMIT=state['commit'], TSUNDOKU_SOURCE_TREE=state['tree'],
               TSUNDOKU_DRIVER_COMMIT=state['driver_commit'])
    app = directory / 'Tsundoku.app'; zipped = directory / 'Tsundoku.zip'
    built_record = directory / 'built.json'
    if not built_record.exists():
        command(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-v'])
        command(['swift', 'test'])
        command(['bash', 'scripts/build-app.sh'], env=env)
        verify_signature(app)
        require(source_state() == state, 'Source changed during the build.')
        command(['ditto', '-c', '-k', '--keepParent', app, zipped])
        save(built_record, {'source': state, 'zip_sha256': sha256(zipped)})
    built = json.loads(built_record.read_text())
    require(built['source'] == state and built['zip_sha256'] == sha256(zipped), 'Build receipt does not match its source/archive.')
    notarize(zipped, args.profile, directory)
    command(['xcrun', 'stapler', 'staple', app]); verify_signature(app); gatekeeper(app)
    dmg = directory / asset_names(state['version'])[0]
    if not dmg.exists():
        with tempfile.TemporaryDirectory(prefix='tsundoku-image-') as temporary:
            stage = Path(temporary)
            command(['ditto', app, stage / 'Tsundoku.app'])
            (stage / 'Applications').symlink_to('/Applications')
            command(['hdiutil', 'create', '-quiet', '-volname', 'Tsundoku ' + state['version'], '-srcfolder', stage, '-format', 'UDZO', dmg])
        identity = os.environ.get('CODESIGN_IDENTITY')
        if not identity:
            identities = command(['security', 'find-identity', '-v', '-p', 'codesigning'])
            matches = re.findall(r'"(Developer ID Application:[^"]+)"', identities)
            require(len(matches) == 1, 'Select CODESIGN_IDENTITY explicitly when identity is ambiguous.')
            identity = matches[0]
        require(identity != '-', 'Ad-hoc signing is not a release.')
        command(['codesign', '--force', '--timestamp', '--sign', identity, dmg])
    # The exact signed image is the immutable upload input. A stapled image has a different checksum.
    marker = directory / 'image-stapled.json'
    if not marker.exists():
        notarize(dmg, args.profile, directory)
        command(['xcrun', 'stapler', 'staple', dmg])
        save(marker, {'sha256': sha256(dmg)})
    require(json.loads(marker.read_text())['sha256'] == sha256(dmg), 'Stapled image changed.')
    gatekeeper(dmg, image=True)
    require(source_state() == state, 'Source changed during notarization.')
    public = dict(schema=1, **state, build=args.build, dmg_sha256=sha256(dmg), app_notarized=True, dmg_notarized=True)
    save(directory / 'release-provenance.json', public)
    checksums = ''.join(sha256(directory / n) + '  ' + n + '\n' for n in asset_names(state['version'])[:2])
    (directory / 'SHA256SUMS').write_text(checksums)
    receipt = dict(public, assets={n: sha256(directory / n) for n in asset_names(state['version'])})
    save(directory / 'receipt.json', receipt)
    print('Built notarized release assets; nothing published. Run verify on the dedicated test Mac.')


def remote_verify(directory, manifest, host):
    require(host and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', host), 'Pass --host with the privately configured test-Mac SSH alias.')
    validate_manifest(manifest); verify_assets(directory, manifest); verify_public_metadata(directory, manifest)
    dmg = directory / asset_names(manifest['version'])[0]
    remote = '/tmp/tsundoku-release-' + manifest['commit'][:12] + '-' + manifest['assets'][dmg.name][:12]
    command(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', host, 'mkdir -p ' + remote])
    command(['scp', '-q', dmg, host + ':' + remote + '/release.dmg'])
    # Headless file/signature checks only. No app, reader or permission request is launched.
    script = '''import pathlib,subprocess,tempfile,hashlib,shutil,plistlib,json,re
p=pathlib.Path(REMOTE)/'release.dmg'
assert hashlib.sha256(p.read_bytes()).hexdigest()==DIGEST
m=pathlib.Path(tempfile.mkdtemp(prefix='tsundoku-release-mount-'))
def run(args):
 r=subprocess.run(args,capture_output=True); assert r.returncode==0
 return r.stdout+r.stderr
def assess(p,kind):
 run(['xcrun','stapler','validate',str(p)])
 args=['spctl','-a','-vvv','-t',kind]
 if kind=='open':args+=['--context','context:primary-signature']
 assert b'source=Notarized Developer ID' in run(args+[str(p)])
try:
 assess(p,'open')
 run(['hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(m),str(p)])
 app=m/'Tsundoku.app'
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 expected=EXPECTED
 for key,value in expected.items(): assert info.get(key)==value
 binary=(app/'Contents/MacOS/Tsundoku').read_bytes()
 assert not re.search(rb'/(?:Users|home)/[A-Za-z0-9._-]+',binary)
 run(['codesign','--verify','--deep','--strict',str(app)])
 assess(app,'exec')
 print('VERIFIED '+DIGEST,flush=True)
finally:
 subprocess.run(['hdiutil','detach','-quiet',str(m)],capture_output=True)
 if not list(m.iterdir()):m.rmdir()
'''.replace('REMOTE', repr(remote)).replace('DIGEST', repr(manifest['assets'][dmg.name])).replace('EXPECTED', repr({
        'CFBundleIdentifier': 'com.lixiaolai.tsundoku', 'CFBundleShortVersionString': manifest['version'],
        'CFBundleVersion': manifest['build'], 'TsundokuSourceCommit': manifest['commit'],
        'TsundokuSourceTree': manifest['tree'], 'TsundokuDriverCommit': manifest['driver_commit']}))
    import shlex
    result = command(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', host, 'python3 -c ' + shlex.quote(script)])
    require('VERIFIED ' + manifest['assets'][dmg.name] in result, 'Remote verification returned no exact checksum receipt.')
    save(directory / 'remote-verification.json', {'assets': manifest['assets'], 'verified': True})
    print('Test Mac accepted the image and its mounted app; no app was launched.')


def verify_draft(release, manifest):
    require(release.get('draft') is True, 'Refusing to modify an already published release.')
    require(release.get('tag_name') == manifest['tag'] and release.get('target_commitish') == manifest['commit'],
            'Draft does not name the exact source commit/tag.')


def releases():
    pages = json_command(['gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'])
    return [row for page in pages for row in page]


def download(asset, target):
    require(isinstance(asset['id'], int), 'Invalid asset ID.')
    with target.open('wb') as output:
        result = subprocess.run(['gh', 'api', f'repos/{REPO}/releases/assets/{asset["id"]}', '-H', 'Accept: application/octet-stream'], stdout=output, stderr=subprocess.PIPE)
    require(result.returncode == 0, 'Could not download the release asset for independent verification.')


def review_public(directory, text, manifest):
    findings = privacy_audit.scan_bytes(text.encode(), 'public-release-input')
    findings.extend(privacy_audit.leak_findings(ROOT, text.encode()))
    require(not findings, 'Release notes or source failed the local privacy scan.')
    require(shutil.which('jev'), 'Jev is required before publication.')
    # Bounded chunks prevent silent model-context truncation. Do not include local receipts/paths.
    source = command(['git', 'diff', '--no-ext-diff', 'origin/main...HEAD'])
    payload = text + '\n' + json.dumps(manifest) + '\n' + source
    for index, start in enumerate(range(0, len(payload), 16000)):
        path = directory / ('public-review-' + str(index) + '.txt'); path.write_text(payload[start:start + 16000])
        result = json_command(['jev', 'docket', 'secret-scan', '--state-file', str(path), '--json'])
        save(directory / ('jev-public-' + str(index) + '.json'), result)
        values = {k: v['noul'] for k, v in result['answers'].items()}
        print('Jev secret-scan:', json.dumps(values))
        require(all(v < 0.1 for v in values.values()), 'Jev was inconclusive or flagged public inputs; inspect them before proceeding.')


def publication_preflight(directory, manifest):
    validate_manifest(manifest); verify_assets(directory, manifest); verify_public_metadata(directory, manifest)
    require(source_state() == {k: manifest[k] for k in ['commit', 'tree', 'driver_commit', 'version', 'tag']}, 'Release source changed.')
    audit(directory); verify_assets(directory, manifest)
    remote = json.loads((directory / 'remote-verification.json').read_text())
    require(remote.get('verified') and remote.get('assets') == manifest['assets'], 'Verify these exact assets on the test Mac first.')
    # Source publication remains an explicit separate git push. This command never pushes arbitrary refs.
    remote_main = command(['git', 'ls-remote', 'origin', 'refs/heads/main']).split()
    require(remote_main and remote_main[0] == manifest['commit'], 'Push the audited commit explicitly to origin/main before creating a draft.')
    tag = command(['git', 'ls-remote', 'origin', 'refs/tags/' + manifest['tag'], 'refs/tags/' + manifest['tag'] + '^{}']).splitlines()
    if tag:
        resolved = next((row.split()[0] for row in tag if row.endswith('^{}')), tag[0].split()[0])
        require(resolved == manifest['commit'], 'Existing release tag names different source bytes.')


def verify_remote_assets(release, directory, manifest):
    assets = release.get('assets', [])
    require({a['name'] for a in assets} == set(manifest['assets']) and len(assets) == len(manifest['assets']), 'Remote asset allowlist mismatch.')
    with tempfile.TemporaryDirectory(prefix='tsundoku-download-') as temporary:
        for asset in assets:
            target = Path(temporary) / asset['name']; download(asset, target)
            check_download(target, manifest['assets'][asset['name']])


def draft(directory, manifest, notes):
    publication_preflight(directory, manifest)
    require(notes and notes.is_file(), 'Pass --notes with the reviewed public release notes.')
    text = notes.read_text(); require(text.strip(), 'Release notes are empty.')
    review_public(directory, text, manifest)
    matches = [r for r in releases() if r['tag_name'] == manifest['tag']]
    require(len(matches) <= 1, 'Ambiguous release tag.')
    if not matches:
        command(['gh', 'release', 'create', manifest['tag'], '--repo', REPO, '--draft', '--target', manifest['commit'],
                 '--title', 'Tsundoku ' + manifest['version'], '--notes-file', notes])
        matches = [r for r in releases() if r['tag_name'] == manifest['tag']]
    require(len(matches) == 1, 'Could not identify the draft by release ID.')
    release = matches[0]; verify_draft(release, manifest)
    require(release.get('body', '').strip() == text.strip(), 'Existing draft notes differ; review them explicitly.')
    present = {a['name'] for a in release['assets']}
    require(present <= set(manifest['assets']), 'Draft contains unapproved assets.')
    for name in manifest['assets']:
        if name not in present:
            command(['gh', 'release', 'upload', manifest['tag'], directory / name, '--repo', REPO])
    release = json_command(['gh', 'api', f'repos/{REPO}/releases/{release["id"]}'])
    verify_draft(release, manifest); verify_remote_assets(release, directory, manifest)
    save(directory / 'draft.json', {'id': release['id'], 'notes_sha256': hashlib.sha256(text.strip().encode()).hexdigest()})
    print('Verified private draft and downloaded asset checksums. Not published.')


def publish(directory, manifest):
    publication_preflight(directory, manifest)
    record = json.loads((directory / 'draft.json').read_text())
    release = json_command(['gh', 'api', f'repos/{REPO}/releases/{record["id"]}'])
    require(release.get('tag_name') == manifest['tag'] and release.get('target_commitish') == manifest['commit'], 'Release source changed.')
    verify_remote_assets(release, directory, manifest)
    body = release.get('body', '').strip()
    require(hashlib.sha256(body.encode()).hexdigest() == record['notes_sha256'], 'Draft notes changed after review.')
    review_public(directory, body, manifest)
    if release.get('draft') is False:
        save(directory / 'published.json', {'id': release['id'], 'assets': manifest['assets']})
        print('Reconciled the already published release; no duplicate mutation.'); return
    verify_draft(release, manifest)
    result = json_command(['gh', 'api', '--method', 'PATCH', f'repos/{REPO}/releases/{record["id"]}', '-F', 'draft=false', '-f', 'make_latest=true'])
    require(result.get('draft') is False, 'Publication did not return a public release receipt. Reconcile before retrying.')
    verify_remote_assets(result, directory, manifest)
    save(directory / 'published.json', {'id': result['id'], 'assets': manifest['assets']})
    print('Published the exact audited release. Tap is a separate explicit command.')


def cask(directory, manifest, tap):
    publication_preflight(directory, manifest)
    record = json.loads((directory / 'published.json').read_text())
    release = json_command(['gh', 'api', f'repos/{REPO}/releases/{record["id"]}'])
    require(release.get('draft') is False and release.get('tag_name') == manifest['tag'], 'Release is not public.')
    verify_remote_assets(release, directory, manifest)
    require(tap and tap.is_dir(), 'Pass --tap with the Homebrew tap checkout.')
    require(command(['git', 'branch', '--show-current'], cwd=tap).strip() == 'main', 'Tap must be on main.')
    require(not command(['git', 'status', '--porcelain'], cwd=tap).strip(), 'Tap checkout must be clean.')
    remote = command(['git', 'remote', 'get-url', 'origin'], cwd=tap).strip()
    require(remote in ['https://github.com/xiaolai/homebrew-tap.git', 'git@github.com:xiaolai/homebrew-tap.git'], 'Tap origin is not the intended repository.')
    command(['git', 'fetch', 'origin', 'main'], cwd=tap)
    head = command(['git', 'rev-parse', 'HEAD'], cwd=tap).strip()
    remote_head = command(['git', 'rev-parse', 'origin/main'], cwd=tap).strip()
    pending_path = directory / 'tap-commit.json'
    if head != remote_head:
        pending = json.loads(pending_path.read_text()) if pending_path.exists() else {}
        require(pending.get('commit') == head and pending.get('parent') == remote_head,
                'Tap has unreviewed local commits or changed upstream; reconcile before pushing.')
        require(sha256(tap / 'Casks/tsundoku.rb') == pending.get('cask_sha256'), 'Pending tap bytes changed.')
        command(['git', 'push', 'origin', 'HEAD:refs/heads/main'], cwd=tap)
        print('Completed the previously recorded tap push.'); return
    command(['git', 'pull', '--ff-only'], cwd=tap)
    text = (ROOT / 'scripts/distribution/tsundoku.rb.in').read_text().replace('@VERSION@', manifest['version']).replace('@OWNER@', 'xiaolai').replace('@SHA256@', manifest['assets'][asset_names(manifest['version'])[0]])
    review_public(directory, text, manifest)
    path = tap / 'Casks/tsundoku.rb'
    if path.exists():
        old = re.search(r'version "([0-9.]+)"', path.read_text())
        require(old and tuple(map(int, old[1].split('.'))) <= tuple(map(int, manifest['version'].split('.'))), 'Refusing to downgrade the cask.')
        if path.read_text() == text: print('Tap already matches.'); return
    path.write_text(text); command(['ruby', '-c', path])
    message = directory / 'cask-message.txt'
    message.write_text('Update tsundoku to ' + manifest['version'] + '\n\nUse the checksum of the verified notarized GitHub release.\n')
    score = json_command(['jev', 'docket', 'commit-message', '--state-file', message, '--json'])
    save(directory / 'jev-cask-message.json', score)
    print('Jev commit-message:', json.dumps(score['answers']))
    command(['git', 'add', '--', 'Casks/tsundoku.rb'], cwd=tap)
    command(['git', 'commit', '--only', '-F', message, '--', 'Casks/tsundoku.rb'], cwd=tap)
    save(pending_path, {'commit': command(['git', 'rev-parse', 'HEAD'], cwd=tap).strip(),
                        'parent': remote_head, 'cask_sha256': sha256(path)})
    command(['git', 'push', 'origin', 'HEAD:refs/heads/main'], cwd=tap)
    print('Published the verified cask update.')


def main():
    global PRIVATE_LOG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['plan', 'build', 'verify', 'draft', 'publish', 'cask'])
    parser.add_argument('--profile', help='Existing Keychain profile; credentials are never read from files.')
    parser.add_argument('--build', default='1')
    parser.add_argument('--host', help='Privately configured test-Mac SSH alias (verify only).')
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--tap', type=Path)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r'[1-9][0-9]*', args.build), 'Build must be a positive integer.')
        if args.phase == 'plan':
            version = (ROOT / 'VERSION').read_text().strip(); asset_names(version)
            print(json.dumps({'version': version, 'phases': ['build', 'verify', 'draft', 'publish', 'cask'],
                              'public_assets': asset_names(version), 'credentials': 'existing Keychain profile only',
                              'source_push': 'explicit, audited origin/main push before draft', 'automatic_gui': False}, indent=2)); return 0
        state = source_state()
        directory = ROOT / 'build/release' / (state['version'] + '-' + args.build + '-' + state['commit'][:12])
        directory.mkdir(parents=True, exist_ok=True)
        PRIVATE_LOG = directory / 'tool.log'
        if args.phase == 'build': build(directory, state, args); return 0
        manifest = json.loads((directory / 'receipt.json').read_text())
        validate_manifest(manifest)
        require(manifest['build'] == args.build and all(manifest[k] == v for k, v in state.items()), 'Receipt differs from the selected source/build.')
        if args.phase == 'verify': remote_verify(directory, manifest, args.host)
        elif args.phase == 'draft': draft(directory, manifest, args.notes)
        elif args.phase == 'publish': publish(directory, manifest)
        elif args.phase == 'cask': cask(directory, manifest, args.tap)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Tool stderr can carry local paths or credentials; never replay it into public CI/release output.
        print('release:', str(error) if isinstance(error, ReleaseError) else 'Operation failed; inspect private local state before retrying.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
