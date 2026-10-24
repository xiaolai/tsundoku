import pathlib
import subprocess
import tempfile
import unittest
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import privacy_audit as audit


class PrivacyAuditTests(unittest.TestCase):
    def test_reading_data_and_agent_state_are_private_at_any_depth(self):
        for path in ['dev-' + 'docs/report.md', 'nested/dev-' + 'docs/log.json', '.env', 'nested/.env.local',
                     'nested/.claude/settings.json', 'AGENTS.md', 'capture/book.pdf', 'export.epub',
                     'history.sqlite-wal', 'backup.bundle', 'identity.p12']:
            self.assertTrue(audit.private_path(path), path)
        for path in ['README.md', 'Sources/Archive.swift', 'Resources/Assets.car',
                     'scripts/distribution/tsundoku.rb.in', 'Tests/fixture.json']:
            self.assertFalse(audit.private_path(path), path)

    def test_findings_never_contain_matched_content(self):
        text = '/Users/' + 'private-person/source.swift on macmini-' + '123\nhttp://192.168.' + '10.42'
        findings = audit.scan_bytes(text.encode(), 'example', 'object')
        self.assertEqual({x['rule'] for x in findings}, {'personal-path', 'internal-host', 'private-network'})
        self.assertNotIn('private-person', str(findings))
        self.assertNotIn('10.42', str(findings))

    def test_synthetic_user_and_loopback_are_safe(self):
        self.assertEqual(audit.scan_bytes(b'/Users/example/Applications/App.app http://127.0.0.1:11434', 'fixture'), [])

    def test_all_history_includes_deleted_content_and_tag_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, '-c', 'core.hooksPath=/dev/null',
                                               '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args], text=True)
            git('init', '-q')
            (root / 'file.txt').write_text('/Users/' + 'private-person/old')
            git('add', '.'); git('commit', '-qm', 'Initial fixture')
            (root / 'file.txt').write_text('safe')
            git('add', '.'); git('commit', '-qm', 'Remove private path')
            git('tag', '-a', 'v0.1.0', '-m', 'measured on macmini-' + '123')
            report = audit.repository_report(root, run_gitleaks=False)
            self.assertTrue(any(x['rule'] == 'personal-path' for x in report['findings']))
            self.assertTrue(any(x['rule'] == 'internal-host' and x['location'].startswith('tag:') for x in report['findings']))

    def test_artifact_symlink_cannot_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'leak').symlink_to('/etc/passwd')
            self.assertEqual(audit.artifact_report(root)['findings'][0]['rule'], 'escaping-symlink')

    def test_artifact_scans_binary_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'binary').write_bytes(b'\x00\x01/Users/' + b'private-person/project\x00')
            self.assertTrue(audit.artifact_report(root)['findings'])

class IgnoreContractTests(unittest.TestCase):
    def test_ignore_rules_work_without_global_excludes(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(['git', '-C', directory, 'init', '-q'], check=True)
            shutil.copyfile(ROOT / '.gitignore', root / '.gitignore')
            for path in ['nested/.env.local', 'nested/.claude/settings.json', 'nested/AGENTS.md',
                         'nested/dev-' + 'docs/report.md', 'nested/archive.sqlite-wal', 'nested/book.epub',
                         'private.bundle', 'nested/key.p12', 'build/release.json']:
                result = subprocess.run(['git', '-C', directory, '-c', 'core.excludesFile=/dev/null',
                                         'check-ignore', '--no-index', '-q', '--', path])
                self.assertEqual(result.returncode, 0, path)
            for path in ['Sources/App.swift', 'Tests/synthetic.json', 'Resources/AppIcon.icns',
                         '.github/workflows/privacy.yml', 'scripts/release_pipeline.py', '.privacy-policy.json']:
                result = subprocess.run(['git', '-C', directory, '-c', 'core.excludesFile=/dev/null',
                                         'check-ignore', '--no-index', '-q', '--', path])
                self.assertEqual(result.returncode, 1, path)


    def test_private_directory_symlinks_are_ignored_too(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(['git', '-C', directory, 'init', '-q'], check=True)
            shutil.copyfile(ROOT / '.gitignore', root / '.gitignore')
            for name in ['dev-' + 'docs', '.claude', '.codex']:
                (root / name).symlink_to('/tmp', target_is_directory=True)
                result = subprocess.run(['git', '-C', directory, '-c', 'core.excludesFile=/dev/null',
                                         'check-ignore', '--no-index', '-q', '--', name])
                self.assertEqual(result.returncode, 0, name)

    def test_new_unreviewed_contributor_contact_is_flagged_without_echoing_it(self):
        data = b'author Example <private-' + b'person@gmail.com> 0 +0000\n'
        findings = audit.contact_findings(data, 'commit', 'hash', [])
        self.assertEqual(findings[0]['rule'], 'unreviewed-contact')
        self.assertNotIn('gmail', str(findings))

class CredentialAndArtifactTests(unittest.TestCase):
    def test_deleted_synthetic_credential_is_detected_and_redacted(self):
        import shutil
        if not shutil.which('gitleaks'): self.skipTest('gitleaks required')
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def git(*args):
                subprocess.run(['git', '-C', directory, '-c', 'core.hooksPath=/dev/null',
                    '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args], check=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git('init', '-q')
            token = 'ghp_' + 'aB7cD9eF2gH4jK6mN8pQ1rS3tU5vW7xY9zA2'
            (root / 'fixture.txt').write_text('access_token=' + token)
            git('add', '.'); git('commit', '-qm', 'Synthetic old credential fixture')
            (root / 'fixture.txt').write_text('removed'); git('add', '.'); git('commit', '-qm', 'Remove synthetic credential')
            report = audit.repository_report(root)
            self.assertTrue(any(f['rule'].startswith('credential:') for f in report['findings']))
            self.assertNotIn(token, str(report))

    def test_artifact_missing_or_containing_private_files_is_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.assertFalse(audit.artifact_report(root / 'missing')['passed'])
            (root / '.env').write_text('not read by the artifact audit')
            report = audit.artifact_report(root)
            self.assertEqual(report['findings'][0]['rule'], 'private-artifact-path')


class SignedResourceEnvelopeTests(unittest.TestCase):
    def test_public_hash_normalization_never_hides_string_credentials(self):
        import shutil, plistlib
        if not shutil.which('gitleaks'): self.skipTest('gitleaks required')
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); signature = root / 'Contents/_CodeSignature'; signature.mkdir(parents=True)
            resource = signature / 'CodeResources'
            resource.write_bytes(plistlib.dumps({'files': {'resource': bytes(range(20))}}))
            self.assertTrue(audit.artifact_report(root, run_gitleaks=True)['passed'])
            token = 'ghp_' + 'aB7cD9eF2gH4jK6mN8pQ1rS3tU5vW7xY9zA2'
            resource.write_bytes(plistlib.dumps({'files': {'resource': bytes(range(20))}, 'api_key': token}))
            report = audit.artifact_report(root, run_gitleaks=True)
            self.assertFalse(report['passed'])
            self.assertTrue(any(x['rule'].startswith('credential:') for x in report['findings']))
            self.assertNotIn(token, str(report))


class HistoricalFindingPolicyTests(unittest.TestCase):
    def test_exact_historical_findings_are_allowed_only_outside_head(self):
        findings = [{'rule': 'internal-host', 'object': 'old'}]
        kept, count = audit.filter_allowed_history(
            findings, {('internal-host', 'old')}, {'other'})
        self.assertEqual((kept, count), ([], 1))
        kept, count = audit.filter_allowed_history(
            findings, {('internal-host', 'old')}, {'old'})
        self.assertEqual((kept, count), (findings, 0))
        kept, count = audit.filter_allowed_history(
            findings, {('private-doc-link', 'old')}, {'other'})
        self.assertEqual((kept, count), (findings, 0))

    def test_no_policy_keeps_every_finding(self):
        findings = [{'rule': 'internal-host', 'object': 'old'}]
        self.assertEqual(audit.filter_allowed_history(findings, set(), set()), (findings, 0))


class CodeSignatureTests(unittest.TestCase):
    def test_code_signature_blob_is_excluded(self):
        import struct
        payload = b'public-code-signature-hash'
        header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0)
        command = struct.pack('<IIII', 0x1d, 16, 48, len(payload))
        data = header + command + payload
        self.assertEqual(audit.without_code_signature(data), header + command)
        self.assertEqual(audit.without_code_signature(b'not-a-macho'), b'not-a-macho')


if __name__ == '__main__':
    unittest.main()
