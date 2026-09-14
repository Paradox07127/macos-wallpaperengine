"""No-network regressions for immutable intake and static status publishing."""
import contextlib
import copy
import io
import json
import subprocess
import fcntl
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
        self.hide_comments = False
        self.after_status = None

    def gh(self, endpoint, payload=None):
        if payload is not None:
            self.statuses.append((endpoint, copy.deepcopy(payload)))
            if self.after_status is not None:
                self.after_status(payload)
            return {}
        if "/pulls/" in endpoint:
            return copy.deepcopy(self.pr)
        if endpoint.endswith('/status'):
            latest = {}
            for _, payload in self.statuses:
                latest[payload['context']] = payload
            return {'statuses': list(latest.values())}
        if '/commits/' in endpoint:
            return {'sha': endpoint.rsplit('/', 1)[1]}
        raise AssertionError("Unexpected GitHub read: " + endpoint)

    def multica(self, argv, body=None):
        if argv[:3] == ["issue", "comment", "list"]:
            return [] if self.hide_comments else copy.deepcopy(self.comments)
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
            "codex_home": str(self.root / 'codex'),
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
            "provenance": {"mmrun_home": str(self.root / 'mmruns')},
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
        self.assertTrue(self.commands.comments[0]['content'].startswith('/note\n'))
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

    def test_all_preparation_and_process_failures_are_persisted(self):
        (self.review_dir / 'manifest.json').unlink()
        fetched = subprocess.CompletedProcess([], 0, stdout='', stderr='')
        failed_fetch = subprocess.CompletedProcess([], 1, stdout='', stderr='private diagnostic')
        origin = 'https://github.com/' + self.cfg['repository'] + '.git'
        scenarios = [
            ('wrong-origin', 'https://github.com/untrusted/repo', [], 'origin validation'),
            ('fetch-exit', origin, [failed_fetch], 'fetch'),
            ('fetch-timeout', origin, [subprocess.TimeoutExpired('git', 180)], 'fetch'),
            ('launch', origin, [fetched, OSError('private diagnostic')], 'runner process'),
            ('invalid-json', origin, [fetched, subprocess.CompletedProcess([], 1, stdout='private model text')],
             'runner result validation'),
            ('wrong-identity', origin, [fetched, subprocess.CompletedProcess([], 0, stdout=json.dumps({
                'verdict': 'PASS', 'job_id': 'another-job'}))], 'runner result validation'),
            ('contradictory-exit', origin, [fetched, subprocess.CompletedProcess([], 1, stdout=json.dumps({
                'verdict': 'PASS', 'job_id': self.job_id}))], 'runner result validation'),
        ]
        for name, remote, responses, phase in scenarios:
            # Each subcase is an independent first attempt. A real existing
            # failed attempt is deliberately never re-executed by `run`.
            (self.job_dir / 'execution.json').unlink(missing_ok=True)
            (self.job_dir / 'execution-result.json').unlink(missing_ok=True)
            with self.subTest(name=name), \
                    patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                    patch.object(executor.runner, 'git', return_value=remote), \
                    patch.object(executor.subprocess, 'run', side_effect=responses):
                result = executor.run_job(self.cfg, self.job_id)
                self.assertEqual(result['verdict'], 'FAILED')
                self.assertEqual(result['job_id'], self.job_id)
                self.assertIn(phase, result['reasons'][0])
                record = executor.runner.load_json(self.job_dir / 'execution-result.json')
                self.assertEqual(record['verdict'], 'FAILED')
                self.assertEqual(record['job_id'], self.job_id)
                self.assertNotIn('private', json.dumps(record))
                self.assertEqual(executor.failed_execution(self.job_dir, self.job_id)['verdict'], 'FAILED')
        self.assertEqual(self.publish()['state'], 'failure')

    def test_target_read_failure_is_recorded_after_identity_validation(self):
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(self.commands, 'gh', side_effect=executor.bridge.BridgeError('private token')):
            result = executor.run_job(self.cfg, self.job_id)
        self.assertEqual(result['verdict'], 'FAILED')
        self.assertNotIn('private token', (self.job_dir / 'execution-result.json').read_text())

    def test_cli_exit_codes_keep_runner_failure_semantics(self):
        for verdict, expected in [('PASS', 0), ('FAILED', 1), ('NEEDS_REVIEW', 2),
                                  ('RUNNING_TIMEOUT', 3), ('RUNNING', 3)]:
            with self.subTest(verdict=verdict), \
                    patch.object(executor.bridge, 'load_config', return_value=self.cfg), \
                    patch.object(executor, 'run_job', return_value={'verdict': verdict, 'job_id': self.job_id}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(executor.main(['--config', 'fixture', 'run', '--job-id', self.job_id]), expected)

    def test_retired_policy_is_skipped_by_collect_all_but_cannot_run(self):
        self.cfg['policy_version'] = '2'
        self.assertEqual(self.publish()['state'], 'retired')
        self.collector.assert_not_called()
        with self.assertRaises(executor.JobError):
            executor.run_job(self.cfg, self.job_id)
        output = io.StringIO()
        with patch.object(executor.bridge, 'load_config', return_value=self.cfg), contextlib.redirect_stdout(output):
            code = executor.main(['--config', 'fixture', 'collect-all'])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.getvalue())[0]['state'], 'retired')
        self.assertEqual(self.commands.statuses, [])

    def test_receipt_repairs_remote_pending_replay_after_revalidation(self):
        self.assertEqual(self.publish()['state'], 'success')
        self.commands.gh('fixture/statuses/' + self.head,
                         {'state': 'pending', 'context': executor.bridge.status_context(self.req),
                          'description': 'intake replay'})
        self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'success')
        self.assertEqual(len(self.commands.comments), 1)
        self.assertEqual(self.collector.call_count, 2)

    def test_receipt_does_not_repair_with_stale_pass_when_evidence_now_fails(self):
        self.publish()
        self.commands.gh('fixture/statuses/' + self.head,
                         {'state': 'pending', 'context': executor.bridge.status_context(self.req),
                          'description': 'intake replay'})
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': ['evidence changed']}
        self.assertEqual(self.publish()['state'], 'failure')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'failure')
        self.assertEqual(len(self.commands.comments), 1)

    def test_target_changes_during_status_post_restore_pending(self):
        def change_base(payload):
            if payload['state'] == 'success':
                self.commands.pr['base']['sha'] = 'c' * 40
        self.commands.after_status = change_base
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual([p['state'] for _, p in self.commands.statuses], ['success', 'pending'])
        self.assertEqual(self.commands.comments, [])
        self.assertEqual(self.commands.updates, [])

    def test_target_recheck_network_failure_restores_pending(self):
        original = self.commands.gh
        reads = 0
        def gh(endpoint, payload=None):
            nonlocal reads
            if '/pulls/' in endpoint and payload is None:
                reads += 1
                if reads == 2:
                    raise executor.bridge.BridgeError('network unavailable')
            return original(endpoint, payload)
        with patch.object(self.commands, 'gh', side_effect=gh), self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertFalse((self.job_dir / 'published.json').exists())
        self.assertEqual(self.commands.comments, [])

    def test_same_head_distinct_prs_and_release_candidates_have_separate_contexts(self):
        requests = [self.req, dict(self.req, pr_number=8),
                    dict(self.req, kind='release', job_id='release-' + '1' * 24),
                    dict(self.req, kind='release', job_id='release-' + '2' * 24)]
        contexts = [executor.status_payload(req, 'PASS')['context'] for req in requests]
        self.assertEqual(len(set(contexts)), 4)
        self.assertEqual(contexts[:2], ['multica/review/pr-7', 'multica/review/pr-8'])
        for req, verdict in zip(requests, ['PASS', 'FAILED', 'PASS', 'FAILED']):
            self.commands.gh('fixture/statuses/' + self.head, executor.status_payload(req, verdict))
        self.assertEqual(len(self.commands.gh('fixture/commits/' + self.head + '/status')['statuses']), 4)

    def test_invisible_ambiguous_comment_is_not_sent_twice(self):
        self.commands.lose_comment_ack = True
        self.commands.hide_comments = True
        with self.assertRaises(executor.bridge.BridgeError):
            self.publish()
        self.assertEqual(self.publish()['state'], 'awaiting_comment_reconciliation')
        self.assertEqual(len(self.commands.comments), 1)
        self.assertFalse((self.job_dir / 'published.json').exists())
        self.commands.hide_comments = False
        self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(len(self.commands.comments), 1)

    def test_existing_run_and_cli_output_do_not_leak_peer_reports(self):
        self.collector.return_value = {'verdict': 'PASS', 'job_id': self.job_id,
                                      'reports': {'grok': 'PRIVATE_FINDINGS'},
                                      'findings': ['PRIVATE_FINDINGS'], 'reasons': []}
        with patch.object(executor.bridge, 'Commands', return_value=self.commands):
            result = executor.run_job(self.cfg, self.job_id)
        self.assertNotIn('reports', result)
        self.assertNotIn('findings', result)
        output = io.StringIO()
        with patch.object(executor.bridge, 'load_config', return_value=self.cfg), contextlib.redirect_stdout(output):
            self.assertEqual(executor.main(['--config', 'fixture', 'collect', '--job-id', self.job_id]), 0)
        self.assertNotIn('PRIVATE_FINDINGS', output.getvalue())
        self.assertFalse((self.job_dir / 'execution.json').exists())

    def test_explicit_retry_preserves_old_evidence_and_publishes_new_attempt(self):
        old_frozen = self.review_dir / 'frozen'
        old_frozen.mkdir()
        (old_frozen / 'source.txt').write_text('old immutable review input')
        protected = self.root / 'old-protected-attestation.json'
        protected.write_text('old reports stay intact')
        original_manifest = (self.review_dir / 'manifest.json').read_bytes()
        def collected(directory):
            return {'job_id': directory.name,
                    'verdict': 'NEEDS_REVIEW' if directory == self.review_dir else 'PASS',
                    'reasons': [], 'attestation_path': str(protected if directory == self.review_dir
                                                         else self.root / 'new-protected-attestation.json')}
        self.collector.side_effect = collected
        self.assertEqual(self.publish()['state'], 'failure')
        old_receipt = (self.job_dir / 'published.json').read_bytes()
        new_id = self.job_id + '-retry-' + '1' * 12
        def process(argv, **kwargs):
            if argv[0] == 'git':
                return subprocess.CompletedProcess(argv, 0)
            self.assertEqual(argv[argv.index('--job-id') + 1], new_id)
            directory = Path(self.cfg['review_state_dir']) / new_id
            directory.mkdir()
            manifest = dict(self.manifest, job_id=new_id, repo=str(directory / 'frozen'))
            (directory / 'manifest.json').write_text(json.dumps(manifest))
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps({
                'job_id': new_id, 'verdict': 'PASS', 'reasons': [],
                'attestation_path': str(self.root / 'new-protected-attestation.json')}))
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor.secrets, 'token_hex', return_value='1' * 12), \
                patch.object(executor.runner, 'git', return_value='https://github.com/' + self.cfg['repository']), \
                patch.object(executor.subprocess, 'run', side_effect=process) as launch:
            result = executor.retry_job(self.cfg, self.job_id)
            self.assertEqual(result['verdict'], 'PASS')
            self.assertEqual(result['job_id'], self.job_id)
            self.assertEqual(result['runner_job_id'], new_id)
            self.assertEqual(launch.call_count, 2)
            self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'PASS')
            self.assertEqual(launch.call_count, 2)  # Repeated run only collects.
        self.assertEqual((self.review_dir / 'manifest.json').read_bytes(), original_manifest)
        self.assertEqual((old_frozen / 'source.txt').read_text(), 'old immutable review input')
        self.assertEqual(protected.read_text(), 'old reports stay intact')
        self.assertEqual((self.job_dir / 'published.json').read_bytes(), old_receipt)
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(self.publish()['state'], 'success')
        new_records = self.job_dir / 'attempts' / new_id
        self.assertEqual(json.loads((new_records / 'published.json').read_text())['runner_job_id'], new_id)
        self.assertEqual(len(self.commands.comments), 2)
        self.assertTrue(all(comment['content'].startswith('/note\n') for comment in self.commands.comments))
        self.assertIn(new_id, self.commands.comments[-1]['content'])
        self.assertEqual(self.publish()['state'], 'already_published')
        self.assertEqual(len(self.commands.comments), 2)

    def test_retry_rejects_pass_running_and_unstarted_attempts(self):
        for verdict in ('PASS', 'RUNNING_TIMEOUT'):
            self.collector.return_value = {'verdict': verdict, 'reasons': []}
            with self.subTest(verdict=verdict), patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                    patch.object(executor.subprocess, 'run') as launch, self.assertRaises(executor.JobError):
                executor.retry_job(self.cfg, self.job_id)
            launch.assert_not_called()
        (self.review_dir / 'manifest.json').unlink()
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertEqual(self.commands.statuses, [])

    def test_retry_rejects_stale_target_and_retired_policy(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        self.commands.pr['base']['sha'] = 'c' * 40
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.cfg['policy_version'] = '2'
        with self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertEqual(self.commands.statuses, [])

    def test_retry_refuses_live_execution_or_publisher_lock(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        for filename in ('executor.lock', 'publish.lock'):
            with self.subTest(filename=filename), (self.job_dir / filename).open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(executor.bridge, 'Commands', return_value=self.commands), self.assertRaises(executor.JobError):
                    executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.collector.assert_not_called()

    def test_failed_collector_cannot_retry_over_a_running_peer_model(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': ['one model failed']}
        self.manifest['mmrun_run_id'] = 'fixture-run'
        self.write_manifest()
        run_root = Path(self.manifest['provenance']['mmrun_home']) / 'fixture-run'
        run_root.mkdir(parents=True)
        (run_root / 'codex.status').write_text('FAIL:1')
        (run_root / 'grok.status').write_text('RUNNING')
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertEqual(self.commands.statuses, [])

    def test_retry_refuses_a_busy_runner_collection_lock(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        with executor.runner.job_lock(self.review_dir) as locked:
            self.assertTrue(locked)
            with patch.object(executor.bridge, 'Commands', return_value=self.commands), self.assertRaises(executor.JobError):
                executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())

    def test_retry_refuses_live_worker_even_if_status_claims_done(self):
        self.collector.return_value = {'verdict': 'NEEDS_REVIEW', 'reasons': []}
        self.manifest['mmrun_run_id'] = 'fixture-run'
        self.write_manifest()
        run_root = Path(self.manifest['provenance']['mmrun_home']) / 'fixture-run'
        run_root.mkdir(parents=True)
        for model in ('codex', 'grok'):
            (run_root / (model + '.status')).write_text('DONE')
        (run_root / 'grok.pid').write_text('123')
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor.runner, 'process_alive', side_effect=lambda pid: pid == 123), \
                self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())

    def test_failed_preparation_requires_explicit_retry_and_keeps_each_attempt(self):
        (self.review_dir / 'manifest.json').unlink()
        old_start = {'job_id': self.job_id, 'started_at': 'first'}
        old_result = {'job_id': self.job_id, 'verdict': 'FAILED', 'reasons': ['origin failed']}
        (self.job_dir / 'execution.json').write_text(json.dumps(old_start))
        (self.job_dir / 'execution-result.json').write_text(json.dumps(old_result))
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor.runner, 'git', return_value='https://github.com/' + self.cfg['repository']), \
                patch.object(executor.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as launch:
            self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'FAILED')
            launch.assert_not_called()
            with patch.object(executor.secrets, 'token_hex', return_value='1' * 12):
                first_retry = executor.retry_job(self.cfg, self.job_id)
            self.assertEqual(first_retry['verdict'], 'FAILED')
            first_path = self.job_dir / 'attempts' / first_retry['runner_job_id'] / 'execution-result.json'
            first_bytes = first_path.read_bytes()
            self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'FAILED')
            self.assertEqual(launch.call_count, 1)
            with patch.object(executor.secrets, 'token_hex', return_value='2' * 12):
                second_retry = executor.retry_job(self.cfg, self.job_id)
            self.assertNotEqual(first_retry['runner_job_id'], second_retry['runner_job_id'])
            self.assertEqual(launch.call_count, 2)
        self.assertEqual(first_path.read_bytes(), first_bytes)
        self.assertEqual(json.loads((self.job_dir / 'execution-result.json').read_text()), old_result)
        self.assertEqual(json.loads((self.job_dir / 'attempt.json').read_text())['previous_runner_job_id'],
                         first_retry['runner_job_id'])

    def test_attempt_selector_and_manifest_identity_are_bound(self):
        new_id = self.job_id + '-retry-' + '1' * 12
        selector = {'schema_version': 1, 'job_id': self.job_id, 'runner_job_id': new_id}
        for invalid in ('../escape', 'another-job-retry-' + '1' * 12, self.job_id, new_id + '/path'):
            (self.job_dir / 'attempt.json').write_text(json.dumps(dict(selector, runner_job_id=invalid)))
            with self.subTest(invalid=invalid), self.assertRaises(executor.JobError):
                executor.collect_verified(self.cfg, self.req)
        (self.job_dir / 'attempt.json').write_text(json.dumps(selector))
        new_dir = Path(self.cfg['review_state_dir']) / new_id
        new_dir.mkdir()
        (new_dir / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaises(executor.JobError):
            executor.collect_verified(self.cfg, self.req)
        self.collector.assert_not_called()

    def test_retry_pending_write_failure_is_persisted_without_launch(self):
        self.collector.return_value = {'verdict': 'NEEDS_REVIEW', 'reasons': []}
        read = self.commands.gh
        def broken(endpoint, payload=None):
            if payload is not None:
                raise executor.bridge.BridgeError('network unavailable')
            return read(endpoint)
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(self.commands, 'gh', side_effect=broken), \
                patch.object(executor.subprocess, 'run') as launch:
            result = executor.retry_job(self.cfg, self.job_id)
        self.assertEqual(result['verdict'], 'FAILED')
        launch.assert_not_called()
        active_id, records = executor.active_attempt(self.cfg, self.req)
        self.assertEqual(executor.failed_execution(records, self.job_id, active_id)['verdict'], 'FAILED')

    def test_started_attempt_with_no_result_never_relaunches_implicitly(self):
        (self.review_dir / 'manifest.json').unlink()
        (self.job_dir / 'execution.json').write_text(json.dumps({'job_id': self.job_id}))
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor.subprocess, 'run') as launch:
            self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'RUNNING_TIMEOUT')
            with self.assertRaises(executor.JobError):
                executor.retry_job(self.cfg, self.job_id)
        launch.assert_not_called()

    def test_retry_cli_dispatches_explicit_retry_and_propagates_exit(self):
        output = io.StringIO()
        with patch.object(executor.bridge, 'load_config', return_value=self.cfg), \
                patch.object(executor, 'retry_job', return_value={'job_id': self.job_id, 'verdict': 'NEEDS_REVIEW'}) as retry, \
                contextlib.redirect_stdout(output):
            code = executor.main(['--config', 'fixture', 'retry', '--job-id', self.job_id])
        self.assertEqual(code, 2)
        retry.assert_called_once_with(self.cfg, self.job_id)


if __name__ == "__main__":
    unittest.main()
