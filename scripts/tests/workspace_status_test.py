import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest import TestCase, main, mock

SCRIPT = Path(__file__).resolve().parents[1] / 'workspace_status.py'
spec = importlib.util.spec_from_file_location('workspace_status', SCRIPT)
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class WorkspaceStatusTest(TestCase):
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

    def test_disk_requirement_boundaries_and_unavailable(self):
        from collections import namedtuple
        usage = namedtuple('usage', 'total used free')
        with mock.patch.object(status.shutil, 'disk_usage', return_value=usage(20*1024**3, 10*1024**3, 10*1024**3)):
            equal = status.collect(self.root, minimum_free_gib=10)
            low = status.collect(self.root, minimum_free_gib=11)
        self.assertIs(equal['disk']['requirement_met'], True)
        self.assertIs(low['disk']['requirement_met'], False)
        self.assertIn('Free-space requirement: 11 GiB; FAIL', status.markdown(low))
        with mock.patch.object(status.shutil, 'disk_usage', side_effect=OSError):
            unavailable = status.collect(self.root, minimum_free_gib=0)
        self.assertEqual(unavailable['disk']['status'], 'unavailable')
        self.assertIs(unavailable['disk']['requirement_met'], False)
        self.assertIn('UNAVAILABLE: filesystem capacity', status.markdown(unavailable))

    def test_disk_preflight_cli_exit_codes(self):
        from collections import namedtuple
        usage = namedtuple('usage', 'total used free')
        for free, wanted in [(10*1024**3, 0), (9*1024**3, 2)]:
            with mock.patch.object(status.shutil, 'disk_usage', return_value=usage(20*1024**3, 20*1024**3-free, free)), mock.patch('sys.argv', [str(SCRIPT), '--repo', str(self.root), '--require-free-gib', '10']), mock.patch('builtins.print'):
                self.assertEqual(status.main(), wanted)
        with mock.patch.object(status.shutil, 'disk_usage', side_effect=OSError), mock.patch('sys.argv', [str(SCRIPT), '--repo', str(self.root)]), mock.patch('builtins.print'):
            self.assertEqual(status.main(), 2)
        for argument in ['-1', 'nan', '1.5']:
            with mock.patch('sys.argv', [str(SCRIPT), '--require-free-gib', argument]), mock.patch('sys.stderr'), self.assertRaises(SystemExit) as caught:
                status.main()
            self.assertEqual(caught.exception.code, 2)

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
    main()
