#!/usr/bin/env python3
"""Run immutable bridge jobs and publish only freshly verified static review status."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import secrets

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


def request(cfg, job_id, *, allow_retired=False):
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
    policy = data.get('policy_version')
    if not isinstance(policy, str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,80}', policy):
        raise JobError('Invalid job policy')
    if data.get('kind') not in ('pr', 'release'):
        raise JobError('Unsupported job kind')
    if data['kind'] == 'pr' and (type(data.get('pr_number')) is not int or data['pr_number'] < 1):
        raise JobError('Invalid PR number')
    version = data.get('version')
    if version is not None and not isinstance(version, str):
        raise JobError('Invalid release version')
    key = '|'.join([cfg['repository'], data['head_sha'], data['base_sha'],
                    policy, data['kind'], str(data.get('pr_number') or ''),
                    version or ''])
    prefix = f"pr-{data['pr_number']}-" if data['kind'] == 'pr' else 'release-'
    if job_id != prefix + bridge.digest(key)[:24]:
        raise JobError('Job ID does not match immutable request fields')
    if not allow_retired and policy != cfg['policy_version']:
        raise JobError('Job policy is no longer current')
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


def active_attempt(cfg, req):
    """Select one immutable runner job; no selector means the original attempt."""
    logical = req['job_id']
    job_dir = Path(cfg['jobs_dir']).resolve() / logical
    selector = job_dir / 'attempt.json'
    runner_id = logical
    if selector.exists() or selector.is_symlink():
        value = runner.load_json(selector)
        if (not isinstance(value, dict) or value.get('schema_version') != 1
                or type(value.get('schema_version')) is not int or value.get('job_id') != logical):
            raise JobError('Invalid active attempt selector')
        runner_id = value.get('runner_job_id')
        if (not isinstance(runner_id, str) or len(runner_id) > 96
                or not re.fullmatch(re.escape(logical) + r'-retry-[0-9a-f]{12}', runner_id)):
            raise JobError('Active runner ID must belong to this logical job')
    records = job_dir if runner_id == logical else job_dir / 'attempts' / runner_id
    if records.is_symlink() or records.parent.is_symlink():
        raise JobError('Attempt records may not be symlinked')
    return runner_id, records


def collect_verified(cfg, req):
    runner_id, _ = active_attempt(cfg, req)
    directory = Path(cfg['review_state_dir']) / runner_id
    if not (directory / 'manifest.json').exists():
        return None
    manifest = runner.load_json(directory / 'manifest.json')
    if (manifest.get('job_id') != runner_id or manifest.get('kind') != req['kind']
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
    # The runner owns the protected evidence path. Never point agents to a local
    # full-report copy outside that protected root.
    if result.get('verdict') in ('PASS', 'NEEDS_REVIEW', 'FAILED') and not result.get('attestation_path'):
        result['attestation_path'] = str(runner.attestation_path(manifest))
    if active_attempt(cfg, req)[0] != runner_id:
        raise JobError('Active review attempt changed during collection')
    result['runner_job_id'] = runner_id
    result['job_id'] = req['job_id']
    return result


def summary(result):
    """Do not copy peer reports/findings into executor logs or Multica run output."""
    return {key: result[key] for key in ('verdict', 'job_id', 'runner_job_id', 'state', 'head_sha', 'base_sha',
                                        'mmrun_run_id', 'attestation_path', 'frozen_checkout',
                                        'reasons', 'error') if key in result}


def failed_execution(directory, job_id, runner_job_id=None):
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
    if runner_job_id is not None and any(
            row.get('runner_job_id', job_id) != runner_job_id for row in (execution, result)):
        raise JobError('Execution failure record belongs to a different attempt')
    if result.get('verdict') != 'FAILED':
        return None  # Even a claimed PASS requires independently collected evidence.
    return {'verdict': 'FAILED', 'job_id': job_id, 'runner_job_id': runner_job_id or job_id,
            'reasons': ['The local runner failed before creating a review manifest. '
                        'Inspect this job\'s execution-result.json; no review approval exists.']}


def _run_attempt(cfg, req, commands):
    """Called with the logical executor lock held; never automatically retries."""
    job_id = req['job_id']
    runner_id, directory = active_attempt(cfg, req)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    already_started = (directory / 'execution.json').exists()
    phase = 'target validation'
    try:
        if not current_target(cfg, req, commands):
            return {'verdict': 'SUPERSEDED', 'job_id': job_id}
        phase = 'existing evidence validation'
        existing = collect_verified(cfg, req)
        if existing is not None:
            return summary(existing)
        previous = failed_execution(directory, job_id, runner_id)
        if previous is not None:
            return previous
        if already_started:
            return {'verdict': 'RUNNING_TIMEOUT', 'job_id': job_id, 'runner_job_id': runner_id,
                    'reasons': ['Attempt already started; collect evidence before an explicit retry']}
        atomic(directory / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                              'started_at': bridge.utcnow()})
        source = Path(cfg['repository_path']).resolve()
        phase = 'origin validation'
        origin = runner.git(source, 'remote', 'get-url', 'origin')
        if origin.rstrip('/').removesuffix('.git') != 'https://github.com/' + cfg['repository']:
            raise JobError('Source repository origin is not the configured GitHub repository')
        env = os.environ.copy()
        env['GIT_LFS_SKIP_SMUDGE'] = '1'
        phase = 'fetch'
        fetched = subprocess.run(['git', '-C', str(source), 'fetch', '--filter=blob:none', 'origin',
                                  req['base_sha'], req['head_sha']], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=180)
        if fetched.returncode:
            raise JobError('Could not fetch verified review commits')
        argv = [sys.executable, str(Path(__file__).with_name('review_runner.py')), 'run',
                '--repo', str(source), '--base', req['base_sha'], '--head', req['head_sha'],
                '--kind', req['kind'], '--job-id', runner_id, '--state-dir', cfg['review_state_dir'],
                '--models', ','.join(cfg.get('review_models', ['codex', 'grok'])),
                '--timeout', str(cfg.get('review_timeout_seconds', 3600)),
                '--codex-home', cfg['codex_home']]
        if cfg.get('mmrun_path'):
            argv.extend(['--mmrun', cfg['mmrun_path']])
        phase = 'runner process'
        completed = subprocess.run(argv, env=env, text=True, capture_output=True)
        phase = 'runner result validation'
        result = json.loads(completed.stdout)
        if (not isinstance(result, dict) or result.get('job_id') != runner_id
                or result.get('verdict') not in runner.EXIT_CODES):
            raise JobError('Review runner returned an invalid result identity or verdict')
        if completed.returncode != runner.EXIT_CODES[result['verdict']]:
            raise JobError('Review runner exit code and verdict disagree')
        result = summary(result)
        result['runner_job_id'] = runner_id
        result['job_id'] = job_id
        atomic(directory / 'execution-result.json', result)
        return result
    except (JobError, runner.ReviewError, bridge.BridgeError, OSError, ValueError,
            TypeError, KeyError, subprocess.SubprocessError) as exc:
        # Persist only controlled diagnostics, never captured model output,
        # process stderr, credentials or peer findings.
        reason = str(exc) if isinstance(exc, JobError) else type(exc).__name__
        result = {'verdict': 'FAILED', 'job_id': job_id, 'runner_job_id': runner_id,
                  'reasons': [phase + ': ' + reason], 'failed_at': bridge.utcnow()}
        if not already_started:
            if not (directory / 'execution.json').exists():
                atomic(directory / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                                      'started_at': bridge.utcnow()})
            atomic(directory / 'execution-result.json', result)
        return result


def run_job(cfg, job_id):
    directory, req = request(cfg, job_id)
    with (directory / 'executor.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'verdict': 'RUNNING', 'job_id': job_id}
        return _run_attempt(cfg, req, bridge.Commands(cfg))


def require_quiescent(cfg, req, runner_id):
    """A FAILED collector result can coexist with another still-running model."""
    directory = Path(cfg['review_state_dir']) / runner_id
    if not directory.exists():
        return  # Preparation failed before a runner directory existed.
    with runner.job_lock(directory) as locked:
        if not locked:
            raise JobError('Cannot retry while preparation or collection is active')
        manifest_path = directory / 'manifest.json'
        if not manifest_path.exists():
            return
        manifest = runner.load_json(manifest_path)
        if runner.process_alive(manifest.get('dispatch_pid')):
            raise JobError('Cannot retry while the previous dispatcher is alive')
        run_id = manifest.get('mmrun_run_id')
        if not run_id:
            return
        if not isinstance(run_id, str) or not runner.JOB.fullmatch(run_id):
            raise JobError('Cannot establish previous worker identity')
        root = Path(manifest['provenance']['mmrun_home']) / run_id
        if root.is_symlink() or not root.is_dir():
            raise JobError('Cannot establish previous model liveness')
        for model in cfg.get('review_models', ['codex', 'grok']):
            status = root / (model + '.status')
            if status.is_symlink() or not status.is_file() or status.stat().st_size > 4096:
                raise JobError('Cannot establish previous model status')
            if status.read_text().strip() == 'RUNNING':
                raise JobError('Cannot retry while a previous model is RUNNING')
            pid_file = root / (model + '.pid')
            if pid_file.exists() or pid_file.is_symlink():
                if pid_file.is_symlink() or not pid_file.is_file() or pid_file.stat().st_size > 4096:
                    raise JobError('Cannot establish previous model process identity')
                value = pid_file.read_text().strip()
                if not value.isdigit():
                    raise JobError('Invalid previous worker PID')
                if runner.process_alive(int(value)):
                    raise JobError('Cannot retry while a previous model process is alive')


def retry_job(cfg, job_id):
    """Explicitly create one new attempt while retaining all earlier evidence."""
    directory, req = request(cfg, job_id)
    with (directory / 'executor.lock').open('a') as execute_lock, (directory / 'publish.lock').open('a') as publish_lock:
        for lock in (execute_lock, publish_lock):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise JobError('Cannot retry while execution or publication is active')
        commands = bridge.Commands(cfg)
        if not current_target(cfg, req, commands):
            raise JobError('Cannot retry a superseded target')
        prior_id, prior_records = active_attempt(cfg, req)
        prior = collect_verified(cfg, req) or failed_execution(prior_records, job_id, prior_id)
        if prior is None or prior.get('verdict') not in ('FAILED', 'NEEDS_REVIEW'):
            raise JobError('Explicit retry requires a completed FAILED or NEEDS_REVIEW attempt')
        require_quiescent(cfg, req, prior_id)
        runner_id = job_id + '-retry-' + secrets.token_hex(6)
        if len(runner_id) > 96:
            raise JobError('Retry runner ID exceeds the supported length')
        records = directory / 'attempts' / runner_id
        review_dir = Path(cfg['review_state_dir']) / runner_id
        if records.exists() or records.is_symlink() or review_dir.exists() or review_dir.is_symlink():
            raise JobError('Retry attempt ID collision; existing evidence was preserved')
        if records.parent.is_symlink():
            raise JobError('Attempt records directory may not be a symlink')
        records.mkdir(parents=True, mode=0o700)
        selection = {'schema_version': 1, 'job_id': job_id, 'runner_job_id': runner_id,
                     'previous_runner_job_id': prior_id, 'previous_verdict': prior['verdict'],
                     'created_at': bridge.utcnow()}
        atomic(records / 'attempt.json', selection)
        atomic(directory / 'attempt.json', selection)
        try:
            commands.gh(f"repos/{cfg['repository']}/statuses/{req['head_sha']}",
                        {'state': 'pending', 'context': bridge.status_context(req),
                         'description': runner_id + ': explicit review retry requested'})
        except (bridge.BridgeError, OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
            result = {'job_id': job_id, 'runner_job_id': runner_id, 'verdict': 'FAILED',
                      'reasons': ['Retry pending write failed: ' + type(exc).__name__]}
            atomic(records / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                                'started_at': bridge.utcnow()})
            atomic(records / 'execution-result.json', result)
            return result
        return _run_attempt(cfg, req, commands)


def status_payload(req, verdict, runner_id=None):
    state = 'success' if verdict == 'PASS' else 'failure'
    text = ('Static review passed; CI and maintainer approval required'
            if state == 'success' else 'Static review needs attention; inspect Multica')
    return {'state': state, 'context': bridge.status_context(req),
            'description': ((runner_id or req['job_id']) + ': ' + text)[:140]}


def remote_status_matches(cfg, req, payload, commands):
    current = commands.gh(f"repos/{cfg['repository']}/commits/{req['head_sha']}/status")
    if not isinstance(current, dict) or not isinstance(current.get('statuses'), list):
        raise JobError('Unexpected combined commit status response')
    for item in current['statuses']:
        if item.get('context') == payload['context']:
            return all(item.get(key) == payload[key] for key in ('state', 'description'))
    return False


def publish_result(cfg, job_id, commands=None):
    directory, req = request(cfg, job_id, allow_retired=True)
    if req['policy_version'] != cfg['policy_version']:
        # Old jobs remain inspectable but cannot execute or publish under a new policy.
        return {'job_id': job_id, 'state': 'retired'}
    commands = commands or bridge.Commands(cfg)
    with (directory / 'publish.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'job_id': job_id, 'state': 'busy'}
        if not req.get('multica_issue_id'):
            return {'job_id': job_id, 'state': 'awaiting_issue_mapping'}
        runner_id, records = active_attempt(cfg, req)
        records.mkdir(parents=True, exist_ok=True, mode=0o700)
        receipt = records / 'published.json'
        previous = None
        if receipt.exists():
            previous = runner.load_json(receipt)
            if (not isinstance(previous, dict) or previous.get('job_id', job_id) != job_id
                    or previous.get('head_sha', req['head_sha']) != req['head_sha']
                    or previous.get('runner_job_id', job_id) != runner_id):
                raise JobError('Invalid publication receipt')
            if not current_target(cfg, req, commands):
                return {'job_id': job_id, 'state': 'superseded'}
            if previous.get('state') in ('success', 'failure'):
                payload = status_payload(req, previous.get('verdict'), runner_id)
                if remote_status_matches(cfg, req, payload, commands):
                    return {'job_id': job_id, 'state': 'already_published'}
                # Intake replay or another write changed the remote status. Revalidate
                # evidence before repairing it; a local receipt is not remote truth.
        result = collect_verified(cfg, req)
        if result is None:
            result = failed_execution(records, job_id, runner_id)
        if result is None or result.get('verdict') in ('RUNNING', 'RUNNING_TIMEOUT'):
            return {'job_id': job_id, 'state': 'pending'}
        if not current_target(cfg, req, commands):
            atomic(receipt, {'state': 'superseded', 'job_id': job_id, 'runner_job_id': runner_id, 'at': bridge.utcnow()})
            return {'job_id': job_id, 'state': 'superseded'}
        verdict = result.get('verdict')
        payload = status_payload(req, verdict, runner_id)
        status_endpoint = f"repos/{cfg['repository']}/statuses/{req['head_sha']}"
        # The status writer is this fixed controller, not the implementation agent.
        commands.gh(status_endpoint, payload)
        try:
            still_current = current_target(cfg, req, commands)
        except (bridge.BridgeError, JobError, OSError, ValueError, TypeError, subprocess.SubprocessError):
            commands.gh(status_endpoint, {'state': 'pending', 'context': payload['context'],
                                         'description': 'Target could not be rechecked; review result withheld'})
            raise JobError('Target verification after status write failed; restored pending')
        if not still_current:
            commands.gh(status_endpoint, {'state': 'pending', 'context': payload['context'],
                                         'description': 'Target changed during publication; awaiting current review'})
            atomic(receipt, {'state': 'superseded', 'job_id': job_id, 'runner_job_id': runner_id, 'at': bridge.utcnow()})
            return {'job_id': job_id, 'state': 'superseded'}
        marker = 'multica-result-' + runner_id
        # Multica otherwise implicitly invokes the assigned agent for a human
        # comment, even without an explicit mention. /note suppresses dispatch.
        body = (f'/note\n{marker}\n\nStatic review result: {verdict}\n'
                f"Head: {req['head_sha']}\nBase: {req['base_sha']}\n"
                f"Attempt: {runner_id}\n"
                f"Attestation: {result.get('attestation_path', '')}\n"
                'This is a static-review result only. Build/runtime/release checks and maintainer approval remain required.\n'
                + json.dumps(result.get('reasons', []), ensure_ascii=False))
        intent_path = records / 'publish-comment-intent.json'
        comments = bridge.rows(commands.multica(['issue', 'comment', 'list', req['multica_issue_id'], '--output', 'json']))
        found = any(marker in str(c.get('content', '')) for c in comments)
        intent = runner.load_json(intent_path) if intent_path.exists() else None
        if intent is not None and (not isinstance(intent, dict) or intent.get('job_id') != job_id
                                   or intent.get('issue_id') != req['multica_issue_id']
                                   or intent.get('runner_job_id', job_id) != runner_id):
            raise JobError('Publication comment intent identity mismatch')
        if found:
            atomic(intent_path, {'job_id': job_id, 'runner_job_id': runner_id, 'issue_id': req['multica_issue_id'], 'state': 'confirmed'})
        elif intent is not None:
            if intent.get('state') != 'confirmed':
                # A prior write may still be processing remotely. Never repeat it
                # merely because this list response does not show the marker yet.
                return {'job_id': job_id, 'state': 'awaiting_comment_reconciliation'}
        else:
            atomic(intent_path, {'job_id': job_id, 'runner_job_id': runner_id, 'issue_id': req['multica_issue_id'],
                                 'state': 'sending', 'at': bridge.utcnow()})
            commands.multica(['issue', 'comment', 'add', req['multica_issue_id'], '--content-stdin', '--output', 'json'], body)
            atomic(intent_path, {'job_id': job_id, 'runner_job_id': runner_id, 'issue_id': req['multica_issue_id'], 'state': 'confirmed'})
        commands.multica(['issue', 'update', req['multica_issue_id'], '--status', 'in_review', '--no-start', '--output', 'json'])
        atomic(receipt, {'job_id': job_id, 'runner_job_id': runner_id, 'state': payload['state'], 'verdict': verdict,
                         'head_sha': req['head_sha'], 'context': payload['context'], 'at': bridge.utcnow()})
        return {'job_id': job_id, 'runner_job_id': runner_id, 'state': payload['state'], 'verdict': verdict}


def exit_code(result):
    if isinstance(result, list):
        return int(any(row.get('state') == 'error' for row in result))
    verdict = result.get('verdict')
    if verdict in runner.EXIT_CODES:
        return runner.EXIT_CODES[verdict]
    if result.get('state') in ('failure', 'error'):
        return 1
    if verdict in ('RUNNING', 'NOT_STARTED') or result.get('state') in (
            'pending', 'busy', 'awaiting_issue_mapping', 'awaiting_comment_reconciliation'):
        return 3
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--config', required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ('run', 'retry', 'collect', 'publish'):
        cmd = commands.add_parser(name, allow_abbrev=False)
        cmd.add_argument('--job-id', required=True)
    commands.add_parser('collect-all', allow_abbrev=False)
    args = parser.parse_args(argv)
    try:
        cfg = bridge.load_config(args.config)
        if args.action == 'run':
            result = run_job(cfg, args.job_id)
        elif args.action == 'retry':
            result = retry_job(cfg, args.job_id)
        elif args.action == 'collect':
            _, req = request(cfg, args.job_id)
            runner_id, records = active_attempt(cfg, req)
            result = collect_verified(cfg, req) or failed_execution(records, args.job_id, runner_id) or {'verdict': 'NOT_STARTED', 'job_id': args.job_id, 'runner_job_id': runner_id}
        elif args.action == 'publish':
            result = publish_result(cfg, args.job_id)
        else:
            result = []
            for path in sorted(Path(cfg['jobs_dir']).glob('*/request.json')):
                try:
                    result.append(publish_result(cfg, path.parent.name))
                except Exception as exc:
                    result.append({'job_id': path.parent.name, 'state': 'error', 'error': str(exc)})
        printable = [summary(row) for row in result] if isinstance(result, list) else summary(result)
        print(json.dumps(printable, ensure_ascii=False))
        return exit_code(result)
    except (JobError, runner.ReviewError, bridge.BridgeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({'verdict': 'FAILED', 'error': str(exc)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
