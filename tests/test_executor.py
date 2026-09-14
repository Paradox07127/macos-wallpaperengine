"""No-network regressions for immutable intake and static status publishing."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/multica"))
import executor


class FakeCommands:
    def __init__(self, pr):
        self.pr = pr
        self.statuses = []
        self.comments = []
        self.updates = []
        self.lose_comment_ack = False

    def gh(self, endpoint, payload=None):
        if payload is not None:
            self.statuses.append((endpoint, copy.deepcopy(payload)))
            return {}
        if "/pulls/" in endpoint:
            return copy.deepcopy(self.pr)
        raise AssertionError("Unexpected GitHub read: " + endpoint)

    def multica(self, argv, body=None):
        if argv[:3] == ["issue", "comment", "list"]:
            return copy.deepcopy(self.comments)
        if argv[:3] == ["issue", "comment", "add"]:
            self.comments.append({"id": "comment-id", "content": body})
            if self.lose_comment_ack:
                self.lose_comment_ack = False
                raise executor.bridge.BridgeError("Response lost after comment was written")
            return {"id": "comment-id"}
        if argv[:2] == ["issue", "update"]:
            self.updates.append(argv)
            return {}
        raise AssertionError("Unexpected Multica command: " + repr(argv))


class ExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cfg = {
            "repository": "Paradox07127/macos-wallpaperengine", "policy_version": "1",
            "repository_path": str(self.root / "source"), "target_branch": "main",
            "jobs_dir": str(self.root / "jobs"), "review_state_dir": str(self.root / "reviews"),
            "review_models": ["codex", "grok"],
        }
        Path(self.cfg["repository_path"]).mkdir()
        self.head, self.base = "a" * 40, "b" * 40
        key = "|".join([self.cfg["repository"], self.head, self.base, "1", "pr", "7", ""])
        self.job_id = "pr-7-" + executor.bridge.digest(key)[:24]
        self.job_dir = Path(self.cfg["jobs_dir"]) / self.job_id
        self.job_dir.mkdir(parents=True)
        self.req = {
            "schema_version": 1, "job_id": self.job_id, "repository": self.cfg["repository"],
            "repository_path": self.cfg["repository_path"], "policy_version": "1", "kind": "pr",
            "pr_number": 7, "head_sha": self.head, "base_sha": self.base,
            "multica_issue_id": "internal-issue-id",
        }
        self.write_request()
        self.review_dir = Path(self.cfg["review_state_dir"]) / self.job_id
        self.review_dir.mkdir(parents=True)
        self.manifest = {
            "schema_version": 1, "job_id": self.job_id, "kind": "pr",
            "repo": str(self.review_dir / "frozen"), "source_repo": self.cfg["repository_path"],
            "head_sha": self.head, "base_sha": self.base,
            "policy": {"version": executor.runner.POLICY_VERSION, "models": ["codex", "grok"]},
        }
        self.write_manifest()
        self.pr = {"state": "open", "draft": False,
                   "head": {"sha": self.head, "repo": {"full_name": self.cfg["repository"]}},
                   "base": {"sha": self.base, "ref": "main"}}
        self.commands = FakeCommands(self.pr)
        self.collector = self.enterContext(patch.object(executor.runner, "collect", return_value={
            "verdict": "PASS", "reasons": [], "head_sha": self.head,
        }))

    def write_request(self):
        (self.job_dir / "request.json").write_text(json.dumps(self.req))

    def write_manifest(self):
        (self.review_dir / "manifest.json").write_text(json.dumps(self.manifest))

    def publish(self):
        return executor.publish_result(self.cfg, self.job_id, self.commands)

    def test_current_sha_pass_publishes_static_status_once(self):
        self.assertEqual(self.publish()["state"], "success")
        self.assertEqual(self.publish()["state"], "already_published")
        self.assertEqual(len(self.commands.statuses), 1)
        endpoint, payload = self.commands.statuses[0]
        self.assertTrue(endpoint.endswith("/statuses/" + self.head))
        self.assertEqual(payload["state"], "success")
        self.assertIn("Static review", payload["description"])
        self.assertEqual(len(self.commands.comments), 1)
        self.assertEqual(len(self.commands.updates), 1)
        self.assertIn("in_review", self.commands.updates[0])
        self.collector.assert_called_once_with(self.review_dir)

    def test_new_head_or_base_never_marks_old_sha_success(self):
        for field in ("head", "base"):
            with self.subTest(field=field):
                self.commands.pr = copy.deepcopy(self.pr)
                self.commands.pr[field]["sha"] = "c" * 40
                receipt = self.job_dir / "published.json"
                receipt.unlink(missing_ok=True)
                self.assertEqual(self.publish()["state"], "superseded")
                self.assertEqual(self.commands.statuses, [])
                self.assertEqual(self.commands.comments, [])

    def test_fork_deleted_repo_draft_closed_or_wrong_branch_cannot_execute(self):
        targets = []
        for update in ({"repo": {"full_name": "someone/fork"}}, {"repo": None}):
            target = copy.deepcopy(self.pr)
            target["head"].update(update)
            targets.append(target)
        targets += [dict(self.pr, draft=True), dict(self.pr, state="closed")]
        wrong_branch = copy.deepcopy(self.pr)
        wrong_branch["base"]["ref"] = "other"
        targets.append(wrong_branch)
        with patch.object(executor.subprocess, "run") as process:
            for target in targets:
                with self.subTest(target=target):
                    self.commands.pr = target
                    with patch.object(executor.bridge, "Commands", return_value=self.commands):
                        self.assertEqual(executor.run_job(self.cfg, self.job_id)["verdict"], "SUPERSEDED")
            process.assert_not_called()
            self.collector.assert_not_called()

    def test_tampered_request_immutable_fields_are_rejected(self):
        original = copy.deepcopy(self.req)
        for key, value in (("head_sha", "c" * 40), ("base_sha", "d" * 40),
                           ("pr_number", 8), ("kind", "release"), ("policy_version", "old"),
                           ("schema_version", True)):
            with self.subTest(key=key):
                self.req = dict(original, **{key: value})
                self.write_request()
                with self.assertRaises(executor.JobError):
                    self.publish()
        self.assertEqual(self.commands.statuses, [])
        self.collector.assert_not_called()

    def test_fork_cannot_publish_even_with_pass_evidence(self):
        self.commands.pr["head"]["repo"]["full_name"] = "someone/fork"
        self.assertEqual(self.publish()["state"], "superseded")
        self.assertEqual(self.commands.statuses, [])
        self.assertEqual(self.commands.comments, [])

    def test_manifest_or_reviewer_set_changes_fail_before_collect(self):
        original = copy.deepcopy(self.manifest)
        mutations = [{"head_sha": "c" * 40}, {"base_sha": "c" * 40},
                     {"kind": "release"}, {"source_repo": str(self.root / "other")},
                     {"policy": {"version": executor.runner.POLICY_VERSION, "models": ["codex"]}},
                     {"policy": {"version": "old", "models": ["codex", "grok"]}}]
        for update in mutations:
            with self.subTest(update=update):
                self.manifest = dict(original, **update)
                self.write_manifest()
                with self.assertRaises(executor.JobError):
                    self.publish()
        self.collector.assert_not_called()
        self.assertEqual(self.commands.statuses, [])

    def test_unstarted_or_timeout_is_pending_never_green(self):
        (self.review_dir / "manifest.json").unlink()
        self.assertEqual(self.publish()["state"], "pending")
        self.write_manifest()
        self.collector.return_value = {"verdict": "RUNNING_TIMEOUT"}
        self.assertEqual(self.publish()["state"], "pending")
        self.assertEqual(self.commands.statuses, [])
        self.assertFalse((self.job_dir / "published.json").exists())

    def test_runner_failure_before_manifest_publishes_failure(self):
        (self.review_dir / 'manifest.json').unlink()
        (self.job_dir / 'execution.json').write_text(json.dumps({'job_id': self.job_id, 'started_at': 'fixture'}))
        (self.job_dir / 'execution-result.json').write_text(json.dumps({
            'job_id': self.job_id, 'verdict': 'FAILED', 'reasons': ['mm profile missing']}))
        self.assertEqual(self.publish()['state'], 'failure')
        self.assertEqual(self.commands.statuses[0][1]['state'], 'failure')
        self.collector.assert_not_called()

    def test_execution_result_cannot_pass_without_manifest_or_start_record(self):
        (self.review_dir / 'manifest.json').unlink()
        result = self.job_dir / 'execution-result.json'
        result.write_text(json.dumps({'job_id': self.job_id, 'verdict': 'FAILED'}))
        self.assertEqual(self.publish()['state'], 'pending')
        (self.job_dir / 'execution.json').write_text(json.dumps({'job_id': self.job_id}))
        result.write_text(json.dumps({'job_id': self.job_id, 'verdict': 'PASS'}))
        self.assertEqual(self.publish()['state'], 'pending')
        self.assertEqual(self.commands.statuses, [])

    def test_execution_failure_record_must_match_job(self):
        (self.review_dir / 'manifest.json').unlink()
        (self.job_dir / 'execution.json').write_text(json.dumps({'job_id': self.job_id}))
        (self.job_dir / 'execution-result.json').write_text(json.dumps({'job_id': 'another-job', 'verdict': 'FAILED'}))
        with self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(self.commands.statuses, [])

    def test_superseded_receipt_recovers_when_original_target_returns(self):
        self.commands.pr['head']['sha'] = 'c' * 40
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.statuses, [])
        self.commands.pr['head']['sha'] = self.head
        self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(self.publish()['state'], 'already_published')
        self.assertEqual(len(self.commands.statuses), 1)
        self.assertEqual(json.loads((self.job_dir / 'published.json').read_text())['state'], 'success')

    def test_collector_failed_evidence_cannot_be_overridden_by_stale_pass(self):
        (self.review_dir / "attestation.json").write_text('{"verdict":"PASS"}')
        self.collector.return_value = {"verdict": "FAILED", "reasons": ["tampered report"]}
        self.assertEqual(self.publish()["state"], "failure")
        self.assertEqual(self.commands.statuses[0][1]["state"], "failure")

    def test_lost_comment_ack_is_reconciled_without_duplicate_comment(self):
        self.commands.lose_comment_ack = True
        with self.assertRaises(executor.bridge.BridgeError):
            self.publish()
        self.assertFalse((self.job_dir / "published.json").exists())
        self.assertEqual(len(self.commands.comments), 1)
        self.assertEqual(self.publish()["state"], "success")
        self.assertEqual(len(self.commands.comments), 1)

    def test_request_traversal_and_symlinks_rejected(self):
        for job_id in ("../escape", self.job_id + "/../escape", "/tmp/request"):
            with self.subTest(job_id=job_id), self.assertRaises(executor.JobError):
                executor.request(self.cfg, job_id)
        path = self.job_dir / "request.json"
        path.rename(self.root / "request.json")
        path.symlink_to(self.root / "request.json")
        with self.assertRaises(executor.JobError):
            executor.request(self.cfg, self.job_id)

    def test_missing_multica_mapping_never_publishes(self):
        self.req["multica_issue_id"] = None
        self.write_request()
        self.assertEqual(self.publish()["state"], "awaiting_issue_mapping")
        self.assertEqual(self.commands.statuses, [])
        self.collector.assert_not_called()

    def test_main_reports_validation_error_without_traceback(self):
        output = io.StringIO()
        with patch.object(executor.bridge, "load_config", return_value=self.cfg), \
                patch.object(executor, "request", side_effect=executor.runner.ReviewError("bad evidence")), \
                contextlib.redirect_stdout(output):
            result = executor.main(["--config", "fixture", "collect", "--job-id", self.job_id])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue())["verdict"], "FAILED")


if __name__ == "__main__":
    unittest.main()
