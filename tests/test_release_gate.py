"""Release gate regression tests; all Git changes stay in temporary fixtures."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOL_DIR = Path(__file__).resolve().parents[1] / "scripts/multica"
sys.path.insert(0, str(TOOL_DIR))
SPEC = importlib.util.spec_from_file_location("release_gate", TOOL_DIR / "release_gate.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/release-app.sh").write_text("#!/bin/sh\nexit 99\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.base = self.git("rev-parse", "HEAD")
        (self.repo / "source.txt").write_text("release\n")
        self.git("add", ".")
        self.git("commit", "-qm", "candidate")
        self.head = self.git("rev-parse", "HEAD")
        self.artifact_root = self.root / "evidence"
        self.artifact_root.mkdir()
        for model in ("codex", "grok"):
            for suffix, value in {"json": json.dumps({"verdict": "approve", "summary": "Reviewed",
                                                       "findings": [], "not_expanded": 0}),
                                  "status": "DONE\n", "meta": "exit=0\n",
                                  "out": "review complete\n"}.items():
                (self.artifact_root / (model + "." + suffix)).write_text(value)
        self.evidence = {
            "schema_version": 1, "kind": "release", "verdict": "PASS", "version": "1.2.3",
            "repo": str(self.repo), "base_sha": self.base, "head_sha": self.head,
            "tree_sha": self.git("rev-parse", "HEAD^{tree}"),
            "artifact_root": str(self.artifact_root),
            "policy": {"version": gate.POLICY_VERSION, "models": ["codex", "grok"],
                       "scope": "release_tree_and_base_delta", "all_models_approve": True,
                       "blocked_severities": ["critical", "major"],
                       "not_expanded_must_equal": 0, "static_only": True},
            "artifacts": [{"path": path.name, "sha256": hashlib.sha256(
                path.read_bytes()).hexdigest()} for path in sorted(self.artifact_root.iterdir())],
        }
        receipt = self.root / "dispatch-result.json"
        outcome = {"schema_version": 1, "started": True, "exit_code": 0, "job_id": "fixture", "request_sha256": "a" * 64}
        receipt.write_text(json.dumps(outcome))
        self.evidence.update(job_id="fixture", dispatch_result=outcome, dispatch_receipt_path=str(receipt),
                             dispatch_request_sha256="a" * 64,
                             dispatch_receipt_sha256=hashlib.sha256(receipt.read_bytes()).hexdigest())
        self.attestation = self.root / "attestation.json"
        self.save()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def save(self):
        self.attestation.write_text(json.dumps(self.evidence))

    def validate(self):
        return gate.validate(self.repo, self.attestation, self.base, self.head)

    def test_valid_release_and_plan_never_execute_packaging(self):
        self.assertEqual(self.validate()["status"], "STATIC_REVIEW_VERIFIED")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = gate.main(["plan", "--repo", str(self.repo), "--attestation",
                              str(self.attestation), "--base-sha", self.base,
                              "--head-sha", self.head, "--sku", "pro", "--version", "1.2.3"])
        self.assertEqual(code, 0)
        result = json.loads(output.getvalue())
        self.assertFalse(result["published"])
        self.assertNotIn("skip", result["manual_packaging_command"])

    def test_wrong_attestation_fields_fail_closed(self):
        original = copy.deepcopy(self.evidence)
        for key, value in [("kind", "pr"), ("verdict", "NEEDS_REVIEW"),
                           ("head_sha", self.base), ("base_sha", self.head),
                           ("head_sha", self.head[:12]), ("repo", "/wrong/repo"),
                           ("tree_sha", self.head), ("schema_version", True),
                           ("artifacts", [])]:
            with self.subTest(key=key, value=value):
                self.evidence = copy.deepcopy(original)
                self.evidence[key] = value
                self.save()
                with self.assertRaises(gate.GateError):
                    self.validate()

    def test_modified_and_untracked_files_block(self):
        for path in (self.repo / "source.txt", self.repo / "untracked.txt"):
            with self.subTest(path=path):
                path.write_text("dirty\n")
                with self.assertRaises(gate.GateError):
                    self.validate()
                if path.name == "source.txt":
                    self.git("restore", "source.txt")
                else:
                    path.unlink()

    def test_moved_head_blocks(self):
        self.git("commit", "--allow-empty", "-qm", "new candidate")
        with self.assertRaises(gate.GateError):
            self.validate()

    def test_tampered_or_missing_artifact_blocks(self):
        path = self.artifact_root / "codex.json"
        path.write_text("tampered")
        with self.assertRaises(gate.GateError):
            self.validate()
        path.unlink()
        with self.assertRaises(gate.GateError):
            self.validate()

    def test_traversal_absolute_and_symlink_artifacts_block(self):
        target = self.artifact_root / "codex.json"
        (self.artifact_root / "linked").symlink_to(target)
        for path in ("../attestation.json", str(target), "linked"):
            with self.subTest(path=path):
                self.evidence["artifacts"][0]["path"] = path
                self.save()
                with self.assertRaises(gate.GateError):
                    self.validate()

    def test_duplicate_manifest_and_json_keys_block(self):
        self.evidence["artifacts"] *= 2
        self.save()
        with self.assertRaises(gate.GateError):
            self.validate()
        self.attestation.write_text('{"kind":"pr","kind":"release"}')
        with self.assertRaises(gate.ReviewError):
            self.validate()

    def test_no_skip_checks_or_dry_run_bypass(self):
        for argument in ("--skip-checks", "--dry-run", "--skip"):
            with self.subTest(argument=argument), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    gate.main(["check", argument])
                self.assertEqual(caught.exception.code, 2)

    def test_forged_pass_with_incomplete_model_run_blocks(self):
        for suffix, content in (("status", "TIMEOUT\n"), ("meta", "exit=1\n"),
                                ("meta", "exit=0\nexit=1\n"), ("out", "")):
            with self.subTest(suffix=suffix, content=content):
                path = self.artifact_root / ("grok." + suffix)
                original = path.read_text()
                path.write_text(content)
                for record in self.evidence["artifacts"]:
                    record["sha256"] = hashlib.sha256(
                        (self.artifact_root / record["path"]).read_bytes()).hexdigest()
                self.save()
                with self.assertRaises(gate.GateError):
                    self.validate()
                path.write_text(original)

    def test_forged_pass_with_unresolved_report_blocks(self):
        path = self.artifact_root / "codex.json"
        original = json.loads(path.read_text())
        for update in ({"verdict": "request_changes"}, {"not_expanded": 1},
                       {"findings": [{"severity": "major", "file": "source.txt", "line": 1,
                                      "quote": "release", "claim": "Unsafe release",
                                      "failure_scenario": "Cannot start", "suggestion": None}]}):
            with self.subTest(update=update):
                path.write_text(json.dumps(dict(original, **update)))
                for record in self.evidence["artifacts"]:
                    record["sha256"] = hashlib.sha256(
                        (self.artifact_root / record["path"]).read_bytes()).hexdigest()
                self.save()
                with self.assertRaises(gate.GateError):
                    self.validate()

    def test_missing_model_or_weaker_scope_blocks(self):
        self.evidence["policy"]["models"] = ["codex"]
        self.save()
        with self.assertRaises(gate.GateError):
            self.validate()
        self.evidence["policy"]["models"] = ["codex", "grok"]
        self.evidence["policy"]["scope"] = "base_to_head_delta"
        self.save()
        with self.assertRaises(gate.GateError):
            self.validate()

    def test_reviewed_version_must_match_packaging_plan(self):
        self.evidence["version"] = "1.2.3"
        self.save()
        with contextlib.redirect_stderr(io.StringIO()):
            code = gate.main(["plan", "--repo", str(self.repo), "--attestation", str(self.attestation),
                              "--base-sha", self.base, "--head-sha", self.head,
                              "--sku", "pro", "--version", "9.9.9"])
        self.assertEqual(code, 1)

    def test_missing_or_nonzero_dispatch_receipt_blocks(self):
        self.evidence.pop("dispatch_result")
        self.save()
        with self.assertRaisesRegex(gate.GateError, "dispatcher"):
            self.validate()

    def test_attestation_uses_aggregate_report_budget(self):
        self.evidence["reports"] = {"fixture": "x" * (8 * 1024 * 1024 + 1)}
        self.save()
        self.assertEqual(self.validate()["status"], "STATIC_REVIEW_VERIFIED")

    def test_receipt_requires_complete_typed_identity_fields(self):
        baseline = copy.deepcopy(self.evidence)
        for key, value in (("schema_version", None), ("schema_version", True),
                           ("job_id", None), ("job_id", ""), ("request_sha256", None),
                           ("request_sha256", "a" * 63)):
            self.evidence = copy.deepcopy(baseline)
            outcome = self.evidence["dispatch_result"]
            if value is None:
                outcome.pop(key, None)
            else:
                outcome[key] = value
            counterpart = "dispatch_request_sha256" if key == "request_sha256" else key
            if key in ("job_id", "request_sha256"):
                self.evidence.pop(counterpart, None)
                if value is not None:
                    self.evidence[counterpart] = value
            receipt = Path(self.evidence["dispatch_receipt_path"])
            receipt.write_text(json.dumps(outcome))
            self.evidence["dispatch_receipt_sha256"] = gate.file_hash(receipt)
            self.save()
            with self.subTest(key=key, value=value), self.assertRaises((gate.GateError, gate.ReviewError)):
                self.validate()

    def test_symlink_ancestor_attestation_is_rejected(self):
        alias = self.root / "redirected"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(gate.GateError, "symlink"):
            gate.validate(self.repo, alias / self.attestation.name, self.base, self.head)

    def test_control_evidence_mutation_during_artifact_validation_blocks(self):
        baseline = copy.deepcopy(self.evidence)
        for mutate in ("attestation", "receipt"):
            self.evidence = copy.deepcopy(baseline)
            receipt = Path(self.evidence["dispatch_receipt_path"])
            receipt.write_text(json.dumps(self.evidence["dispatch_result"]))
            self.save()
            original = gate.file_hash
            changed = False
            def hashing(path):
                nonlocal changed
                if path.parent == self.artifact_root and not changed:
                    changed = True
                    if mutate == "attestation":
                        self.evidence["verdict"] = "FAILED"
                        self.save()
                    else:
                        receipt.write_text("{}")
                return original(path)
            with patch.object(gate, "file_hash", side_effect=hashing):
                with self.subTest(mutate=mutate), self.assertRaises(gate.GateError):
                    self.validate()

    def test_gate_respects_collector_lifecycle_lock(self):
        with gate.job_lock(self.root) as locked:
            self.assertTrue(locked)
            with self.assertRaisesRegex(gate.GateError, "lifecycle is busy"):
                self.validate()

    def test_release_attestation_without_version_blocks(self):
        self.evidence.pop("version")
        self.save()
        with self.assertRaisesRegex(gate.GateError, "version"):
            self.validate()

    def test_claude_can_replace_grok_but_every_listed_model_must_approve(self):
        self.evidence["policy"]["models"] = ["codex", "claude"]
        for artifact in self.evidence["artifacts"]:
            if artifact["path"].startswith("grok."):
                old = self.artifact_root / artifact["path"]
                artifact["path"] = artifact["path"].replace("grok.", "claude.")
                old.rename(self.artifact_root / artifact["path"])
        self.save()
        self.assertEqual(self.validate()["status"], "STATIC_REVIEW_VERIFIED")
        self.evidence["policy"]["models"].append("grok")
        self.save()
        with self.assertRaisesRegex(gate.GateError, "required model evidence missing"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
