#!/usr/bin/env python3
"""One supervised intake/collection tick; launchd supplies scheduling."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

import github_bridge


def run_stage(command, timeout, label, capture_output=False):
    """A failed/timed-out stage must not strand completed review collection."""
    try:
        return subprocess.run(command, text=True, capture_output=capture_output,
                              timeout=timeout, shell=False)
    except (subprocess.TimeoutExpired, OSError) as exc:
        # CLI diagnostics can contain credentials or user source data. Log only
        # the failing stage and exception category, never command output.
        print(f'{label} failed: {type(exc).__name__}', file=sys.stderr, flush=True)
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--config', required=True)
    args = parser.parse_args(argv)
    try:
        cfg = github_bridge.load_config(args.config)
    except (github_bridge.BridgeError, ValueError, KeyError, TypeError, OSError) as exc:
        print(f'Bridge configuration rejected: {type(exc).__name__}', file=sys.stderr)
        return 1
    enabled = cfg.get('enabled', False)
    if type(enabled) is not bool:
        print('Invalid enabled setting: expected a JSON boolean', file=sys.stderr)
        return 1
    if not enabled:
        print('Multica bridge paused by local config')
        return 0
    Path(cfg['state_path']).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    cli = [cfg['multica_path'], '--profile', cfg['multica_profile']]
    status = run_stage(cli + ['daemon', 'status', '--output', 'json'], 20,
                       'Daemon status', capture_output=True)
    state = None
    try:
        if status is not None and status.returncode == 0:
            payload = json.loads(status.stdout)
            state = payload.get('status') if isinstance(payload, dict) else None
    except (json.JSONDecodeError, TypeError):
        pass
    failed = state not in ('running', 'stopped')
    if state == 'stopped':
        started = run_stage(cli + ['--workspace-id', cfg['workspace_id'], 'daemon', 'start',
                                   '--max-concurrent-tasks', '2', '--agent-timeout', '90m',
                                   '--no-auto-update', '--workspaces-root', cfg['workspaces_root']],
                            40, 'Daemon start')
        failed = started is None or started.returncode != 0
    elif state != 'running':
        # Unknown health is not proof the daemon stopped. Avoid starting a
        # second process, but still attempt intake and collection independently.
        print('Daemon status unavailable; startup skipped for this tick', file=sys.stderr, flush=True)
    print(datetime.datetime.now(datetime.timezone.utc).isoformat(), flush=True)
    location = Path(__file__).resolve().parent
    python = cfg.get('python_path', sys.executable)
    polled = run_stage([python, str(location / 'github_bridge.py'),
                        '--config', args.config, 'poll', '--once'], 300, 'Intake poll')
    # Existing completed reviews must still be collected if intake has a transient failure.
    collected = run_stage([python, str(location / 'executor.py'),
                           '--config', args.config, 'collect-all'], 300, 'Review collection')
    return int(failed or polled is None or polled.returncode != 0
               or collected is None or collected.returncode != 0)


if __name__ == '__main__':
    raise SystemExit(main())
