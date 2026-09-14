#!/usr/bin/env python3
"""Trusted, detached mmrun dispatcher supervisor; no models or repository code here."""
import os
from pathlib import Path
import subprocess
import sys
import time

from review_runner import ReviewError, digest, load_json, write_json


def supervise(job_dir: Path) -> int:
    request_path = job_dir / 'dispatch-request.json'
    request = load_json(request_path)
    identity = {'schema_version': 1, 'job_id': job_dir.name,
                'request_sha256': digest(request_path), 'supervisor_pid': os.getpid(),
                'started': False}
    write_json(job_dir / 'dispatch-identity.json', identity)
    try:
        argv = request['argv']
        if (request['job_id'] != job_dir.name or type(argv) is not list or not argv
                or any(type(v) is not str for v in argv)):
            raise ReviewError('INVALID_DISPATCH_REQUEST')
        if digest(Path(argv[0])) != request['executable_sha256']:
            raise ReviewError('DISPATCH_EXECUTABLE_CHANGED')
        with Path(request['stdin']).open('rb') as stdin, (job_dir / 'dispatch.stdout').open('wb') as stdout, (job_dir / 'dispatch.stderr').open('wb') as stderr:
            proc = subprocess.Popen(argv, cwd=request['cwd'], stdin=stdin, stdout=stdout, stderr=stderr,
                                    env=os.environ.copy(), shell=False)
            identity.update(started=True, dispatch_pid=proc.pid)
            write_json(job_dir / 'dispatch-identity.json', identity)
            rc = proc.wait()
        result = dict(identity, exit_code=rc, finished_at=time.time())
    except (OSError, ValueError, KeyError, TypeError, ReviewError):
        # Parent must distinguish a proven spawn failure from ambiguous loss
        # of the supervisor after a child has started.
        if identity['started']:
            return 1
        result = dict(identity, exit_code=127, error='DISPATCH_START_FAILED', finished_at=time.time())
    write_json(job_dir / 'dispatch-result.json', result)
    return 0


if __name__ == '__main__':
    sys.exit(supervise(Path(sys.argv[1]).resolve()))
