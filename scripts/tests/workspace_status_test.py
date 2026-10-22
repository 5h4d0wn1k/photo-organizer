import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'workspace_status.py'
spec = importlib.util.spec_from_file_location('workspace_status', SCRIPT)
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class WorkspaceStatusTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='workspace status ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo with spaces'
        self.root.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.root / 'tracked').write_text('initial')
        (self.root / '.gitignore').write_text('ignored/\n')
        self.git('add', '.')
        self.git('commit', '-m', 'initial')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_dirty_ignored_and_gone_upstream_without_contents(self):
        self.git('config', 'branch.main.remote', 'origin')
        self.git('config', 'branch.main.merge', 'refs/heads/missing')
        self.git('remote', 'add', 'origin', 'https://example.invalid/repo')
        (self.root / 'tracked').write_text('DO_NOT_REPORT_SECRET')
        (self.root / 'new\nfile').write_text('DO_NOT_REPORT_SECRET')
        (self.root / 'ignored').mkdir()
        (self.root / 'ignored' / 'private-key').write_text('DO_NOT_REPORT_SECRET')
        before = self.git('status', '--porcelain', '-z')
        report = status.collect(self.root)
        self.assertEqual(before, self.git('status', '--porcelain', '-z'))
        self.assertEqual(report['branches'][0]['upstream_status'], 'gone')
        self.assertEqual(report['worktrees'][0]['ignored_entries'], 1)
        self.assertEqual(len(report['worktrees'][0]['changes']), 2)
        self.assertNotIn('DO_NOT_REPORT_SECRET', json.dumps(report))
        self.assertNotIn('private-key', json.dumps(report))
        self.assertIn('new&#92;nfile', status.markdown(report))
        self.assertEqual(report['github']['status'], 'not-requested')

    def test_detached_worktree_and_rename(self):
        sibling = Path(self.temp.name) / 'detached sibling'
        self.git('worktree', 'add', '--detach', str(sibling), 'HEAD')
        self.git('mv', 'tracked', 'renamed file')
        report = status.collect(self.root)
        self.assertEqual(len(report['worktrees']), 2)
        self.assertEqual(report['worktrees'][1]['branch'], 'detached')
        change = report['worktrees'][0]['changes'][0]
        self.assertEqual(change['path'], 'renamed file')
        self.assertEqual(change['original_path'], 'tracked')

    def test_unavailable_github_is_explicit(self):
        original = status.command
        def no_gh(args, cwd):
            if args[0] == 'gh':
                raise FileNotFoundError('missing')
            return original(args, cwd)
        with mock.patch.object(status, 'command', side_effect=no_gh):
            report = status.collect(self.root, github=True)
        self.assertEqual(report['github']['status'], 'unavailable')

    def test_relative_repo(self):
        previous = Path.cwd()
        try:
            os.chdir(self.temp.name)
            report = status.collect(self.root.name)
        finally:
            os.chdir(previous)
        self.assertEqual(report['repository'], str(self.root))

    def test_markdown_does_not_embed_remote_content(self):
        text = status.inline('![image](https://example.invalid/pixel)<img src="x">')
        self.assertNotIn('![', text)
        self.assertNotIn('<img', text)
        self.assertNotIn('](', text)

    def test_output_refuses_existing_directory(self):
        dest = Path(self.temp.name) / 'report'
        args = ['python3', str(SCRIPT), '--repo', str(self.root), '--output-dir', str(dest)]
        first = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(first.returncode, 0)
        saved = (dest / 'status.json').read_bytes()
        second = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(second.returncode, 2)
        self.assertEqual(saved, (dest / 'status.json').read_bytes())


if __name__ == '__main__':
    unittest.main()
