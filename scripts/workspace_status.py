#!/usr/bin/env python3
"""Inventory Git state without changing worktrees or including file contents in reports."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


def command(args, cwd):
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=60, check=True)
    return result.stdout


def git(root, *args):
    # Do not let optional status/index refreshes write repository state.
    return command(['git', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', str(root), *args], root)


def collect(root, github=False):
    root = Path(root).resolve()
    root = Path(os.fsdecode(git(root, 'rev-parse', '--show-toplevel')).strip())
    report = {'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'repository': str(root), 'worktrees': [], 'branches': [],
              'github': {'status': 'not-requested', 'pull_requests': []}}
    raw = git(root, 'worktree', 'list', '--porcelain', '-z')
    for record in raw.split(b'\0\0'):
        if not record.strip(b'\0'):
            continue
        fields = {}
        for line in record.split(b'\0'):
            key, _, value = line.partition(b' ')
            fields[os.fsdecode(key)] = os.fsdecode(value)
        path = fields['worktree']
        entry = {'path': path, 'head': fields.get('HEAD'),
                 'branch': fields.get('branch', 'detached'),
                 'locked': 'locked' in fields, 'prunable': 'prunable' in fields}
        try:
            status = git(path, 'status', '--porcelain=v1', '-z', '--untracked-files=all')
            changes = []
            parts = iter(status.split(b'\0'))
            for part in parts:
                if not part:
                    continue
                code = part[:2].decode('ascii')
                change = {'status': code, 'path': os.fsdecode(part[3:])}
                if 'R' in code or 'C' in code:
                    change['original_path'] = os.fsdecode(next(parts))
                changes.append(change)
            ignored = git(path, 'ls-files', '--others', '--ignored',
                          '--exclude-standard', '--directory', '-z')
            entry.update(status='ok', changes=changes,
                         ignored_entries=len([p for p in ignored.split(b'\0') if p]))
        except (OSError, subprocess.SubprocessError, StopIteration):
            entry.update(status='unavailable', changes=None, ignored_entries=None)
        report['worktrees'].append(entry)
    fmt = '%(refname:short)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00'
    parts = git(root, 'for-each-ref', '--format='+fmt, 'refs/heads').split(b'\0')
    # for-each-ref appends a newline after each formatted record.
    for i in range(0, len(parts)-1, 4):
        name, sha, upstream, track = [os.fsdecode(x) for x in parts[i:i+4]]
        name = name.lstrip('\n')
        report['branches'].append({'name': name, 'head': sha, 'upstream': upstream,
                                   'tracking': track, 'upstream_status':
                                   'gone' if '[gone]' in track else
                                   ('present' if upstream else 'none')})
    if github:
        try:
            prs = json.loads(command(['gh', 'pr', 'list', '--state', 'open', '--limit', '1000',
                                      '--json', 'number,title,url,isDraft,headRefOid,baseRefOid,mergeStateStatus,statusCheckRollup'], root))
            report['github'] = {'status': 'ok', 'pull_requests': prs}
        except (OSError, subprocess.SubprocessError, ValueError):
            report['github']['status'] = 'unavailable'
    return report


def inline(value):
    # JSON escaping keeps filenames containing newlines/control chars on one line.
    text = json.dumps(value, ensure_ascii=True)
    # HTML entities keep links/images/HTML in filenames and PR titles inert.
    for char in '&<>![]()*_`\\':
        text = text.replace(char, '&#'+str(ord(char))+';')
    return text


def markdown(report):
    lines = ['# Workspace status', '', 'Generated: '+report['generated_at'],
             '', 'Repository: '+inline(report['repository']), '',
             'Snapshot only; this report does not certify release readiness.', '',
             '## Worktrees', '']
    for entry in report['worktrees']:
        changes = entry['changes']
        state = 'UNAVAILABLE' if changes is None else ('DIRTY' if changes else 'clean')
        lines += ['- '+inline(entry['path'])+' — '+state,
                  '  - Branch: '+inline(entry['branch'])+'; HEAD: '+str(entry['head']),
                  '  - Ignored entries (directories counted once): '+str(entry['ignored_entries'])]
        for change in changes or []:
            lines.append('  - '+inline(change['status'])+' '+inline(change['path']))
    lines += ['', '## Branches', '']
    for branch in report['branches']:
        lines.append('- '+inline(branch['name'])+' @ '+branch['head'][:12]+
                     '; upstream '+inline(branch['upstream'])+' ('+branch['upstream_status']+') '+branch['tracking'])
    remote = report['github']
    lines += ['', '## GitHub', '', 'Evidence: '+remote['status']]
    for pr in remote['pull_requests']:
        states = []
        for check in pr.get('statusCheckRollup') or []:
            states.append(check.get('conclusion') or check.get('state') or check.get('status') or 'UNKNOWN')
        lines.append('- PR #'+str(pr['number'])+' '+inline(pr['title'])+'; head '+pr['headRefOid'][:12]+
                     '; draft '+str(pr['isDraft'])+'; merge '+pr['mergeStateStatus']+'; checks '+inline(states))
    lines += ['', '## Next actions', '',
              '- Review dirty worktrees before switching, moving or deleting them.',
              '- Map branches with missing upstreams to issues/PRs before cleanup.',
              '- Refresh required PR checks and independent review before merging.',
              '- Follow the release checklist; a clean Git tree is not release proof.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    parser.add_argument('--github', action='store_true', help='query GitHub explicitly using gh')
    parser.add_argument('--output-dir', type=Path, help='write JSON and Markdown to a NEW directory')
    args = parser.parse_args()
    try:
        report = collect(args.repo, args.github)
        if args.output_dir:
            # Refuse an existing destination, preventing accidental overwrite of any file.
            args.output_dir.mkdir(parents=True, exist_ok=False)
            (args.output_dir/'status.json').write_text(json.dumps(report, indent=2)+'\n')
            (args.output_dir/'status.md').write_text(markdown(report))
        print(markdown(report))
        return 2 if (report['github']['status'] == 'unavailable' or
                     any(w['status'] != 'ok' for w in report['worktrees'])) else 0
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print('Workspace status failed ('+type(error).__name__+'); no Git changes made.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
