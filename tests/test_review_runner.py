"""Offline review runner tests: subprocesses/models are mocked, no mmrun invocation."""

import argparse
import copy
import importlib.util
import json
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
            path = Path(tmp) / "report.json"
            for text in ('{"verdict":"approve","verdict":"request_changes"}', '{"x":NaN}'):
                path.write_text(text)
                with self.assertRaises(runner.ReviewError):
                    runner.load_json(path)

    def test_raw_streams_never_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "codex.raw"
            path.write_text("not evidence")
            with self.assertRaises(runner.ReviewError):
                runner.digest(path)


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.job = self.root / "reviews/job-1"
        self.job.mkdir(parents=True)
        self.frozen = self.job / "frozen"
        self.frozen.mkdir()
        self.artifacts = self.root / "mmruns" / RUN_ID
        self.artifacts.mkdir(parents=True)
        self.manifest = {"schema_version": 1, "job_id": "job-1", "kind": "pr", "repo": str(self.frozen), "source_repo": str(self.root / "repo"),
                         "base_sha": BASE, "head_sha": HEAD, "merge_base_sha": BASE, "tree_sha": TREE, "frozen_checkout": str(self.frozen),
                         "policy": {"version": runner.POLICY_VERSION, "models": ["codex", "grok"]},
                         "provenance": {"mmrun_home": str(self.root / "mmruns"), "session": "multica-job-1"},
                         "mmrun_run_id": RUN_ID}
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
        self.assertEqual(runner.collect(self.job)["verdict"], "RUNNING_TIMEOUT")
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
        self.manifest.update(kind="release", merge_base_sha=ancestor)
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


class LaunchTests(unittest.TestCase):
    def test_subprocess_command_failure_is_checked(self):
        with patch.object(runner.subprocess, "run", return_value=Mock(returncode=1, stderr="no commit", stdout="")) as call:
            with self.assertRaises(runner.ReviewError):
                runner.git(Path("/repo"), "rev-parse", "HEAD")
            self.assertEqual(call.call_args.kwargs["timeout"], 30)

    def test_reject_short_sha_before_any_subprocess(self):
        with patch.object(runner.subprocess, "run") as call:
            with self.assertRaises(runner.ReviewError):
                runner.check_target(Path("/repo"), "abc", HEAD)
            call.assert_not_called()

    def test_timeout_does_not_kill_process_or_remove_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            frozen = job / "frozen"
            frozen.mkdir()
            manifest = {"mmrun_run_id": None, "provenance": {"mmrun_home": str(job / "mmruns")},
                        "controller_checkout": str(job), "frozen_checkout": str(frozen)}
            args = argparse.Namespace(timeout=1, mmrun="/trusted/mmrun", base=BASE, models=["codex", "grok"], poll_interval=1)
            process = Mock(pid=123)
            process.wait.side_effect = subprocess.TimeoutExpired("mmrun", 1)
            with patch.object(runner, "prepare", return_value=(job, manifest, {})), patch.object(runner.subprocess, "Popen", return_value=process) as popen:
                result = runner.run(args)
            self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")
            process.kill.assert_not_called()
            process.terminate.assert_not_called()
            self.assertTrue(frozen.exists())
            self.assertEqual(popen.call_args.kwargs["cwd"], str(job))
            self.assertNotIn("--sandbox", popen.call_args.args[0])

    def test_redirected_codex_home_requires_explicit_choice(self):
        args = argparse.Namespace(mmrun_home="/tmp/test-mmruns", job_id="job", mmrun_d="/tmp/test-mmd",
                                  mmrun="/tmp/test-mmrun", models=["codex"], codex_home=None)
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
            sidecar = {"version": "mmrun-grok-transport-v1", "security_flags_changed": False,
                       "output": str(executable), "output_sha256": runner.digest(executable),
                       "source": str(source), "source_sha256": runner.digest(source),
                       "helper": str(helper), "helper_sha256": runner.digest(helper)}
            runner.write_json(Path(str(executable) + ".provenance.json"), sidecar)
            args = argparse.Namespace(mmrun_home=str(root / "mmruns"), job_id="job", mmrun_d=str(root),
                                      mmrun=str(executable), models=["grok"], codex_home=None)
            _, provenance = runner.environment(args)
            self.assertEqual(provenance["compatibility"], sidecar)
            helper.write_text("changed helper\n")
            with self.assertRaisesRegex(runner.ReviewError, "helper changed"):
                runner.environment(args)


if __name__ == "__main__":
    unittest.main()
