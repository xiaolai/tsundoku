#!/usr/bin/env python3
"""Audit public Git inputs and app bytes. Findings never include matched values."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

PATTERNS = {
    'personal-path': re.compile(rb'/(?:Users|home)/(?!example(?:/|\b)|runner(?:/|\b))[A-Za-z0-9._-]+'),
    'internal-host': re.compile(rb'\b(?:macmini[-_]?[0-9]+|mbp[0-9]+|spark0[12]|legio\.internal)\b', re.I),
    'private-network': re.compile(rb'(?<![0-9.])(?:10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9.])'),
    'private-doc-link': re.compile(rb'(?:dev-docs|codex-plans|measurements)/'),
}
PRIVATE_PARTS = {'dev-docs', '.claude', '.codex', '.agents', '.gemini', '.cursor', '.windsurf',
                 '.opencode', '.continue', '.cc-suite', '.git-backups', 'node_modules',
                 '.ssh', '.aws', '.azure', '.kube', '.direnv', 'captures', 'exports', 'diagnostics', 'measurements'}
PRIVATE_NAMES = {'AGENTS.md', 'CLAUDE.md', 'CLAUDE.local.md', 'GEMINI.md', 'QWEN.md',
                 '.cc-suite.md', '.mcp.json', '.cursorrules', '.windsurfrules', 'local.mk',
                 '.DS_Store', '.envrc', 'auth.json', 'credentials.json', 'tokens.json', 'id_rsa', 'id_ed25519', '.netrc', '.npmrc', '.pypirc'}
PRIVATE_SUFFIXES = ('.p8', '.token', '.jsonl', '.pem', '.key', '.p12', '.pfx', '.mobileprovision', '.keychain', '.keychain-db',
                    '.sqlite', '.sqlite3', '.db', '.sqlite-wal', '.sqlite-shm', '.sqlite3-wal', '.sqlite3-shm',
                    '.db-wal', '.db-shm', '.epub', '.pdf', '.mobi', '.azw', '.azw3', '.kfx', '.bundle',
                    '.dmg', '.zip', '.tar', '.tgz', '.gz', '.log', '.xcuserstate')


def private_path(name):
    parts = Path(name).parts
    return (any(p.endswith(('.app', '.dSYM', '.xcarchive', '.xcresult')) for p in parts)
            or any(p in PRIVATE_PARTS or p in PRIVATE_NAMES or p == '.env' or p.startswith('.env.') for p in parts)
            or name.lower().endswith(PRIVATE_SUFFIXES))


def finding(rule, location, object_id='', line=None):
    return dict(rule=rule, location=location, object=object_id, **({'line': line} if line else {}))


def scan_bytes(data, location, object_id=''):
    result = []
    for rule, pattern in PATTERNS.items():
        if rule == 'private-doc-link' and Path(location).name == '.gitignore':
            continue
        for match in pattern.finditer(data):
            result.append(finding(rule, location, object_id, data[:match.start()].count(b'\n') + 1))
    return result


def git(root, *args, data=None):
    return subprocess.check_output(['git', '-C', str(root), *args], input=data, stderr=subprocess.DEVNULL)


def leak_findings(root, metadata, modes=('git', 'stdin')):
    if not shutil.which('gitleaks'):
        return [finding('scanner-unavailable', 'gitleaks')]
    result = []
    with tempfile.TemporaryDirectory(prefix='tsundoku-audit-') as directory:
        for mode in modes:
            report = Path(directory) / (mode + '.json')
            config = Path(directory) / 'config.toml'
            config.write_text('[extend]\nuseDefault = true\n')
            ignored = Path(directory) / 'empty-ignore'
            ignored.write_text('')
            args = ['gitleaks', mode, '--redact=100', '--ignore-gitleaks-allow', '--no-banner',
                    '--report-format', 'json', '--report-path', str(report), '--config', str(config),
                    '--gitleaks-ignore-path', str(ignored)]
            if mode == 'git':
                args += ['--log-opts=--all --full-history', str(root)]
            process = subprocess.run(args, input=metadata if mode == 'stdin' else None,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if process.returncode not in [0, 1] or not report.exists():
                result.append(finding('scanner-failed', 'gitleaks:' + mode)); continue
            for row in json.loads(report.read_text()):
                result.append(finding('credential:' + row['RuleID'], row.get('File') or 'git-metadata',
                                      row.get('Commit', ''), row.get('StartLine')))
    return result


def contact_findings(raw, location, object_id, allowed):
    result = []
    for address in re.findall(rb'^(?:author|committer|tagger) [^\n]*<([^>]+)>', raw, re.M):
        value = address.decode(errors='replace').lower()
        if value == 'noreply@github.com' or value.endswith(('@users.noreply.github.com', '@example.invalid')):
            continue
        if hashlib.sha256(value.encode()).hexdigest() not in allowed:
            result.append(finding('unreviewed-contact', location, object_id))
    return result


def repository_report(root, run_gitleaks=True):
    root = Path(root).resolve()
    result = []; metadata = bytearray(); checked = set(); forbidden_env = False
    policy = root / '.privacy-policy.json'
    allowed = json.loads(policy.read_text()).get('public_contact_sha256', []) if policy.exists() else []
    commits = git(root, 'rev-list', '--all').decode().splitlines()
    if not commits: result.append(finding('no-history', 'repository'))
    result.extend(scan_bytes(git(root, 'for-each-ref', '--format=%(refname)'), 'ref-names'))
    for commit in commits:
        raw = git(root, 'cat-file', 'commit', commit)
        metadata.extend(raw + b'\n')
        result.extend(scan_bytes(raw, 'commit:' + commit[:12], commit))
        result.extend(contact_findings(raw, 'commit:' + commit[:12], commit, allowed))
        tree = git(root, 'ls-tree', '-rz', commit)
        for entry in tree.split(b'\0'):
            if not entry: continue
            header, name_bytes = entry.split(b'\t', 1)
            mode, kind, oid = header.decode().split()
            name = os.fsdecode(name_bytes)
            key = (oid, name)
            if key in checked: continue
            checked.add(key)
            if private_path(name):
                result.append(finding('private-tracked-path', name, oid))
                if any(p == '.env' or p.startswith('.env.') for p in Path(name).parts):
                    forbidden_env = True
                continue
            if mode == '120000':
                import posixpath
                target = git(root, 'cat-file', 'blob', oid).decode(errors='replace')
                joined = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if target.startswith('/') or joined == '..' or joined.startswith('../'):
                    result.append(finding('escaping-symlink', name, oid))
            if kind == 'blob':
                result.extend(scan_bytes(git(root, 'cat-file', 'blob', oid), name, oid))
            elif kind == 'commit' and name != 'vendor/kindle-toolkit':
                result.append(finding('unexpected-submodule', name, oid))
    for row in git(root, 'for-each-ref', '--format=%(objecttype) %(objectname) %(refname)', 'refs/tags').decode().splitlines():
        kind, oid, name = row.split(' ', 2)
        if kind == 'tag':
            raw = git(root, 'cat-file', 'tag', oid); metadata.extend(raw + b'\n')
            result.extend(scan_bytes(raw, 'tag:' + name, oid))
            result.extend(contact_findings(raw, 'tag:' + name, oid, allowed))
    # Include uncommitted tracked changes. Ignore private env values rather than opening them.
    for name_bytes in git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0'):
        if not name_bytes: continue
        name = os.fsdecode(name_bytes); path = root / name
        if private_path(name):
            result.append(finding('private-tracked-path', name)); continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root): result.append(finding('escaping-symlink', name))
        elif path.is_file():
            result.extend(scan_bytes(path.read_bytes(), name))
    if run_gitleaks and not forbidden_env:
        result.extend(leak_findings(root, bytes(metadata)))
    elif run_gitleaks:
        result.append(finding('forbidden-env-not-read', 'history'))
    unique = list({json.dumps(item, sort_keys=True): item for item in result}.values())
    return {'schema': 1, 'scope': 'all-local-refs-and-tracked-worktree', 'commits': len(commits),
            'checked_objects_and_paths': len(checked), 'gitleaks_ran': run_gitleaks and not forbidden_env,
            'passed': not unique, 'findings': unique}


def artifact_report(root, run_gitleaks=False):
    original = Path(root)
    if original.is_symlink():
        return {'schema': 1, 'scope': 'artifact-bytes', 'checked_files': 0, 'passed': False, 'findings': [finding('escaping-symlink', 'artifact-root')]}
    root = original.resolve(); result = []; checked = 0; strings = bytearray()
    if not root.is_dir():
        return {'schema': 1, 'scope': 'artifact-bytes', 'checked_files': 0, 'passed': False, 'findings': [finding('artifact-missing', 'artifact')]}
    for path in root.rglob('*'):
        name = str(path.relative_to(root))
        if private_path(name):
            result.append(finding('private-artifact-path', name)); continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root): result.append(finding('escaping-symlink', name))
        elif path.is_file():
            checked += 1
            data = path.read_bytes()
            result.extend(scan_bytes(data, name))
            if run_gitleaks:
                if path.name == 'CodeResources' and path.parent.name == '_CodeSignature':
                    # Apple's resource envelope contains public SHA-1/SHA-256 digests, not API keys.
                    # Preserve all string values; normalize only actual binary hash values.
                    import plistlib, base64
                    envelope = plistlib.loads(data)
                    def resource_value(value):
                        if isinstance(value, bytes) and len(value) in (20, 32): return '<resource-digest>'
                        if isinstance(value, bytes): return base64.b64encode(value).decode()
                        raise TypeError('Unexpected resource envelope value')
                    strings.extend(json.dumps(envelope, default=resource_value).encode() + b'\n')
                else:
                    strings.extend(b'\n'.join(re.findall(rb'[\x20-\x7e]{8,}', data)) + b'\n')
    if run_gitleaks:
        result.extend(leak_findings(root, bytes(strings), modes=['stdin']))
    return {'schema': 1, 'scope': 'artifact-bytes', 'checked_files': checked, 'passed': not result, 'findings': result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        report = artifact_report(args.artifact, run_gitleaks=True) if args.artifact else repository_report(args.repo)
        text = json.dumps(report, indent=2) + '\n'
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True); args.report.write_text(text)
        print(json.dumps({'passed': report['passed'], 'findings': len(report['findings']), 'scope': report['scope']}))
        return 0 if report['passed'] else 1
    except (OSError, ValueError, subprocess.SubprocessError):
        print('Privacy audit could not complete; publication is blocked.'); return 2


if __name__ == '__main__':
    raise SystemExit(main())
