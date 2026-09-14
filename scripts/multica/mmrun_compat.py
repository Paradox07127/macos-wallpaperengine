#!/usr/bin/env python3
"""Create a narrow local mmrun copy for current Grok JSON transport compatibility.

Never edits the installed mmrun and never invokes a model. The generated copy
preserves all sandbox, tool, permission and provider flags. Its only changes are
fresh Grok session IDs per attempt, split stdout/stderr, and JSON normalization.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import sys


VERSION = "mmrun-grok-transport-v1"
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
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
            raise CompatibilityError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def constant(value):
    raise CompatibilityError("Non-finite JSON value: " + value)


def normalize(text):
    """Accept one terminal JSON envelope, with optional non-JSON log prefix.

    No arbitrary last-object fallback: the envelope must end the stream and
    contain a structured result or a JSON text result. Logs are never echoed.
    Downstream review_runner still independently validates the report schema.
    """
    if len(text.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise CompatibilityError("Grok stdout exceeds the transport size limit")
    decoder = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=constant)
    # Parse the first envelope once. Searching inside a malformed outer object
    # could discard its error flag and mistake an inner result for success.
    offset = text.find("{")
    prefix = text[:offset] if offset >= 0 else text
    if offset < 0 or "[" in prefix or (prefix.strip() and not prefix.endswith("\n")):
        raise CompatibilityError("Expected a top-level Grok JSON result envelope")
    try:
        envelope, end = decoder.raw_decode(text, offset)
    except (ValueError, CompatibilityError) as exc:
        raise CompatibilityError("Malformed Grok JSON result envelope") from exc
    if not isinstance(envelope, dict) or text[end:].strip():
        raise CompatibilityError("Expected exactly one terminal Grok JSON result envelope")
    if envelope.get("isError") or envelope.get("is_error") or envelope.get("error"):
        raise CompatibilityError("Grok envelope reports an error")
    stops = [envelope[key] for key in ("stopReason", "stop_reason") if key in envelope]
    if len(stops) == 2 and stops[0] != stops[1]:
        raise CompatibilityError("Conflicting completion aliases")
    if any(stop not in ("end_turn", "stop", "completed") for stop in stops):
        raise CompatibilityError("Grok did not report normal end-of-turn completion")
    values = [envelope[key] for key in ("structuredOutput", "structured_output") if key in envelope]
    if len(values) == 2 and values[0] != values[1]:
        raise CompatibilityError("Conflicting structured output aliases")
    report = values[0] if values else envelope.get("text")
    if isinstance(report, str):
        stripped = report.strip()
        if stripped.startswith("```json\n") and stripped.endswith("\n```"):
            stripped = stripped[8:-4]
        try:
            report = json.loads(stripped, object_pairs_hook=pairs, parse_constant=constant)
        except (ValueError, CompatibilityError) as exc:
            raise CompatibilityError("Grok result text is not a single JSON object") from exc
    if not isinstance(report, dict) or not report:
        raise CompatibilityError("Grok structured result is missing or not an object")
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


def prepare(source_path, output_path):
    source_path = Path(source_path).expanduser().resolve()
    output_path = Path(output_path).expanduser().absolute()
    helper = Path(__file__).resolve()
    if output_path.is_symlink() or output_path.resolve() == source_path:
        raise CompatibilityError("Output must be a separate non-symlink local copy")
    source = source_path.read_text()
    rendered = patched_source(source, helper, sys.executable)
    if output_path.exists() and output_path.read_text() != rendered:
        raise CompatibilityError("Output already contains different content; use a new output path")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not output_path.exists():
        with output_path.open("x") as stream:
            stream.write(rendered)
    output_path.chmod(0o700)
    provenance = {"version": VERSION, "source": str(source_path), "source_sha256": file_hash(source_path),
                  "output": str(output_path.resolve()), "output_sha256": file_hash(output_path),
                  "helper": str(helper), "helper_sha256": file_hash(helper), "python": sys.executable,
                  "changes": ["fresh Grok session UUID for every attempt", "separate stdout and stderr",
                              "normalize terminal structuredOutput/structured_output envelope"],
                  "security_flags_changed": False}
    sidecar = output_path.with_name(output_path.name + ".provenance.json")
    if sidecar.is_symlink():
        raise CompatibilityError("Provenance sidecar may not be a symlink")
    sidecar.write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare")
    build.add_argument("--source", required=True)
    build.add_argument("--output", required=True)
    convert = commands.add_parser("normalize")
    convert.add_argument("--input", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(args.source, args.output)
        else:
            path = Path(args.input)
            if path.is_symlink() or path.suffix == ".raw" or ".raw." in path.name:
                raise CompatibilityError("Only a dedicated, non-symlink stdout capture may be normalized")
            if path.stat().st_size > MAX_OUTPUT_BYTES:
                raise CompatibilityError("Grok stdout exceeds the transport size limit")
            result = normalize(path.read_text())
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, UnicodeError, ValueError, CompatibilityError) as exc:
        # Deliberately do not print captured model/log output or credentials.
        print("mmrun compatibility: " + str(exc), file=sys.stderr)
        return 65


if __name__ == "__main__":
    sys.exit(main())
