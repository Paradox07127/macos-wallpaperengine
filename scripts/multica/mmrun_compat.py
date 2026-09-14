#!/usr/bin/env python3
"""Prepare a separate mmrun copy with strict Grok and read-only Claude adapters.

Never edits the installed mmrun and never invokes a model. The generated copy
preserves the existing providers' sandbox, tool and permission flags. Claude is
available only for static review, with restricted file tools and the same fence.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
import shlex
import stat
import sys
import tempfile


VERSION = "mmrun-provider-transport-v4"
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_SCRIPT_BYTES = 8 * 1024 * 1024
MAX_STDERR_BYTES = 8 * 1024 * 1024
SESSION_ANCHOR = '      sid=$(cat "$rd/grok.session")'
OUTPUT_ANCHOR = '''        "$GROK_BIN" --prompt-file "$rd/prompt.md" -s "$sid" "${args[@]}" > "$rd/grok.raw" 2>&1
      rc=$?
      jq -r 'if .structured_output then (.structured_output|tojson) else (.text // empty) end' "$rd/grok.raw" > "$rd/grok.out" 2>/dev/null
      jq -r '.total_cost_usd // empty' "$rd/grok.raw" > "$rd/grok.cost" 2>/dev/null
      jq -c '.usage // empty' "$rd/grok.raw" > "$rd/grok.usage" 2>/dev/null'''


class CompatibilityError(Exception):
    pass


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise CompatibilityError("Duplicate JSON key")
        result[key] = value
    return result


def constant(value):
    raise CompatibilityError("Non-finite JSON value: " + value)


def normalize(text, provider="grok"):
    """Accept one terminal JSON envelope, with optional non-JSON log prefix.

    No arbitrary last-object fallback: the envelope must end the stream and
    contain a structured result or a JSON text result. Logs are never echoed.
    Downstream review_runner still independently validates the report schema.
    """
    if len(text.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise CompatibilityError("Provider stdout exceeds the transport size limit")
    decoder = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=constant)
    # Parse the first envelope once. Searching inside a malformed outer object
    # could discard its error flag and mistake an inner result for success.
    offset = text.find("{")
    prefix = text[:offset] if offset >= 0 else text
    # Accept only complete, recognized diagnostic lines before the object.
    # An arbitrary prefix could actually be a truncated JSON array/wrapper.
    diagnostics = prefix.rpartition("\n")[0] if "\n" in prefix else ""
    indentation = prefix.rpartition("\n")[2]
    log_line = re.compile(r"(?:\[(?:warn(?:ing)?|info|debug|error|trace)\]|(?:warning|warn|info|debug|error|trace):)\s+[^{}]*", re.I)
    if (offset < 0 or indentation.strip()
            or any(line.strip() and not log_line.fullmatch(line.strip())
                   for line in diagnostics.splitlines())):
        raise CompatibilityError("Expected a top-level provider JSON result envelope")
    try:
        envelope, end = decoder.raw_decode(text, offset)
    except (ValueError, RecursionError, CompatibilityError) as exc:
        raise CompatibilityError("Malformed provider JSON result envelope") from exc
    if not isinstance(envelope, dict) or text[end:].strip():
        raise CompatibilityError("Expected exactly one terminal provider JSON result envelope")
    if envelope.get("isError") or envelope.get("is_error") or envelope.get("error"):
        raise CompatibilityError("Provider envelope reports an error")
    if provider == "claude":
        if (envelope.get("type") != "result" or envelope.get("subtype") != "success"
                or envelope.get("is_error") is not False):
            raise CompatibilityError("Claude did not report a successful terminal result")
    elif provider == "grok":
        stops = [envelope[key] for key in ("stopReason", "stop_reason") if key in envelope]
        if len(stops) == 2 and stops[0] != stops[1]:
            raise CompatibilityError("Conflicting completion aliases")
        if not stops or any(stop not in ("end_turn", "stop", "completed") for stop in stops):
            raise CompatibilityError("Grok did not report normal end-of-turn completion")
    else:
        raise CompatibilityError("Unsupported provider")
    values = [envelope[key] for key in ("structuredOutput", "structured_output") if key in envelope]
    if len(values) == 2 and values[0] != values[1]:
        raise CompatibilityError("Conflicting structured output aliases")
    report = values[0] if values else envelope.get("result" if provider == "claude" else "text")
    if isinstance(report, str):
        stripped = report.strip()
        if stripped.startswith("```json\n") and stripped.endswith("\n```"):
            stripped = stripped[8:-4]
        try:
            report = json.loads(stripped, object_pairs_hook=pairs, parse_constant=constant)
        except (ValueError, RecursionError, CompatibilityError) as exc:
            raise CompatibilityError("Provider result text is not a single JSON object") from exc
    if not isinstance(report, dict) or not report:
        raise CompatibilityError("Provider structured result is missing or not an object")
    result = {"structured_output": report}
    # Keep only known transport metadata; never reproduce logging or thoughts.
    for source, destination in (("usage", "usage"), ("total_cost_usd", "total_cost_usd"),
                                ("totalCostUsd", "total_cost_usd"), ("sessionId", "session_id"),
                                ("session_id", "session_id")):
        if source in envelope:
            if destination in result and result[destination] != envelope[source]:
                raise CompatibilityError("Conflicting transport metadata aliases")
            result[destination] = envelope[source]
    return result


GROK_PREFIX = '      env "${GROK_ENV[@]}" "$SELF" __fence "$w" "$HOME/.grok" "$rd/prompt.md" "$ro" \\\n'
CODEX_CAPTURE = '''      "$CODEX_BIN" exec --json --skip-git-repo-check "${args[@]}" -o "$rd/codex.out" - \\\n        < "$rd/prompt.md" > "$rd/codex.raw" 2>&1'''
AGY_CAPTURE = '''      (cd "$cwd" && "$SELF" __fence "$w" "$HOME/.gemini" "$rd/prompt.md" "$ro" \\\n        "$AGY_BIN" -p "$(cat "$rd/prompt.md")" "${args[@]}") > "$rd/agy.raw" 2>&1'''


def patched_source(source, helper, python):
    for anchor in (SESSION_ANCHOR, OUTPUT_ANCHOR, GROK_PREFIX + OUTPUT_ANCHOR, CODEX_CAPTURE, AGY_CAPTURE):
        if source.count(anchor) != 1:
            raise CompatibilityError("Installed mmrun changed: expected capture patch anchor once; refusing to guess")
    session = '''      sid=$(uuidgen | tr 'A-Z' 'a-z')
      printf '%s\\n' "$sid" > "$rd/grok.session"'''
    normalizer = " ".join(shlex.quote(str(value)) for value in (python, helper))
    output = '''      NORMALIZER capture --stdout "$rd/grok.stdout" --stderr "$rd/grok.raw" -- env "${GROK_ENV[@]}" "$SELF" __fence "$w" "$HOME/.grok" "$rd/prompt.md" "$ro" \\\n        "$GROK_BIN" --prompt-file "$rd/prompt.md" -s "$sid" "${args[@]}"
      rc=$?
      local transport_rc=0
      NORMALIZER normalize --input "$rd/grok.stdout" > "$rd/grok.normalized.json" 2>> "$rd/grok.raw" || transport_rc=$?
      if [ "$rc" -eq 0 ] && [ "$transport_rc" -ne 0 ]; then rc=$transport_rc; fi
      jq -r 'if .structured_output then (.structured_output|tojson) else (.text // empty) end' "$rd/grok.normalized.json" > "$rd/grok.out" 2>/dev/null
      jq -r '.total_cost_usd // empty' "$rd/grok.normalized.json" > "$rd/grok.cost" 2>/dev/null
      jq -c '.usage // empty' "$rd/grok.normalized.json" > "$rd/grok.usage" 2>/dev/null'''
    codex = '''      NORMALIZER capture --stdout "$rd/codex.raw" --stderr "$rd/codex.raw" --stdin "$rd/prompt.md" -- \\\n        "$CODEX_BIN" exec --json --skip-git-repo-check "${args[@]}" -o "$rd/codex.out" -'''
    agy = '''      NORMALIZER capture --stdout "$rd/agy.raw" --stderr "$rd/agy.raw" --cwd "$cwd" -- \\\n        "$SELF" __fence "$w" "$HOME/.gemini" "$rd/prompt.md" "$ro" \\\n        "$AGY_BIN" -p "$(cat "$rd/prompt.md")" "${args[@]}"'''
    return (source.replace(SESSION_ANCHOR, session)
            .replace(GROK_PREFIX + OUTPUT_ANCHOR, output.replace("NORMALIZER", normalizer))
            .replace(CODEX_CAPTURE, codex.replace("NORMALIZER", normalizer))
            .replace(AGY_CAPTURE, agy.replace("NORMALIZER", normalizer)))


def file_hash(path):
    return hashlib.sha256(input_snapshot(path)[0]).hexdigest()


CLAUDE_ANCHORS = {
    "binary": 'CODEX_BIN="${CODEX_BIN:-codex}"',
    "models": 'ALL_MODELS="codex grok agy"',
    "selection": '  local models="codex,grok" wd="$PWD" tag="" gm="" cm="" am="" mode="start" schema="" wt="" rid=""',
    "start": 'case "$m" in codex|grok|agy) ;; *) die "unsupported model: $m ($ALL_MODELS)";; esac',
    "workdir": '  [ -d "$wd" ] || die "workdir not found: $wd"',
    "case": '    agy)\n',
    "run": 'case "$m" in codex|grok|agy) ;; *) die "--model 必须是 $ALL_MODELS 之一";; esac',
}


def add_claude_provider(source, helper, python):
    for name, anchor in CLAUDE_ANCHORS.items():
        if source.count(anchor) != 1:
            raise CompatibilityError("Installed mmrun changed: Claude anchor mismatch: " + name)
    normalizer = " ".join(shlex.quote(str(v)) for v in (python, helper))
    clause = '''    claude)
      [ "$mode" = review ] || { echo "Claude adapter supports static review only" >&2; return 64; }
      local args=(-p --model opus --output-format json --restricted --safe-mode
                  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
                  --tools "Read,Grep,Glob" --permission-mode plan
                  --no-session-persistence --system-prompt-snapshot off)
      if [ -n "$schema" ]; then args+=(--json-schema "$(cat "$schema")"); fi
      NORMALIZER capture --stdout "$rd/claude.stdout" --stderr "$rd/claude.raw" --stdin "$rd/prompt.md" --cwd "$wd" -- \\
        "$SELF" __fence "$ROOT/.no-write" "$HOME/.claude" "$rd/prompt.md" "$wd" "$CLAUDE_BIN" "${args[@]}"
      rc=$?
      local transport_rc=0
      NORMALIZER normalize --provider claude --input "$rd/claude.stdout" > "$rd/claude.normalized.json" 2>> "$rd/claude.raw" || transport_rc=$?
      if [ "$rc" -eq 0 ] && [ "$transport_rc" -ne 0 ]; then rc=$transport_rc; fi
      jq -c '.structured_output' "$rd/claude.normalized.json" > "$rd/claude.out" 2>/dev/null
      jq -r '.total_cost_usd // empty' "$rd/claude.normalized.json" > "$rd/claude.cost" 2>/dev/null
      jq -c '.usage // empty' "$rd/claude.normalized.json" > "$rd/claude.usage" 2>/dev/null
      sid=$(jq -r '.session_id // empty' "$rd/claude.normalized.json" 2>/dev/null)
      ;;
'''.replace("NORMALIZER", normalizer)
    source = source.replace(CLAUDE_ANCHORS["binary"], CLAUDE_ANCHORS["binary"] + '\nCLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"')
    source = source.replace(CLAUDE_ANCHORS["models"], 'ALL_MODELS="codex grok agy claude"')
    source = source.replace(CLAUDE_ANCHORS["start"], CLAUDE_ANCHORS["start"].replace('codex|grok|agy)', 'codex|grok|agy|claude)'))
    source = source.replace(CLAUDE_ANCHORS["workdir"], '''  case ",$models," in *,claude,*) [ "$mode" = review ] || die "Claude adapter supports static review only";; esac
''' + CLAUDE_ANCHORS["workdir"])
    source = source.replace(CLAUDE_ANCHORS["run"], 'case "$m" in codex|grok|agy) ;; *) die "Implementation mode supports codex, grok, agy; Claude is review-only";; esac')
    return source.replace(CLAUDE_ANCHORS["case"], clause + CLAUDE_ANCHORS["case"])


def atomic_text(path, text, mode):
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        # Publish without replacing a destination created by another writer.
        os.link(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def input_snapshot(path, *, max_bytes=MAX_SCRIPT_BYTES):
    initial = path.lstat()
    if not stat.S_ISREG(initial.st_mode) or initial.st_size > max_bytes:
        raise CompatibilityError("Input must be a bounded regular file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > max_bytes:
            raise CompatibilityError("Input must be a bounded regular file")
        data = stream.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise CompatibilityError("Input exceeds size limit")
        after = os.fstat(stream.fileno())
    identity = lambda v: (v.st_dev, v.st_ino, v.st_size, v.st_mtime_ns)
    if identity(before) != identity(after) or identity(after) != identity(path.stat()):
        raise CompatibilityError("Preparation input changed while reading")
    return data, identity(after)


def prepare(source_path, output_path):
    source_path = Path(source_path).expanduser().resolve()
    output_path = Path(output_path).expanduser().absolute()
    if output_path.is_symlink():
        raise CompatibilityError("Output must be a separate non-symlink local copy")
    output_path = output_path.parent.resolve() / output_path.name
    helper = Path(__file__).resolve()
    sidecar = output_path.with_name(output_path.name + ".provenance.json")
    lock_path = output_path.with_name(output_path.name + ".prepare.lock")
    protected = (source_path, helper)
    for destination in (output_path, sidecar, lock_path):
        if destination.is_symlink() or any(destination == item or (
                destination.exists() and destination.samefile(item)) for item in protected):
            raise CompatibilityError("Preparation destination overlaps a protected input")
    missing = []
    directory = output_path.parent
    while not directory.exists():
        missing.append(directory)
        directory = directory.parent
    output_path.parent.mkdir(parents=True, exist_ok=True)
    for directory in reversed(missing):
        parent = os.open(directory.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source_bytes, source_identity = input_snapshot(source_path)
        helper_bytes, helper_identity = input_snapshot(helper)
        rendered = add_claude_provider(patched_source(source_bytes.decode("utf-8"), helper, sys.executable), helper, sys.executable)
        if len(rendered.encode("utf-8")) > MAX_SCRIPT_BYTES:
            raise CompatibilityError("Prepared script exceeds runner input limit")
        provenance = {"version": VERSION, "source": str(source_path),
                      "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
                      "output": str(output_path), "output_sha256": hashlib.sha256(rendered.encode()).hexdigest(),
                      "helper": str(helper), "helper_sha256": hashlib.sha256(helper_bytes).hexdigest(), "python": sys.executable,
                      "changes": ["fresh Grok session UUID for every attempt", "separate stdout and stderr",
                                  "normalize terminal structuredOutput/structured_output envelope",
                                  "static-only Claude Opus with restricted Read/Grep/Glob tools, empty MCP and filesystem fence",
                                  "bounded runtime stdout/stderr capture for every provider"],
                      "added_providers": ["claude"], "security_flags_changed": False,
                      "capture_limits": {"stdout_bytes": MAX_OUTPUT_BYTES, "stderr_bytes": MAX_STDERR_BYTES, "file_bytes": MAX_OUTPUT_BYTES}}
        contents = ((output_path, rendered, 0o700),
                    (sidecar, json.dumps(provenance, indent=2) + "\n", 0o600))
        for path, content, mode in contents:
            if path.is_symlink() or (path.exists() and input_snapshot(path)[0] != content.encode()):
                raise CompatibilityError("Destination already contains different content; use a new output path")
            if path.exists() and stat.S_IMODE(path.stat().st_mode) != mode:
                raise CompatibilityError("Existing destination permissions differ; use a new output path")
        def verify_inputs():
            if (input_snapshot(source_path) != (source_bytes, source_identity)
                    or input_snapshot(helper) != (helper_bytes, helper_identity)):
                raise CompatibilityError("Preparation input changed; use a newly verified copy")
        verify_inputs()
        for path, content, mode in contents:
            if not path.exists():
                atomic_text(path, content, mode)
            if input_snapshot(path)[0] != content.encode():
                raise CompatibilityError("Preparation destination changed during publication")
            verify_inputs()
        for path, content, mode in contents:
            if input_snapshot(path)[0] != content.encode() or stat.S_IMODE(path.stat().st_mode) != mode:
                raise CompatibilityError("Preparation destination changed during publication")
        return provenance


def kill_capture_group(proc):
    """Call only while our child has not been reaped, so its PGID cannot be reused."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin returns EPERM for a zombie-only group. A live leader must
        # never be treated as stopped merely because signalling was denied.
        observed = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if sys.platform != "darwin" or observed is None:
            raise


def capture(argv, stdout_path, stderr_path, *, stdin_path=None, cwd=None,
            stdout_limit=MAX_OUTPUT_BYTES, stderr_limit=MAX_STDERR_BYTES,
            file_limit=MAX_OUTPUT_BYTES, exit_grace=30.0, timeout=3600.0):
    """Bound only captured streams; never cap the provider's existing databases."""
    if not argv or any(type(v) is not int or v <= 0 for v in (stdout_limit, stderr_limit, file_limit)):
        raise CompatibilityError("Invalid capture command or limits")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 86400:
        raise CompatibilityError("Invalid capture timeout")
    deadline = time.monotonic() + timeout
    targets = [Path(stdout_path).absolute(), Path(stderr_path).absolute()]
    protected = [Path(__file__).resolve()]
    if stdin_path is not None:
        protected.append(Path(stdin_path).resolve())
    for path in targets:
        if path.is_symlink() or path.resolve() in protected or any(
                path.exists() and path.samefile(item) for item in protected):
            raise CompatibilityError("Capture destination overlaps protected input")
    target_keys = [str(path.resolve()) for path in targets]
    if target_keys[0] != target_keys[1] and all(path.exists() for path in targets) and targets[0].samefile(targets[1]):
        raise CompatibilityError("Capture destinations alias the same file")
    outputs = {}
    proc = None
    stdin = None
    can_signal = True
    try:
        for path in targets:
            key = str(path.resolve())
            if key not in outputs:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
                stream = os.fdopen(fd, "wb", buffering=0)
                outputs[key] = [stream, 0]
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    raise CompatibilityError("Capture destination must be a regular file")
                os.fchmod(fd, 0o600)
                os.ftruncate(fd, 0)
        if stdin_path:
            initial = Path(stdin_path).lstat()
            if not stat.S_ISREG(initial.st_mode) or initial.st_size > MAX_OUTPUT_BYTES:
                raise CompatibilityError("Capture stdin must be a bounded regular file")
            fd = os.open(stdin_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            stdin = os.fdopen(fd, "rb")
            current = os.fstat(fd)
            if not stat.S_ISREG(current.st_mode) or current.st_size > MAX_OUTPUT_BYTES:
                raise CompatibilityError("Capture stdin must be a bounded regular file")
        proc = subprocess.Popen(argv, cwd=cwd, stdin=stdin if stdin else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True, bufsize=0)
        limits = [stdout_limit, stderr_limit]
        counts = [0, 0]
        exit_seen = None
        with selectors.DefaultSelector() as selector:
            for index, stream in enumerate((proc.stdout, proc.stderr)):
                if stream is None:
                    continue
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, index)
            while selector.get_map() or exit_seen is None:
                if time.monotonic() >= deadline:
                    raise CompatibilityError("PROVIDER_CAPTURE_TIMEOUT")
                for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    index = key.data
                    try:
                        data = os.read(key.fileobj.fileno(), 65536)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not data:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    target = outputs[target_keys[index]]
                    allowed = min(len(data), limits[index] - counts[index], file_limit - target[1])
                    if allowed:
                        view = memoryview(data)[:allowed]
                        while view:
                            written = target[0].write(view)
                            if not written:
                                raise CompatibilityError("Capture write could not progress")
                            view = view[written:]
                        counts[index] += allowed
                        target[1] += allowed
                    if allowed < len(data):
                        raise CompatibilityError("PROVIDER_OUTPUT_LIMIT")
                # Observe without reaping: retaining the child PID prevents a
                # reused, unrelated process group from being signalled during cleanup.
                try:
                    observed = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                except ChildProcessError:
                    can_signal = False
                    raise CompatibilityError("CAPTURE_CHILD_IDENTITY_LOST")
                if observed is not None:
                    if exit_seen is None:
                        exit_seen = time.monotonic()
                    if selector.get_map() and time.monotonic() - exit_seen >= exit_grace:
                        raise CompatibilityError("PROVIDER_DESCENDANT_STREAM_UNKNOWN")
            kill_capture_group(proc)
            code = proc.wait(timeout=10)
            can_signal = False
        for stream, _ in outputs.values():
            os.fsync(stream.fileno())
        return code if code >= 0 else 128 - code
    finally:
        cleanup_error = None
        if proc is not None and can_signal:
            try:
                kill_capture_group(proc)
            except OSError as exc:
                cleanup_error = exc
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired as exc:
                cleanup_error = exc
        if proc is not None:
            for stream in (proc.stdout, proc.stderr):
                if stream and not stream.closed:
                    stream.close()
        if stdin:
            stdin.close()
        for stream, _ in outputs.values():
            stream.close()
        if cleanup_error is not None:
            raise CompatibilityError("CAPTURE_CLEANUP_UNCONFIRMED") from cleanup_error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare", allow_abbrev=False)
    build.add_argument("--source", required=True)
    build.add_argument("--output", required=True)
    convert = commands.add_parser("normalize", allow_abbrev=False)
    convert.add_argument("--input", required=True)
    convert.add_argument("--provider", choices=("grok", "claude"), default="grok")
    bounded = commands.add_parser("capture", allow_abbrev=False)
    bounded.add_argument("--stdout", required=True)
    bounded.add_argument("--stderr", required=True)
    bounded.add_argument("--stdin")
    bounded.add_argument("--cwd")
    bounded.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.command == "capture":
            command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            return capture(command, args.stdout, args.stderr, stdin_path=args.stdin, cwd=args.cwd,
                           timeout=float(os.environ.get("MMRUN_CAPTURE_TIMEOUT", "3600")))
        if args.command == "prepare":
            result = prepare(args.source, args.output)
        else:
            path = Path(args.input)
            if path.is_symlink() or path.suffix == ".raw" or ".raw." in path.name:
                raise CompatibilityError("Only a dedicated, non-symlink stdout capture may be normalized")
            raw, _ = input_snapshot(path, max_bytes=MAX_OUTPUT_BYTES)
            text = raw.decode("utf-8")
            del raw
            result = normalize(text, args.provider)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except subprocess.SubprocessError:
        print("mmrun compatibility: CAPTURE_PROCESS_ERROR", file=sys.stderr)
        return 65
    except (OSError, UnicodeError, ValueError, CompatibilityError) as exc:
        # Deliberately do not print captured model/log output or credentials.
        print("mmrun compatibility: " + str(exc), file=sys.stderr)
        return 65


if __name__ == "__main__":
    sys.exit(main())
