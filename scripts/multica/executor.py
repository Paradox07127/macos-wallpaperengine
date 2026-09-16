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
import shlex
import time
from urllib.parse import urlsplit

import github_bridge as bridge
import review_runner as runner

JOB = re.compile(r"^(?:pr-[1-9][0-9]*|release)-[0-9a-f]{24}$")
SHA = re.compile(r"^[0-9a-f]{40}$")


class JobError(RuntimeError):
    pass


class RunnerNotStarted(JobError):
    """Popen failed before a runner process existed."""


def execute_runner(argv, *, env, timeout):
    try:
        proc = subprocess.Popen(argv, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise RunnerNotStarted('Runner process could not be created') from exc
    with proc:
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except BaseException:
            proc.kill()
            proc.communicate()
            raise
        return subprocess.CompletedProcess(argv, proc.returncode, stdout, stderr)


def atomic(path, value):
    path = Path(path)
    runner.durable_mkdir(path.parent)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.record-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
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
    if data['kind'] == 'release' and (not isinstance(version, str) or not bridge.RELEASE_VERSION.fullmatch(version)):
        raise JobError('Release job requires an exact supported version')
    fingerprint = data.get('policy_fingerprint')
    if fingerprint is None:
        # Legacy history is inspectable, never eligible for execution/publication.
        key = '|'.join([cfg['repository'], data['head_sha'], data['base_sha'],
                        policy, data['kind'], str(data.get('pr_number') or ''), version or ''])
        prefix = f"pr-{data['pr_number']}-" if data['kind'] == 'pr' else 'release-'
        expected_id = prefix + bridge.digest(key)[:24]
    else:
        if not isinstance(fingerprint, str) or not re.fullmatch(r'[0-9a-f]{64}', fingerprint):
            raise JobError('Invalid effective policy fingerprint')
        if fingerprint != bridge.digest(json.dumps(data.get('review_policy'), sort_keys=True, separators=(',', ':'))):
            raise JobError('Effective policy object does not match its fingerprint')
        expected_id = bridge.job_id_for(data)
    if job_id != expected_id:
        raise JobError('Job ID does not match immutable request fields')
    if not allow_retired and not current_policy(cfg, data):
        raise JobError('Job policy is no longer current')
    return path.parent, data


def validate_issue_mapping(req):
    issue_id = req.get('multica_issue_id')
    if issue_id is not None and (not isinstance(issue_id, str) or not bridge.UUID.fullmatch(issue_id)):
        raise JobError('Multica issue mapping must be a UUID or null')


def current_policy(cfg, req):
    return (req.get('policy_version') == cfg['policy_version']
            and req.get('policy_fingerprint') == bridge.policy_fingerprint(cfg, req['kind'])
            and req.get('review_policy') == bridge.effective_policy(cfg, req['kind']))


def current_target(cfg, req, commands):
    if req['kind'] == 'pr':
        pr = commands.gh(f"repos/{cfg['repository']}/pulls/{req['pr_number']}")
        if not isinstance(pr, dict) or not isinstance(pr.get('head'), dict) or not isinstance(pr.get('base'), dict):
            raise JobError('PR target response must contain head/base objects')
        head, base = pr['head'], pr['base']
        repository = head.get('repo')
        if repository is not None and not isinstance(repository, dict):
            raise JobError('PR source repository must be an object or null')
        return (pr.get('state') == 'open' and not pr.get('draft')
                and (repository or {}).get('full_name') == cfg['repository']
                and base.get('ref') == cfg.get('target_branch', 'main')
                and head.get('sha') == req['head_sha']
                and base.get('sha') == req['base_sha'])
    # A release job names a fixed candidate; moving main is not an implicit replacement.
    commit = commands.gh(f"repos/{cfg['repository']}/commits/{req['head_sha']}")
    if not isinstance(commit, dict):
        raise JobError('Release target response must be an object')
    return commit.get('sha') == req['head_sha']


def active_attempt(cfg, req):
    """Select one immutable runner job; no selector means the original attempt."""
    logical = req['job_id']
    job_dir = Path(cfg['jobs_dir']).resolve() / logical
    selector = job_dir / 'attempt.json'
    runner_id = logical
    if not selector.exists() and not selector.is_symlink() and any((job_dir / 'attempts').glob('*/attempt.json')):
        raise JobError('Retry history exists but active selector is missing; explicitly recover the selected runner ID')
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


def allowed_origin(value, repository):
    """Accept canonical GitHub HTTPS/SSH origins, never another host or URL credentials."""
    if value.startswith('git@github.com:'):
        name = value[len('git@github.com:'):]
    else:
        parsed = urlsplit(value)
        if parsed.hostname is None or parsed.hostname.lower() != 'github.com' or parsed.query or parsed.fragment:
            return False
        if parsed.scheme == 'https' and (parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443)):
            return False
        if parsed.scheme == 'ssh' and (parsed.username != 'git' or parsed.password is not None or parsed.port not in (None, 22)):
            return False
        if parsed.scheme not in ('https', 'ssh'):
            return False
        name = parsed.path.removeprefix('/')
    name = name.rstrip('/').removesuffix('.git')
    return bool(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', name)) and name.lower() == repository.lower()


CREDENTIAL_ENVIRONMENT_KEYS = ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
                               'SSH_AUTH_SOCK', 'SSH_AGENT_PID')


def runner_environment(cfg):
    """Environment for the model runner: the controller's Git isolation without its credentials.

    The fetch environment carries gh's credential helper and the SSH agent so the controller
    can talk to origin; the runner publishes model output back to the PR, so none of that may
    reach it. It also keeps Git on local protocols only.
    """
    env = runner.git_environment()
    for key in CREDENTIAL_ENVIRONMENT_KEYS:
        env.pop(key, None)
    return env


def fetch_git_environment(cfg):
    """Use the same controller-owned Git settings for origin checks and fetch.

    gh authenticates using its own trusted config or GH_TOKEN/GITHUB_TOKEN.
    SSH uses the normal agent/default identities, never inherited SSH commands.
    """
    env = runner.git_environment()
    env.update(GIT_ALLOW_PROTOCOL='https:ssh', GIT_LFS_SKIP_SMUDGE='1',
               GIT_SSH_COMMAND='/usr/bin/ssh -F /dev/null -oBatchMode=yes',
               SSH_ASKPASS_REQUIRE='never')
    env.pop('SSH_ASKPASS', None)
    helper = '!' + shlex.quote(cfg['gh_path']) + ' auth git-credential'
    overrides = [('credential.helper', ''), ('credential.helper', helper),
                 ('credential.https://github.com.helper', ''),
                 ('credential.https://github.com.helper', helper),
                 ('credential.interactive', 'false'), ('credential.useHttpPath', 'false'),
                 ('core.sshCommand', env['GIT_SSH_COMMAND']),
                 ('remote.origin.uploadpack', 'git-upload-pack'),
                 ('fetch.recurseSubmodules', 'false'), ('gc.auto', '0'),
                 ('maintenance.auto', 'false'), ('fetch.writeCommitGraph', 'false')]
    offset = int(env['GIT_CONFIG_COUNT'])
    for index, (key, value) in enumerate(overrides, offset):
        env[f'GIT_CONFIG_KEY_{index}'] = key
        env[f'GIT_CONFIG_VALUE_{index}'] = value
    env['GIT_CONFIG_COUNT'] = str(offset + len(overrides))
    return env


def fetch_origin(source, env):
    # get-url expands insteadOf using exactly the config visible to fetch.
    result = subprocess.run(['git', '-C', str(source), 'remote', 'get-url', 'origin'],
                            env=env, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise JobError('Could not resolve source fetch origin')
    return result.stdout.strip()


def collect_verified(cfg, req):
    runner_id, _ = active_attempt(cfg, req)
    directory = Path(cfg['review_state_dir']) / runner_id
    if not (directory / 'manifest.json').exists():
        return None
    manifest = runner.load_json(directory / 'manifest.json')
    if not isinstance(manifest, dict) or any(not isinstance(manifest.get(key), dict) for key in ('policy', 'provenance')):
        raise JobError('Review manifest and policy/provenance must be objects')
    if (manifest.get('job_id') != runner_id or manifest.get('kind') != req['kind']
            or manifest.get('head_sha') != req['head_sha'] or manifest.get('base_sha') != req['base_sha']):
        raise JobError('Review manifest does not match intake request')
    source = manifest.get('source_repo', manifest.get('repo'))
    if not isinstance(source, str) or not source or Path(source).resolve() != Path(cfg['repository_path']).resolve():
        raise JobError('Review belongs to another source repository')
    if manifest.get('policy', {}).get('version') != runner.POLICY_VERSION:
        raise JobError('Review policy mismatch')
    if manifest.get('policy') != runner.review_policy(req['kind'], sorted(cfg.get('review_models', ['claude', 'codex']))):
        raise JobError('Required review policy changed')
    if manifest.get('provenance', {}).get('mmrun_kind') != cfg.get('mmrun_kind', 'compat'):
        raise JobError('Review transport identity changed')
    if req['kind'] == 'release' and manifest.get('version') != req.get('version'):
        raise JobError('Review release version mismatch')
    # Re-read the actual reports, statuses, and frozen tree. Never trust an agent's PASS string.
    result = runner.collect(directory, deadline=cfg.get('_collection_deadline',
                            time.monotonic() + cfg.get('collection_job_budget_seconds', 60)))
    if not isinstance(result, dict):
        raise JobError('Collector result must be an object')
    # The runner owns this path. A null path on a fresh failure/pending result
    # must stay null: a retained historical PASS is not current evidence.
    if active_attempt(cfg, req)[0] != runner_id:
        raise JobError('Active review attempt changed during collection')
    result['runner_job_id'] = runner_id
    result['job_id'] = req['job_id']
    return result


def summary(result):
    """Do not copy peer reports/findings into executor logs or Multica run output."""
    return {key: result[key] for key in ('verdict', 'job_id', 'runner_job_id', 'state', 'head_sha', 'base_sha',
                                        'mmrun_run_id', 'attestation_path', 'frozen_checkout',
                                        'recorded_verdict', 'recorded_policy', 'recorded_policy_fingerprint',
                                        'reasons', 'error') if key in result}


def failed_execution(directory, job_id, runner_job_id=None):
    """A runner failure before manifest creation may fail the check, never pass it."""
    execution_path = directory / 'execution.json'
    recovery = directory / 'recovery.json'
    result_path = recovery if recovery.exists() else directory / 'execution-result.json'
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
            'recovered': result.get('recovered') is True,
            'reasons': ['The local runner failed before creating a review manifest. '
                        'Inspect this job\'s execution-result.json; no review approval exists.']}


def _run_attempt(cfg, req, commands, *, dispatch_reserved=False):
    """Called with the logical executor lock held; never automatically retries."""
    job_id = req['job_id']
    runner_id, directory = active_attempt(cfg, req)
    runner.durable_mkdir(directory)
    already_started = (directory / 'execution.json').exists()
    if dispatch_reserved:
        reservation = runner.load_json(directory / 'execution.json')
        if (runner_id == job_id or not isinstance(reservation, dict)
                or reservation.get('job_id') != job_id or reservation.get('runner_job_id') != runner_id
                or reservation.get('phase') != 'NOT_DISPATCHED'):
            raise JobError('Retry dispatch requires an intact, unused reservation')
        already_started = False
    phase = 'target validation'
    try:
        if not current_target(cfg, req, commands):
            if runner_id != job_id and not already_started:
                atomic(directory / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                                      'phase': 'NOT_DISPATCHED', 'controller_pid': os.getpid()})
                atomic(directory / 'execution-result.json', {'job_id': job_id, 'runner_job_id': runner_id,
                       'verdict': 'FAILED', 'reasons': ['Target changed before retry dispatch; no models started']})
            return {'verdict': 'SUPERSEDED', 'job_id': job_id, 'runner_job_id': runner_id}
        phase = 'existing evidence validation'
        existing = attempt_result(cfg, req)
        if existing is not None:
            return summary(existing)
        previous = failed_execution(directory, job_id, runner_id)
        if previous is not None:
            return previous
        if already_started:
            return {'verdict': 'RUNNING_TIMEOUT', 'job_id': job_id, 'runner_job_id': runner_id,
                    'reasons': ['Attempt already started; collect evidence before an explicit retry']}
        execution = {'job_id': job_id, 'runner_job_id': runner_id, 'controller_pid': os.getpid(),
                     'phase': 'PREPARING', 'started_at': bridge.utcnow()}
        atomic(directory / 'execution.json', execution)
        source = Path(cfg['repository_path']).resolve()
        phase = 'origin validation'
        env = fetch_git_environment(cfg)
        origin = fetch_origin(source, env)
        if not allowed_origin(origin, cfg['repository']):
            raise JobError('Source repository origin is not the configured GitHub repository')
        phase = 'fetch'
        fetched = subprocess.run(['git', '-C', str(source), 'fetch', '-q', '--no-filter', 'origin',
                                  req['base_sha'], req['head_sha']], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=180)
        if fetched.returncode:
            raise JobError('Could not fetch verified review commits')
        phase = 'post-fetch target validation'
        if not current_target(cfg, req, commands):
            execution['phase'] = 'NOT_DISPATCHED'
            atomic(directory / 'execution.json', execution)
            atomic(directory / 'execution-result.json', {
                'verdict': 'FAILED', 'job_id': job_id, 'runner_job_id': runner_id,
                'reasons': ['Target changed during fetch; no runner or models started']})
            return {'verdict': 'SUPERSEDED', 'job_id': job_id, 'runner_job_id': runner_id}
        argv = [sys.executable, str(Path(__file__).with_name('review_runner.py')), 'run',
                '--repo', str(source), '--base', req['base_sha'], '--head', req['head_sha'],
                '--kind', req['kind'], '--job-id', runner_id, '--state-dir', cfg['review_state_dir'],
                '--models', ','.join(cfg.get('review_models', ['claude', 'codex'])),
                '--timeout', str(cfg.get('review_timeout_seconds', 3600)),
                '--codex-home', cfg['codex_home'], '--mmrun-kind', cfg.get('mmrun_kind', 'compat')]
        if req['kind'] == 'release':
            argv.extend(['--version', req['version']])
        if cfg.get('mmrun_path'):
            argv.extend(['--mmrun', cfg['mmrun_path']])
        phase = 'runner process'
        execution['phase'] = 'RUNNER_LAUNCH_INTENT'
        atomic(directory / 'execution.json', execution)
        try:
            # Preparation has independently bounded Git stages before the
            # runner's model deadline. Bound this wrapper too, without treating
            # detached workers as stopped or authorizing an automatic retry.
            completed = execute_runner(argv, env=runner_environment(cfg),
                                       timeout=cfg.get('review_timeout_seconds', 3600) + 1200)
        except RunnerNotStarted:
            execution['phase'] = 'NOT_DISPATCHED'
            execution['launch_failure'] = 'POPEN_FAILED'
            atomic(directory / 'execution.json', execution)
            raise
        except subprocess.TimeoutExpired:
            result = {'verdict': 'RUNNING_TIMEOUT', 'job_id': job_id, 'runner_job_id': runner_id,
                      'reasons': ['Executor wrapper deadline elapsed; retained supervisor/worker evidence must be collected or explicitly recovered']}
            atomic(directory / 'execution-result.json', result)
            return result
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
            TypeError, KeyError, RecursionError, subprocess.SubprocessError) as exc:
        # Persist only controlled diagnostics, never captured model output,
        # process stderr, credentials or peer findings.
        reason = str(exc) if isinstance(exc, JobError) else type(exc).__name__
        result = {'verdict': 'FAILED', 'job_id': job_id, 'runner_job_id': runner_id,
                  'reasons': [phase + ': ' + reason], 'failed_at': bridge.utcnow()}
        if not already_started:
            if not (directory / 'execution.json').exists():
                atomic(directory / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                                      'phase': 'NOT_DISPATCHED', 'started_at': bridge.utcnow()})
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
    """Delegate session/dispatcher recovery to the runner's authoritative journal."""
    directory = Path(cfg['review_state_dir']) / runner_id
    if directory.is_symlink():
        raise JobError('Review evidence directory may not be a symlink')
    if not directory.exists():
        job_dir = Path(cfg['jobs_dir']).resolve() / req['job_id']
        if runner_id != req['job_id'] and not re.fullmatch(re.escape(req['job_id']) + r'-retry-[0-9a-f]{12}', runner_id):
            raise JobError('Unknown runner identity for missing review directory')
        records = job_dir if runner_id == req['job_id'] else job_dir / 'attempts' / runner_id
        if records.is_symlink() or records.parent.is_symlink():
            raise JobError('Attempt records may not be symlinked')
        execution = runner.load_json(records / 'execution.json')
        if (not isinstance(execution, dict) or execution.get('job_id') != req['job_id']
                or execution.get('runner_job_id', req['job_id']) != runner_id
                or execution.get('phase') not in ('PREPARING', 'NOT_DISPATCHED')):
            raise JobError('Review evidence is missing after possible dispatch; process state is unknown')
        # Only these durable pre-launch phases prove this controller did not
        # start a runner. A missing directory or empty ps match alone cannot.
        no_active_controller(runner_id)
        return
    with runner.job_lock(directory) as locked:
        if not locked:
            raise JobError('Cannot retry while preparation or collection is active')
        try:
            runner.require_quiescent(directory, models=cfg.get('review_models', ['claude', 'codex']))
        except runner.ReviewError as exc:
            raise JobError('Runner cannot prove this attempt is quiescent') from exc


def no_active_controller(runner_id):
    """Inspect controller argv only; runner.require_quiescent proves worker/session liveness."""
    try:
        table = subprocess.run(['/bin/ps', '-axww', '-o', 'pid=,command='], text=True,
                               capture_output=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise JobError('Cannot inspect orphan controller identity') from exc
    if table.returncode:
        raise JobError('Cannot inspect orphan controller identity')
    for line in table.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) == os.getpid():
            continue
        if runner_id not in fields[1]:
            continue
        try:
            args = shlex.split(fields[1])
        except ValueError:
            raise JobError('Cannot parse a possible orphan controller command')
        if runner_id in args:
            raise JobError('A controller for this attempt is still alive')


def attempt_result(cfg, req):
    result = collect_verified(cfg, req)
    runner_id, records = active_attempt(cfg, req)
    failed = failed_execution(records, req['job_id'], runner_id)
    if result is None or (result.get('verdict') in ('RUNNING', 'RUNNING_TIMEOUT')
                          and failed is not None and failed.get('recovered')):
        return failed or result
    return result


def collect_job(cfg, job_id):
    """Inspect retired metadata without re-adjudicating or rewriting old evidence."""
    _, req = request(cfg, job_id, allow_retired=True)
    runner_id, records = active_attempt(cfg, req)
    if current_policy(cfg, req):
        return attempt_result(cfg, req) or {
            'verdict': 'RUNNING_TIMEOUT' if (records / 'execution.json').exists() else 'NOT_STARTED',
            'job_id': job_id, 'runner_job_id': runner_id}
    result = {'state': 'retired', 'job_id': job_id, 'runner_job_id': runner_id,
              'head_sha': req['head_sha'], 'base_sha': req['base_sha'],
              'recorded_policy': req['policy_version'],
              'recorded_policy_fingerprint': req.get('policy_fingerprint'),
              'reasons': ['Historical metadata only; evidence has not been revalidated under the current policy']}
    reference = Path(cfg['review_state_dir']) / runner_id / 'attestation.json'
    is_reference = reference.exists()
    if is_reference:
        record, reference_hash, _ = runner.read_json_snapshot(reference)
        expected_id = runner_id
    else:
        reference = records / 'execution-result.json'
        if not reference.exists():
            result['recorded_verdict'] = 'NOT_STARTED' if not (records / 'execution.json').exists() else 'RUNNING_TIMEOUT'
            return result
        record = runner.load_json(reference)
        expected_id = job_id
    if (not isinstance(record, dict) or record.get('job_id') != expected_id
            or record.get('runner_job_id', runner_id) != runner_id):
        raise JobError('Historical record does not match the selected attempt')
    if record.get('verdict') not in runner.EXIT_CODES:
        raise JobError('Historical record has an unsupported verdict')
    if is_reference:
        try:
            target = record.get('attestation_path')
            expected_hash = record.get('sha256')
            if (not isinstance(target, str) or not Path(target).is_absolute()
                    or not isinstance(expected_hash, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_hash)):
                raise JobError('Historical attestation pointer lacks a valid path/hash')
            actual, actual_hash, _ = runner.read_json_snapshot(Path(target), max_bytes=runner.MAX_ATTESTATION_BYTES)
            if (actual_hash != expected_hash or not isinstance(actual, dict)
                    or actual.get('job_id') != runner_id or actual.get('verdict') != record['verdict']
                    or actual.get('head_sha') != req['head_sha'] or actual.get('base_sha') != req['base_sha']
                    or runner.read_json_snapshot(reference)[1] != reference_hash):
                raise JobError('Historical attestation pointer does not match its evidence')
        except (JobError, runner.ReviewError, runner.CollectionUnavailable, OSError, ValueError, TypeError, RecursionError):
            result['recorded_verdict'] = 'UNKNOWN'
            result['reasons'].append('Historical attestation reference is unavailable or inconsistent; no recorded verdict can be confirmed')
            return result
    result['recorded_verdict'] = record['verdict']
    # A reference is reported as historical; no reports or findings are copied
    # into the agent-readable CLI output and no current approval is asserted.
    if isinstance(record.get('attestation_path'), str):
        result['attestation_path'] = record['attestation_path']
    return result


def recover_job(cfg, job_id, selected_runner_id=None):
    """Record a proven orphan as FAILED; this action never starts models."""
    directory, req = request(cfg, job_id)
    with (directory / 'executor.lock').open('a') as execute_lock, (directory / 'publish.lock').open('a') as publish_lock:
        for lock in (execute_lock, publish_lock):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise JobError('Cannot recover while execution or publication is active')
        if selected_runner_id is not None:
            if not re.fullmatch(re.escape(job_id) + r'-retry-[0-9a-f]{12}', selected_runner_id):
                raise JobError('Selected recovery attempt does not belong to this job')
            selector = directory / 'attempt.json'
            if selector.exists() or selector.is_symlink():
                if active_attempt(cfg, req)[0] != selected_runner_id:
                    raise JobError('Cannot replace an existing active attempt selector')
            else:
                # The operator chooses the missing selector explicitly. Do not infer
                # the newest or most favorable result from historical attempts.
                snapshot = runner.load_json(directory / 'attempts' / selected_runner_id / 'attempt.json')
                if not isinstance(snapshot, dict) or snapshot.get('job_id') != job_id or snapshot.get('runner_job_id') != selected_runner_id:
                    raise JobError('Preserved attempt identity mismatch')
                for identifier in [job_id] + [p.parent.name for p in (directory / 'attempts').glob('*/attempt.json')]:
                    no_active_controller(identifier)
                    require_quiescent(cfg, req, identifier)
                atomic(selector, snapshot)
        runner_id, records = active_attempt(cfg, req)
        existing = attempt_result(cfg, req)
        if existing is not None and existing.get('verdict') in ('PASS', 'FAILED', 'NEEDS_REVIEW'):
            return summary(existing)
        if not (records / 'execution.json').exists() and runner_id == job_id:
            raise JobError('No started attempt exists to recover')
        no_active_controller(runner_id)
        require_quiescent(cfg, req, runner_id)
        if not (records / 'execution.json').exists():
            atomic(records / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                                               'phase': 'NOT_DISPATCHED', 'recovered_at': bridge.utcnow()})
        result = {'job_id': job_id, 'runner_job_id': runner_id, 'verdict': 'FAILED',
                  'recovered': True, 'recovered_at': bridge.utcnow(),
                  'reasons': ['Orphan recovery proved no active controllers or workers; explicit retry required']}
        atomic(records / 'recovery.json', result)
        return result


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
        prior = attempt_result(cfg, req)
        if prior is None or prior.get('verdict') not in ('FAILED', 'NEEDS_REVIEW'):
            raise JobError('Explicit retry requires a completed FAILED or NEEDS_REVIEW attempt')
        require_quiescent(cfg, req, prior_id)
        with bridge.status_lock(cfg, req) as locked:
            if not locked:
                raise JobError('Status context is busy; no retry was selected')
            validate_issue_mapping(req)
            issue_id = req.get('multica_issue_id')
            if not issue_id:
                raise JobError('Retry requires a current issue generation mapping')
            with bridge.issue_generation_lock(cfg, issue_id) as generation_locked:
                if not generation_locked:
                    raise JobError('Issue generation is busy; no retry was selected')
                if not current_target(cfg, req, commands):
                    raise JobError('Retry target changed while prior evidence was checked')
                if bridge.current_generation(cfg, issue_id) != job_id:
                    raise JobError('Retry belongs to a superseded or unknown issue generation')
                latest = remote_status(cfg, req, commands)
                if latest and not re.match(r'^' + re.escape(job_id) + r'(?:-retry-[0-9a-f]{12})?:',
                                           str(latest.get('description', ''))):
                    raise JobError('Status context belongs to another generation; retry withheld')
                runner_id = job_id + '-retry-' + secrets.token_hex(6)
                if len(runner_id) > 96:
                    raise JobError('Retry runner ID exceeds the supported length')
                records = directory / 'attempts' / runner_id
                review_dir = Path(cfg['review_state_dir']) / runner_id
                if records.exists() or records.is_symlink() or review_dir.exists() or review_dir.is_symlink():
                    raise JobError('Retry attempt ID collision; existing evidence was preserved')
                if records.parent.is_symlink():
                    raise JobError('Attempt records directory may not be a symlink')
                runner.durable_mkdir(records.parent)
                records.mkdir(mode=0o700)
                selection = {'schema_version': 1, 'job_id': job_id, 'runner_job_id': runner_id,
                             'previous_runner_job_id': prior_id, 'previous_verdict': prior['verdict'],
                             'created_at': bridge.utcnow()}
                # Reserve before selecting: a crash never leaves an apparently
                # empty attempt that could conceal a previously dispatched runner.
                atomic(records / 'execution.json', {'job_id': job_id, 'runner_job_id': runner_id,
                       'phase': 'NOT_DISPATCHED', 'started_at': bridge.utcnow()})
                atomic(records / 'attempt.json', selection)
                atomic(directory / 'attempt.json', selection)
                try:
                    commands.gh(f"repos/{cfg['repository']}/statuses/{req['head_sha']}",
                                {'state': 'pending', 'context': bridge.status_context(req),
                                 'description': runner_id + ': explicit review retry requested'})
                except (bridge.BridgeError, OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
                    result = {'job_id': job_id, 'runner_job_id': runner_id, 'verdict': 'FAILED',
                              'reasons': ['Retry pending write failed: ' + type(exc).__name__]}
                    atomic(records / 'execution-result.json', result)
                    return result
        # The selection and pending write are durable. Publication may observe
        # this attempt while the executor lock still prevents another dispatch.
        fcntl.flock(publish_lock, fcntl.LOCK_UN)
        return _run_attempt(cfg, req, commands, dispatch_reserved=True)


def status_payload(req, verdict, runner_id=None, revision=''):
    state = 'success' if verdict == 'PASS' else 'failure'
    text = ('Static review passed; CI/maintainer approval required'
            if state == 'success' else 'Static review needs attention')
    return {'state': state, 'context': bridge.status_context(req),
            'description': ((runner_id or req['job_id']) + ': ' + revision[:12] + ' ' + text)[:140]}


def remote_status(cfg, req, commands):
    count = 0
    for page in range(1, 101):
        current = commands.gh(f"repos/{cfg['repository']}/commits/{req['head_sha']}/status?per_page=100&page={page}")
        if (not isinstance(current, dict) or not isinstance(current.get('statuses'), list)
                or any(not isinstance(row, dict) for row in current['statuses'])):
            raise JobError('Unexpected combined commit status response')
        rows = current['statuses']
        total = current.get('total_count')
        if total is not None and (type(total) is not int or total < 0):
            raise JobError('Unexpected combined status total count')
        match = next((row for row in rows if row.get('context') == bridge.status_context(req)), None)
        if match is not None:
            return match
        count += len(rows)
        if len(rows) < 100:
            if total is not None and count < total:
                raise JobError('Incomplete combined status pagination')
            return None
    raise JobError('Combined status pagination limit reached; context is unknown')


def remote_status_matches(cfg, req, payload, commands):
    current = remote_status(cfg, req, commands)
    return current is not None and all(current.get(key) == payload[key]
                                       for key in ('state', 'description', 'context'))


def revoke_owned_status(cfg, req, runner_id, commands):
    # Call only while holding the shared context lock. Never revoke another
    # generation's newer result when an older controller resumes after a crash.
    latest = remote_status(cfg, req, commands)
    if latest and latest.get('state') != 'pending' and str(latest.get('description', '')).startswith(runner_id + ':'):
        commands.gh(f"repos/{cfg['repository']}/statuses/{req['head_sha']}",
                    {'state': 'pending', 'context': bridge.status_context(req),
                     'description': runner_id + ': target verification incomplete; result withheld'})


def confirmed_target(cfg, req, runner_id, commands):
    """Unknown target identity withholds any status owned by this generation."""
    try:
        return current_target(cfg, req, commands)
    except (bridge.BridgeError, JobError, OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
        revoke_owned_status(cfg, req, runner_id, commands)
        raise JobError('Current review target could not be confirmed; owned result withheld') from exc


def result_revision(req, runner_id, result):
    value = {'runner_job_id': runner_id, 'head': req['head_sha'], 'base': req['base_sha'],
             'policy': req['policy_fingerprint'],
             **{key: result.get(key) for key in ('verdict', 'reasons', 'artifacts', 'reports', 'tree_sha')}}
    return bridge.digest(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False))


def publication_record(path):
    if not path.exists() and not path.is_symlink():
        return None
    record = runner.load_json(path)
    if not isinstance(record, dict):
        raise JobError('Publication record must be an object')
    return record


def revoke_job_status(cfg, req, commands):
    """A validated logical request can revoke its own generation despite bad logs."""
    latest = remote_status(cfg, req, commands)
    owner = re.match(r'^(' + re.escape(req['job_id']) + r'(?:-retry-[0-9a-f]{12})?):',
                     str(latest.get('description', '')) if latest else '')
    if owner:
        revoke_owned_status(cfg, req, owner.group(1), commands)


def publish_locked(cfg, req, commands, records, runner_id):
    # Lock order is publication -> status -> issue. Intake releases its status
    # lock before taking the issue lock; never acquire another status lock here.
    with bridge.issue_generation_lock(cfg, req['multica_issue_id']) as locked:
        if not locked:
            revoke_owned_status(cfg, req, runner_id, commands)
            return {'job_id': req['job_id'], 'state': 'busy'}
        try:
            generation = bridge.current_generation(cfg, req['multica_issue_id'])
        except bridge.BridgeError as exc:
            raise JobError('Shared issue generation record is invalid') from exc
        if generation != req['job_id']:
            revoke_owned_status(cfg, req, runner_id, commands)
            return {'job_id': req['job_id'], 'state': (
                'awaiting_issue_generation' if generation is None else 'superseded')}
        return publish_generation_locked(cfg, req, commands, records, runner_id)


def publish_generation_locked(cfg, req, commands, records, runner_id):
    job_id = req['job_id']
    receipt = records / 'published.json'
    status_intent = records / 'publish-status-intent.json'
    previous = publication_record(receipt)
    intent = publication_record(status_intent)
    for record in (previous, intent):
        if record is not None and (not isinstance(record, dict) or record.get('job_id') != job_id
                                   or record.get('head_sha') != req['head_sha']
                                   or record.get('runner_job_id') != runner_id):
            raise JobError('Invalid publication identity')
        if record is not None and (not isinstance(record.get('revision'), str)
                                   or not re.fullmatch(r'[0-9a-f]{64}', record['revision'])):
            raise JobError('Invalid publication revision')
    if previous is not None and (previous.get('state') not in ('success', 'failure')
            or previous.get('verdict') not in ('PASS', 'NEEDS_REVIEW', 'FAILED')
            or previous['state'] != ('success' if previous['verdict'] == 'PASS' else 'failure')
            or previous.get('context') != bridge.status_context(req)):
        raise JobError('Invalid publication receipt state')
    if intent is not None:
        payload_record = intent.get('payload')
        if (intent.get('state') not in ('sending', 'verified', 'revoked', 'complete')
                or not isinstance(payload_record, dict)
                or payload_record.get('context') != bridge.status_context(req)
                or payload_record.get('state') not in ('success', 'failure')
                or not isinstance(payload_record.get('description'), str)):
            raise JobError('Invalid publication status intent')
    target_current = confirmed_target(cfg, req, runner_id, commands)
    if not target_current:
        revoke_owned_status(cfg, req, runner_id, commands)
        if intent is not None:
            atomic(status_intent, dict(intent, state='revoked'))
        return {'job_id': job_id, 'state': 'superseded'}
    # A matching remote status never substitutes for fresh evidence validation.
    try:
        result = attempt_result(cfg, req)
    except runner.CollectionUnavailable:
        revoke_owned_status(cfg, req, runner_id, commands)
        return {'job_id': job_id, 'state': 'pending'}
    except (JobError, runner.ReviewError, OSError, ValueError, TypeError, KeyError, RecursionError):
        if previous is None and intent is None:
            raise
        result = {'verdict': 'FAILED', 'reasons': ['Previously published evidence failed validation']}
    if result is None or result.get('verdict') in ('RUNNING', 'RUNNING_TIMEOUT'):
        revoke_owned_status(cfg, req, runner_id, commands)
        return {'job_id': job_id, 'state': 'pending'}
    verdict = result.get('verdict')
    if verdict not in ('PASS', 'NEEDS_REVIEW', 'FAILED'):
        raise JobError('Unsupported publication verdict')
    revision = result_revision(req, runner_id, result)
    payload = status_payload(req, verdict, runner_id, revision)
    marker = 'multica-result-' + runner_id + '-' + revision[:24]
    # /note prevents the cloud task's default human-comment fallback dispatch.
    # Evidence paths are local; publishing them discloses machine directory names.
    body = (f'/note\n{marker}\n\nStatic review result: {verdict}\n'
            f"Head: {req['head_sha']}\nBase: {req['base_sha']}\nAttempt: {runner_id}\n"
            f'Result revision: {revision} (supersedes earlier results for this attempt).\n'
            'This record describes only the head and attempt above; after a newer review starts, it is historical.\n'
            'This is a static-review result only. Build/runtime/release checks and maintainer approval remain required.')
    matches = remote_status_matches(cfg, req, payload, commands)
    if previous and previous.get('revision') == revision and matches:
        confirmation = publication_record(records / 'comment-intents' / (revision + '.json'))
        if (confirmation is None or confirmation.get('state') != 'confirmed'
                or any(confirmation.get(key) != value for key, value in {
                    'job_id': job_id, 'runner_job_id': runner_id,
                    'issue_id': req['multica_issue_id'], 'revision': revision}.items())
                or not isinstance(confirmation.get('body_sha256'), str)
                or confirmation['body_sha256'] != bridge.digest(body)):
            raise JobError('Published result lacks a valid comment confirmation')
        try:
            bridge.comment_ack(cfg, {'id': confirmation.get('comment_id')}, req['multica_issue_id'], '')
        except bridge.BridgeError as exc:
            raise JobError('Published comment acknowledgement is invalid') from exc
        if not confirmed_target(cfg, req, runner_id, commands):
            revoke_owned_status(cfg, req, runner_id, commands)
            if intent is not None:
                atomic(status_intent, dict(intent, state='revoked'))
            return {'job_id': job_id, 'state': 'superseded'}
        if intent and intent.get('state') != 'complete':
            atomic(status_intent, dict(intent, state='complete'))
        return {'job_id': job_id, 'runner_job_id': runner_id, 'state': 'already_published'}
    journal = {'job_id': job_id, 'runner_job_id': runner_id, 'head_sha': req['head_sha'],
               'revision': revision, 'payload': payload, 'state': 'sending'}
    atomic(status_intent, journal)
    write_error = None
    if not matches:
        try:
            commands.gh(f"repos/{cfg['repository']}/statuses/{req['head_sha']}", payload)
        except (bridge.BridgeError, OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
            # The server may have accepted this POST. Keep intent until an
            # authoritative read resolves it; never assume a transport error means no write.
            write_error = exc
    still_current = confirmed_target(cfg, req, runner_id, commands)
    if not still_current:
        revoke_owned_status(cfg, req, runner_id, commands)
        atomic(status_intent, dict(journal, state='revoked'))
        return {'job_id': job_id, 'state': 'superseded'}
    if not remote_status_matches(cfg, req, payload, commands):
        raise JobError('Status write is unconfirmed; durable intent retained') from write_error
    atomic(status_intent, dict(journal, state='verified'))
    intent_path = records / 'comment-intents' / (revision + '.json')
    comment_intent = publication_record(intent_path)
    identity = {'job_id': job_id, 'runner_job_id': runner_id, 'issue_id': req['multica_issue_id'],
                'revision': revision, 'body_sha256': bridge.digest(body)}
    if comment_intent is not None and (not isinstance(comment_intent, dict)
                                      or any(comment_intent.get(key) != value for key, value in identity.items())):
        raise JobError('Publication comment intent identity mismatch')
    if comment_intent is not None and comment_intent.get('state') == 'sending':
        created = comment_intent.get('at')
        if not isinstance(created, str):
            raise JobError('Uncertain comment intent is missing its send timestamp')
        # The installed CLI supports --since, not a limit/page for this mode.
        # Query only uncertain sends in their time window; never read the full
        # history on a first send or when a valid acknowledgement was recorded.
        try:
            since = bridge.since_overlap(created)
        except (bridge.BridgeError, ValueError, TypeError) as exc:
            raise JobError('Invalid uncertain comment send timestamp') from exc
        comments = bridge.rows(commands.multica(['issue', 'comment', 'list', req['multica_issue_id'],
                    '--since', since, '--roots-only', '--output', 'json']))
        found = next((item for item in comments if bridge.trusted_comment(cfg, item, body)), None)
        if found is None:
            return {'job_id': job_id, 'state': 'awaiting_comment_reconciliation'}
        comment_id = bridge.comment_ack(cfg, found, req['multica_issue_id'], body)
        atomic(intent_path, dict(identity, state='confirmed', comment_id=comment_id, at=created))
    elif comment_intent is None or comment_intent.get('state') == 'not_started':
        created = bridge.utcnow()
        atomic(intent_path, dict(identity, state='sending', at=created))
        try:
            response = commands.multica(['issue', 'comment', 'add', req['multica_issue_id'], '--content-stdin', '--output', 'json'], body)
        except bridge.CommandNotStarted:
            atomic(intent_path, dict(identity, state='not_started'))
            return {'job_id': job_id, 'state': 'pending'}
        try:
            comment_id = bridge.comment_ack(cfg, response, req['multica_issue_id'], body)
        except bridge.BridgeError:
            # The CLI may have submitted the comment despite a malformed ACK.
            # Retain sending; a later trusted full-body match must confirm it.
            return {'job_id': job_id, 'state': 'awaiting_comment_reconciliation'}
        atomic(intent_path, dict(identity, state='confirmed', comment_id=comment_id, at=created))
    elif comment_intent.get('state') == 'confirmed':
        try:
            bridge.comment_ack(cfg, {'id': comment_intent.get('comment_id')}, req['multica_issue_id'], body)
        except bridge.BridgeError as exc:
            raise JobError('Confirmed comment record lacks a valid acknowledgement') from exc
    else:
        raise JobError('Unknown publication comment intent state')
    # The generation lock remains held through the remote issue update and
    # durable receipt; a competing head cannot advance its mapping mid-publish.
    if not confirmed_target(cfg, req, runner_id, commands):
        revoke_owned_status(cfg, req, runner_id, commands)
        atomic(status_intent, dict(journal, state='revoked'))
        return {'job_id': job_id, 'state': 'superseded'}
    commands.multica(['issue', 'update', req['multica_issue_id'], '--status', 'in_review', '--no-start', '--output', 'json'])
    atomic(receipt, {'job_id': job_id, 'runner_job_id': runner_id, 'state': payload['state'], 'verdict': verdict,
                     'revision': revision, 'head_sha': req['head_sha'], 'context': payload['context'], 'at': bridge.utcnow()})
    atomic(status_intent, dict(journal, state='complete'))
    return {'job_id': job_id, 'runner_job_id': runner_id, 'state': payload['state'], 'verdict': verdict}


def publish_result(cfg, job_id, commands=None):
    directory, req = request(cfg, job_id, allow_retired=True)
    commands = commands or bridge.Commands(cfg)
    with (directory / 'publish.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'job_id': job_id, 'state': 'busy'}
        with bridge.status_lock(cfg, req) as locked:
            if not locked:
                return {'job_id': job_id, 'state': 'busy'}
            try:
                if not current_policy(cfg, req):
                    revoke_job_status(cfg, req, commands)
                    return {'job_id': job_id, 'state': 'retired'}
                validate_issue_mapping(req)
                if not req.get('multica_issue_id'):
                    revoke_job_status(cfg, req, commands)
                    return {'job_id': job_id, 'state': 'awaiting_issue_mapping'}
                runner_id, records = active_attempt(cfg, req)
                runner.durable_mkdir(records)
                return publish_locked(cfg, req, commands, records, runner_id)
            except (JobError, runner.ReviewError, bridge.BridgeError, OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError) as exc:
                # Request identity and the ownership lock precede all local
                # publication/attempt record reads. Corruption never preserves
                # our green status merely because its own receipt is unreadable.
                revoke_job_status(cfg, req, commands)
                raise JobError('Publication could not be validated; owned result withheld') from exc


def collect_all(cfg):
    """Rotate before each job so a killed service tick cannot starve later jobs."""
    candidates = sorted(Path(cfg['jobs_dir']).glob('*/request.json'))
    paths = [path for path in candidates if JOB.fullmatch(path.parent.name)]
    results = []
    if len(paths) != len(candidates):
        results.append({'state': 'skipped_invalid_job_dirs', 'reasons': [
            f'Ignored {len(candidates) - len(paths)} directories without a valid immutable job ID']})
    cursor_path = Path(cfg['state_path']).parent / 'executor-collection.json'
    cursor = ''
    if cursor_path.exists() or cursor_path.is_symlink():
        try:
            record = runner.load_json(cursor_path)
            if not isinstance(record, dict) or not isinstance(record.get('last_job_id'), str):
                raise JobError('Invalid disposable cursor')
            cursor = record['last_job_id']
            if cursor and not JOB.fullmatch(cursor):
                raise JobError('Invalid disposable cursor value')
        except (JobError, runner.ReviewError, OSError, ValueError, TypeError, RecursionError):
            cursor = ''
            results.append({'state': 'cursor_reset', 'reasons': ['Discarded an invalid collection cursor; starting from the default position']})
    paths.sort(key=lambda p: (p.parent.name <= cursor, p.parent.name))
    deadline = time.monotonic() + cfg.get('collection_budget_seconds', 210)
    commands = bridge.Commands(cfg)
    commands.deadline = deadline  # Commands applies this absolute deadline to every child.
    cursor_write_warned = False
    for path in paths[:cfg.get('collection_max_jobs', 20)]:
        if time.monotonic() >= deadline:
            break
        try:
            atomic(cursor_path, {'last_job_id': path.parent.name})
        except OSError:
            if not cursor_write_warned:
                results.append({'state': 'cursor_unavailable', 'reasons': ['Collection cursor could not be saved; jobs are still being processed']})
                cursor_write_warned = True
        try:
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                break
            reserve = min(10, remaining * 0.1)
            job_cfg = dict(cfg, _collection_deadline=min(deadline - reserve, now +
                            cfg.get('collection_job_budget_seconds', 60)))
            results.append(publish_result(job_cfg, path.parent.name, commands))
        except Exception as exc:
            results.append({'job_id': path.parent.name, 'state': 'error', 'error': type(exc).__name__})
    return results


def exit_code(result):
    if isinstance(result, list):
        return int(any(row.get('state') == 'error' for row in result))
    verdict = result.get('verdict')
    if verdict in runner.EXIT_CODES:
        return runner.EXIT_CODES[verdict]
    if result.get('state') in ('failure', 'error'):
        return 1
    if verdict == 'SUPERSEDED' or result.get('state') == 'superseded':
        return 4
    if verdict in ('RUNNING', 'NOT_STARTED') or result.get('state') in (
            'pending', 'busy', 'retired', 'awaiting_issue_mapping', 'awaiting_issue_generation', 'awaiting_comment_reconciliation'):
        return 3
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--config', required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ('run', 'retry', 'collect', 'publish'):
        cmd = commands.add_parser(name, allow_abbrev=False)
        cmd.add_argument('--job-id', required=True)
    recovery = commands.add_parser('recover', allow_abbrev=False)
    recovery.add_argument('--job-id', required=True)
    recovery.add_argument('--runner-job-id')
    commands.add_parser('collect-all', allow_abbrev=False)
    args = parser.parse_args(argv)
    try:
        cfg = bridge.load_config(args.config)
        if args.action == 'run':
            result = run_job(cfg, args.job_id)
        elif args.action == 'retry':
            result = retry_job(cfg, args.job_id)
        elif args.action == 'recover':
            result = recover_job(cfg, args.job_id, args.runner_job_id)
        elif args.action == 'collect':
            result = collect_job(cfg, args.job_id)
        elif args.action == 'publish':
            result = publish_result(cfg, args.job_id)
        else:
            result = collect_all(cfg)
        printable = [summary(row) for row in result] if isinstance(result, list) else summary(result)
        print(json.dumps(printable, ensure_ascii=False))
        return exit_code(result)
    except (JobError, runner.ReviewError, bridge.BridgeError, ValueError, TypeError, KeyError, RecursionError, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({'verdict': 'FAILED', 'error': str(exc)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
