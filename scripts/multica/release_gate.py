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

from github_bridge import RELEASE_VERSION
from review_runner import (POLICY_VERSION, MAX_ATTESTATION_BYTES, ReviewError, load_json,
                           validate_report, git as controlled_git, job_lock, validate_dispatch_receipt, JOB)


class GateError(ValueError):
    """A required release precondition is absent or invalid."""


def git(repo, *args):
    try:
        return controlled_git(repo, *args)
    except ReviewError as exc:
        raise GateError("GIT_VALIDATION_FAILED") from exc


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
    """Hold the collector lifecycle lock and pin both control evidence files."""
    attestation = Path(attestation).absolute()
    reject_symlinks(attestation)
    initial_hash = file_hash(attestation)
    identity = attestation.stat()
    evidence = load_json(attestation, max_bytes=MAX_ATTESTATION_BYTES)
    if type(evidence) is not dict:
        raise GateError("attestation must be a JSON object")
    receipt_path = evidence.get("dispatch_receipt_path")
    if type(receipt_path) is not str or not Path(receipt_path).is_absolute():
        raise GateError("dispatch receipt path required")
    receipt = Path(receipt_path)
    reject_symlinks(receipt)
    job_dir = receipt.parent
    if job_dir != Path(repo).resolve(strict=True).parent:
        raise GateError("dispatcher receipt must share the frozen checkout lifecycle directory")
    with job_lock(job_dir) as locked:
        if not locked:
            raise GateError("review lifecycle is busy; retry validation")
        reject_symlinks(attestation)
        if file_hash(attestation) != initial_hash:
            raise GateError("attestation changed before lifecycle lock")
        result = _validate_locked(repo, attestation, base_sha, head_sha)
        reject_symlinks(attestation)
        final_identity = attestation.stat()
        if ((identity.st_dev, identity.st_ino, identity.st_size, identity.st_mtime_ns)
                != (final_identity.st_dev, final_identity.st_ino, final_identity.st_size, final_identity.st_mtime_ns)
                or file_hash(attestation) != initial_hash):
            raise GateError("attestation changed during validation")
        return result


def _validate_locked(repo, attestation, base_sha, head_sha):
    """Fail closed; return an evidence summary, not authorization to publish."""
    repo = Path(repo).resolve(strict=True)
    if Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
        raise GateError("--repo must name the repository root")
    full_sha(base_sha, "base_sha")
    full_sha(head_sha, "head_sha")
    evidence = load_json(Path(attestation), max_bytes=MAX_ATTESTATION_BYTES)
    if not isinstance(evidence, dict):
        raise GateError("attestation must be a JSON object")
    if type(evidence.get("schema_version")) is not int or evidence["schema_version"] != 1:
        raise GateError("unsupported attestation schema")
    if type(evidence.get("version")) is not str or not RELEASE_VERSION.fullmatch(evidence["version"]):
        raise GateError("a valid reviewed release version is required")
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
    outcome = evidence.get("dispatch_result")
    if (type(outcome) is not dict or type(outcome.get("exit_code")) is not int
            or outcome["exit_code"] != 0 or outcome.get("started") is not True):
        raise GateError("successful dispatcher completion receipt required")
    receipt_path = evidence.get("dispatch_receipt_path")
    if type(receipt_path) is not str or not Path(receipt_path).is_absolute():
        raise GateError("dispatch receipt path required")
    validate_dispatch_receipt(outcome, evidence.get("job_id"), evidence.get("dispatch_request_sha256"))
    full_sha(evidence.get("dispatch_receipt_sha256"), "dispatch_receipt_sha256", 64)
    reject_symlinks(Path(receipt_path))
    receipt_identity = Path(receipt_path).stat()
    if (load_json(Path(receipt_path)) != outcome
            or file_hash(Path(receipt_path)) != evidence.get("dispatch_receipt_sha256")
            or outcome.get("request_sha256") != evidence.get("dispatch_request_sha256")
            or outcome.get("job_id") != evidence.get("job_id")):
        raise GateError("dispatcher receipt does not match reviewed job")
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
        try:
            path = path.resolve(strict=True)
        except FileNotFoundError as exc:
            raise GateError("missing artifact: " + name) from exc
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
        len(set(models)) != len(models) or "codex" not in models or not {"grok", "claude"}.intersection(models)
        or not set(models).issubset({"codex", "grok", "claude", "agy"})
    ):
        raise GateError("release review must use codex plus grok or claude")
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
    reject_symlinks(Path(receipt_path))
    receipt_final = Path(receipt_path).stat()
    if ((receipt_identity.st_dev, receipt_identity.st_ino, receipt_identity.st_size, receipt_identity.st_mtime_ns)
            != (receipt_final.st_dev, receipt_final.st_ino, receipt_final.st_size, receipt_final.st_mtime_ns)
            or file_hash(Path(receipt_path)) != evidence["dispatch_receipt_sha256"]
            or load_json(Path(receipt_path)) != outcome):
        raise GateError("dispatcher receipt changed during validation")
    return {"status": "STATIC_REVIEW_VERIFIED", "repo": str(repo), "base_sha": base_sha,
            "head_sha": head_sha, "artifacts_verified": len(seen), "published": False,
            "version": evidence.get("version")}


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
    if args.version and not RELEASE_VERSION.fullmatch(args.version):
        parser.error("invalid --version")
    try:
        result = validate(args.repo, args.attestation, args.base_sha, args.head_sha)
        if args.action == "plan":
            if result["version"] != args.version:
                raise GateError("packaging version differs from reviewed release version")
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
