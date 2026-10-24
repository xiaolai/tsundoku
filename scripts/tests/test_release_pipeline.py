import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import release_pipeline as release


class ReleasePipelineTests(unittest.TestCase):
    def test_manifest_requires_exact_public_asset_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            files = release.asset_names('1.2.3')
            for name in files:
                (root / name).write_text('fixture')
            manifest = {'version': '1.2.3', 'assets': {name: release.sha256(root / name) for name in files}}
            release.verify_assets(root, manifest)
            manifest['assets']['private.log'] = '0' * 64
            with self.assertRaises(release.ReleaseError):
                release.verify_assets(root, manifest)

    def test_local_artifact_tampering_blocks_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            names = release.asset_names('1.2.3')
            for name in names:
                (root / name).write_text('fixture')
            manifest = {'version': '1.2.3', 'assets': {n: release.sha256(root / n) for n in names}}
            (root / names[0]).write_text('tampered')
            with self.assertRaises(release.ReleaseError):
                release.verify_assets(root, manifest)

    def test_remote_bytes_not_just_http_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'artifact').write_bytes(b'wrong')
            with self.assertRaises(release.ReleaseError):
                release.check_download(root / 'artifact', '0' * 64)

    def test_notary_reuses_known_submission_and_does_not_resend_ambiguous_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            artifact = root / 'artifact.zip'; artifact.write_bytes(b'fixture')
            calls = []
            def runner(args):
                calls.append(args)
                if 'submit' in args: return {'id': 'known-id'}
                if 'wait' in args: raise release.ReleaseError('connection interrupted')
                return {}
            with self.assertRaises(release.ReleaseError):
                release.notarize(artifact, 'fixture-profile', root, runner)
            def accepted(args):
                calls.append(args)
                return {'status': 'Accepted'}
            release.notarize(artifact, 'fixture-profile', root, accepted)
            self.assertEqual(sum('submit' in c for c in calls), 1)
            (root / 'artifact.zip.notary.json').unlink()
            calls.clear()
            def ambiguous(args):
                calls.append(args); raise release.ReleaseError('unknown outcome')
            for _ in range(2):
                with self.assertRaises(release.ReleaseError):
                    release.notarize(artifact, 'fixture-profile', root, ambiguous)
            self.assertEqual(sum('submit' in c for c in calls), 1)

    def test_notary_invalid_verdict_is_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); artifact = root / 'a.zip'; artifact.write_bytes(b'fixture')
            def runner(args): return {'id': 'known-id'} if 'submit' in args else {'status': 'Invalid'}
            with self.assertRaises(release.ReleaseError):
                release.notarize(artifact, 'profile', root, runner)

    def test_draft_gate_requires_exact_target_and_private_state(self):
        manifest = {'commit': 'a' * 40, 'tag': 'v1.2.3'}
        release.verify_draft({'draft': True, 'tag_name': 'v1.2.3', 'target_commitish': 'a' * 40}, manifest)
        for field, value in [('draft', False), ('target_commitish', 'main'), ('tag_name', 'v0.0.1')]:
            item = {'draft': True, 'tag_name': 'v1.2.3', 'target_commitish': 'a' * 40}; item[field] = value
            with self.assertRaises(release.ReleaseError): release.verify_draft(item, manifest)

class SourceReceiptTests(unittest.TestCase):
    def test_missing_dirty_and_moved_private_pin_are_rejected(self):
        import subprocess
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory); root = base / 'public'; driver = base / 'driver'
            root.mkdir(); driver.mkdir()
            def git(folder, *args):
                return subprocess.check_output(['git', '-C', str(folder), '-c', 'core.hooksPath=/dev/null',
                    '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args], text=True, stderr=subprocess.DEVNULL)
            for folder in [root, driver]: git(folder, 'init', '-q')
            (driver / 'source').write_text('driver fixture'); git(driver, 'add', '.'); git(driver, 'commit', '-qm', 'Driver fixture')
            (root / 'VERSION').write_text('1.2.3\n'); git(root, 'add', '.'); git(root, 'commit', '-qm', 'Public fixture')
            with patch.object(release, 'ROOT', root):
                # command's default cwd is bound at definition time; override it for this isolated fixture.
                original = release.command
                def isolated(args, cwd=None, env=None): return original(args, cwd=cwd or root, env=env)
                with patch.object(release, 'command', isolated):
                    with self.assertRaises(release.ReleaseError): release.source_state()
                    git(root, '-c', 'protocol.file.allow=always', 'submodule', 'add', str(driver), 'vendor/kindle-toolkit')
                    git(root, 'config', '-f', '.gitmodules', 'submodule.vendor/kindle-toolkit.url', 'https://github.com/xiaolai/kindle-toolkit.git')
                    git(root, 'add', '.'); git(root, 'commit', '-qm', 'Pin fixture driver')
                    self.assertEqual(release.source_state()['version'], '1.2.3')
                    checked = root / 'vendor/kindle-toolkit'
                    (checked / 'source').write_text('dirty')
                    with self.assertRaises(release.ReleaseError): release.source_state()
                    git(checked, 'add', '.'); git(checked, 'commit', '-qm', 'Move fixture driver')
                    with self.assertRaises(release.ReleaseError): release.source_state()

    def test_unverified_assets_stop_before_any_publication_api_call(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            names = release.asset_names('1.2.3')
            for name in names: (root / name).write_bytes(b'fixture')
            state = {'commit': 'a' * 40, 'tree': 'b' * 40, 'driver_commit': 'c' * 40, 'version': '1.2.3', 'tag': 'v1.2.3'}
            manifest = dict(state, assets={n: release.sha256(root / n) for n in names})
            with patch.object(release, 'source_state', return_value=state), patch.object(release, 'audit'), patch.object(release, 'json_command') as api:
                with self.assertRaises(release.ReleaseError): release.publish(root, manifest)
                api.assert_not_called()


def complete_fixture(root):
    import json
    manifest = {'schema': 1, 'commit': 'a' * 40, 'tree': 'b' * 40, 'driver_commit': 'c' * 40,
                'version': '1.2.3', 'tag': 'v1.2.3', 'build': '1', 'app_notarized': True, 'dmg_notarized': True}
    names = release.asset_names('1.2.3')
    (root / names[0]).write_bytes(b'owned synthetic image')
    public = dict(manifest, dmg_sha256=release.sha256(root / names[0]))
    (root / names[1]).write_text(json.dumps(public))
    (root / names[2]).write_text(''.join(release.sha256(root / name) + '  ' + name + '\n' for name in names[:2]))
    return dict(manifest, assets={name: release.sha256(root / name) for name in names})


class PublicationBoundaryTests(unittest.TestCase):
    def test_public_metadata_rejects_extra_fields_and_modified_checksums(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); manifest = complete_fixture(root)
            release.validate_manifest(manifest); release.verify_assets(root, manifest); release.verify_public_metadata(root, manifest)
            path = root / 'release-provenance.json'; content = json.loads(path.read_text())
            content['unexpected'] = 'synthetic extra data'; path.write_text(json.dumps(content))
            with self.assertRaises(release.ReleaseError): release.verify_public_metadata(root, manifest)
            manifest = complete_fixture(root)
            (root / 'SHA256SUMS').write_text('unexpected data')
            with self.assertRaises(release.ReleaseError): release.verify_public_metadata(root, manifest)

    def test_invalid_source_identifier_is_rejected_before_remote_shell_use(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = complete_fixture(pathlib.Path(directory)); manifest['commit'] = 'invalid; command'
            with self.assertRaises(release.ReleaseError): release.validate_manifest(manifest)

    def test_valid_but_unverified_release_never_reaches_public_api(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); manifest = complete_fixture(root)
            state = {k: manifest[k] for k in ['commit', 'tree', 'driver_commit', 'version', 'tag']}
            with patch.object(release, 'source_state', return_value=state), patch.object(release, 'audit'), patch.object(release, 'json_command') as api:
                with self.assertRaises(FileNotFoundError): release.publish(root, manifest)
                api.assert_not_called()

    def test_notes_privacy_failure_precedes_draft_creation(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); manifest = complete_fixture(root); notes = root / 'notes.md'; notes.write_text('Fixture')
            with patch.object(release, 'publication_preflight'), patch.object(release, 'review_public', side_effect=release.ReleaseError('blocked')), patch.object(release, 'releases') as api, patch.object(release, 'command') as mutation:
                with self.assertRaises(release.ReleaseError): release.draft(root, manifest, notes)
                api.assert_not_called(); mutation.assert_not_called()

    def test_known_publication_reconciles_without_repeating_patch(self):
        from unittest.mock import patch
        import json, hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); manifest = complete_fixture(root); body = 'Fixture notes'
            (root / 'draft.json').write_text(json.dumps({'id': 123, 'notes_sha256': hashlib.sha256(body.encode()).hexdigest()}))
            existing = {'id': 123, 'draft': False, 'target_commitish': manifest['commit'], 'tag_name': manifest['tag'], 'body': body}
            with patch.object(release, 'publication_preflight'), patch.object(release, 'verify_remote_assets'), patch.object(release, 'review_public'), patch.object(release, 'json_command', return_value=existing) as api:
                release.publish(root, manifest)
                self.assertEqual(api.call_count, 1)
                self.assertNotIn('PATCH', api.call_args.args[0])
                self.assertTrue((root / 'published.json').exists())


if __name__ == '__main__':
    unittest.main()
