#!/usr/bin/env python3
"""Run immutable bridge jobs and publish only freshly verified static review status."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import github_bridge as bridge
import review_runner as runner

JOB = re.compile(r"^(?:pr-[1-9][0-9]*|release)-[0-9a-f]{24}$")
SHA = re.compile(r"^[0-9a-f]{40}$")


class JobError(RuntimeError):
    pass


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.record-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def request(cfg, job_id):
    if not JOB.fullmatch(job_id):
        raise JobError('Invalid bridge job ID')
    root = Path(cfg['jobs_dir']).resolve()
    path = root / job_id / 'request.json'
    if path.is_symlink() or path.parent.is_symlink():
        raise JobError('Job manifests must not be symlinks')
    data = runner.load_json(path)
    if not isinstance(data, dict) or type(data.get('schema_version')) is not int or data.get('schema_version') != 1 or data.get('job_id') != job_id:
        raise JobError('Manifest identity mismatch')
    if data.get('repository') != cfg['repository']:
        raise JobError('Manifest repository mismatch')
    if Path(data.get('repository_path', '')).resolve() != Path(cfg['repository_path']).resolve():
        raise JobError('Manifest source path mismatch')
    for field in ('head_sha', 'base_sha'):
        if not SHA.fullmatch(str(data.get(field, ''))):
            raise JobError('Manifest must contain full immutable commit IDs')
    if data.get('policy_version') != cfg['policy_version']:
        raise JobError('Job policy is no longer current')
    if data.get('kind') not in ('pr', 'release'):
        raise JobError('Unsupported job kind')
    if data['kind'] == 'pr' and (type(data.get('pr_number')) is not int or data['pr_number'] < 1):
        raise JobError('Invalid PR number')
    version = data.get('version')
    if version is not None and not isinstance(version, str):
        raise JobError('Invalid release version')
    key = '|'.join([cfg['repository'], data['head_sha'], data['base_sha'],
                    str(cfg['policy_version']), data['kind'], str(data.get('pr_number') or ''),
                    version or ''])
    prefix = f"pr-{data['pr_number']}-" if data['kind'] == 'pr' else 'release-'
    if job_id != prefix + bridge.digest(key)[:24]:
        raise JobError('Job ID does not match immutable request fields')
    return path.parent, data


def current_target(cfg, req, commands):
    if req['kind'] == 'pr':
        pr = commands.gh(f"repos/{cfg['repository']}/pulls/{req['pr_number']}")
        head = pr.get('head') or {}
        base = pr.get('base') or {}
        return (pr.get('state') == 'open' and not pr.get('draft')
                and (head.get('repo') or {}).get('full_name') == cfg['repository']
                and base.get('ref') == cfg.get('target_branch', 'main')
                and head.get('sha') == req['head_sha']
                and base.get('sha') == req['base_sha'])
    # A release job names a fixed candidate; moving main is not an implicit replacement.
    commit = commands.gh(f"repos/{cfg['repository']}/commits/{req['head_sha']}")
    return commit.get('sha') == req['head_sha']


def collect_verified(cfg, req):
    directory = Path(cfg['review_state_dir']) / req['job_id']
    if not (directory / 'manifest.json').exists():
        return None
    manifest = runner.load_json(directory / 'manifest.json')
    if (manifest.get('job_id') != req['job_id'] or manifest.get('kind') != req['kind']
            or manifest.get('head_sha') != req['head_sha'] or manifest.get('base_sha') != req['base_sha']):
        raise JobError('Review manifest does not match intake request')
    source = manifest.get('source_repo', manifest.get('repo'))
    if Path(source).resolve() != Path(cfg['repository_path']).resolve():
        raise JobError('Review belongs to another source repository')
    if manifest.get('policy', {}).get('version') != runner.POLICY_VERSION:
        raise JobError('Review policy mismatch')
    if manifest.get('policy', {}).get('models') != cfg.get('review_models', ['codex', 'grok']):
        raise JobError('Required reviewer set changed')
    # Re-read the actual reports, statuses, and frozen tree. Never trust an agent's PASS string.
    result = runner.collect(directory)
    result['attestation_path'] = str(directory / 'attestation.json')
    return result


def failed_execution(directory, job_id):
    """A runner failure before manifest creation may fail the check, never pass it."""
    execution_path = directory / 'execution.json'
    result_path = directory / 'execution-result.json'
    if not execution_path.exists() or not result_path.exists():
        return None
    execution = runner.load_json(execution_path)
    result = runner.load_json(result_path)
    if (not isinstance(execution, dict) or not isinstance(result, dict)
            or execution.get('job_id') != job_id or result.get('job_id') != job_id):
        raise JobError('Execution failure record does not match this immutable job')
    if result.get('verdict') != 'FAILED':
        return None  # Even a claimed PASS requires independently collected evidence.
    return {'verdict': 'FAILED', 'job_id': job_id,
            'reasons': ['The local runner failed before creating a review manifest. '
                        'Inspect this job\'s execution-result.json; no review approval exists.']}


def run_job(cfg, job_id):
    directory, req = request(cfg, job_id)
    with (directory / 'executor.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'verdict': 'RUNNING', 'job_id': job_id}
        commands = bridge.Commands(cfg)
        if not current_target(cfg, req, commands):
            return {'verdict': 'SUPERSEDED', 'job_id': job_id}
        existing = collect_verified(cfg, req)
        if existing is not None:
            return existing
        source = Path(cfg['repository_path']).resolve()
        origin = runner.git(source, 'remote', 'get-url', 'origin')
        if origin.rstrip('/').removesuffix('.git') != 'https://github.com/' + cfg['repository']:
            raise JobError('Source repository origin is not the configured GitHub repository')
        env = os.environ.copy()
        env['GIT_LFS_SKIP_SMUDGE'] = '1'
        fetched = subprocess.run(['git', '-C', str(source), 'fetch', '--filter=blob:none', 'origin',
                                  req['base_sha'], req['head_sha']], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=180)
        if fetched.returncode:
            raise JobError('Could not fetch verified review commits')
        argv = [sys.executable, str(Path(__file__).with_name('review_runner.py')), 'run',
                '--repo', str(source), '--base', req['base_sha'], '--head', req['head_sha'],
                '--kind', req['kind'], '--job-id', job_id, '--state-dir', cfg['review_state_dir'],
                '--models', ','.join(cfg.get('review_models', ['codex', 'grok'])),
                '--timeout', str(cfg.get('review_timeout_seconds', 3600)),
                '--codex-home', cfg['codex_home']]
        if cfg.get('mmrun_path'):
            argv.extend(['--mmrun', cfg['mmrun_path']])
        atomic(directory / 'execution.json', {'job_id': job_id, 'started_at': bridge.utcnow()})
        completed = subprocess.run(argv, env=env, text=True, capture_output=True)
        try:
            result = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise JobError(f'Review runner returned no structured result (exit {completed.returncode})') from exc
        atomic(directory / 'execution-result.json', result)
        return result


def publish_result(cfg, job_id, commands=None):
    directory, req = request(cfg, job_id)
    commands = commands or bridge.Commands(cfg)
    with (directory / 'publish.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'job_id': job_id, 'state': 'busy'}
        if not req.get('multica_issue_id'):
            return {'job_id': job_id, 'state': 'awaiting_issue_mapping'}
        receipt = directory / 'published.json'
        if receipt.exists():
            previous = runner.load_json(receipt)
            if not isinstance(previous, dict):
                raise JobError('Invalid publication receipt')
            if previous.get('state') != 'superseded':
                return {'job_id': job_id, 'state': 'already_published'}
            if not current_target(cfg, req, commands):
                return {'job_id': job_id, 'state': 'superseded'}
            # A PR may restore an earlier head/base or leave draft mode. Recheck
            # its existing evidence, then replace the superseded receipt.
        result = collect_verified(cfg, req)
        if result is None:
            result = failed_execution(directory, job_id)
        if result is None or result.get('verdict') in ('RUNNING', 'RUNNING_TIMEOUT'):
            return {'job_id': job_id, 'state': 'pending'}
        if not current_target(cfg, req, commands):
            atomic(receipt, {'state': 'superseded', 'job_id': job_id, 'at': bridge.utcnow()})
            return {'job_id': job_id, 'state': 'superseded'}
        verdict = result.get('verdict')
        state = 'success' if verdict == 'PASS' else 'failure'
        context = 'multica/review' if req['kind'] == 'pr' else 'multica/release'
        description = ('Static review passed; CI and maintainer approval still required'
                       if state == 'success' else 'Static review incomplete or changes requested; inspect Multica')
        # The status writer is this fixed controller, not the implementation agent.
        commands.gh(f"repos/{cfg['repository']}/statuses/{req['head_sha']}",
                    {'state': state, 'context': context, 'description': description})
        marker = 'multica-result-' + job_id
        body = (f'{marker}\n\nStatic review result: {verdict}\n'
                f"Head: {req['head_sha']}\nBase: {req['base_sha']}\n"
                f"Attestation: {result.get('attestation_path', '')}\n"
                'This is a static-review result only. Build/runtime/release checks and maintainer approval remain required.\n'
                + json.dumps(result.get('reasons', []), ensure_ascii=False))
        comments = bridge.rows(commands.multica(['issue', 'comment', 'list', req['multica_issue_id'], '--output', 'json']))
        if not any(marker in str(c.get('content', '')) for c in comments):
            commands.multica(['issue', 'comment', 'add', req['multica_issue_id'], '--content-stdin', '--output', 'json'], body)
        commands.multica(['issue', 'update', req['multica_issue_id'], '--status', 'in_review', '--no-start', '--output', 'json'])
        atomic(receipt, {'state': state, 'verdict': verdict, 'head_sha': req['head_sha'], 'at': bridge.utcnow()})
        return {'job_id': job_id, 'state': state, 'verdict': verdict}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--config', required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ('run', 'collect', 'publish'):
        cmd = commands.add_parser(name, allow_abbrev=False)
        cmd.add_argument('--job-id', required=True)
    commands.add_parser('collect-all', allow_abbrev=False)
    args = parser.parse_args(argv)
    try:
        cfg = bridge.load_config(args.config)
        if args.action == 'run':
            result = run_job(cfg, args.job_id)
        elif args.action == 'collect':
            _, req = request(cfg, args.job_id)
            result = collect_verified(cfg, req) or {'verdict': 'NOT_STARTED', 'job_id': args.job_id}
        elif args.action == 'publish':
            result = publish_result(cfg, args.job_id)
        else:
            result = []
            for path in sorted(Path(cfg['jobs_dir']).glob('*/request.json')):
                try:
                    result.append(publish_result(cfg, path.parent.name))
                except Exception as exc:
                    result.append({'job_id': path.parent.name, 'state': 'error', 'error': str(exc)})
        print(json.dumps(result, ensure_ascii=False))
        if isinstance(result, list) and any(row.get('state') == 'error' for row in result):
            return 1
        return 0
    except (JobError, runner.ReviewError, bridge.BridgeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({'verdict': 'FAILED', 'error': str(exc)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
