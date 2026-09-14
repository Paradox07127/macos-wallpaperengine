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
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile


VERSION = "mmrun-provider-transport-v3"
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_SCRIPT_BYTES = 16 * 1024 * 1024
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
    except (ValueError, CompatibilityError) as exc:
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
        except (ValueError, CompatibilityError) as exc:
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


def patched_source(source, helper, python):
    for anchor in (SESSION_ANCHOR, OUTPUT_ANCHOR):
        if source.count(anchor) != 1:
            raise CompatibilityError("Installed mmrun changed: expected Grok patch anchor once; refusing to guess")
    session = '''      sid=$(uuidgen | tr 'A-Z' 'a-z')
      printf '%s\\n' "$sid" > "$rd/grok.session"'''
    normalizer = " ".join(shlex.quote(str(value)) for value in (python, helper))
    output = '''        "$GROK_BIN" --prompt-file "$rd/prompt.md" -s "$sid" "${args[@]}" > "$rd/grok.stdout" 2> "$rd/grok.raw"
      rc=$?
      local transport_rc=0
      NORMALIZER normalize --input "$rd/grok.stdout" > "$rd/grok.normalized.json" 2>> "$rd/grok.raw" || transport_rc=$?
      if [ "$rc" -eq 0 ] && [ "$transport_rc" -ne 0 ]; then rc=$transport_rc; fi
      jq -r 'if .structured_output then (.structured_output|tojson) else (.text // empty) end' "$rd/grok.normalized.json" > "$rd/grok.out" 2>/dev/null
      jq -r '.total_cost_usd // empty' "$rd/grok.normalized.json" > "$rd/grok.cost" 2>/dev/null
      jq -c '.usage // empty' "$rd/grok.normalized.json" > "$rd/grok.usage" 2>/dev/null'''
    # Arguments before the output redirection (including __fence) remain verbatim.
    return source.replace(SESSION_ANCHOR, session).replace(OUTPUT_ANCHOR, output.replace("NORMALIZER", normalizer))


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


CLAUDE_ANCHORS = {
    "binary": 'CODEX_BIN="${CODEX_BIN:-codex}"',
    "models": 'ALL_MODELS="codex grok agy"',
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
      (cd "$wd" && "$SELF" __fence "$ROOT/.no-write" "$HOME/.claude" "$rd/prompt.md" "$wd" \\
        "$CLAUDE_BIN" "${args[@]}" < "$rd/prompt.md") > "$rd/claude.stdout" 2> "$rd/claude.raw"
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
        provenance = {"version": VERSION, "source": str(source_path),
                      "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
                      "output": str(output_path), "output_sha256": hashlib.sha256(rendered.encode()).hexdigest(),
                      "helper": str(helper), "helper_sha256": hashlib.sha256(helper_bytes).hexdigest(), "python": sys.executable,
                      "changes": ["fresh Grok session UUID for every attempt", "separate stdout and stderr",
                                  "normalize terminal structuredOutput/structured_output envelope",
                                  "static-only Claude Opus with restricted Read/Grep/Glob tools, empty MCP and filesystem fence"],
                      "added_providers": ["claude"], "security_flags_changed": False}
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare", allow_abbrev=False)
    build.add_argument("--source", required=True)
    build.add_argument("--output", required=True)
    convert = commands.add_parser("normalize", allow_abbrev=False)
    convert.add_argument("--input", required=True)
    convert.add_argument("--provider", choices=("grok", "claude"), default="grok")
    args = parser.parse_args(argv)
    try:
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
    except (OSError, UnicodeError, ValueError, CompatibilityError) as exc:
        # Deliberately do not print captured model/log output or credentials.
        print("mmrun compatibility: " + str(exc), file=sys.stderr)
        return 65


if __name__ == "__main__":
    sys.exit(main())
