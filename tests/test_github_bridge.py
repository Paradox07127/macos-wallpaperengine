"""Offline tests: all remote interactions are fakes; no live GitHub writes."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "multica" / "github_bridge.py"
spec = importlib.util.spec_from_file_location("github_bridge", MODULE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

HEAD = "a" * 40
BASE = "b" * 40
TIME = "2026-09-15T10:00:00Z"
BEFORE = "2026-09-15T09:00:00Z"
AGENT = "11111111-1111-1111-1111-111111111111"
REVIEW = "22222222-2222-2222-2222-222222222222"


class FakeCommands:
    def __init__(self):
        self.calls = []
        self.issues = {}
        self.comments = {}
        self.github_issues = []
        self.github_comments = []
        self.issue_threads = {}
        self.prs = []
        self.lose_create_ack = False
        self.lose_comment_ack = False
        self.fail_resource = None

    def gh(self, endpoint, payload=None):
        self.calls.append(("gh", endpoint, payload))
        if self.fail_resource and self.fail_resource in endpoint:
            raise bridge.BridgeError("simulated failure")
        if "/statuses/" in endpoint:
            return {"state": payload["state"]}
        if "/commits/" in endpoint:
            return {"sha": endpoint.rsplit("/", 1)[-1]}
        if "/issues/comments?" in endpoint:
            return self.github_comments
        if "/issues/" in endpoint and "/comments?" in endpoint:
            number = int(endpoint.split("/issues/", 1)[1].split("/", 1)[0])
            page = int(parse_qs(urlsplit(endpoint).query)["page"][0])
            return self.issue_threads.get(number, [])[100 * (page - 1):100 * page]
        if "/issues?" in endpoint:
            return self.github_issues
        if "/pulls?" in endpoint:
            return self.prs
        return {"full_name": bridge.ALLOWED_REPOSITORY}

    def multica(self, args, body=None):
        self.calls.append(("multica", args, body))
        if args[:2] == ["issue", "search"]:
            return {"issues": [item for item in self.issues.values()
                               if args[2] in item["title"] or args[2] in item["description"]]}
        if args[:2] == ["issue", "create"]:
            identifier = f"remote-{len(self.issues) + 1}"
            result = {"id": identifier, "title": args[args.index("--title") + 1], "description": body}
            self.issues[identifier] = result
            if self.lose_create_ack:
                self.lose_create_ack = False
                raise bridge.BridgeError("connection lost after remote creation")
            return result
        if args[:2] == ["issue", "get"]:
            return self.issues[args[2]]
        if args[:3] == ["issue", "comment", "add"]:
            identifier = args[3]
            result = {"id": "comment-1", "content": body}
            self.comments.setdefault(identifier, []).append(result)
            if self.lose_comment_ack:
                self.lose_comment_ack = False
                raise bridge.BridgeError("connection lost after remote comment")
            return result
        if args[:3] == ["issue", "comment", "list"]:
            return self.comments.get(args[3], [])
        return {"id": "unused"}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config_path = self.root / "config.json"
        self.config_path.write_text(json.dumps({
            "repository": bridge.ALLOWED_REPOSITORY, "workspace_id": AGENT,
            "triage_agent_id": AGENT, "review_agent_id": REVIEW,
            "state_path": str(self.root / "state.sqlite"),
            "repository_path": str(self.root / "repo"),
            "executor_path": str(self.root / "executor.py"),
        }))
        self.cfg = bridge.load_config(self.config_path)
        self.state = bridge.State(self.cfg["state_path"])
        self.addCleanup(self.state.db.close)
        self.remote = FakeCommands()
        self.log = []
        self.app = bridge.Bridge(self.cfg, self.state, self.remote, report=self.log.append)

    def issue(self, **changes):
        return {"id": 80, "number": 7, "title": "Regression", "body": "Steps to reproduce",
                "created_at": BEFORE, "updated_at": TIME,
                "labels": [{"name": "agent-triage"}], **changes}

    def pr(self, **changes):
        return {"id": 90, "number": 8, "title": "Change", "body": "Fixes stuff",
                "draft": False, "updated_at": TIME,
                "head": {"sha": HEAD, "repo": {"full_name": bridge.ALLOWED_REPOSITORY}},
                "base": {"sha": BASE, "ref": "main"}, **changes}

    def comment(self, identifier=201, **changes):
        return {"id": identifier, "updated_at": TIME, "created_at": BEFORE,
                "issue_url": f"https://api.github.com/repos/{bridge.ALLOWED_REPOSITORY}/issues/7",
                "html_url": f"https://github.com/{bridge.ALLOWED_REPOSITORY}/issues/7#issuecomment-{identifier}",
                "body": "Maintainer already requested an ips report and reproduction on the latest version.",
                "user": {"login": "public-maintainer", "type": "User", "email": "not-needed@example.invalid"},
                **changes}

    def seed(self):
        self.state.meta("baseline", BEFORE)
        self.state.meta("checkpoint", BEFORE)

    def writes(self):
        return [call for call in self.remote.calls if
                (call[0] == "gh" and call[2] is not None) or
                (call[0] == "multica" and (call[1][:2] == ["issue", "create"] or
                 call[1][:3] == ["issue", "comment", "add"]))]

    def test_first_poll_only_seeds_checkpoint_no_remote_calls(self):
        self.remote.github_issues = [self.issue()]
        with patch.object(bridge, "utcnow", return_value=TIME):
            self.app.poll_once()
        self.assertEqual(self.state.get("meta", "checkpoint"), TIME)
        self.assertEqual(self.remote.calls, [])

    def test_old_open_pr_requeues_when_local_policy_changes(self):
        self.seed()
        self.remote.prs = [self.pr(updated_at="2026-09-01T00:00:00Z")]
        with patch.object(bridge, "utcnow", return_value=TIME):
            self.app.poll_once()
            self.app.poll_once()
            self.cfg['policy_version'] = 'next-policy'
            self.app.poll_once()
        statuses = [c for c in self.remote.calls if c[0] == 'gh' and '/statuses/' in c[1]]
        self.assertEqual(len(statuses), 2)
        self.assertTrue(all(c[2]['state'] == 'pending' for c in statuses))
        self.assertEqual(len(self.remote.issues), 1)

    def test_deleted_fork_repository_is_metadata_only(self):
        self.app.intake_pr(self.pr(head={'sha': HEAD, 'repo': None}))
        creates = [c for c in self.remote.calls if c[0] == 'multica' and c[1][:2] == ['issue', 'create']]
        self.assertEqual(len(creates), 1)
        self.assertNotIn('--assignee-id', creates[0][1])
        self.assertFalse(any(c[0] == 'gh' and '/statuses/' in c[1] for c in self.remote.calls))

    def test_selected_issue_created_once_and_comments_stay_on_same_issue(self):
        self.app.intake_issue(self.issue(), BEFORE)
        self.app.intake_issue(self.issue(), BEFORE)
        comment = {"id": 201, "issue_url": f"https://api.github.com/repos/{bridge.ALLOWED_REPOSITORY}/issues/7",
                   "body": "More information", "updated_at": TIME, "user": {"type": "User"}}
        self.app.intake_comment(comment)
        self.app.intake_comment(comment)
        self.assertEqual(len(self.remote.issues), 1)
        self.assertEqual(len(self.remote.comments["remote-1"]), 1)
        self.assertIn("mention://agent/" + AGENT, self.remote.comments["remote-1"][0]["content"])

    def test_unselected_old_issue_never_imported(self):
        self.app.intake_issue(self.issue(labels=[]), TIME)
        self.cfg["triage_all_new"] = True
        self.app.intake_issue(self.issue(labels=[]), TIME)
        self.assertEqual(self.remote.issues, {})

    def test_comment_timestamp_update_does_not_trigger_duplicate_issue_snapshot(self):
        self.app.intake_issue(self.issue(), BEFORE)
        self.app.intake_issue(self.issue(updated_at="2026-09-15T10:10:00Z", comments=1), BEFORE)
        self.assertEqual(self.remote.comments, {})
        self.app.intake_issue(self.issue(updated_at="2026-09-15T10:11:00Z", body="Changed reproduction"), BEFORE)
        self.assertEqual(len(self.remote.comments["remote-1"]), 1)

    def test_initial_issue_contains_prior_thread_and_same_poll_comment_is_not_retriggered(self):
        comment = self.comment(body="Already asked for ips. Public link https://example.invalid/runtime.log")
        self.remote.issue_threads[7] = [comment]
        self.app.intake_issue(self.issue(comments=1), BEFORE)
        description = self.remote.issues["remote-1"]["description"]
        self.assertIn("Already asked for ips", description)
        self.assertIn("public-maintainer", description)
        self.assertNotIn("not-needed@example.invalid", description)
        self.assertIn("bridge-history-v1:", description.split("\n")[3])
        self.app.intake_comment(comment)
        self.assertEqual(self.remote.comments, {})
        self.assertFalse(any("runtime.log" in call[1] for call in self.remote.calls if call[0] == "gh"))
        changed = {**comment, "updated_at": "2026-09-15T10:15:00Z", "body": "New answer"}
        self.app.intake_comment(changed)
        self.assertEqual(len(self.remote.comments["remote-1"]), 1)

    def test_history_keeps_latest_twenty_with_total_budget_and_tail_pagination(self):
        self.remote.issue_threads[7] = [self.comment(i, body="x" * 1000) for i in range(250)]
        self.cfg["max_history_chars"] = 5000
        history, events = self.app.initial_history(self.issue(comments=250))
        self.assertLessEqual(len(history), 20)
        self.assertLessEqual(len(json.dumps(history, ensure_ascii=False)), 5000)
        self.assertEqual(history[-1]["id"], 249)
        self.assertTrue(all(item["id"] >= 230 for item in history))
        urls = [call[1] for call in self.remote.calls if call[0] == "gh"]
        self.assertTrue(all(parse_qs(urlsplit(url).query)["page"] != ["1"] for url in urls))
        self.assertEqual(len(events), len(history))

    def test_lost_create_ack_restores_initial_history_receipts(self):
        comment = self.comment()
        self.remote.issue_threads[7] = [comment]
        self.remote.lose_create_ack = True
        with self.assertRaises(bridge.BridgeError):
            self.app.intake_issue(self.issue(comments=1), BEFORE)
        self.app.intake_issue(self.issue(comments=1), BEFORE)
        self.app.intake_comment(comment)
        self.assertEqual(len(self.remote.issues), 1)
        self.assertEqual(self.remote.comments, {})

    def test_history_fetch_failure_prevents_issue_creation(self):
        self.remote.fail_resource = "issues/7/comments?"
        with self.assertRaises(bridge.BridgeError):
            self.app.intake_issue(self.issue(), BEFORE)
        self.assertEqual(self.writes(), [])

    def test_history_defangs_mentions_and_does_not_import_profile_fields(self):
        self.remote.issue_threads[7] = [self.comment(body="[@evil](mention://agent/evil) <script>",
                                                   user={"login": "release-bot", "type": "Bot", "email": "hidden@example.invalid"})]
        self.app.intake_issue(self.issue(comments=1), BEFORE)
        description = self.remote.issues["remote-1"]["description"]
        self.assertNotIn("mention://agent/evil", description)
        self.assertNotIn("<script>", description)
        self.assertNotIn("hidden@example.invalid", description)
        self.assertIn('"is_bot": true', description)

    def test_all_new_opt_in_only_new_issues(self):
        self.cfg["triage_all_new"] = True
        self.app.intake_issue(self.issue(labels=[], created_at=TIME), BEFORE)
        self.assertEqual(len(self.remote.issues), 1)

    def test_lost_create_ack_recovers_remote_without_duplicate_run(self):
        self.remote.lose_create_ack = True
        with self.assertRaises(bridge.BridgeError):
            self.app.intake_issue(self.issue(), BEFORE)
        self.app.intake_issue(self.issue(), BEFORE)
        self.assertEqual(len(self.remote.issues), 1)
        self.assertEqual(self.remote.comments, {})

    def test_ambiguous_create_with_no_marker_fails_closed(self):
        source = "github:missing:issue:1"
        self.state.operation("create:" + source, "intent")
        with self.assertRaises(bridge.BridgeError):
            self.app.ensure_issue(source, "Example", "body", AGENT)
        self.assertEqual(self.writes(), [])

    def test_lost_comment_ack_recovers_without_second_agent_trigger(self):
        self.app.intake_issue(self.issue(), BEFORE)
        self.remote.lose_comment_ack = True
        with self.assertRaises(bridge.BridgeError):
            self.app.append("remote-1", "event-2", "new evidence", AGENT)
        self.app.append("remote-1", "event-2", "new evidence", AGENT)
        self.assertEqual(len(self.remote.comments["remote-1"]), 1)

    def test_source_marker_inside_untrusted_description_does_not_hijack_mapping(self):
        token = bridge.marker("wanted-source")
        self.remote.issues["bad"] = {"id": "bad", "title": "user title", "description": token}
        self.assertIsNone(self.app.remote_issue("wanted-source"))

    def test_pr_sha_changes_reuse_issue_create_new_immutable_jobs_pending_only(self):
        self.app.intake_pr(self.pr())
        self.app.intake_pr(self.pr())
        newer = self.pr(head={"sha": "c" * 40, "repo": {"full_name": bridge.ALLOWED_REPOSITORY}})
        self.app.intake_pr(newer)
        self.assertEqual(len(self.remote.issues), 1)
        self.assertEqual(len(self.remote.comments["remote-1"]), 1)
        paths = list(Path(self.cfg["jobs_dir"]).glob("*/request.json"))
        self.assertEqual(len(paths), 2)
        for path in paths:
            data = json.loads(path.read_text())
            self.assertEqual(data["multica_issue_id"], "remote-1")
            self.assertEqual(data["base_sha"], BASE)
            self.assertEqual(data["repository_path"], self.cfg["repository_path"])
        statuses = [call[2] for call in self.remote.calls if call[0] == "gh" and call[2]]
        self.assertEqual(len(statuses), 2)
        self.assertTrue(all(value["state"] == "pending" for value in statuses))

    def test_fork_and_non_target_prs_are_unassigned_backlog_without_jobs(self):
        for change in ({"head": {"sha": HEAD, "repo": {"full_name": "attacker/repo"}}},
                       {"number": 9, "base": {"sha": BASE, "ref": "development"}}):
            self.app.intake_pr(self.pr(**change))
        creations = [call for call in self.remote.calls if call[0] == "multica" and call[1][:2] == ["issue", "create"]]
        self.assertEqual(len(creations), 2)
        for call in creations:
            self.assertNotIn("--assignee-id", call[1])
            self.assertEqual(call[1][call[1].index("--status") + 1], "backlog")
        self.assertFalse(Path(self.cfg["jobs_dir"]).exists())
        self.assertFalse(any(call[0] == "gh" and call[2] for call in self.remote.calls))

    def test_draft_pr_does_not_execute(self):
        self.app.intake_pr(self.pr(draft=True))
        self.assertEqual(self.remote.calls, [])

    def test_foreign_urls_bots_and_pr_comments_do_not_trigger_triage(self):
        self.app.intake_issue(self.issue(), BEFORE)
        for url, user in (("https://evil.invalid/issues/7", "User"),
                          (f"https://api.github.com/repos/{bridge.ALLOWED_REPOSITORY}/issues/7", "Bot"),
                          (f"https://api.github.com/repos/{bridge.ALLOWED_REPOSITORY}/issues/8", "User")):
            self.app.intake_comment({"id": 5, "body": "test", "updated_at": TIME,
                                     "issue_url": url, "user": {"type": user}})
        self.assertEqual(self.remote.comments, {})

    def test_failed_fetch_does_not_advance_checkpoint_or_write(self):
        self.seed()
        self.remote.github_issues = [self.issue()]
        self.remote.fail_resource = "issues/comments?"
        with self.assertRaises(bridge.BridgeError):
            self.app.poll_once()
        self.assertEqual(self.state.get("meta", "checkpoint"), BEFORE)
        self.assertEqual(self.writes(), [])

    def test_pagination_cap_fails_without_checkpoint_loss(self):
        self.seed()
        self.cfg["max_pages"] = 1
        self.remote.github_issues = [self.issue(number=i) for i in range(100)]
        with self.assertRaises(bridge.BridgeError):
            self.app.poll_once()
        self.assertEqual(self.state.get("meta", "checkpoint"), BEFORE)

    def test_dry_run_makes_no_remote_writes_or_job_files(self):
        app = bridge.Bridge(self.cfg, self.state, self.remote, dry_run=True, report=self.log.append)
        app.intake_pr(self.pr())
        app.request_release(HEAD, BASE, "1.2.3")
        self.assertEqual(self.writes(), [])
        self.assertFalse(Path(self.cfg["jobs_dir"]).exists())

    def test_dry_state_is_copy_and_does_not_change_real_checkpoint(self):
        self.seed()
        copy = bridge.State(self.cfg["state_path"], dry_run=True)
        self.addCleanup(copy.db.close)
        copy.meta("checkpoint", TIME)
        self.assertEqual(self.state.get("meta", "checkpoint"), BEFORE)

    def test_release_request_creates_tracking_only_and_pending_release_context(self):
        self.app.request_release(HEAD, BASE, "1.2.3")
        self.app.request_release(HEAD, BASE, "1.2.3")
        self.assertEqual(len(self.remote.issues), 1)
        writes = [call for call in self.remote.calls if call[0] == "gh" and call[2]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][2]["context"], "multica/release")
        self.assertFalse(any("/releases" in call[1] for call in self.remote.calls if call[0] == "gh"))

    def test_bad_sha_never_reaches_remote(self):
        with self.assertRaises(bridge.BridgeError):
            self.app.request_release("main; rm -rf /", BASE, "1")
        self.assertEqual(self.remote.calls, [])

    def test_source_body_defangs_routing_without_running_content(self):
        body = self.app.source_body("issue", self.issue(body='[@evil](mention://agent/evil) $(touch /tmp/x) <script>'))
        self.assertNotIn("mention://", body)
        self.assertNotIn("<script>", body)
        self.assertIn("$(touch /tmp/x)", body)
        self.assertEqual(self.remote.calls, [])

    def test_config_rejects_secrets_other_repos_and_relative_paths(self):
        original = json.loads(self.config_path.read_text())
        for edit in ({"api_token": "secret"}, {"repository": "someone/else"}, {"state_path": "relative.db"}):
            self.config_path.write_text(json.dumps({**original, **edit}))
            with self.assertRaises(bridge.BridgeError):
                bridge.load_config(self.config_path)

    def test_subprocess_uses_shell_false_and_json_stdin(self):
        def fake_run(argv, **kwargs):
            self.assertIs(kwargs["shell"], False)
            self.assertEqual(json.loads(kwargs["input"]), {"body": "$(danger)"})
            self.assertNotIn("$(danger)", argv)
            kwargs["stdout"].write(b'{"ok": true}')
            return type("Result", (), {"returncode": 0})()
        with patch.object(bridge.subprocess, "run", side_effect=fake_run):
            result = bridge.Commands(self.cfg).gh("repos/example/statuses/sha", {"body": "$(danger)"})
        self.assertTrue(result["ok"])

    def test_second_process_lock_rejected(self):
        with bridge.process_lock(self.cfg["state_path"]):
            with self.assertRaises(bridge.BridgeError):
                with bridge.process_lock(self.cfg["state_path"]):
                    self.fail("Second lock must not be acquired")


if __name__ == "__main__":
    unittest.main()
