#!/usr/bin/env python3
"""Trusted, detached mmrun dispatcher supervisor; no models or repository code here."""
import os
from pathlib import Path
import subprocess
import sys
import time

from review_runner import (ReviewError, digest, load_json, write_json,
                           validate_execution_provenance, validate_execution_environment, process_identity, require_object)


def supervise(job_dir: Path) -> int:
    request_path = job_dir / 'dispatch-request.json'
    request = require_object(load_json(request_path), "DISPATCH_REQUEST_NOT_OBJECT")
    identity = {'schema_version': 1, 'job_id': job_dir.name,
                'request_sha256': digest(request_path), 'supervisor_pid': os.getpid(),
                'supervisor_identity': process_identity(os.getpid()), 'started': False}
    write_json(job_dir / 'dispatch-identity.json', identity)
    try:
        argv = request['argv']
        if (request['job_id'] != job_dir.name or type(argv) is not list or not argv
                or any(type(v) is not str for v in argv)):
            raise ReviewError('INVALID_DISPATCH_REQUEST')
        validate_execution_provenance(request['provenance'])
        validate_execution_environment(os.environ, request['provenance'])
        if digest(Path(argv[0])) != request['executable_sha256']:
            raise ReviewError('DISPATCH_EXECUTABLE_CHANGED')
        with Path(request['stdin']).open('rb') as stdin, (job_dir / 'dispatch.stdout').open('wb') as stdout, (job_dir / 'dispatch.stderr').open('wb') as stderr:
            identity["spawn_intent"] = True
            write_json(job_dir / 'dispatch-identity.json', identity)
            proc = subprocess.Popen(argv, cwd=request['cwd'], stdin=stdin, stdout=stdout, stderr=stderr,
                                    env=os.environ.copy(), shell=False)
            # Record the irreversible spawn before any fallible identity query.
            # A query or persistence failure must never fabricate started=False.
            identity['started'] = True
            identity['dispatch_pid'] = proc.pid
            try:
                write_json(job_dir / 'dispatch-identity.json', identity)
                child_identity = process_identity(proc.pid)
                if child_identity is None:
                    raise ReviewError('DISPATCH_PROCESS_IDENTITY_UNKNOWN')
                identity['dispatch_identity'] = child_identity
                write_json(job_dir / 'dispatch-identity.json', identity)
            except (OSError, ValueError, KeyError, TypeError, ReviewError):
                # Supplementary identity/persistence failure cannot relinquish
                # our known direct child or invent an unstarted receipt.
                identity['identity_observation_failed'] = True
            while True:
                try:
                    rc = proc.wait()
                    break
                except InterruptedError:
                    continue
        result = dict(identity, exit_code=rc, finished_at=time.time())
    except (OSError, ValueError, KeyError, TypeError, ReviewError):
        # Parent must distinguish a proven spawn failure from ambiguous loss
        # of the supervisor after a child has started.
        if identity['started']:
            return 1
        result = dict(identity, exit_code=127, error='DISPATCH_START_FAILED', finished_at=time.time())
    for attempt in range(3):
        try:
            write_json(job_dir / 'dispatch-result.json', result)
            return 0
        except OSError:
            if attempt == 2:
                raise
            time.sleep(0.05 * (attempt + 1))
    return 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: runner_dispatch.py <job-dir>", file=sys.stderr)
        return 2
    try:
        return supervise(Path(argv[0]).resolve())
    except (ReviewError, OSError, KeyError, TypeError, ValueError):
        print("DISPATCH_REQUEST_INVALID", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
