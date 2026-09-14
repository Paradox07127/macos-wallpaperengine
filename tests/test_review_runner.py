"""Offline review runner tests: subprocesses/models are mocked, no mmrun invocation."""

import argparse
import copy
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
                                        "mmrun_path": str(self.executable), "mmrun_sha256": runner.digest(self.executable)},
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
        self.manifest.update(kind="release", merge_base_sha=ancestor)
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
        for extra in ({"dispatch_exit": 1}, {"dispatch_exit": 0}, {"dispatch_error": "cannot spawn"}):
            with self.subTest(extra=extra):
                manifest = dict(self.manifest, mmrun_run_id=None, **extra)
                runner.write_json(self.job / "manifest.json", manifest)
                self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
                self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_nonzero_dispatch_even_with_run_id_fails(self):
        runner.write_json(self.job / "manifest.json", dict(self.manifest, dispatch_exit=1))
        self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")

    def test_live_and_dead_dispatch_without_run_id(self):
        runner.write_json(self.job / "manifest.json", dict(self.manifest, mmrun_run_id=None, dispatch_pid=123))
        for alive, verdict in ((True, "RUNNING_TIMEOUT"), (False, "FAILED")):
            with patch.object(runner, "process_alive", return_value=alive):
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
            self.assertEqual(runner.collect(self.job)["verdict"], "FAILED")
        call.assert_not_called()


class LaunchTests(unittest.TestCase):
    def test_subprocess_command_failure_is_checked(self):
        with patch.object(runner.subprocess, "run", return_value=Mock(returncode=1, stderr="no commit", stdout="")) as call:
            with self.assertRaises(runner.ReviewError):
                runner.git(Path("/repo"), "rev-parse", "HEAD")
            self.assertEqual(call.call_args.kwargs["timeout"], 30)

    def test_worktree_command_can_have_longer_preparation_timeout(self):
        with patch.object(runner.subprocess, "run", return_value=Mock(returncode=0, stdout="", stderr="")) as call:
            runner.git(Path("/repo"), "worktree", "add", "--detach", "/frozen", HEAD, timeout=300)
            self.assertEqual(call.call_args.kwargs["timeout"], 300)

    def test_reject_short_sha_before_any_subprocess(self):
        with patch.object(runner.subprocess, "run") as call:
            with self.assertRaises(runner.ReviewError):
                runner.check_target(Path("/repo"), "abc", HEAD)
            call.assert_not_called()

    def test_timeout_does_not_kill_process_or_remove_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp).resolve()
            frozen = job / "frozen"
            frozen.mkdir()
            manifest = {"job_id": job.name, "kind": "pr", "mmrun_run_id": None, "provenance": {"mmrun_home": str(job / "mmruns")},
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

    def test_dispatch_spawn_error_is_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp).resolve()
            manifest = {"job_id": job.name, "kind": "pr", "mmrun_run_id": None,
                        "provenance": {"mmrun_home": str(job / "mmruns")},
                        "controller_checkout": str(job), "frozen_checkout": str(job / "frozen")}
            args = argparse.Namespace(timeout=1, mmrun="/trusted/mmrun", base=BASE, models=["codex", "grok"], poll_interval=1)
            with patch.object(runner, "prepare", return_value=(job, manifest, {})), patch.object(runner.subprocess, "Popen", side_effect=OSError("no executable")):
                self.assertEqual(runner.run(args)["verdict"], "FAILED")
            saved = runner.load_json(job / "manifest.json")
            self.assertEqual(saved["phase"], "DISPATCH_FAILED")
            self.assertIn("no executable", saved["dispatch_error"])

    def test_atomic_json_writers_use_independent_temporary_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            values = [{"worker": n, "text": str(n) * 10000} for n in range(30)]
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda value: runner.write_json(path, value), values))
            self.assertIn(runner.load_json(path), values)
            self.assertEqual(list(Path(tmp).glob("*.tmp")), [])

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

    def test_long_job_ids_have_distinct_untruncated_session_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name in ("mmrun", "review.schema.json", "fence.sb"):
                (root / name).write_text("fixture")
            args = argparse.Namespace(mmrun_home=str(root / "mmruns"), job_id="x" * 95 + "1", mmrun_d=str(root),
                                      mmrun=str(root / "mmrun"), models=["grok"], codex_home=None)
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
        runner.git(self.repo, "init", "-q")
        (self.repo / "file.txt").write_text("release fixture\n")
        runner.git(self.repo, "add", "file.txt")
        runner.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        self.head = runner.git(self.repo, "rev-parse", "HEAD")
        self.args = argparse.Namespace(repo=str(self.repo), base=self.head, head=self.head, kind="release",
                                       models=["codex", "grok"], job_id="empty-delta", state_dir=str(self.root / "reviews"),
                                       timeout=1, poll_interval=1, mmrun="/trusted/mmrun")
        self.provenance = {"mmrun_home": str(self.root / "mmruns"), "session": "fixture"}
        self.env = {"MMRUN_D": str(self.root / "mmd")}

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
            if args[:2] == ("worktree", "add"):
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
            self.assertEqual(argv[1:4], ["start", "--mode", "review"])
            self.assertIn("--schema", argv)
            self.assertNotIn("--wt", argv)
            content = kwargs["stdin"].read()
            self.assertIn(b"[empty delta]", content)
            self.assertIn(b"release fixture", content)
            job = Path(self.args.state_dir) / self.args.job_id
            self.assertEqual(runner.collect(job)["verdict"], "RUNNING_TIMEOUT")
            return process
        # subprocess.run uses Popen for Git too, so prepare before mocking.
        with patch.object(runner, "environment", return_value=(self.env, self.provenance)):
            prepared = runner.prepare(self.args)
        with patch.object(runner, "prepare", return_value=prepared), patch.object(runner.subprocess, "Popen", side_effect=launch):
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
        with patch.object(runner, "prepare", return_value=prepared), patch.object(
                runner.subprocess, "Popen", return_value=process) as launch:
            result = runner.run(self.args)
        argv = launch.call_args.args[0]
        self.assertEqual(argv[1:5], ["review", "--base", self.args.base, "--exhaustive"])
        self.assertEqual(argv[argv.index("--notes-file") + 1], str(job / "review-notes.txt"))
        self.assertEqual(result["verdict"], "RUNNING_TIMEOUT")


if __name__ == "__main__":
    unittest.main()
