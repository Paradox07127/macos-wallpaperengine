#!/usr/bin/env python3
"""Validate static review evidence and print a packaging plan; never publish."""

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

from review_runner import POLICY_VERSION, ReviewError, load_json, validate_report


class GateError(ValueError):
    """A required release precondition is absent or invalid."""


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False, timeout=30
    )
    if result.returncode:
        raise GateError("git validation failed: " + " ".join(args))
    return result.stdout.strip()


def full_sha(value, name, length=40):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{%d}" % length, value):
        raise GateError(name + " must be a full lowercase SHA")
    return value


def reject_symlinks(path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise GateError("symlink evidence paths are not allowed: " + str(path))


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(repo, attestation, base_sha, head_sha):
    """Fail closed; return an evidence summary, not authorization to publish."""
    repo = Path(repo).resolve(strict=True)
    if Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
        raise GateError("--repo must name the repository root")
    full_sha(base_sha, "base_sha")
    full_sha(head_sha, "head_sha")
    evidence = load_json(Path(attestation))
    if not isinstance(evidence, dict):
        raise GateError("attestation must be a JSON object")
    if type(evidence.get("schema_version")) is not int or evidence["schema_version"] != 1:
        raise GateError("unsupported attestation schema")
    if evidence.get("kind") != "release" or evidence.get("verdict") != "PASS":
        raise GateError("a release PASS attestation is required")
    if evidence.get("repo") != str(repo):
        raise GateError("attestation repository does not match")
    for name, expected in (("base_sha", base_sha), ("head_sha", head_sha)):
        if full_sha(evidence.get(name), name) != expected:
            raise GateError("attestation " + name + " does not match requested revision")
    full_sha(evidence.get("tree_sha"), "tree_sha")
    if git(repo, "rev-parse", "HEAD") != head_sha:
        raise GateError("HEAD moved since review")
    if git(repo, "rev-parse", base_sha + "^{commit}") != base_sha:
        raise GateError("base_sha is not a commit")
    git(repo, "merge-base", "--is-ancestor", base_sha, head_sha)
    if git(repo, "rev-parse", "HEAD^{tree}") != evidence["tree_sha"]:
        raise GateError("reviewed tree does not match HEAD")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"):
        raise GateError("worktree must be clean, including untracked files and submodules")
    root_value = evidence.get("artifact_root")
    if not isinstance(root_value, str) or not Path(root_value).is_absolute():
        raise GateError("artifact_root must be an absolute path")
    root = Path(root_value)
    reject_symlinks(root)
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise GateError("artifact_root is not a directory")
    artifacts = evidence.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise GateError("nonempty artifact manifest required")
    seen = set()
    verified = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise GateError("invalid artifact record")
        name = artifact.get("path")
        if not isinstance(name, str) or not name or "\x00" in name:
            raise GateError("invalid artifact path")
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise GateError("artifact path must stay inside artifact_root")
        path = root / relative
        reject_symlinks(path)
        path = path.resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file() or path in seen:
            raise GateError("artifact must be a unique regular file inside artifact_root")
        seen.add(path)
        expected_hash = full_sha(artifact.get("sha256"), "artifact sha256", 64)
        if file_hash(path) != expected_hash:
            raise GateError("artifact hash mismatch: " + name)
        verified[name] = path
    policy = evidence.get("policy")
    if not isinstance(policy, dict) or policy.get("version") != POLICY_VERSION:
        raise GateError("unsupported review policy version")
    if (policy.get("scope") != "release_tree_and_base_delta"
            or policy.get("all_models_approve") is not True
            or policy.get("blocked_severities") != ["critical", "major"]
            or type(policy.get("not_expanded_must_equal")) is not int
            or policy["not_expanded_must_equal"] != 0 or policy.get("static_only") is not True):
        raise GateError("attestation does not use the full static release review policy")
    models = policy.get("models")
    if not isinstance(models, list) or any(not isinstance(m, str) for m in models) or (
        len(set(models)) != len(models) or not {"codex", "grok"}.issubset(models)
        or not set(models).issubset({"codex", "grok", "agy"})
    ):
        raise GateError("release review must use the codex + grok model policy")
    for model in models:
        for suffix in ("json", "status", "meta", "out"):
            if model + "." + suffix not in verified:
                raise GateError("required model evidence missing: " + model + "." + suffix)
        if verified[model + ".status"].read_text().strip() != "DONE":
            raise GateError("model review is not DONE: " + model)
        exits = [line.partition("=")[2].strip() for line in
                 verified[model + ".meta"].read_text().splitlines()
                 if line.partition("=")[0].strip() == "exit"]
        if exits != ["0"]:
            raise GateError("model review must have one successful exit: " + model)
        if not verified[model + ".out"].read_text().strip():
            raise GateError("model output is empty: " + model)
        report = validate_report(load_json(verified[model + ".json"]))
        if report["verdict"] != "approve" or report["not_expanded"] != 0 or any(
            finding["severity"] in ("critical", "major") for finding in report["findings"]
        ):
            raise GateError("model review requires human resolution: " + model)
    for artifact in artifacts:
        reject_symlinks(verified[artifact["path"]])
        if file_hash(verified[artifact["path"]]) != artifact["sha256"]:
            raise GateError("evidence changed during validation")
    # Recheck Git after hashing evidence, so ordinary concurrent edits fail closed.
    if git(repo, "rev-parse", "HEAD") != head_sha or git(
        repo, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"
    ):
        raise GateError("repository changed while validating evidence")
    return {"status": "STATIC_REVIEW_VERIFIED", "repo": str(repo), "base_sha": base_sha,
            "head_sha": head_sha, "artifacts_verified": len(seen), "published": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("action", choices=("check", "plan"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--attestation", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--sku", choices=("lite", "pro"))
    parser.add_argument("--version")
    args = parser.parse_args(argv)
    if args.action == "plan" and (not args.sku or not args.version):
        parser.error("plan requires --sku and --version")
    if args.version and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?", args.version):
        parser.error("invalid --version")
    try:
        result = validate(args.repo, args.attestation, args.base_sha, args.head_sha)
        if args.action == "plan":
            script = Path(result["repo"]) / "scripts/release-app.sh"
            if not script.is_file():
                raise GateError("existing release-app.sh is missing")
            result["manual_packaging_command"] = shlex.join(
                [str(script), "--sku", args.sku, "--version", args.version]
            )
            result["remaining"] = ["Run existing release checks and packaging manually",
                                   "Verify and archive built assets and review evidence",
                                   "Obtain human approval for final publication"]
        print(json.dumps(result, indent=2))
        return 0
    except (GateError, ReviewError, OSError, ValueError, TypeError, subprocess.TimeoutExpired) as error:
        print("RELEASE_GATE_BLOCKED: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
