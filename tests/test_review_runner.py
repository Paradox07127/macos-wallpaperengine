"""Offline tests use temporary Git repos and local fixture subprocesses; no real models, daemon, or network."""

import argparse
import copy
import contextlib
import sys
import time
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location(
    "review_runner", Path(__file__).resolve().parents[1] / "scripts/multica/review_runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

BASE = "a" * 40
HEAD = "b" * 40
TREE = "c" * 40
RUN_ID = "20260914-010203-abcd"


def report():
    return {"verdict": "approve", "summary": "No blocking static findings.", "findings": [], "not_expanded": 0}


def finding(severity="major"):
    return {"severity": severity, "file": "code.py", "line": 3, "quote": "return x[0]",
            "claim": "Empty input is indexed.", "failure_scenario": "An empty list raises IndexError.", "suggestion": None}


def fixture_provenance(root, executable, models=None):
    root.mkdir(parents=True, exist_ok=True)
    models = ["codex", "grok"] if models is None else models
    inputs = {}
    for name in ("schema", "fence", "notes", "codex_profile", "codex_profile_snapshot"):
        path = root / ("input-" + name)
        path.write_text("trusted fixture " + name)
        inputs[name] = {"path": str(path), "sha256": runner.digest(path)}
    helper = Path(runner.__file__).with_name("runner_dispatch.py")
    return {"mmrun_kind": "upstream", "mmrun_path": str(executable),
            "mmrun_sha256": runner.digest(executable), "mmrun_home": str(root / "mmruns"),
            "session": "fixture", "models": models, "input_files": inputs,
            "dispatch_helper": str(helper), "dispatch_helper_sha256": runner.digest(helper),
            "review_runner_path": str(Path(runner.__file__).resolve()),
            "review_runner_sha256": runner.digest(Path(runner.__file__).resolve()),
            "codex_home": str(root), "mmrun_d_snapshot": str(root)}


class ReportSchemaTests(unittest.TestCase):
    def test_valid_report(self):
        self.assertEqual(runner.validate_report(report())["verdict"], "approve")

    def test_invalid_shapes_fail_closed(self):
        cases = []
        for key in report():
            case = report()
            del case[key]
            cases.append(case)
        cases.extend([dict(report(), extra=True), dict(report(), not_expanded=True),
                      dict(report(), not_expanded=-1), dict(report(), verdict="PASS"),
                      dict(report(), summary=""), dict(report(), findings={})])
        for case in cases:
            with self.subTest(case=case), self.assertRaises(runner.ReviewError):
                runner.validate_report(case)

    def test_finding_requires_evidence_and_typed_line(self):
        for field, value in (("line", True), ("line", 0), ("quote", ""), ("suggestion", 7), ("severity", "high")):
            case = report()
            case["findings"] = [dict(finding(), **{field: value})]
            with self.subTest(field=field), self.assertRaises(runner.ReviewError):
                runner.validate_report(case)

    def test_duplicate_keys_and_nan_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "report.json"
            for text in ('{"verdict":"approve","verdict":"request_changes"}', '{"x":NaN}'):
                path.write_text(text)
                with self.assertRaises(runner.ReviewError):
                    runner.load_json(path)

    def test_raw_streams_never_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "codex.raw"
            path.write_text("not evidence")
            with self.assertRaises(runner.ReviewError):
                runner.digest(path)


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.job = self.root / "reviews/job-1"
        self.job.mkdir(parents=True)
        self.frozen = self.job / "frozen"
        self.frozen.mkdir()
        self.artifacts = self.root / "mmruns" / RUN_ID
        self.artifacts.mkdir(parents=True)
        self.executable = self.root / "mmrun-never-executed"
        self.executable.write_text("mocked mmrun fixture")
        self.manifest = {"schema_version": 1, "job_id": "job-1", "kind": "pr", "repo": str(self.frozen), "source_repo": str(self.root / "repo"),
                         "base_sha": BASE, "head_sha": HEAD, "merge_base_sha": BASE, "tree_sha": TREE, "frozen_checkout": str(self.frozen),
                         "policy": runner.review_policy("pr", ["codex", "grok"]),
                         "provenance": {"mmrun_home": str(self.root / "mmruns"), "session": "multica-job-1",
                                        "mmrun_kind": "upstream", "mmrun_path": str(self.executable), "mmrun_sha256": runner.digest(self.executable)},
                         "mmrun_run_id": RUN_ID}
        self.manifest["provenance"] = dict(fixture_provenance(self.root, self.executable),
                                           session="multica-job-1", mmrun_home=str(self.root / "mmruns"))
        helper = Path(runner.__file__).with_name("runner_dispatch.py")
        self.manifest["provenance"].update(dispatch_helper=str(helper), dispatch_helper_sha256=runner.digest(helper))
        runner.write_json(self.job / "dispatch-request.json", {"schema_version": 1, "job_id": "job-1",
            "argv": [str(self.executable)], "executable_sha256": self.manifest["provenance"]["mmrun_sha256"],
            "provenance": self.manifest["provenance"], "candidate": runner.candidate_identity(self.manifest)})
        self.manifest["dispatch_request_sha256"] = runner.digest(self.job / "dispatch-request.json")
        self.outcome = {"schema_version": 1, "job_id": "job-1", "started": True, "exit_code": 0,
                        "request_sha256": self.manifest["dispatch_request_sha256"]}
        runner.write_json(self.job / "dispatch-result.json", self.outcome)
        runner.write_json(self.job / "manifest.json", self.manifest)
        (self.artifacts / "run.meta").write_text(
            f"runid={RUN_ID}\nmode=review\nworkdir={self.frozen}\nmodels=codex,grok\nsession=multica-job-1\n")
        for model in ("codex", "grok"):
            (self.artifacts / f"{model}.status").write_text("DONE\n")
            (self.artifacts / f"{model}.meta").write_text("exit=0\nattempts=1\n")
            (self.artifacts / f"{model}.out").write_text("rendered output\n")
            runner.write_json(self.artifacts / f"{model}.json", report())
        # Even an unreadable/non-UTF8 raw stream must be irrelevant.
        (self.artifacts / "codex.raw").write_bytes(b"\xff\x00\xfe")
        self.git = patch.object(runner, "git", side_effect=self.git_reply).start()
        self.addCleanup(patch.stopall)

    def git_reply(self, repo, *args):
        if args[:2] == ("rev-parse", "--verify"):
            return args[2].split("^")[0]
        if args[0] == "merge-base":
            return BASE
        if args == ("rev-parse", "HEAD"):
            return HEAD
        if args[0] == "rev-parse" and args[-1].endswith("^{tree}"):
            return TREE
        if args[0] in ("status", "ls-files"):
            return ""
        raise AssertionError(args)

    def test_all_approve_pass_with_artifact_hashes(self):
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["artifact_root"], str(self.artifacts))
        self.assertEqual(len(result["artifacts"]), 9)
        self.assertFalse(any("raw" in entry["path"] for entry in result["artifacts"]))
        self.assertEqual(result["head_sha"], HEAD)
        self.assertEqual(runner.load_json(self.job / "attestation.json")["verdict"], "PASS")

    def test_request_changes_done_does_not_pass(self):
        runner.write_json(self.artifacts / "grok.json", dict(report(), verdict="request_changes"))
        self.assertEqual(runner.collect(self.job)["verdict"], "NEEDS_REVIEW")

    def test_blocking_findings_override_approve(self):
        for severity in ("critical", "major"):
            # Each severity is an independent synthetic attempt.
            (self.job / "terminal-evidence.json").unlink(missing_ok=True)
            runner.write_json(self.job / "manifest.json", self.manifest)
            runner.write_json(self.artifacts / "codex.json", dict(report(), findings=[finding(severity)]))
            result = runner.collect(self.job)
            self.assertEqual(result["verdict"], "NEEDS_REVIEW")
            self.assertEqual(result["findings"][0]["model"], "codex")

    def test_unexpanded_findings_do_not_pass(self):
        runner.write_json(self.artifacts / "grok.json", dict(report(), not_expanded=1))
        self.assertEqual(runner.collect(self.job)["verdict"], "NEEDS_REVIEW")

    def test_minor_findings_remain_visible_on_pass(self):
        runner.write_json(self.artifacts / "grok.json", dict(report(), findings=[finding("minor")]))
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(len(result["findings"]), 1)

    def test_normalized_transport_is_hashed_when_present(self):
        runner.write_json(self.artifacts / "grok.normalized.json", {"structured_output": report()})
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "PASS")
        self.assertIn("grok.normalized.json", [item["path"] for item in result["artifacts"]])

    def test_malformed_json_does_not_fall_back_to_text(self):
        (self.artifacts / "codex.json").write_text("```json\n{}\n```")
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_done_without_report_fails(self):
        (self.artifacts / "codex.json").unlink()
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_running_preserves_job(self):
        (self.artifacts / "codex.status").write_text("RUNNING\n")
        with patch.object(runner.subprocess, "run", return_value=Mock(returncode=0)) as call:
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
        self.assertEqual(call.call_args.args[0], [str(self.executable), "status", RUN_ID])
        self.assertEqual(call.call_args.kwargs["env"]["MMRUN_HOME"], str(self.artifacts.parent))
        self.assertTrue(self.frozen.exists())
        self.assertTrue((self.artifacts / "codex.status").exists())

    def test_stale_and_failed_status_fail(self):
        for status in ("STALE", "FAIL:0", "FAIL:1", "UNKNOWN"):
            (self.artifacts / "codex.status").write_text(status)
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_successful_status_with_nonzero_exit_fails(self):
        (self.artifacts / "codex.meta").write_text("exit=1\n")
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_mismatched_run_or_session_fails(self):
        path = self.artifacts / "run.meta"
        path.write_text(path.read_text().replace("multica-job-1", "multica-other"))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_changed_head_fails(self):
        original = self.git_reply
        self.git.side_effect = lambda repo, *args: "d" * 40 if args == ("rev-parse", "HEAD") else original(repo, *args)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_recorded_merge_base_mismatch_fails(self):
        self.manifest["merge_base_sha"] = "e" * 40
        runner.write_json(self.job / "manifest.json", self.manifest)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_pr_with_advanced_base_tip_passes_with_explicit_merge_base(self):
        # A→F(feature), A→B(main): base=B, head=F, recorded merge-base=A.
        ancestor = "e" * 40
        self.manifest["merge_base_sha"] = ancestor
        runner.write_json(self.job / "manifest.json", self.manifest)
        original = self.git_reply
        self.git.side_effect = lambda repo, *args: ancestor if args[0] == "merge-base" else original(repo, *args)
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["base_sha"], BASE)
        self.assertEqual(result["merge_base_sha"], ancestor)

    def test_release_with_advanced_base_tip_still_fails(self):
        ancestor = "e" * 40
        self.manifest.update(kind="release", version="1.2.3", merge_base_sha=ancestor)
        self.manifest["policy"] = runner.review_policy("release", ["codex", "grok"])
        runner.write_json(self.job / "manifest.json", self.manifest)
        original = self.git_reply
        self.git.side_effect = lambda repo, *args: ancestor if args[0] == "merge-base" else original(repo, *args)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_dirty_and_ignored_files_fail(self):
        original = self.git_reply
        for kind in ("status", "ls-files"):
            self.git.side_effect = lambda repo, *args: "bad.py" if args[0] == kind else original(repo, *args)
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_symlink_artifact_fails(self):
        path = self.artifacts / "codex.json"
        saved = self.root / "other.json"
        path.rename(saved)
        path.symlink_to(saved)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_collect_recovers_explicit_run_id_after_dispatch_timeout(self):
        self.manifest["mmrun_run_id"] = None
        runner.write_json(self.job / "manifest.json", self.manifest)
        (self.job / "dispatch.stdout").write_text(f"RUN {RUN_ID}  models=codex,grok mode=review\n")
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")

    def test_complete_policy_and_schema_types_are_required(self):
        changes = [{"all_models_approve": False}, {"static_only": 1}, {"not_expanded_must_equal": False},
                   {"scope": "changed_lines"}, {"blocked_severities": []}, {"extra": True}, {"version": "old"}]
        for change in changes:
            with self.subTest(change=change):
                manifest = copy.deepcopy(self.manifest)
                manifest["policy"].update(change)
                runner.write_json(self.job / "manifest.json", manifest)
                self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
        manifest = dict(self.manifest, schema_version=True)
        runner.write_json(self.job / "manifest.json", manifest)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_release_cannot_drop_required_reviewer_during_collection(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["kind"] = "release"
        manifest["version"] = "1.2.3"
        manifest["policy"] = runner.review_policy("release", ["codex", "grok"])
        manifest["policy"]["models"] = ["codex"]
        runner.write_json(self.job / "manifest.json", manifest)
        (self.artifacts / "grok.status").unlink()
        path = self.artifacts / "run.meta"
        path.write_text(path.read_text().replace("models=codex,grok", "models=codex"))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_full_reports_only_written_under_denied_artifact_root(self):
        runner.write_json(self.artifacts / "grok.json", dict(report(), findings=[finding("minor")]))
        result = runner.collect(self.job)
        path = runner.attestation_path(self.manifest)
        self.assertTrue(path.is_relative_to(self.artifacts.parent))
        self.assertEqual(runner.load_json(path)["reports"], result["reports"])
        reference = runner.load_json(self.job / "attestation.json")
        self.assertEqual(reference["sha256"], runner.digest(path))
        self.assertEqual(reference["attestation_path"], str(path))
        self.assertNotIn("reports", reference)
        self.assertNotIn("findings", reference)
        self.assertNotIn("No blocking", (self.job / "attestation.json").read_text())

    def test_collector_lock_does_not_write_or_read_incomplete_state(self):
        before = (self.job / "manifest.json").read_bytes()
        with runner.job_lock(self.job) as locked:
            self.assertTrue(locked)
            result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
        self.assertFalse((self.job / "attestation.json").exists())
        self.assertEqual((self.job / "manifest.json").read_bytes(), before)

    def test_collect_canonicalizes_symlink_ancestor_path(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        result = runner.collect(alias / "reviews" / "job-1")
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["frozen_checkout"], str(self.frozen))

    def test_collect_still_rejects_symlink_job_directory(self):
        alias = self.root / "job-alias"
        alias.symlink_to(self.job, target_is_directory=True)
        with self.assertRaisesRegex(runner.ReviewError, "Job directory"):
            runner.collect(alias)

    def test_collect_rejects_external_frozen_symlink(self):
        # Git status is mocked clean: isolate the independent symlink check.
        (self.frozen / "host-link").symlink_to(self.root / "outside.txt")
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "FAILED")
        self.assertIn("escapes", result["reasons"][0])

    def test_collect_allows_internal_frozen_symlink(self):
        (self.frozen / "target.txt").write_text("fixture")
        (self.frozen / "internal-link").symlink_to("target.txt")
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")

    def test_no_manifest_is_preparing_not_final_failure(self):
        (self.job / "manifest.json").unlink()
        self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
        self.assertFalse((self.job / "attestation.json").exists())

    def test_explicit_dispatch_failure_cannot_be_rewritten_pending(self):
        for extra in ({"dispatch_error": "cannot spawn"},):
            with self.subTest(extra=extra):
                manifest = dict(self.manifest, mmrun_run_id=None, **extra)
                runner.write_json(self.job / "manifest.json", manifest)
                self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
                self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_nonzero_dispatch_even_with_run_id_fails(self):
        runner.write_json(self.job / "dispatch-result.json", dict(self.outcome, exit_code=1))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_live_and_dead_dispatch_without_run_id(self):
        (self.job / "dispatch-result.json").unlink()
        runner.write_json(self.job / "manifest.json", dict(self.manifest, mmrun_run_id=None, dispatch_pid=123,
                     dispatch_identity={"pid":123,"start":"fixture","platform":"darwin"}))
        for alive, verdict in ((True, "RUNNING_TIMEOUT"), (False, "FAILED")):
            with patch.object(runner, "process_alive", return_value=alive), patch.object(runner, "identity_alive", return_value=alive):
                self.assertEqual(runner.collect(self.job)["verdict"], verdict)

    def test_upstream_status_marks_dead_worker_stale(self):
        (self.artifacts / "codex.status").write_text("RUNNING\n")
        def status(*args, **kwargs):
            (self.artifacts / "codex.status").write_text("STALE\n")
            return Mock(returncode=0)
        with patch.object(runner.subprocess, "run", side_effect=status) as call:
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
        call.assert_called_once()
        self.assertTrue(self.frozen.exists())

    def test_changed_status_executable_is_not_run(self):
        (self.artifacts / "codex.status").write_text("RUNNING\n")
        self.executable.write_text("changed")
        with patch.object(runner.subprocess, "run") as call:
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
        call.assert_not_called()


class LaunchTests(unittest.TestCase):
    def test_subprocess_command_failure_is_checked(self):
        with patch.object(runner, "bounded_command", return_value=Mock(returncode=1, stderr="no commit", stdout="")) as call:
            with self.assertRaises(runner.ReviewError):
                runner.git(Path("/repo"), "rev-parse", "HEAD")
            self.assertEqual(call.call_args.kwargs["timeout"], 30)

    def test_worktree_command_can_have_longer_preparation_timeout(self):
        with patch.object(runner, "bounded_command", return_value=Mock(returncode=0, stdout="", stderr="")) as call:
            runner.git(Path("/repo"), "worktree", "add", "--detach", "/frozen", HEAD, timeout=300)
            self.assertEqual(call.call_args.kwargs["timeout"], 300)

    def test_reject_short_sha_before_any_subprocess(self):
        with patch.object(runner.subprocess, "run") as call:
            with self.assertRaises(runner.ReviewError):
                runner.check_target(Path("/repo"), "abc", HEAD, kind="pr")
            call.assert_not_called()

    def test_timeout_does_not_kill_process_or_remove_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp).resolve()
            frozen = job / "frozen"
            frozen.mkdir()
            manifest = {"job_id": job.name, "kind": "pr", "mmrun_run_id": None, "provenance": {"mmrun_home": str(job / "mmruns"), "session": "fixture", "mmrun_sha256": "a" * 64,
                        "dispatch_helper": str(Path(runner.__file__).with_name("runner_dispatch.py")),
                        "dispatch_helper_sha256": runner.digest(Path(runner.__file__).with_name("runner_dispatch.py"))},
                        "controller_checkout": str(job), "frozen_checkout": str(frozen)}
            args = argparse.Namespace(timeout=1, mmrun="/trusted/mmrun", base=BASE, models=["codex", "grok"], poll_interval=1)
            executable = job / "fake-mmrun"
            executable.write_text("not executed")
            args.mmrun = str(executable)
            manifest["provenance"] = fixture_provenance(job, executable)
            env = {"MMRUN_D": str(job), "CODEX_HOME": str(job)}
            process = Mock(pid=123)
            process.wait.side_effect = subprocess.TimeoutExpired("mmrun", 1)
            with patch.object(runner, "preparing", return_value=contextlib.nullcontext((job, manifest, env))), patch.object(runner.subprocess, "Popen", return_value=process) as popen:
                result = runner.run(args)
            self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
            process.kill.assert_not_called()
            process.terminate.assert_not_called()
            self.assertTrue(frozen.exists())
            self.assertEqual(popen.call_args.kwargs["cwd"], str(job))
            self.assertNotIn("--sandbox", popen.call_args.args[0])

    def test_dispatch_spawn_error_is_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp).resolve()
            manifest = {"job_id": job.name, "kind": "pr", "mmrun_run_id": None,
                        "provenance": {"mmrun_home": str(job / "mmruns"), "session": "fixture", "mmrun_sha256": "a" * 64,
                        "dispatch_helper": str(Path(runner.__file__).with_name("runner_dispatch.py")),
                        "dispatch_helper_sha256": runner.digest(Path(runner.__file__).with_name("runner_dispatch.py"))},
                        "controller_checkout": str(job), "frozen_checkout": str(job / "frozen")}
            args = argparse.Namespace(timeout=1, mmrun="/trusted/mmrun", base=BASE, models=["codex", "grok"], poll_interval=1)
            executable = job / "fake-mmrun"
            executable.write_text("not executed")
            args.mmrun = str(executable)
            manifest["provenance"] = fixture_provenance(job, executable)
            env = {"MMRUN_D": str(job), "CODEX_HOME": str(job)}
            with patch.object(runner, "preparing", return_value=contextlib.nullcontext((job, manifest, env))), patch.object(runner.subprocess, "Popen", side_effect=OSError("no executable")):
                self.assertEqual(runner.run(args)["verdict"], "FAILED")
            saved = runner.load_json(job / "manifest.json")
            self.assertEqual(saved["phase"], "DISPATCH_FAILED")
            self.assertEqual("DISPATCH_SUPERVISOR_START_FAILED", saved["dispatch_error"])

    def test_atomic_json_writers_use_independent_temporary_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp).resolve() / "state.json"
            values = [{"worker": n, "text": str(n) * 10000} for n in range(30)]
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda value: runner.write_json(path, value), values))
            self.assertIn(runner.load_json(path), values)
            self.assertEqual(list(Path(tmp).glob("*.tmp")), [])

    def test_redirected_codex_home_requires_explicit_choice(self):
        args = argparse.Namespace(mmrun_home="/tmp/test-mmruns", job_id="job", mmrun_d="/tmp/test-mmd",
                                  mmrun="/tmp/test-mmrun", mmrun_kind="upstream", models=["codex"], codex_home=None)
        with patch.object(runner, "digest", return_value="a" * 64), patch.dict(runner.os.environ, {"CODEX_HOME": "/tmp/redirected"}):
            with self.assertRaisesRegex(runner.ReviewError, "redirected"):
                runner.environment(args)

    def test_compatibility_helper_changes_fail_before_model_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, helper, executable = (root / name for name in ("original", "helper.py", "mmrun-copy"))
            for path in (source, helper, executable):
                path.write_text("trusted fixture\n")
            (root / "review.schema.json").write_text("{}")
            (root / "fence.sb").write_text("unchanged fixture")
            sidecar = {"version": "mmrun-provider-transport-v4", "capture_limits": runner.CAPTURE_LIMITS, "security_flags_changed": False,
                       "output": str(executable), "output_sha256": runner.digest(executable),
                       "source": str(source), "source_sha256": runner.digest(source),
                       "helper": str(helper), "helper_sha256": runner.digest(helper)}
            runner.write_json(Path(str(executable) + ".provenance.json"), sidecar)
            args = argparse.Namespace(mmrun_home=str(root / "mmruns"), job_id="job", mmrun_d=str(root),
                                      mmrun=str(executable), mmrun_kind="upstream", models=["grok"], codex_home=None)
            _, provenance = runner.environment(args)
            self.assertEqual(provenance["compatibility"], sidecar)
            for invalid in (None, {}, dict(runner.CAPTURE_LIMITS, stdout_bytes=1)):
                runner.write_json(Path(str(executable) + ".provenance.json"), dict(sidecar, capture_limits=invalid))
                with self.assertRaisesRegex(runner.ReviewError, "provenance"):
                    runner.environment(args)
            runner.write_json(Path(str(executable) + ".provenance.json"), sidecar)
            args.mmrun_kind = "compat"
            args.timeout = 71.5
            env, bound = runner.environment(args)
            self.assertEqual(env["MMRUN_CAPTURE_TIMEOUT"], "71.5")
            self.assertEqual(bound["capture_timeout_seconds"], 71.5)
            bound["mmrun_d_snapshot"] = str(root)
            runner.validate_execution_environment(env, bound)
            for changed in (None, "3600", "nan"):
                modified = dict(env)
                if changed is None:
                    modified.pop("MMRUN_CAPTURE_TIMEOUT")
                else:
                    modified["MMRUN_CAPTURE_TIMEOUT"] = changed
                with self.assertRaisesRegex(runner.ReviewError, "CAPTURE_TIMEOUT_ENVIRONMENT_CHANGED"):
                    runner.validate_execution_environment(modified, bound)
            for invalid in (True, None, 0.2, 0, float("inf"), float("nan"), 86401):
                args.timeout = invalid
                with self.assertRaisesRegex(runner.ReviewError, "CAPTURE_TIMEOUT_INVALID"):
                    runner.environment(args)
            args.timeout = 71.5
            helper.write_text("changed helper\n")
            with self.assertRaisesRegex(runner.ReviewError, "helper changed"):
                runner.environment(args)

    def test_long_job_ids_have_distinct_untruncated_session_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name in ("mmrun", "review.schema.json", "fence.sb"):
                (root / name).write_text("fixture")
            args = argparse.Namespace(mmrun_home=str(root / "mmruns"), job_id="x" * 95 + "1", mmrun_d=str(root),
                                      mmrun=str(root / "mmrun"), mmrun_kind="upstream", models=["grok"], codex_home=None)
            first, _ = runner.environment(args)
            args.job_id = "x" * 95 + "2"
            second, _ = runner.environment(args)
            self.assertLessEqual(len(first["MMRUN_SESSION"]), 64)
            self.assertNotEqual(first["MMRUN_SESSION"], second["MMRUN_SESSION"])


class InlineTreeTests(unittest.TestCase):
    def inline(self, contents, modes=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            entries = []
            for index, content in enumerate(contents):
                name = f"file-{index}.txt"
                (root / name).write_bytes(content)
                mode = modes[index] if modes else "100644"
                entries.append(f"{mode} blob {'a' * 40}\t{name}\0")
            with patch.object(runner, "git", return_value="".join(entries)):
                return runner.inline_small_tree(root, HEAD)

    def test_all_text_files_are_inlined_without_truncation(self):
        output = self.inline([b"first unique content", "第二个文件".encode()])
        self.assertIn("no files omitted or truncated", output)
        self.assertIn("first unique content", output)
        self.assertIn("第二个文件", output)

    def test_exact_256_kib_is_allowed(self):
        output = self.inline([b"x" * runner.MAX_INLINE_TREE_BYTES])
        self.assertIn("no files omitted or truncated", output)
        self.assertEqual(output.count("x"), runner.MAX_INLINE_TREE_BYTES + 1)  # .txt filename

    def test_over_limit_is_all_or_nothing_across_files(self):
        output = self.inline([b"unique prefix", b"y" * runner.MAX_INLINE_TREE_BYTES])
        self.assertIn("exceeds 256 KiB", output)
        self.assertNotIn("unique prefix", output)
        self.assertIn("No partial contents", output)
        self.assertIn("Read the entire", output)

    def test_binary_or_non_utf8_does_not_leave_partial_inline(self):
        for binary in (b"\0binary", b"\xff\xfe"):
            with self.subTest(binary=binary):
                output = self.inline([b"unique prefix", binary])
                self.assertIn("NOT inlined", output)
                self.assertNotIn("unique prefix", output)
                self.assertIn("request_changes", output)

    def test_nonregular_tree_is_not_partially_inlined(self):
        output = self.inline([b"unique prefix", b"file-0.txt"], ["100644", "120000"])
        self.assertIn("non-regular entries", output)
        self.assertNotIn("unique prefix", output)


class OfflineGitPreparationTests(unittest.TestCase):
    """Exercise real Git worktrees; only model dispatch remains mocked."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.cleanup)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        runner.git(self.repo, "init", "-q", "--template=")
        (self.repo / "file.txt").write_text("release fixture\n")
        runner.git(self.repo, "add", "file.txt")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        self.head = runner.git(self.repo, "rev-parse", "HEAD")
        self.args = argparse.Namespace(repo=str(self.repo), base=self.head, head=self.head, kind="release", version="1.2.3",
                                       models=["codex", "grok"], job_id="empty-delta", state_dir=str(self.root / "reviews"),
                                       timeout=1, poll_interval=1, mmrun="/trusted/mmrun")
        self.provenance = {"mmrun_home": str(self.root / "mmruns"), "session": "fixture", "mmrun_sha256": "a" * 64,
                           "dispatch_helper": str(Path(runner.__file__).with_name("runner_dispatch.py")),
                           "dispatch_helper_sha256": runner.digest(Path(runner.__file__).with_name("runner_dispatch.py"))}
        executable = self.root / "mock-mmrun"
        executable.write_text("not executed")
        self.args.mmrun = str(executable)
        self.provenance = fixture_provenance(self.root, executable)
        self.env = {"MMRUN_D": str(self.root), "CODEX_HOME": str(self.root)}

    def cleanup(self):
        for directory, dirs, files in os.walk(self.root):
            Path(directory).chmod(0o700)
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink():
                    path.chmod(0o600)
        self.temp.cleanup()

    def test_manifest_hidden_until_real_worktree_and_notes_are_complete(self):
        job = Path(self.args.state_dir) / self.args.job_id
        original = runner.make_readonly
        def during_preparation(frozen):
            self.assertFalse((job / "manifest.json").exists())
            self.assertEqual(runner.collect(job)["verdict"], "RUNNING_TIMEOUT")
            self.assertFalse((job / "attestation.json").exists())
            original(frozen)
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)), patch.object(
                runner, "make_readonly", side_effect=during_preparation):
            job, manifest, _ = runner.prepare(self.args)
        runner.verify_frozen(manifest)
        self.assertEqual(manifest["head_sha"], self.head)
        self.assertTrue((job / "review-notes.txt").is_file())
        self.assertTrue((job / "release-prompt.txt").is_file())
        prompt = (job / "release-prompt.txt").read_text()
        self.assertIn("file.txt", prompt)
        self.assertIn("[empty delta]", prompt)
        self.assertIn("release fixture", prompt)
        self.assertIn(runner.EXHAUSTIVE_REVIEW_INSTRUCTIONS, prompt)
        self.assertIn("Review only this frozen checkout: " + manifest["frozen_checkout"], prompt)
        self.assertIn("Source repository (identity only; do not review this checkout)", prompt)
        self.assertEqual(runner.load_json(job / "manifest.json")["provenance"]["release_prompt_sha256"],
                         runner.digest(job / "release-prompt.txt"))

    def test_preparation_uses_long_timeout_and_canonicalizes_git_root(self):
        original = runner.git
        alias = self.root / "repo-alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        seen_timeouts = []
        def git_with_alias(repo, *args, **kwargs):
            if args == ("rev-parse", "--show-toplevel"):
                return str(alias)
            if args[0] == "fetch":
                seen_timeouts.append(kwargs.get("timeout"))
            return original(repo, *args, **kwargs)
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)), patch.object(
                runner, "git", side_effect=git_with_alias):
            _, manifest, _ = runner.prepare(self.args)
        self.assertEqual(seen_timeouts, [300])
        self.assertEqual(manifest["source_repo"], str(self.repo))

    def test_real_tracked_external_symlink_blocks_preparation(self):
        (self.repo / "outside-link").symlink_to(self.root / "host-secret-not-read.txt")
        runner.git(self.repo, "add", "outside-link")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "-c", "core.hooksPath=/dev/null", "commit", "-qm", "external symlink")
        self.args.head = runner.git(self.repo, "rev-parse", "HEAD")
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            with self.assertRaisesRegex(runner.ReviewError, "symlink escapes"):
                runner.prepare(self.args)
        self.assertFalse((Path(self.args.state_dir) / self.args.job_id / "manifest.json").exists())

    def test_empty_delta_release_starts_review_mode_without_diff_precondition(self):
        process = Mock(pid=123)
        process.wait.side_effect = subprocess.TimeoutExpired("mmrun", 1)
        def launch(argv, **kwargs):
            request = runner.load_json(Path(argv[-1]) / "dispatch-request.json")
            self.assertEqual(request["argv"][1:4], ["start", "--mode", "review"])
            self.assertIn("--schema", request["argv"])
            self.assertNotIn("--wt", request["argv"])
            content = Path(request["stdin"]).read_bytes()
            self.assertIn(b"[empty delta]", content)
            self.assertIn(b"release fixture", content)
            job = Path(self.args.state_dir) / self.args.job_id
            self.assertEqual(runner.collect(job)["verdict"], "RUNNING_TIMEOUT")
            return process
        # subprocess.run uses Popen for Git too, so prepare before mocking.
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            prepared = runner.prepare(self.args)
        with patch.object(runner, "preparing", return_value=contextlib.nullcontext(prepared)), patch.object(runner.subprocess, "Popen", side_effect=launch):
            result = runner.run(self.args)
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
        process.kill.assert_not_called()
        process.terminate.assert_not_called()

    def test_nonempty_delta_release_uses_original_exhaustive_review_entrypoint(self):
        (self.repo / "file.txt").write_text("changed release fixture\n")
        runner.git(self.repo, "add", "file.txt")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "-c", "core.hooksPath=/dev/null", "commit", "-qm", "release delta")
        self.args.head = runner.git(self.repo, "rev-parse", "HEAD")
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            prepared = runner.prepare(self.args)
        job, manifest, _ = prepared
        self.assertIs(manifest["release_empty_delta"], False)
        self.assertFalse((job / "release-prompt.txt").exists())
        notes = (job / "review-notes.txt").read_text()
        self.assertIn("inspect the target tree and relevant callers, not only", notes)
        self.assertIn("Review only this frozen checkout: " + manifest["frozen_checkout"], notes)
        process = Mock(pid=123)
        process.wait.side_effect = subprocess.TimeoutExpired("mmrun", 1)
        with patch.object(runner, "preparing", return_value=contextlib.nullcontext(prepared)), patch.object(
                runner.subprocess, "Popen", return_value=process) as launch:
            result = runner.run(self.args)
        argv = runner.load_json(job / "dispatch-request.json")["argv"]
        self.assertEqual(argv[1:5], ["review", "--base", self.args.base, "--exhaustive"])
        self.assertEqual(argv[argv.index("--notes-file") + 1], str(job / "review-notes.txt"))
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")


class HardenedCollectionTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply
    # Reuse complete mature-job fixtures for the new receipt boundaries.
    def test_missing_receipt_with_done_reports_never_passes(self):
        (self.job / "dispatch-result.json").unlink()
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "FAILED")
        self.assertIn("DISPATCH_COMPLETION_UNKNOWN", result["reasons"])

    def test_removing_receipt_after_pass_does_not_reuse_cached_success(self):
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")
        (self.job / "dispatch-result.json").unlink()
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_changed_dispatch_helper_provenance_blocks_collection(self):
        self.manifest["provenance"]["dispatch_helper_sha256"] = "0" * 64
        runner.write_json(self.job / "manifest.json", self.manifest)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_delayed_nonzero_dispatch_receipt_overrides_done_reports(self):
        (self.job / "dispatch-result.json").unlink()
        manifest = dict(self.manifest, supervisor_pid=43210, supervisor_identity={"pid":43210,"start":"fixture","platform":"darwin"})
        runner.write_json(self.job / "manifest.json", manifest)
        with patch.object(runner, "process_alive", return_value=True), patch.object(runner, "identity_alive", return_value=True):
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
        runner.write_json(self.job / "dispatch-result.json", dict(self.outcome, exit_code=7))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_failed_dispatch_recovers_runid_from_session_metadata(self):
        runner.write_json(self.job / "manifest.json", dict(self.manifest, mmrun_run_id=None))
        runner.write_json(self.job / "dispatch-result.json", dict(self.outcome, exit_code=1))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
        self.assertEqual(runner.load_json(self.job / "manifest.json")["mmrun_run_id"], RUN_ID)

    def test_quiescence_requires_worker_pid_and_terminal_receipt(self):
        self.manifest["controller_pid"] = 98765
        runner.write_json(self.job / "manifest.json", self.manifest)
        with patch.object(runner, "process_alive", return_value=False):
            with self.assertRaisesRegex(runner.ReviewError, "WORKER_PID_UNKNOWN"):
                runner.require_quiescent(self.job)
            for model in ("codex", "grok"):
                (self.artifacts / (model + ".pid")).write_text("98766")
            runner.require_quiescent(self.job)
            (self.artifacts / "grok.meta").unlink()
            with self.assertRaises(runner.ReviewError):
                runner.require_quiescent(self.job)

    def test_quote_four_lines_rejected(self):
        invalid = dict(report(), findings=[dict(finding("minor"), quote="one\ntwo\nthree\nfour")])
        runner.write_json(self.artifacts / "codex.json", invalid)
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_aggregate_attestation_has_distinct_size_budget(self):
        huge = dict(report(), summary="x" * (runner.MAX_REPORT_BYTES // 2 + 100))
        for model in ("codex", "grok"):
            runner.write_json(self.artifacts / (model + ".json"), huge)
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "PASS")
        path = runner.attestation_path(self.manifest)
        self.assertGreater(path.stat().st_size, runner.MAX_REPORT_BYTES)
        self.assertEqual(runner.load_json(path, max_bytes=runner.MAX_ATTESTATION_BYTES)["verdict"], "PASS")


class IsolationTests(unittest.TestCase):
    setUp = OfflineGitPreparationTests.setUp
    cleanup = OfflineGitPreparationTests.cleanup
    def test_plain_frozen_diff_works_without_inherited_diff_or_pack_hooks(self):
        (self.repo / "file.txt").write_text("changed release fixture\n")
        runner.git(self.repo, "add", "file.txt")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "commit", "-qm", "nonempty diff fixture")
        self.args.head = runner.git(self.repo, "rev-parse", "HEAD")
        marker = self.root / "external-command-must-not-run"
        extension = self.root / "hostile-extension"
        extension.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\nexit 99\n")
        extension.chmod(0o700)
        runner.git(self.repo, "config", "diff.external", str(extension))
        runner.git(self.repo, "config", "uploadpack.packObjectsHook", str(extension))
        global_config = self.root / "fake-global.gitconfig"
        global_config.write_text('[diff]\n external = "' + str(extension) + '"\n'
                                 '[uploadpack]\n packObjectsHook = "' + str(extension) + '"\n')
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(global_config),
                                     "GIT_EXTERNAL_DIFF": str(extension)}), patch.object(
                runner, "environment", return_value=(self.env, self.provenance)):
            _, manifest, _ = runner.prepare(self.args)
            # Match the upstream mmrun's ordinary Git diff: no --no-ext-diff.
            result = subprocess.run(["git", "-C", manifest["frozen_checkout"], "diff",
                                     self.args.base + "..." + self.args.head],
                                    env=runner.git_environment(), text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+changed release fixture", result.stdout)
        self.assertFalse(marker.exists())
        # The ordinary diff has no empty external executable configured.
        config = runner.git(Path(manifest["frozen_checkout"]), "config", "--list")
        self.assertNotIn("diff.external=", config)
        # The source-local hook is ignored by protected config scope; the real
        # local upload-pack above succeeds without an empty-value override.
        self.assertNotIn("uploadpack.packobjectshook=", config.lower())

    def test_missing_promisor_blob_fails_before_freeze_without_lazy_fetch(self):
        marker = self.root / "lazy-fetch-must-not-run"
        upload = self.root / "fake-upload-pack"
        upload.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\nexit 1\n")
        upload.chmod(0o700)
        runner.git(self.repo, "config", "remote.origin.url", str(self.repo))
        runner.git(self.repo, "config", "remote.origin.promisor", "true")
        runner.git(self.repo, "config", "remote.origin.partialclonefilter", "blob:none")
        runner.git(self.repo, "config", "remote.origin.uploadpack", str(upload))
        blob = runner.git(self.repo, "rev-parse", "HEAD:file.txt")
        (self.repo / ".git/objects" / blob[:2] / blob[2:]).unlink()
        with patch.object(runner, "freeze_repository") as freeze, patch.object(runner, "environment") as environment:
            with self.assertRaisesRegex(runner.ReviewError, "SOURCE_OBJECTS_MISSING.*lazy fetch is disabled"):
                runner.prepare(self.args)
        freeze.assert_not_called()
        environment.assert_not_called()
        self.assertFalse(marker.exists())
        job = Path(self.args.state_dir) / self.args.job_id
        self.assertTrue((job / "preparation-result.json").is_file())
        self.assertFalse((job / "dispatch-request.json").exists())

    def test_hydrated_promisor_repository_is_allowed(self):
        runner.git(self.repo, "config", "remote.origin.promisor", "true")
        runner.git(self.repo, "config", "remote.origin.partialclonefilter", "blob:none")
        runner.require_local_objects(self.repo, self.args.base, self.args.head)
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            _, manifest, _ = runner.prepare(self.args)
        runner.verify_frozen(manifest)

    def test_missing_commit_reports_actionable_object_preflight_failure(self):
        self.args.head = "1" * 40
        with patch.object(runner, "freeze_repository") as freeze:
            with self.assertRaisesRegex(runner.ReviewError, "SOURCE_OBJECT(?:S_MISSING|_SCAN_FAILED).*complete local clone"):
                runner.prepare(self.args)
        freeze.assert_not_called()

    def test_source_hook_and_filter_do_not_execute_or_transfer(self):
        marker = self.root / "must-not-exist"
        hooks = self.repo / ".githooks"
        hooks.mkdir()
        hook = hooks / "post-checkout"
        hook.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
        hook.chmod(0o700)
        (self.repo / ".gitattributes").write_text("*.txt filter=evil\n")
        runner.git(self.repo, "add", ".")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "hostile extension fixture")
        self.args.head = runner.git(self.repo, "rev-parse", "HEAD")
        runner.git(self.repo, "config", "core.hooksPath", ".githooks")
        runner.git(self.repo, "config", "filter.evil.smudge", "touch '" + str(marker) + "'; cat")
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            _, manifest, _ = runner.prepare(self.args)
        self.assertFalse(marker.exists())
        frozen = Path(manifest["frozen_checkout"])
        self.assertTrue((frozen / ".git").is_dir())
        self.assertFalse((frozen / ".git/objects/info/alternates").exists())
        self.assertNotIn("evil", (frozen / ".git/config").read_text())
        self.assertNotIn("hooksPath", (frozen / ".git/config").read_text())

    def test_unrelated_source_commit_is_not_present_in_frozen_objects(self):
        runner.git(self.repo, "checkout", "--orphan", "unrelated")
        (self.repo / "other.txt").write_text("unrelated data")
        runner.git(self.repo, "add", ".")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "unrelated")
        unrelated = runner.git(self.repo, "rev-parse", "HEAD")
        runner.git(self.repo, "checkout", "--detach", self.args.head)
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            _, manifest, _ = runner.prepare(self.args)
        with self.assertRaises(runner.ReviewError):
            runner.git(Path(manifest["frozen_checkout"]), "cat-file", "-e", unrelated)

    def test_pr_empty_delta_is_explicit_and_review_mode_ready(self):
        self.args.kind = "pr"
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            job, manifest, _ = runner.prepare(self.args)
        self.assertTrue(manifest["empty_delta"])
        self.assertIn("PR merge-base-to-head delta is empty", (job / "release-prompt.txt").read_text())

    def test_preparation_and_dispatch_keep_one_lock(self):
        def dispatch(args, job, manifest, env, deadline):
            self.assertEqual(runner.collect(job)["verdict"], "RUNNING_TIMEOUT")
            with runner.job_lock(job) as locked:
                self.assertFalse(locked)
            return {"verdict": "RUNNING_TIMEOUT"}
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)), patch.object(
                runner, "_dispatch_locked", side_effect=dispatch):
            self.assertEqual(runner.run(self.args)["verdict"], "RUNNING_TIMEOUT")


class SupervisorTests(unittest.TestCase):
    def test_detached_supervisor_records_exit_after_launcher_returns(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp).resolve()
            executable = job / "fake-mmrun"
            executable.write_text("#!/bin/sh\nsleep 0.15\necho 'RUN fixture models=codex'\nexit 7\n")
            executable.chmod(0o700)
            runner.write_json(job / "dispatch-request.json", {"job_id": job.name,
                "argv": [str(executable)], "executable_sha256": runner.digest(executable),
                "cwd": str(job), "stdin": os.devnull, "provenance": fixture_provenance(job, executable)})
            helper = str(Path(runner.__file__).with_name("runner_dispatch.py"))
            parent = "import subprocess,sys; subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2]],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)"
            subprocess.run([sys.executable, "-c", parent, helper, str(job)], check=True,
                           env=dict(os.environ, MMRUN_D=str(job), CODEX_HOME=str(job)))
            deadline = time.monotonic() + 30
            while not (job / "dispatch-result.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            outcome = runner.load_json(job / "dispatch-result.json")
            self.assertEqual(outcome["exit_code"], 7)
            self.assertTrue(outcome["started"])

    def test_compatibility_mode_requires_sidecar_and_resolves_executable_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            executable = root / "mmrun"
            executable.write_text("fixture")
            alias = root / "alias"
            alias.symlink_to(executable)
            (root / "review.schema.json").write_text("{}")
            args = argparse.Namespace(mmrun=str(alias), mmrun_kind="compat", mmrun_home=str(root / "runs"),
                                      mmrun_d=str(root), job_id="fixture", models=[], codex_home=None)
            with self.assertRaises(runner.ReviewError):
                runner.environment(args)
            args.mmrun_kind = "upstream"
            _, provenance = runner.environment(args)
            self.assertEqual(provenance["mmrun_path"], str(executable))
            self.assertEqual(provenance["mmrun_sha256"], runner.digest(executable))

    def test_empty_delta_checks_exit_status_without_materializing_patch(self):
        for rc, empty in ((0, True), (1, False)):
            with patch.object(runner, "bounded_command", return_value=Mock(returncode=rc)) as call:
                self.assertIs(runner.empty_delta(Path("/repo"), BASE, HEAD), empty)
                self.assertIn("--quiet", call.call_args.args[0])
                self.assertIn("--no-textconv", call.call_args.args[0])
        with patch.object(runner, "bounded_command", return_value=Mock(returncode=2)):
            with self.assertRaises(runner.ReviewError):
                runner.empty_delta(Path("/repo"), BASE, HEAD)

    def test_external_command_stderr_never_becomes_attestation_reason(self):
        with patch.object(runner, "bounded_command", return_value=Mock(returncode=1, stderr="SECRET_REPOSITORY_DATA", stdout="")):
            with self.assertRaises(runner.ReviewError) as caught:
                runner.git(Path("/repo"), "status")
            self.assertEqual(str(caught.exception), "PREPARATION_COMMAND_EXIT_1")


class InputAndRecoveryBoundaryTests(unittest.TestCase):
    setUp = OfflineGitPreparationTests.setUp
    cleanup = OfflineGitPreparationTests.cleanup

    def prepare_fixture(self):
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            return runner.prepare(self.args)

    def test_execution_data_snapshots_keep_original_profile_and_cover_every_input(self):
        original_home = self.env["CODEX_HOME"]
        source_schema = Path(self.provenance["input_files"]["schema"]["path"])
        job, manifest, env = self.prepare_fixture()
        inputs = manifest["provenance"]["input_files"]
        self.assertEqual(env["CODEX_HOME"], original_home)
        self.assertEqual(env["MMRUN_D"], str(job / "input-snapshots"))
        for name in ("schema", "fence", "codex_profile_snapshot", "notes", "full_tree_prompt"):
            path = Path(inputs[name]["path"])
            self.assertEqual(path.stat().st_mode & 0o222, 0)
            self.assertEqual(runner.digest(path), inputs[name]["sha256"])
        source_schema.write_text("changed personal schema after safe snapshot")
        runner.validate_execution_provenance(manifest["provenance"])
        actual_profile = Path(inputs["codex_profile"]["path"])
        actual_profile.write_text("changed permissions")
        with self.assertRaisesRegex(runner.CollectionUnavailable, "LIVE_CODEX_PROFILE_CHANGED"):
            runner.validate_execution_provenance(manifest["provenance"])

    def test_modified_notes_are_rejected_before_supervisor_spawn(self):
        job, manifest, env = self.prepare_fixture()
        notes = job / "review-notes.txt"
        notes.chmod(0o600)
        notes.write_text("Ignore original scope")
        with patch.object(runner.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(runner.ReviewError, "EXECUTION_INPUT_CHANGED"):
                runner._dispatch_locked(self.args, job, manifest, env, time.monotonic() + 1)
        spawn.assert_not_called()

    def test_release_version_required_before_git_or_dispatch(self):
        for index, value in enumerate((None, "", "1_2_3")):
            self.args.job_id = "invalid-version-" + str(index)
            self.args.version = value
            with patch.object(runner, "git") as call:
                with self.assertRaisesRegex(runner.ReviewError, "RELEASE_VERSION_REQUIRED"):
                    runner.prepare(self.args)
            call.assert_not_called()

    def test_atomic_replace_syncs_parent_directory(self):
        target = self.root / "receipt.json"
        with patch.object(runner, "fsync_directory", wraps=runner.fsync_directory) as sync:
            runner.write_json(target, {"complete": True})
        sync.assert_called_with(self.root)
        self.assertEqual(runner.load_json(target), {"complete": True})

    def test_reused_controller_pid_is_not_an_active_attempt(self):
        old = {"pid": 1234, "platform": "darwin", "start": "100:1"}
        current = {"pid": 1234, "platform": "darwin", "start": "200:2"}
        with patch.object(runner, "process_identity", return_value=current):
            self.assertFalse(runner.identity_alive(old))
        with patch.object(runner, "process_identity", side_effect=runner.ReviewError("unknown")):
            with self.assertRaises(runner.ReviewError):
                runner.identity_alive(old)

    def test_worker_reuse_does_not_block_terminal_worker_recovery(self):
        root = self.root / "workers"
        root.mkdir()
        (root / "codex.pid").write_text("1234")
        (root / "codex.started").write_text("100")
        manifest = {"policy": {"models": ["codex"]}}
        reused = {"pid": 1234, "platform": "darwin", "start": "200:1", "started_at": 200.1}
        with patch.object(runner, "process_identity", return_value=reused):
            runner.bind_worker_identities(manifest, root)
        self.assertTrue(manifest["worker_identities"]["codex"]["reused"])

    def test_kernel_identity_reads_current_process_without_ps_text(self):
        identity = runner.process_identity(os.getpid())
        self.assertEqual(identity["pid"], os.getpid())
        self.assertTrue(runner.identity_alive(identity))


class CollectionBudgetTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_expired_budget_returns_pending_without_rewriting_previous_pass(self):
        runner.collect(self.job)
        path = runner.attestation_path(self.manifest)
        before = path.read_bytes()
        result = runner.collect(self.job, deadline=time.monotonic() - 1)
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
        self.assertIsNone(result["attestation_path"])
        self.assertEqual(path.read_bytes(), before)

    def test_budget_checked_between_hash_chunks(self):
        path = self.root / "bounded-hash"
        path.write_bytes(b"x" * 200_000)
        with patch.object(runner.time, "monotonic", side_effect=[0, 0, 0, 2]):
            with self.assertRaises(runner.CollectionDeadline):
                with runner.collection_budget(1):
                    runner.digest(path)

    def test_git_subprocess_receives_remaining_budget(self):
        with runner.collection_budget(time.monotonic() + 0.25), patch.object(
                runner, "bounded_command", return_value=Mock(returncode=0, stdout="")) as call:
            runner.command(["git", "status"], timeout=30)
        self.assertGreater(call.call_args.kwargs["timeout"], 0)
        self.assertLessEqual(call.call_args.kwargs["timeout"], 0.25)

    def test_directory_walk_cooperatively_checks_budget(self):
        calls = 0
        original = runner.check_deadline
        def budget():
            nonlocal calls
            calls += 1
            if calls >= 2:
                raise runner.CollectionDeadline()
            original()
        (self.frozen / "file.txt").write_text("fixture")
        with patch.object(runner, "check_deadline", side_effect=budget):
            with self.assertRaises(runner.CollectionDeadline):
                runner.verify_frozen(self.manifest)

    def test_reused_controller_pid_allows_proven_never_spawned_attempt_recovery(self):
        self.manifest.update(controller_pid=1234,
                             controller_identity={"pid":1234,"platform":"darwin","start":"100:1"})
        runner.write_json(self.job / "manifest.json", self.manifest)
        runner.write_json(self.job / "dispatch-result.json", dict(self.outcome, started=False, exit_code=127))
        current = {"pid":1234,"platform":"darwin","start":"200:1"}
        with patch.object(runner, "process_identity", return_value=current):
            runner.require_quiescent(self.job)

    def test_every_bound_execution_input_is_revalidated_on_collection(self):
        inputs = self.manifest["provenance"]["input_files"]
        for name in ("schema", "fence", "notes", "codex_profile", "codex_profile_snapshot"):
            path = Path(inputs[name]["path"])
            original = path.read_bytes()
            path.write_text("replaced " + name)
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT" if name == "codex_profile" else "FAILED", name)
            path.write_bytes(original)


class ClaudePolicyTests(unittest.TestCase):
    def test_default_and_release_baselines(self):
        args = runner.parser().parse_args(["run", "--repo", "/repo", "--base", BASE, "--head", HEAD,
                                          "--kind", "pr", "--job-id", "fixture", "--state-dir", "/tmp/state"])
        self.assertEqual(args.models, ["claude", "codex"])
        self.assertEqual(runner.review_policy("release", ["codex", "claude"])["models"], ["claude", "codex"])
        runner.review_policy("release", ["codex", "grok"])
        runner.review_policy("release", ["codex", "grok", "claude"])
        for models in (["claude"], ["codex"], ["codex", "agy"]):
            with self.assertRaises(runner.ReviewError):
                runner.review_policy("release", models)


class FinalEvidenceBoundaryTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_controller_module_hash_is_required_and_rechecked(self):
        for key, value in (("review_runner_sha256", "0" * 64), ("review_runner_path", "/wrong/controller.py")):
            original = self.manifest["provenance"][key]
            self.manifest["provenance"][key] = value
            runner.write_json(self.job / "manifest.json", self.manifest)
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
            self.manifest["provenance"][key] = original

    def test_duplicate_model_keys_never_escape_in_public_diagnostics(self):
        marker = "PRIVATE_MODEL_BODY_" + "secret" * 1000
        encoded = json.dumps(marker)
        (self.artifacts / "codex.json").write_text("{" + encoded + ":1," + encoded + ":2}")
        result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "FAILED")
        self.assertEqual(result["reasons"], ["JSON_DUPLICATE_KEY"])
        self.assertNotIn(marker, json.dumps(result))
        self.assertNotIn(marker, runner.attestation_path(self.manifest).read_text())
        self.assertNotIn(marker, (self.job / "attestation.json").read_text())

    def test_spawn_identity_error_cannot_create_unstarted_receipt_or_allow_retry(self):
        helper_spec = importlib.util.spec_from_file_location("runner_dispatch_under_test", Path(runner.__file__).with_name("runner_dispatch.py"))
        helper = importlib.util.module_from_spec(helper_spec)
        with patch.dict(sys.modules, {"review_runner": runner}):
            helper_spec.loader.exec_module(helper)
        request = {"schema_version": 1, "job_id": self.job.name, "argv": [str(self.executable)],
                   "executable_sha256": runner.digest(self.executable), "cwd": str(self.job),
                   "stdin": os.devnull, "provenance": self.manifest["provenance"]}
        runner.write_json(self.job / "dispatch-request.json", request)
        (self.job / "dispatch-result.json").unlink()
        parent_identity = {"pid": os.getpid(), "platform": "darwin", "start": "fixture"}
        proc = Mock(pid=7654321)
        proc.wait.return_value = 0
        with patch.object(helper, "process_identity", side_effect=[parent_identity, runner.ReviewError("temporary kernel query failure")]), patch.object(
                helper.subprocess, "Popen", return_value=proc), patch.dict(
                os.environ, {"MMRUN_D": str(self.root), "CODEX_HOME": str(self.root)}):
            self.assertEqual(helper.supervise(self.job), 0)
        identity = runner.load_json(self.job / "dispatch-identity.json")
        self.assertIs(identity["started"], True)
        self.assertEqual(identity["dispatch_pid"], proc.pid)
        receipt = runner.load_json(self.job / "dispatch-result.json")
        self.assertIs(receipt["started"], True)
        self.assertEqual(receipt["exit_code"], 0)
        proc.wait.assert_called_once()
        proc.kill.assert_not_called()
        proc.terminate.assert_not_called()
        self.manifest.update(controller_pid=4321, phase="DISPATCHING",
                             dispatch_request_sha256=runner.digest(self.job / "dispatch-request.json"))
        runner.write_json(self.job / "manifest.json", self.manifest)
        with patch.object(runner, "process_alive", return_value=False):
            with self.assertRaisesRegex(runner.ReviewError, "WORKER_PID_UNKNOWN"):
                runner.require_quiescent(self.job)


class ClaudeReviewRegressionTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_transient_command_timeout_preserves_pass_and_returns_pending(self):
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")
        destination = runner.attestation_path(self.manifest)
        before = destination.read_bytes()
        with patch.object(runner, "git", side_effect=runner.CollectionUnavailable("PREPARATION_COMMAND_TIMEOUT")):
            result = runner.collect(self.job)
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
        self.assertIsNone(result["attestation_path"])
        self.assertEqual(destination.read_bytes(), before)
        with patch.object(runner, "bounded_command", side_effect=subprocess.TimeoutExpired("git", 30)):
            with self.assertRaises(runner.CollectionUnavailable):
                runner.command(["git", "status"])

    def test_transient_io_is_pending_but_confirmed_missing_evidence_is_failed(self):
        import errno
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")
        destination = runner.attestation_path(self.manifest)
        before = destination.read_bytes()
        with patch.object(runner, "verify_frozen", side_effect=OSError(errno.EIO, "temporary io")):
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
        self.assertEqual(destination.read_bytes(), before)
        with patch.object(runner, "verify_frozen", side_effect=FileNotFoundError(errno.ENOENT, "missing frozen tree")):
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_live_workers_do_not_repeat_full_tree_checks(self):
        (self.artifacts / "codex.status").write_text("RUNNING\n")
        with patch.object(runner, "refresh_worker_status"), patch.object(runner, "verify_frozen") as tree:
            self.assertEqual(runner.collect(self.job, _initial_wait=True)["verdict"], "RUNNING_TIMEOUT")
        tree.assert_not_called()
        self.assertFalse(any(call.args[1:] == ("merge-base", BASE, HEAD) for call in self.git.call_args_list))

    def test_external_collection_still_checks_frozen_evidence_while_running(self):
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")
        (self.artifacts / "codex.status").write_text("RUNNING\n")
        with patch.object(runner, "verify_frozen", side_effect=runner.ReviewError("Frozen tree changed")) as tree:
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
        tree.assert_called_once()

    def test_non_object_manifest_returns_controlled_failure(self):
        for value in (None, [], "corrupt", 1):
            runner.write_json(self.job / "manifest.json", value)
            result = runner.collect(self.job)
            self.assertEqual(result["verdict"], "FAILED")
            self.assertEqual(result["reasons"], ["MANIFEST_NOT_OBJECT"])
            with self.assertRaisesRegex(runner.ReviewError, "MANIFEST_NOT_OBJECT"):
                runner.validate_manifest_policy(value)

    def test_unknown_spawn_intent_is_pending_and_never_allows_retry(self):
        (self.job / "dispatch-result.json").unlink()
        self.manifest.update(controller_pid=4321, phase="DISPATCHING", spawn_intent=True)
        runner.write_json(self.job / "manifest.json", self.manifest)
        with patch.object(runner, "process_alive", return_value=False):
            self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
            with self.assertRaisesRegex(runner.ReviewError, "DISPATCH_OUTCOME_UNKNOWN"):
                runner.require_quiescent(self.job)

    def test_deleted_completed_receipt_is_invalid_evidence_not_unknown_spawn(self):
        self.manifest["spawn_intent"] = True
        runner.write_json(self.job / "manifest.json", self.manifest)
        self.assertEqual(runner.collect(self.job)["verdict"], "PASS")
        (self.job / "dispatch-result.json").unlink()
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_nonzero_dispatch_with_missing_worker_pid_is_still_unknown(self):
        self.manifest["controller_pid"] = 4321
        runner.write_json(self.job / "manifest.json", self.manifest)
        runner.write_json(self.job / "dispatch-result.json", dict(self.outcome, exit_code=1))
        with patch.object(runner, "process_alive", return_value=False):
            with self.assertRaisesRegex(runner.ReviewError, "WORKER_PID_UNKNOWN"):
                runner.require_quiescent(self.job)

    def test_post_supervisor_spawn_io_failure_is_not_mislabeled_unstarted(self):
        args = argparse.Namespace(mmrun=str(self.executable), base=BASE, models=["codex", "grok"])
        self.manifest["controller_checkout"] = str(self.root)
        self.manifest["controller_pid"] = 4321
        env = {"MMRUN_D": str(self.root), "CODEX_HOME": str(self.root)}
        process = Mock(pid=7654321)
        (self.job / "dispatch-result.json").unlink()
        with patch.object(runner.subprocess, "Popen", return_value=process), patch.object(
                runner, "process_identity", side_effect=OSError("temporary kernel access")):
            result = runner._dispatch_locked(args, self.job, self.manifest, env, time.monotonic() + 1)
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
        saved = runner.load_json(self.job / "manifest.json")
        self.assertIs(saved["spawn_intent"], True)
        self.assertNotIn("dispatch_error", saved)
        with patch.object(runner, "process_alive", return_value=False):
            with self.assertRaisesRegex(runner.ReviewError, "DISPATCH_OUTCOME_UNKNOWN"):
                runner.require_quiescent(self.job)
        process.kill.assert_not_called()

    def test_supervisor_argument_count_is_controlled(self):
        spec = importlib.util.spec_from_file_location("runner_dispatch_arity", Path(runner.__file__).with_name("runner_dispatch.py"))
        helper = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"review_runner": runner}):
            spec.loader.exec_module(helper)
        import io
        for args in ([], ["one", "two"]):
            with contextlib.redirect_stderr(io.StringIO()) as error:
                self.assertEqual(helper.main(args), 2)
            self.assertNotIn("Traceback", error.getvalue())


class CanonicalModelPreparationTests(unittest.TestCase):
    setUp = OfflineGitPreparationTests.setUp
    cleanup = OfflineGitPreparationTests.cleanup

    def test_canonical_model_order_is_shared_by_policy_and_dispatch(self):
        self.args.models = ["grok", "codex"]
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            job, manifest, env = runner.prepare(self.args)
        self.assertEqual(self.args.models, ["codex", "grok"])
        self.assertEqual(manifest["policy"]["models"], self.args.models)
        process = Mock(pid=123)
        process.wait.side_effect = subprocess.TimeoutExpired("fixture", 1)
        with patch.object(runner.subprocess, "Popen", return_value=process):
            runner._dispatch_locked(self.args, job, manifest, env, time.monotonic() + 1)
        argv = runner.load_json(job / "dispatch-request.json")["argv"]
        self.assertEqual(argv[argv.index("--models") + 1], "codex,grok")


class V6ControlShapeTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_identity_top_and_nested_shapes_revoke_existing_pass(self):
        valid = dict(self.outcome)
        cases = [None, [], 'invalid', 3]
        cases.extend(dict(valid, **fields) for fields in [
            {'supervisor_pid': 12, 'supervisor_identity': []},
            {'dispatch_pid': 12, 'dispatch_identity': 'invalid'},
            {'controller_pid': True}, {'spawn_intent': []},
            {'worker_identities': []}, {'worker_identities': {'codex': None}},
            {'worker_identities': {'codex': {'pid': 12, 'start': [], 'platform': 'darwin'}}},
            {'worker_identities': {'codex': {'pid': 12, 'reused': True, 'worker_started': None}}},
        ])
        path = self.job / 'dispatch-identity.json'
        for value in cases:
            with self.subTest(value=value):
                path.unlink(missing_ok=True)
                runner.write_json(self.job / 'manifest.json', self.manifest)
                self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
                runner.write_json(path, value)
                result = runner.collect(self.job)
                self.assertEqual(result['verdict'], 'FAILED')
                self.assertEqual(runner.load_json(self.job / 'attestation.json')['verdict'], 'PASS')
                self.assertIsNone(result['attestation_path'])

    def test_manifest_nested_shapes_never_break_failure_path(self):
        cases = [dict(self.manifest, provenance=value) for value in (None, [], 'invalid', {})]
        cases += [dict(self.manifest, provenance=dict(self.manifest['provenance'], mmrun_home=value))
                  for value in (None, [], {}, 12)]
        cases += [dict(self.manifest, **{key:value}) for key,value in (
            ('policy', []), ('worker_identities', []), ('controller_identity', []),
            ('completion_observed', 'yes'), ('mmrun_run_id', {}))]
        for value in cases:
            with self.subTest(value=value):
                runner.write_json(self.job / 'manifest.json', value)
                self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')

    def test_receipt_nested_identity_and_preparing_shapes_fail_closed(self):
        for fields in ({'supervisor_pid': 12, 'supervisor_identity': []},
                       {'worker_identities': {'codex': None}}, {'dispatch_pid': '12'}):
            with self.subTest(fields=fields):
                runner.write_json(self.job / 'dispatch-result.json', dict(self.outcome, **fields))
                self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
        (self.job / 'manifest.json').unlink()
        for value in (None, [], {'controller_pid': 12, 'controller_identity': []}):
            runner.write_json(self.job / 'preparing.json', value)
            with self.assertRaises(runner.ReviewError):
                runner.require_quiescent(self.job)

    def test_completion_observation_survives_repeated_missing_receipt_collection(self):
        runner.write_json(self.job / 'manifest.json', dict(self.manifest, spawn_intent=True))
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        (self.job / 'dispatch-result.json').unlink()
        for _ in range(3):
            self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
            self.assertIs(runner.load_json(self.job / 'manifest.json')['completion_observed'], True)

    def test_non_object_compat_sidecar_is_controlled(self):
        provenance = copy.deepcopy(self.manifest['provenance'])
        provenance['mmrun_kind'] = 'compat'
        provenance['capture_timeout_seconds'] = 3600
        for value in (None, [], 'invalid'):
            runner.write_json(Path(str(self.executable) + '.provenance.json'), value)
            with self.assertRaisesRegex(runner.ReviewError, 'COMPAT_PROVENANCE_NOT_OBJECT'):
                runner.validate_execution_provenance(provenance)


class V6FrozenInputTests(unittest.TestCase):
    setUp = OfflineGitPreparationTests.setUp
    cleanup = OfflineGitPreparationTests.cleanup

    def test_derived_fence_binds_source_and_copy_without_changing_source(self):
        source = Path(self.provenance['input_files']['fence']['path'])
        original = source.read_bytes()
        with patch.object(runner, 'environment', return_value=(self.env, self.provenance)):
            job, manifest, env = runner.prepare(self.args)
        record = manifest['provenance']['input_files']['fence']
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(record['source_sha256'], runner.digest(source))
        self.assertNotEqual(record['source_sha256'], record['sha256'])
        self.assertEqual(Path(record['path']).read_bytes(), runner.harden_fence_bytes(original))
        self.assertTrue(Path(record['path']).read_bytes().endswith(runner.FENCE_ARTIFACT_WRITE_DENY))
        runner.validate_execution_provenance(manifest['provenance'])

    def test_collection_target_survives_source_mirror_removal(self):
        with patch.object(runner, 'environment', return_value=(self.env, self.provenance)):
            job, manifest, env = runner.prepare(self.args)
        self.repo.rename(self.root / 'removed-source')
        runner.validate_target_evidence(manifest)

    def test_git_fixture_ignores_inherited_repo_and_hook_configuration(self):
        sentinel_head = runner.git(self.repo, 'rev-parse', 'HEAD')
        sentinel_config = (self.repo / '.git/config').read_bytes()
        other = self.root / 'other'; other.mkdir()
        hooks = self.root / 'hooks'; hooks.mkdir()
        marker = self.root / 'hook-ran'
        hook = hooks / 'pre-commit'
        hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n'); hook.chmod(0o700)
        global_config = self.root / 'inherited.gitconfig'
        global_config.write_text('[core]\n hooksPath = ' + str(hooks) + '\n')
        pollution = {'GIT_DIR': str(self.repo / '.git'), 'GIT_WORK_TREE': str(self.repo),
                     'GIT_CONFIG_GLOBAL': str(global_config), 'GIT_CONFIG_COUNT': '1',
                     'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': str(hooks),
                     'GIT_TEMPLATE_DIR': str(hooks)}
        with patch.dict(os.environ, pollution):
            runner.git(other, 'init', '-q', '--template=')
            (other / 'new.txt').write_text('fixture')
            runner.git(other, 'add', '.')
            runner.git(other, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                       'commit', '-qm', 'isolated fixture')
        self.assertTrue((other / '.git').is_dir())
        self.assertEqual(runner.git(self.repo, 'rev-parse', 'HEAD'), sentinel_head)
        self.assertEqual((self.repo / '.git/config').read_bytes(), sentinel_config)
        self.assertFalse(marker.exists())


class V7EvidenceSnapshotTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_first_needs_review_baseline_cannot_be_replaced_with_approve(self):
        path = self.artifacts / 'codex.json'
        runner.write_json(path, dict(report(), verdict='request_changes'))
        first = runner.collect(self.job)
        self.assertEqual(first['verdict'], 'NEEDS_REVIEW')
        baseline = self.job / 'terminal-evidence.json'; original = baseline.read_bytes()
        runner.write_json(path, report())
        for _ in range(2):
            result = runner.collect(self.job)
            self.assertEqual(result['verdict'], 'FAILED')
            self.assertIn('TERMINAL_EVIDENCE_CHANGED', result['reasons'])
        self.assertEqual(baseline.read_bytes(), original)
        self.assertEqual(baseline.stat().st_mode & 0o222, 0)
        runner.write_json_once(baseline, {'replacement': True})
        self.assertEqual(baseline.read_bytes(), original)

    def test_missing_bound_terminal_baseline_never_recreates(self):
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        (self.job / 'terminal-evidence.json').unlink()
        self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
        self.assertFalse((self.job / 'terminal-evidence.json').exists())

    def test_semantic_status_and_metadata_are_bound_to_recorded_snapshot(self):
        original_read = runner.read_bytes_snapshot
        for name in ('codex.status', 'run.meta', 'codex.meta'):
            target = self.artifacts / name; original = target.read_bytes()
            mutated = False
            def interleave(path, **kwargs):
                nonlocal mutated
                result = original_read(path, **kwargs)
                if path == self.artifacts / 'codex.json' and not mutated:
                    mutated = True; target.write_text('FAIL:1' if name.endswith('status') else 'different=value\n')
                return result
            with self.subTest(name=name), patch.object(runner, 'read_bytes_snapshot', side_effect=interleave):
                result = runner.collect(self.job)
                self.assertEqual(result['verdict'], 'FAILED')
                self.assertIn('Evidence changed during collection', result['reasons'])
            target.write_bytes(original)

    def test_deep_json_report_and_control_records_are_controlled(self):
        deep = '[' * 2000 + '0' + ']' * 2000
        for path in (self.artifacts / 'codex.json', self.job / 'manifest.json'):
            original = path.read_bytes(); path.write_text(deep)
            self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
            with self.assertRaises(runner.ReviewError):
                runner.load_json(path)
            path.write_bytes(original)
        with self.assertRaisesRegex(runner.ReviewError, 'JSON_TOO_DEEP'):
            runner.parse_json_bytes(('[' * 150 + '0' + ']' * 150).encode())

    def test_artifact_limits_precede_reads_and_hashes(self):
        for name in ('codex.status', 'run.meta', 'codex.json', 'codex.out'):
            target = self.artifacts / name; original = target.read_bytes()
            with target.open('wb') as stream:
                stream.truncate(runner.artifact_limit(target) + 1)
            with self.subTest(name=name), patch.object(os, 'open', wraps=os.open) as opened:
                with self.assertRaisesRegex(runner.ReviewError, 'NOT_REGULAR_OR_OVERSIZED'):
                    runner.artifact_digest(target)
                opened.assert_not_called()
            result = runner.collect(self.job)
            self.assertEqual(result['verdict'], 'FAILED')
            target.write_bytes(original)

    def test_output_requires_utf8_nonwhitespace_text(self):
        path = self.artifacts / 'codex.out'
        for value in (b' \n\t', b'valid prefix\xff'):
            path.write_bytes(value)
            self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')

    def test_dispatch_request_and_inputs_remain_required_after_pass(self):
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        request = self.job / 'dispatch-request.json'; request.unlink()
        self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')

    def test_empty_delta_timeout_becomes_controlled_error(self):
        with patch.object(runner, 'bounded_command', side_effect=subprocess.TimeoutExpired('git', 300)):
            with self.assertRaisesRegex(runner.ReviewError, 'DELTA_CHECK_TIMEOUT'):
                runner.empty_delta(self.frozen, BASE, HEAD)

    def test_real_child_is_reaped_after_identity_query_failure(self):
        spec = importlib.util.spec_from_file_location('v7_real_dispatch', Path(runner.__file__).with_name('runner_dispatch.py'))
        helper = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'review_runner': runner}):
            spec.loader.exec_module(helper)
        self.executable.write_text('#!' + sys.executable + '\nimport sys\nprint("local fixture completed")\nsys.exit(17)\n')
        self.executable.chmod(0o700)
        provenance = self.manifest['provenance']
        provenance['mmrun_sha256'] = runner.digest(self.executable)
        request = {'schema_version': 1, 'job_id': self.job.name, 'argv': [str(self.executable)],
                   'stdin': os.devnull, 'cwd': str(self.job), 'provenance': provenance,
                   'executable_sha256': provenance['mmrun_sha256']}
        runner.write_json(self.job / 'dispatch-request.json', request)
        parent_identity = runner.process_identity(os.getpid())
        with patch.object(helper, 'process_identity', side_effect=[parent_identity, runner.ReviewError('temporary query failure')]), patch.dict(
                os.environ, {'MMRUN_D': str(self.root), 'CODEX_HOME': str(self.root)}):
            self.assertEqual(helper.supervise(self.job), 0)
        outcome = runner.load_json(self.job / 'dispatch-result.json')
        self.assertIs(outcome['started'], True)
        self.assertEqual(outcome['exit_code'], 17)
        self.assertEqual((self.job / 'dispatch.stdout').read_text(), 'local fixture completed\n')

    def test_post_spawn_identity_persistence_failure_still_records_actual_exit(self):
        spec = importlib.util.spec_from_file_location('v7_dispatch', Path(runner.__file__).with_name('runner_dispatch.py'))
        helper = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'review_runner': runner}):
            spec.loader.exec_module(helper)
        request = runner.load_json(self.job / 'dispatch-request.json')
        request.update(stdin=os.devnull, cwd=str(self.job))
        runner.write_json(self.job / 'dispatch-request.json', request)
        proc = Mock(pid=7654321); proc.wait.return_value = 17
        write = helper.write_json; failed = False
        def write_with_failure(path, value):
            nonlocal failed
            if path.name == 'dispatch-identity.json' and value.get('started') is True and not failed:
                failed = True; raise OSError('transient write')
            return write(path, value)
        identity = {'pid': os.getpid(), 'platform': 'darwin', 'start': 'fixture'}
        with patch.object(helper, 'write_json', side_effect=write_with_failure), patch.object(
                helper, 'process_identity', return_value=identity), patch.object(helper.subprocess, 'Popen', return_value=proc), patch.dict(
                os.environ, {'MMRUN_D': str(self.root), 'CODEX_HOME': str(self.root)}):
            self.assertEqual(helper.supervise(self.job), 0)
        outcome = runner.load_json(self.job / 'dispatch-result.json')
        self.assertIs(outcome['started'], True)
        self.assertEqual(outcome['exit_code'], 17)
        proc.wait.assert_called_once(); proc.kill.assert_not_called(); proc.terminate.assert_not_called()


class V7ProfileAllowlistTests(unittest.TestCase):
    def test_filesystem_permission_values_are_explicit_read_or_deny_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); codex_home = root / 'codex'; codex_home.mkdir()
            executable = root / 'mmrun'; executable.write_text('fixture')
            (root / 'review.schema.json').write_text('{}')
            args = argparse.Namespace(mmrun_home=str(root / 'mmruns'), job_id='fixture', mmrun_d=str(root),
                                      mmrun=str(executable), mmrun_kind='upstream', models=['codex'], codex_home=str(codex_home))
            home = Path.home()
            base = 'sandbox_mode="read-only"\ndefault_permissions="fixture"\n[permissions.fixture.filesystem]\n":root"="read"\n'
            for path in (root / 'mmruns', home / '.claude/projects', home / '.grok/sessions'):
                base += json.dumps(str(path)) + '="deny"\n'
            for value, accepted in [('"read"', True), ('"deny"', True), ('"write"', False),
                                    ('"rw"', False), ('"read-write"', False), ('{mode="write"}', False),
                                    ('true', False), ('["read"]', False), ('42', False)]:
                with self.subTest(value=value):
                    (codex_home / 'mm.config.toml').write_text(base + '"/fixture-extra"=' + value + '\n')
                    if accepted:
                        runner.environment(args)
                    else:
                        with self.assertRaisesRegex(runner.ReviewError, 'CODEX_PERMISSION_VALUE_INVALID'):
                            runner.environment(args)


class V8TerminalAndIdentityTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_failed_model_status_cannot_be_repaired_into_same_attempt_pass(self):
        status = self.artifacts / 'codex.status'; status.write_text('FAIL:1')
        (self.artifacts / 'codex.meta').write_text('exit=1\n')
        self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
        proof_path = self.job / 'terminal-failure.json'; original = proof_path.read_bytes()
        self.assertIn({'path': 'codex.status', 'sha256': runner.artifact_digest(status)}, runner.load_json(proof_path)['artifacts'])
        status.write_text('DONE')
        (self.artifacts / 'codex.meta').write_text('exit=0\n')
        runner.write_json(self.artifacts / 'codex.json', report())
        for _ in range(2):
            result = runner.collect(self.job)
            self.assertEqual(result['verdict'], 'FAILED')
            self.assertIn('ATTEMPT_PREVIOUSLY_FAILED', result['reasons'])
        self.assertEqual(proof_path.read_bytes(), original)
        self.assertFalse((self.job / 'terminal-evidence.json').exists())

    def test_nonzero_dispatch_cannot_be_repaired_into_same_attempt_pass(self):
        runner.write_json(self.job / 'dispatch-result.json', dict(self.outcome, exit_code=17))
        self.assertEqual(runner.collect(self.job)['verdict'], 'FAILED')
        proof = runner.load_json(self.job / 'terminal-failure.json')
        self.assertEqual(proof['dispatch_receipt_sha256'], runner.artifact_digest(self.job / 'dispatch-result.json'))
        runner.write_json(self.job / 'dispatch-result.json', self.outcome)
        self.assertEqual(runner.collect(self.job)['reasons'], ['ATTEMPT_PREVIOUSLY_FAILED'])

    def test_transient_status_read_does_not_create_failed_terminal_latch(self):
        original = runner.read_text_snapshot
        def transient(path):
            if path.name == 'codex.status':
                raise runner.CollectionUnavailable('temporarily unavailable')
            return original(path)
        with patch.object(runner, 'read_text_snapshot', side_effect=transient):
            self.assertEqual(runner.collect(self.job)['verdict'], 'RUNNING_TIMEOUT')
        self.assertFalse((self.job / 'terminal-failure.json').exists())
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')

    def test_release_version_is_bound_to_original_request_and_terminal_baseline(self):
        self.manifest.update(kind='release', version='1.2.3', policy=runner.review_policy('release', ['codex', 'grok']))
        request = runner.load_json(self.job / 'dispatch-request.json')
        request['candidate'] = runner.candidate_identity(self.manifest)
        runner.write_json(self.job / 'dispatch-request.json', request)
        self.manifest['dispatch_request_sha256'] = runner.artifact_digest(self.job / 'dispatch-request.json')
        runner.write_json(self.job / 'dispatch-result.json', dict(self.outcome, request_sha256=self.manifest['dispatch_request_sha256']))
        runner.write_json(self.job / 'manifest.json', self.manifest)
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        self.assertEqual(runner.load_json(self.job / 'terminal-evidence.json')['candidate']['version'], '1.2.3')
        changed = runner.load_json(self.job / 'manifest.json'); changed['version'] = '9.9.9'
        runner.write_json(self.job / 'manifest.json', changed)
        self.assertEqual(runner.collect(self.job)['reasons'], ['DISPATCH_REQUEST_CONTRACT_MISMATCH'])

    def test_model_budget_starts_after_preparation_completes(self):
        clock = [0]
        @contextlib.contextmanager
        def prepared(args):
            clock[0] = 90
            yield self.job, self.manifest, {}
        args = argparse.Namespace(timeout=60)
        def dispatched(args, job, manifest, env, deadline):
            self.assertEqual(deadline, 150)
            return {'verdict': 'RUNNING_TIMEOUT'}
        with patch.object(runner, 'preparing', prepared), patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(
                runner, '_dispatch_locked', side_effect=dispatched):
            self.assertEqual(runner.run(args)['verdict'], 'RUNNING_TIMEOUT')


class V8BoundedControllerTests(unittest.TestCase):
    def test_real_command_stream_caps_kill_and_reap_owned_group(self):
        original_spawn = runner.subprocess.Popen
        for fd in (1, 2):
            spawned = []
            def spawn(*args, **kwargs):
                child = original_spawn(*args, **kwargs); spawned.append(child); return child
            with self.subTest(fd=fd), patch.object(runner.subprocess, 'Popen', side_effect=spawn), patch.object(
                    runner.os, 'killpg', wraps=runner.os.killpg) as kill:
                with self.assertRaisesRegex(runner.ReviewError, 'PREPARATION_COMMAND_OUTPUT_LIMIT'):
                    runner.bounded_command([sys.executable, '-c', 'import os;os.write(' + str(fd) + ',b"x"*65536)'],
                                           stdout_limit=1024, stderr_limit=1024, timeout=10)
            self.assertIsNotNone(spawned[0].poll())
            kill.assert_called_with(spawned[0].pid, runner.signal.SIGKILL)

    def test_real_closed_pipes_do_not_allow_unbounded_wait(self):
        original_spawn = runner.subprocess.Popen; spawned = []
        def spawn(*args, **kwargs):
            child = original_spawn(*args, **kwargs); spawned.append(child); return child
        with patch.object(runner.subprocess, 'Popen', side_effect=spawn):
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.bounded_command([sys.executable, '-c', 'import os,time;os.close(1);os.close(2);time.sleep(30)'], timeout=0.2)
        self.assertIsNotNone(spawned[0].poll())


class V8ReleasePromptTests(unittest.TestCase):
    setUp = OfflineGitPreparationTests.setUp
    cleanup = OfflineGitPreparationTests.cleanup

    def test_release_kind_and_version_are_in_both_notes_and_empty_delta_prompt(self):
        with patch.object(runner, 'environment', return_value=(self.env, self.provenance)):
            job, manifest, _ = runner.prepare(self.args)
        for filename in ('review-notes.txt', 'release-prompt.txt'):
            text = (job / filename).read_text()
            self.assertIn('Review kind: release', text)
            self.assertIn('Release version: 1.2.3', text)


class V8HistoricalEvidenceTests(unittest.TestCase):
    setUp = CollectTests.setUp
    git_reply = CollectTests.git_reply

    def test_live_profile_change_withholds_current_approval_and_preserves_history(self):
        first = runner.collect(self.job); self.assertEqual(first['verdict'], 'PASS')
        path = runner.attestation_path(self.manifest); original = path.read_bytes()
        profile = Path(self.manifest['provenance']['input_files']['codex_profile']['path'])
        profile_bytes = profile.read_bytes(); profile.write_text('new personal configuration')
        current = runner.collect(self.job)
        self.assertEqual(current['verdict'], 'RUNNING_TIMEOUT'); self.assertIsNone(current['attestation_path'])
        self.assertEqual(path.read_bytes(), original)
        profile.write_bytes(profile_bytes)
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        self.assertEqual(path.read_bytes(), original)

    def test_live_upstream_change_preserves_original_completed_report(self):
        self.assertEqual(runner.collect(self.job)['verdict'], 'PASS')
        path = runner.attestation_path(self.manifest); original = path.read_bytes()
        self.executable.write_text('upgraded personal upstream')
        current = runner.collect(self.job)
        self.assertEqual(current['verdict'], 'RUNNING_TIMEOUT'); self.assertIsNone(current['attestation_path'])
        self.assertEqual(path.read_bytes(), original)

    def test_current_invalid_evidence_does_not_overwrite_completed_needs_review(self):
        runner.write_json(self.artifacts / 'codex.json', dict(report(), verdict='request_changes'))
        self.assertEqual(runner.collect(self.job)['verdict'], 'NEEDS_REVIEW')
        path = runner.attestation_path(self.manifest); original = path.read_bytes()
        (self.artifacts / 'codex.json').unlink()
        current = runner.collect(self.job)
        self.assertEqual(current['verdict'], 'FAILED'); self.assertIsNone(current['attestation_path'])
        self.assertEqual(current['job_id'], self.job.name)
        self.assertEqual(path.read_bytes(), original)
        self.assertIn('codex', runner.load_json(path, max_bytes=runner.MAX_ATTESTATION_BYTES)['reports'])

    def test_digest_and_durable_directory_reject_unsafe_or_oversized_inputs(self):
        regular = self.root / 'regular'; regular.write_text('fixture')
        link = self.root / 'directory-link'; link.symlink_to(self.job, target_is_directory=True)
        for path in (regular, link):
            with self.subTest(path=path), self.assertRaises(runner.ReviewError):
                runner.durable_mkdir(path)
        with self.assertRaises(runner.ReviewError):
            runner.digest(link / 'manifest.json')
        with regular.open('wb') as stream:
            stream.truncate(runner.MAX_REPORT_BYTES + 1)
        with patch.object(os, 'open', wraps=os.open) as opened:
            with self.assertRaisesRegex(runner.ReviewError, 'NOT_REGULAR_OR_OVERSIZED'):
                runner.digest(regular)
            opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
