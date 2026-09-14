"""No-network regressions for immutable intake and static status publishing."""
import contextlib
import copy
import io
import json
import os
import subprocess
import fcntl
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/multica"))
import executor

REAL_COLLECT = executor.runner.collect


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
        if endpoint.split('?', 1)[0].endswith('/status'):
            latest = {}
            for _, payload in self.statuses:
                latest[payload['context']] = payload
            page = int(endpoint.rsplit('page=', 1)[-1]) if '?' in endpoint else 1
            rows = list(latest.values())
            return {'statuses': rows[(page - 1) * 100:page * 100], 'total_count': len(rows)}
        if '/commits/' in endpoint:
            return {'sha': endpoint.rsplit('/', 1)[1]}
        raise AssertionError("Unexpected GitHub read: " + endpoint)

    def multica(self, argv, body=None):
        if argv[:3] == ["issue", "comment", "list"]:
            return [] if self.hide_comments else copy.deepcopy(self.comments)
        if argv[:3] == ["issue", "comment", "add"]:
            self.comments.append({"id": "11111111-1111-4111-8111-111111111111", "content": body, "author_type": "member", "author_id": "trusted-actor"})
            if self.lose_comment_ack:
                self.lose_comment_ack = False
                raise executor.bridge.BridgeError("Response lost after comment was written")
            return {"id": "11111111-1111-4111-8111-111111111111"}
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
            "codex_home": str(self.root / 'codex'), "state_path": str(self.root / "state.json"),
            "bridge_actor_id": "trusted-actor", "gh_path": "/trusted/gh",
        }
        Path(self.cfg["repository_path"]).mkdir()
        self.head, self.base = "a" * 40, "b" * 40
        key = "|".join([self.cfg["repository"], self.head, self.base, "1", "pr", "7", "",
                        executor.bridge.policy_fingerprint(self.cfg)])
        self.job_id = "pr-7-" + executor.bridge.digest(key)[:24]
        self.job_dir = Path(self.cfg["jobs_dir"]) / self.job_id
        self.job_dir.mkdir(parents=True)
        self.req = {
            "schema_version": 1, "job_id": self.job_id, "repository": self.cfg["repository"],
            "repository_path": self.cfg["repository_path"], "policy_version": "1", "kind": "pr",
            "pr_number": 7, "head_sha": self.head, "base_sha": self.base,
            "multica_issue_id": "internal-issue-id",
            "policy_fingerprint": executor.bridge.policy_fingerprint(self.cfg),
            "review_policy": executor.bridge.effective_policy(self.cfg),
        }
        self.write_request()
        with executor.bridge.issue_generation_lock(self.cfg, self.req['multica_issue_id']) as locked:
            self.assertTrue(locked)
            executor.bridge.set_generation(self.cfg, self.req['multica_issue_id'], self.job_id)
        self.review_dir = Path(self.cfg["review_state_dir"]) / self.job_id
        self.review_dir.mkdir(parents=True)
        self.manifest = {
            "schema_version": 1, "job_id": self.job_id, "kind": "pr",
            "repo": str(self.review_dir / "frozen"), "source_repo": self.cfg["repository_path"],
            "head_sha": self.head, "base_sha": self.base,
            "policy": executor.runner.review_policy("pr", ["codex", "grok"]),
            "provenance": {"mmrun_home": str(self.root / 'mmruns'), "mmrun_kind": "compat"},
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
        self.assertEqual(self.collector.call_count, 2)
        self.assertEqual(self.collector.call_args.args, (self.review_dir,))
        self.assertGreater(self.collector.call_args.kwargs["deadline"], executor.time.monotonic())

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
                    patch.object(executor, 'fetch_origin', return_value=remote), \
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

    def test_fetch_explicitly_disables_inherited_partial_clone_filter(self):
        (self.review_dir / 'manifest.json').unlink()
        origin = 'https://github.com/' + self.cfg['repository'] + '.git'
        responses = [subprocess.CompletedProcess([], 0, stdout='', stderr=''),
                     subprocess.CompletedProcess([], 1, stdout=json.dumps({
                         'job_id': self.job_id, 'verdict': 'FAILED', 'reasons': []}))]
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'fetch_origin', return_value=origin), \
                patch.object(executor.subprocess, 'run', side_effect=responses) as process:
            executor.run_job(self.cfg, self.job_id)
        fetch = process.call_args_list[0].args[0]
        self.assertEqual(fetch, ['git', '-C', self.cfg['repository_path'], 'fetch', '-q',
                                 '--no-filter', 'origin', self.base, self.head])
        self.assertFalse(any(argument.startswith('--filter') for argument in fetch))
        self.assertNotIn('blob:none', ' '.join(fetch))

    def test_missing_model_list_never_falls_back_to_exhausted_grok(self):
        (self.review_dir / 'manifest.json').unlink()
        cfg = dict(self.cfg)
        cfg.pop('review_models')
        responses = [subprocess.CompletedProcess([], 0, stdout='', stderr=''),
                     subprocess.CompletedProcess([], 1, stdout=json.dumps({
                         'job_id': self.job_id, 'verdict': 'FAILED', 'reasons': []}))]
        with patch.object(executor, 'fetch_origin', return_value='https://github.com/' + cfg['repository']), \
                patch.object(executor.subprocess, 'run', side_effect=responses) as process:
            executor._run_attempt(cfg, self.req, self.commands)
        argv = process.call_args_list[-1].args[0]
        self.assertEqual(argv[argv.index('--models') + 1], 'claude,codex')
        self.assertEqual(argv[argv.index('--mmrun-kind') + 1], 'compat')

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
        with patch.object(executor.bridge, 'load_config', return_value=self.cfg), \
                patch.object(executor.bridge, 'Commands', return_value=self.commands), contextlib.redirect_stdout(output):
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
        self.assertEqual(len(self.commands.comments), 2)

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
        self.enterContext(patch.object(executor.runner, "require_quiescent"))
        self.enterContext(patch.object(executor, "no_active_controller"))
        old_frozen = self.review_dir / 'frozen'
        old_frozen.mkdir()
        (old_frozen / 'source.txt').write_text('old immutable review input')
        protected = self.root / 'old-protected-attestation.json'
        protected.write_text('old reports stay intact')
        original_manifest = (self.review_dir / 'manifest.json').read_bytes()
        def collected(directory, **kwargs):
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
                patch.object(executor, 'fetch_origin', return_value='https://github.com/' + self.cfg['repository']), \
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
        self.enterContext(patch.object(executor.runner, "require_quiescent"))
        self.enterContext(patch.object(executor, "no_active_controller"))
        (self.review_dir / 'manifest.json').unlink()
        old_start = {'job_id': self.job_id, 'started_at': 'first'}
        old_result = {'job_id': self.job_id, 'verdict': 'FAILED', 'reasons': ['origin failed']}
        (self.job_dir / 'execution.json').write_text(json.dumps(old_start))
        (self.job_dir / 'execution-result.json').write_text(json.dumps(old_result))
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'fetch_origin', return_value='https://github.com/' + self.cfg['repository']), \
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
        self.enterContext(patch.object(executor.runner, "require_quiescent"))
        self.enterContext(patch.object(executor, "no_active_controller"))
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

    def test_unchanged_remote_pass_revalidates_and_revises_comment(self):
        self.publish()
        old_body = self.commands.comments[0]['content']
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': ['evidence changed']}
        self.assertEqual(self.publish()['state'], 'failure')
        self.assertEqual(self.collector.call_count, 2)
        self.assertEqual(len(self.commands.comments), 2)
        self.assertNotEqual(old_body, self.commands.comments[-1]['content'])
        self.assertIn('supersedes earlier results', self.commands.comments[-1]['content'])
        self.assertNotIn(str(self.root), self.commands.comments[-1]['content'])

    def test_corrupt_manifest_revokes_previously_published_success(self):
        self.publish()
        self.manifest['head_sha'] = 'c' * 40
        self.write_manifest()
        self.assertEqual(self.publish()['state'], 'failure')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'failure')
        self.assertEqual(len(self.commands.comments), 2)

    def test_status_ack_lost_after_write_and_target_change_is_reconciled(self):
        original = self.commands.gh
        def gh(endpoint, payload=None):
            result = original(endpoint, payload)
            if payload and payload['state'] == 'success':
                self.commands.pr['draft'] = True
                raise executor.bridge.BridgeError('response lost')
            return result
        with patch.object(self.commands, 'gh', side_effect=gh):
            self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        intent = json.loads((self.job_dir / 'publish-status-intent.json').read_text())
        self.assertEqual(intent['state'], 'revoked')
        self.assertEqual(self.commands.comments, [])

    def test_completed_success_is_revoked_when_same_head_target_changes(self):
        self.publish()
        self.commands.pr['base']['sha'] = 'c' * 40
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(len(self.commands.comments), 1)

    def test_target_change_during_revalidation_revokes_matching_receipt(self):
        self.publish()
        def changed(directory, **kwargs):
            self.commands.pr['draft'] = True
            return {'verdict': 'PASS', 'reasons': [], 'head_sha': self.head}
        self.collector.side_effect = changed
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(len(self.commands.comments), 1)

    def test_unknown_status_intent_survives_crash_and_revokes_on_next_tick(self):
        original = self.commands.gh
        def gh(endpoint, payload=None):
            if payload:
                original(endpoint, payload)
                raise KeyboardInterrupt('crash after accepted write')
            return original(endpoint)
        with patch.object(self.commands, 'gh', side_effect=gh), self.assertRaises(KeyboardInterrupt):
            self.publish()
        self.assertEqual(json.loads((self.job_dir / 'publish-status-intent.json').read_text())['state'], 'sending')
        self.commands.pr['draft'] = True
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')

    def test_old_rollback_cannot_overwrite_newer_generation(self):
        newer = dict(self.req, base_sha='c' * 40)
        newer['job_id'] = executor.bridge.job_id_for(newer)
        def replaced(payload):
            if payload['state'] == 'success' and payload['description'].startswith(self.job_id + ':'):
                self.commands.pr['base']['sha'] = 'c' * 40
                self.commands.statuses.append(('new-controller', executor.status_payload(newer, 'PASS')))
        self.commands.after_status = replaced
        self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(len(self.commands.statuses), 2)
        self.assertTrue(self.commands.statuses[-1][1]['description'].startswith(newer['job_id'] + ':'))

    def test_publication_and_intake_share_context_lock_across_job_ids(self):
        newer = dict(self.req, job_id='pr-7-' + 'f' * 24, base_sha='c' * 40)
        with executor.bridge.status_lock(self.cfg, newer) as locked:
            self.assertTrue(locked)
            self.assertEqual(self.publish()['state'], 'busy')
        self.collector.assert_not_called()
        self.assertEqual(self.commands.statuses, [])

    def test_untrusted_exact_comment_cannot_reconcile_uncertain_write(self):
        self.commands.lose_comment_ack = True
        with self.assertRaises(executor.bridge.BridgeError):
            self.publish()
        self.commands.comments[0]['author_id'] = 'attacker'
        self.assertEqual(self.publish()['state'], 'awaiting_comment_reconciliation')
        self.assertEqual(len(self.commands.comments), 1)
        self.commands.comments[0]['author_id'] = 'trusted-actor'
        self.commands.comments[0]['content'] += '\nquoted by another discussion'
        self.assertEqual(self.publish()['state'], 'awaiting_comment_reconciliation')
        self.assertFalse((self.job_dir / 'published.json').exists())

    def test_effective_policy_and_legacy_history_retire_without_collecting(self):
        self.cfg['review_models'] = ['codex']
        self.assertEqual(self.publish()['state'], 'retired')
        with self.assertRaises(executor.JobError):
            executor.run_job(self.cfg, self.job_id)
        self.cfg['review_models'] = ['codex', 'grok']
        self.req.pop('policy_fingerprint')
        self.req.pop('review_policy')
        legacy_key = '|'.join([self.cfg['repository'], self.head, self.base, '1', 'pr', '7', ''])
        legacy_id = 'pr-7-' + executor.bridge.digest(legacy_key)[:24]
        self.req['job_id'] = legacy_id
        directory = Path(self.cfg['jobs_dir']) / legacy_id
        directory.mkdir()
        (directory / 'request.json').write_text(json.dumps(self.req))
        self.assertEqual(executor.publish_result(self.cfg, legacy_id, self.commands)['state'], 'retired')
        self.collector.assert_not_called()

    def test_policy_fingerprint_tampering_is_rejected(self):
        self.req['review_policy']['runner']['static_only'] = False
        self.write_request()
        with self.assertRaises(executor.JobError):
            self.publish()
        self.req['policy_fingerprint'] = executor.bridge.digest(json.dumps(
            self.req['review_policy'], sort_keys=True, separators=(',', ':')))
        self.write_request()
        with self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(self.commands.statuses, [])

    def test_orphan_recovery_preserves_evidence_and_never_starts_models(self):
        (self.review_dir / 'manifest.json').unlink()
        start = {'job_id': self.job_id, 'runner_job_id': self.job_id, 'controller_pid': 99999}
        executor.atomic(self.job_dir / 'execution.json', start)
        with patch.object(executor, 'no_active_controller') as inspect, \
                patch.object(executor.runner, 'require_quiescent') as quiet, \
                patch.object(executor.subprocess, 'run') as launch:
            result = executor.recover_job(self.cfg, self.job_id)
            self.assertEqual(result['verdict'], 'FAILED')
            inspect.assert_called_once_with(self.job_id)
            quiet.assert_called_once_with(self.review_dir, models=['codex', 'grok'])
            launch.assert_not_called()
            with patch.object(executor.bridge, 'Commands', return_value=self.commands):
                self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'FAILED')
        self.assertEqual(json.loads((self.job_dir / 'execution.json').read_text()), start)
        self.assertFalse((self.job_dir / 'execution-result.json').exists())
        self.assertEqual(self.commands.statuses, [])

    def test_missing_retry_selector_requires_explicit_identity_recovery(self):
        retry_id = self.job_id + '-retry-' + '1' * 12
        snapshot = {'schema_version': 1, 'job_id': self.job_id, 'runner_job_id': retry_id}
        executor.atomic(self.job_dir / 'attempts' / retry_id / 'attempt.json', snapshot)
        with self.assertRaises(executor.JobError):
            executor.active_attempt(self.cfg, self.req)
        with patch.object(executor, 'no_active_controller'), patch.object(executor, 'require_quiescent'):
            recovered = executor.recover_job(self.cfg, self.job_id, retry_id)
        self.assertEqual(recovered['runner_job_id'], retry_id)
        self.assertEqual(recovered['verdict'], 'FAILED')
        self.assertEqual(executor.active_attempt(self.cfg, self.req)[0], retry_id)
        self.assertTrue((self.review_dir / 'manifest.json').exists())

    def test_orphan_process_identity_unknown_or_live_refuses_recovery(self):
        (self.review_dir / 'manifest.json').unlink()
        executor.atomic(self.job_dir / 'execution.json', {'job_id': self.job_id})
        cases = [subprocess.CompletedProcess([], 1, stdout=''),
                 subprocess.CompletedProcess([], 0, stdout='99999 python review_runner.py run --job-id ' + self.job_id)]
        for response in cases:
            with self.subTest(response=response.returncode), \
                    patch.object(executor.subprocess, 'run', return_value=response), self.assertRaises(executor.JobError):
                executor.recover_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'recovery.json').exists())

    def test_retry_target_changes_after_selection_records_not_dispatched(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        def draft_after_pending(payload):
            self.commands.pr['draft'] = True
        self.commands.after_status = draft_after_pending
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'require_quiescent'), patch.object(executor.subprocess, 'run') as launch:
            result = executor.retry_job(self.cfg, self.job_id)
        self.assertEqual(result['verdict'], 'SUPERSEDED')
        self.assertEqual(executor.exit_code(result), 4)
        _, records = executor.active_attempt(self.cfg, self.req)
        self.assertEqual(json.loads((records / 'execution-result.json').read_text())['verdict'], 'FAILED')
        launch.assert_not_called()

    def test_canonical_ssh_origins_and_foreign_origin_rejection(self):
        repository = self.cfg['repository']
        for value in ('https://github.com/' + repository, 'git@github.com:' + repository + '.git',
                      'ssh://git@github.com/' + repository + '.git'):
            self.assertTrue(executor.allowed_origin(value, repository))
        for value in ('https://github.com.evil/' + repository, 'https://secret@github.com/' + repository,
                      'ssh://git@elsewhere/' + repository, 'git@github.com:' + repository + '/..',
                      'https://github.com/' + repository + '?secret=1'):
            self.assertFalse(executor.allowed_origin(value, repository))

    def test_collection_rotates_before_work_and_honors_batch_bound(self):
        second = 'pr-8-' + 'e' * 24
        executor.atomic(Path(self.cfg['jobs_dir']) / second / 'request.json', {})
        self.cfg['collection_max_jobs'] = 1
        visited = []
        def publish(cfg, job_id, commands):
            cursor = json.loads((self.root / 'executor-collection.json').read_text())
            self.assertEqual(cursor['last_job_id'], job_id)
            visited.append(job_id)
            if len(visited) == 1:
                raise KeyboardInterrupt('service killed')
            return {'job_id': job_id, 'state': 'retired'}
        with patch.object(executor, 'publish_result', side_effect=publish), \
                patch.object(executor.bridge, 'Commands', return_value=self.commands):
            with self.assertRaises(KeyboardInterrupt):
                executor.collect_all(self.cfg)
            self.assertEqual(len(executor.collect_all(self.cfg)), 1)
        self.assertEqual(visited, [self.job_id, second])
        self.cfg['collection_budget_seconds'] = 0
        self.assertEqual(executor.collect_all(self.cfg), [])


    def test_retired_policy_revokes_only_its_own_published_success(self):
        self.publish()
        self.cfg['policy_version'] = 'next'
        self.assertEqual(self.publish()['state'], 'retired')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(self.collector.call_count, 1)
        count = len(self.commands.statuses)
        self.assertEqual(self.publish()['state'], 'retired')
        self.assertEqual(len(self.commands.statuses), count)
        newer = dict(self.req, job_id='pr-7-' + 'f' * 24)
        self.commands.gh('new-policy', executor.status_payload(newer, 'PASS'))
        count = len(self.commands.statuses)
        self.assertEqual(self.publish()['state'], 'retired')
        self.assertEqual(len(self.commands.statuses), count)
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'success')

    def test_retired_policy_revokes_prior_retry_without_cloud_mapping(self):
        retry_id = self.job_id + '-retry-' + 'a' * 12
        self.commands.gh('old-retry', executor.status_payload(self.req, 'PASS', retry_id))
        self.cfg['review_models'] = ['codex']
        self.req['multica_issue_id'] = None
        self.write_request()
        self.assertEqual(self.publish()['state'], 'retired')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.collector.assert_not_called()

    def test_malformed_manifest_shapes_downgrade_published_pass(self):
        shapes = [[], None, {'policy': None}, {'policy': []}, {'provenance': None},
                  {'provenance': []}, {'source_repo': None}]
        for shape in shapes:
            with self.subTest(shape=shape):
                self.write_manifest()
                self.assertEqual(self.publish()['state'], 'success')
                invalid = dict(self.manifest, **shape) if isinstance(shape, dict) else shape
                (self.review_dir / 'manifest.json').write_text(json.dumps(invalid))
                self.assertEqual(self.publish()['state'], 'failure')
                self.assertEqual(self.commands.statuses[-1][1]['state'], 'failure')

    def test_status_pagination_finds_and_revokes_second_page(self):
        for index in range(100):
            self.commands.statuses.append(('other', {'context': 'other-' + str(index),
                'state': 'success', 'description': 'unrelated'}))
        self.commands.gh('target', executor.status_payload(self.req, 'PASS'))
        self.cfg['policy_version'] = 'next'
        self.assertEqual(self.publish()['state'], 'retired')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')

    def test_status_second_page_failure_is_unknown_without_post(self):
        for index in range(100):
            self.commands.statuses.append(('other', {'context': 'other-' + str(index),
                'state': 'success', 'description': 'unrelated'}))
        self.commands.gh('target', executor.status_payload(self.req, 'PASS'))
        original = self.commands.gh
        def fail_page(endpoint, payload=None):
            if 'page=2' in endpoint:
                raise executor.bridge.BridgeError('page unavailable')
            return original(endpoint, payload)
        self.cfg['policy_version'] = 'next'
        with patch.object(self.commands, 'gh', side_effect=fail_page), self.assertRaises(executor.bridge.BridgeError):
            self.publish()
        self.assertEqual(len(self.commands.statuses), 101)

    def test_collection_passes_remaining_local_budget_and_timeout_stays_pending(self):
        self.publish()
        self.collector.return_value = {'verdict': 'RUNNING_TIMEOUT', 'reasons': ['collection budget exhausted']}
        cfg = dict(self.cfg, collection_job_budget_seconds=1, collection_budget_seconds=30)
        with patch.object(executor.bridge, 'Commands', return_value=self.commands):
            results = executor.collect_all(cfg)
        self.assertEqual(results[0]['state'], 'pending')
        remaining = self.collector.call_args.kwargs['deadline'] - executor.time.monotonic()
        self.assertGreater(remaining, 0)
        self.assertLessEqual(remaining, 1)
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(json.loads((self.job_dir / 'published.json').read_text())['verdict'], 'PASS')

    def test_real_runner_expired_budget_preserves_evidence_and_withholds_success(self):
        self.publish()
        evidence = self.review_dir / 'attestation.json'
        evidence.write_text('preserved previous evidence')
        self.collector.side_effect = REAL_COLLECT
        cfg = dict(self.cfg, _collection_deadline=executor.time.monotonic() - 1)
        result = executor.publish_result(cfg, self.job_id, self.commands)
        self.assertEqual(result['state'], 'pending')
        self.assertEqual(evidence.read_text(), 'preserved previous evidence')
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(json.loads((self.job_dir / 'published.json').read_text())['verdict'], 'PASS')


    def test_small_collection_budgets_leave_positive_local_deadline(self):
        for total in (1, 10):
            cfg = dict(self.cfg, collection_budget_seconds=total, collection_job_budget_seconds=total)
            with self.subTest(total=total), patch.object(executor.time, 'monotonic', return_value=100), \
                    patch.object(executor.bridge, 'Commands', return_value=self.commands):
                results = executor.collect_all(cfg)
            self.assertEqual(results[0]['state'], 'success' if total == 1 else 'already_published')
            deadline = self.collector.call_args.kwargs['deadline']
            self.assertGreater(deadline, 100)
            self.assertLess(deadline, 100 + total)
            self.assertAlmostEqual(deadline, 100 + total * 0.9)

    def test_completed_success_target_query_error_revokes_on_first_and_second_check(self):
        original = self.commands.gh
        for failed_read in (1, 2):
            with self.subTest(failed_read=failed_read):
                self.assertEqual(self.publish()['state'], 'success')
                reads = 0
                def unavailable(endpoint, payload=None):
                    nonlocal reads
                    if '/pulls/' in endpoint and payload is None:
                        reads += 1
                        if reads == failed_read:
                            raise executor.bridge.BridgeError('target lookup unavailable')
                    return original(endpoint, payload)
                with patch.object(self.commands, 'gh', side_effect=unavailable), self.assertRaises(executor.JobError):
                    self.publish()
                self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
                self.assertEqual(len(self.commands.comments), 1)

    def test_known_not_started_comment_is_retryable_not_ambiguous(self):
        original = self.commands.multica
        attempts = 0
        def before_start(argv, body=None):
            nonlocal attempts
            if argv[:3] == ['issue', 'comment', 'add']:
                attempts += 1
                if attempts == 1:
                    raise executor.bridge.CommandNotStarted('deadline before launch')
            return original(argv, body)
        with patch.object(self.commands, 'multica', side_effect=before_start):
            self.assertEqual(self.publish()['state'], 'pending')
            intent_path = next((self.job_dir / 'comment-intents').glob('*.json'))
            self.assertEqual(json.loads(intent_path.read_text())['state'], 'not_started')
            self.assertEqual(self.commands.comments, [])
            self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(attempts, 2)
        self.assertEqual(len(self.commands.comments), 1)

    def test_new_generation_during_result_comment_cannot_update_shared_issue(self):
        new_job = 'pr-7-' + 'f' * 24
        original = self.commands.multica
        def changed_generation(argv, body=None):
            result = original(argv, body)
            if argv[:3] == ['issue', 'comment', 'add']:
                with executor.bridge.issue_generation_lock(self.cfg, self.req['multica_issue_id']) as locked:
                    self.assertTrue(locked)
                    executor.bridge.set_generation(self.cfg, self.req['multica_issue_id'], new_job)
            return result
        with patch.object(self.commands, 'multica', side_effect=changed_generation):
            self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.updates, [])
        self.assertEqual(len(self.commands.comments), 1)
        self.assertIn(self.head, self.commands.comments[0]['content'])
        self.assertIn('it is historical', self.commands.comments[0]['content'])
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertFalse((self.job_dir / 'published.json').exists())

    def test_target_change_after_comment_cannot_update_issue_even_before_intake(self):
        original = self.commands.multica
        def changed_head(argv, body=None):
            result = original(argv, body)
            if argv[:3] == ['issue', 'comment', 'add']:
                self.commands.pr['head']['sha'] = 'c' * 40
            return result
        with patch.object(self.commands, 'multica', side_effect=changed_head):
            self.assertEqual(self.publish()['state'], 'superseded')
        self.assertEqual(self.commands.updates, [])
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')

    def test_shared_generation_lock_blocks_final_update_across_heads(self):
        with executor.bridge.issue_generation_lock(self.cfg, self.req['multica_issue_id']) as locked:
            self.assertTrue(locked)
            self.assertEqual(self.publish()['state'], 'busy')
        self.assertEqual(self.commands.updates, [])
        self.assertFalse((self.job_dir / 'published.json').exists())
        self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(len(self.commands.comments), 1)


    def test_orphan_scan_requests_unlimited_width_and_detects_long_argv(self):
        line = '999999 python ' + 'x' * 500 + ' review_runner.py run --job-id ' + self.job_id
        with patch.object(executor.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=line)) as process:
            with self.assertRaises(executor.JobError):
                executor.no_active_controller(self.job_id)
        self.assertEqual(process.call_args.args[0], ['/bin/ps', '-axww', '-o', 'pid=,command='])

    def test_runner_wrapper_timeout_is_pending_and_never_relaunches(self):
        (self.review_dir / 'manifest.json').unlink()
        responses = [subprocess.CompletedProcess([], 0), subprocess.TimeoutExpired('runner', 4800)]
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'fetch_origin', return_value='https://github.com/' + self.cfg['repository']), \
                patch.object(executor.subprocess, 'run', side_effect=responses) as process:
            result = executor.run_job(self.cfg, self.job_id)
            self.assertEqual(result['verdict'], 'RUNNING_TIMEOUT')
            self.assertEqual(process.call_args.kwargs['timeout'], 4800)
            self.assertEqual(executor.run_job(self.cfg, self.job_id)['verdict'], 'RUNNING_TIMEOUT')
            with self.assertRaises(executor.JobError):
                executor.retry_job(self.cfg, self.job_id)
            self.assertEqual(process.call_count, 2)
        self.assertEqual(json.loads((self.job_dir / 'execution-result.json').read_text())['verdict'], 'RUNNING_TIMEOUT')
        self.assertFalse((self.job_dir / 'recovery.json').exists())
        self.assertFalse((self.job_dir / 'attempt.json').exists())

    def test_retired_collect_reports_history_without_current_pass_or_mutation(self):
        evidence = self.review_dir / 'attestation.json'
        protected = self.root / 'protected.json'
        protected.write_text(json.dumps({'job_id': self.job_id, 'verdict': 'PASS',
            'head_sha': self.head, 'base_sha': self.base, 'reports': {'claude': 'PRIVATE_PEER_REPORT'}}))
        record = {'job_id': self.job_id, 'verdict': 'PASS',
                  'attestation_path': str(protected), 'sha256': executor.runner.digest(protected)}
        evidence.write_text(json.dumps(record))
        original = evidence.read_bytes()
        self.cfg['policy_version'] = 'next'
        result = executor.collect_job(self.cfg, self.job_id)
        self.assertEqual(result['state'], 'retired')
        self.assertEqual(result['recorded_verdict'], 'PASS')
        self.assertEqual(result['recorded_policy'], '1')
        self.assertNotIn('verdict', result)
        self.assertNotIn('reports', result)
        self.assertEqual(evidence.read_bytes(), original)
        self.collector.assert_not_called()
        output = io.StringIO()
        with patch.object(executor.bridge, 'load_config', return_value=self.cfg), contextlib.redirect_stdout(output):
            code = executor.main(['--config', 'fixture', 'collect', '--job-id', self.job_id])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.getvalue())['recorded_verdict'], 'PASS')
        self.assertNotIn('PRIVATE_PEER_REPORT', output.getvalue())

    def test_retry_parent_and_leaf_directories_are_private_under_normal_umask(self):
        self.collector.return_value = {'verdict': 'NEEDS_REVIEW', 'reasons': []}
        previous_umask = os.umask(0o022)
        try:
            with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                    patch.object(executor, 'require_quiescent'), \
                    patch.object(executor, '_run_attempt', return_value={'verdict': 'RUNNING_TIMEOUT'}):
                executor.retry_job(self.cfg, self.job_id)
        finally:
            os.umask(previous_umask)
        _, records = executor.active_attempt(self.cfg, self.req)
        self.assertEqual(records.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(records.stat().st_mode & 0o777, 0o700)
        self.assertEqual((records / 'attempt.json').stat().st_mode & 0o777, 0o600)


    def test_all_malformed_publication_records_withhold_owned_success(self):
        self.publish()
        receipt = self.job_dir / 'published.json'
        status_intent = self.job_dir / 'publish-status-intent.json'
        comment_intent = next((self.job_dir / 'comment-intents').glob('*.json'))
        selector = self.job_dir / 'attempt.json'
        originals = {path: path.read_bytes() for path in (receipt, status_intent, comment_intent)}
        cases = [(receipt, 'null'), (receipt, '[]'), (receipt, '{'),
                 (status_intent, 'null'), (status_intent, '[]'), (status_intent, '{'),
                 (comment_intent, 'null'), (comment_intent, '[]'), (selector, '[]')]
        status_row = json.loads(originals[status_intent])
        cases += [(status_intent, json.dumps(dict(status_row, payload=None))),
                  (status_intent, json.dumps(dict(status_row, state=[])))]
        for path, content in cases:
            with self.subTest(path=path.name, content=content):
                for original_path, original in originals.items():
                    original_path.write_bytes(original)
                selector.unlink(missing_ok=True)
                self.commands.gh('restore-owned-status', status_row['payload'])
                path.write_text(content)
                with self.assertRaises(executor.JobError):
                    self.publish()
                self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(len(self.commands.comments), 1)

    def test_corrupt_attempt_record_never_revokes_another_generation(self):
        self.publish()
        newer = dict(self.req, job_id='pr-7-' + 'f' * 24)
        self.commands.gh('newer-policy', executor.status_payload(newer, 'PASS'))
        count = len(self.commands.statuses)
        (self.job_dir / 'attempt.json').write_text('null')
        with self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(len(self.commands.statuses), count)
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'success')

    def test_first_send_and_confirmed_send_never_read_comment_history(self):
        original = self.commands.multica
        def capped_history(argv, body=None):
            if argv[:3] == ['issue', 'comment', 'list']:
                raise executor.bridge.BridgeError('history exceeds output cap')
            return original(argv, body)
        with patch.object(self.commands, 'multica', side_effect=capped_history):
            self.assertEqual(self.publish()['state'], 'success')
            self.assertEqual(self.publish()['state'], 'already_published')
            self.commands.gh('replayed-pending', {'context': executor.bridge.status_context(self.req),
                             'state': 'pending', 'description': 'replay'})
            self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(len(self.commands.comments), 1)

    def test_uncertain_comment_reads_only_send_window_with_full_body(self):
        self.commands.lose_comment_ack = True
        with self.assertRaises(executor.bridge.BridgeError):
            self.publish()
        intent_path = next((self.job_dir / 'comment-intents').glob('*.json'))
        created = json.loads(intent_path.read_text())['at']
        with patch.object(self.commands, 'multica', wraps=self.commands.multica) as calls:
            self.assertEqual(self.publish()['state'], 'success')
        reads = [call.args[0] for call in calls.call_args_list if call.args[0][:3] == ['issue', 'comment', 'list']]
        self.assertEqual(len(reads), 1)
        self.assertEqual(reads[0][reads[0].index('--since') + 1], executor.bridge.since_overlap(created))
        self.assertIn('--roots-only', reads[0])
        self.assertNotIn('--summary', reads[0])
        self.assertEqual(len(self.commands.comments), 1)

    def test_invalid_comment_ack_remains_uncertain_until_trusted_match(self):
        original = self.commands.multica
        def bad_ack(argv, body=None):
            response = original(argv, body)
            return {} if argv[:3] == ['issue', 'comment', 'add'] else response
        with patch.object(self.commands, 'multica', side_effect=bad_ack):
            self.assertEqual(self.publish()['state'], 'awaiting_comment_reconciliation')
        intent_path = next((self.job_dir / 'comment-intents').glob('*.json'))
        self.assertEqual(json.loads(intent_path.read_text())['state'], 'sending')
        self.assertFalse((self.job_dir / 'published.json').exists())
        self.assertEqual(self.publish()['state'], 'success')
        self.assertEqual(len(self.commands.comments), 1)
        self.assertEqual(json.loads(intent_path.read_text())['comment_id'], self.commands.comments[0]['id'])

    def test_corrupt_disposable_cursor_never_blocks_job_collection(self):
        cursor = self.root / 'executor-collection.json'
        for invalid in ('{', 'null', '[]', '{"last_job_id":42}', '{"last_job_id":"../bad"}'):
            with self.subTest(invalid=invalid):
                cursor.write_text(invalid)
                with patch.object(executor.bridge, 'Commands', return_value=self.commands):
                    results = executor.collect_all(self.cfg)
                self.assertEqual(results[0]['state'], 'cursor_reset')
                self.assertEqual(results[1]['job_id'], self.job_id)
                self.assertIn(results[1]['state'], ('success', 'already_published'))
                self.assertEqual(json.loads(cursor.read_text())['last_job_id'], self.job_id)
                self.assertEqual(executor.exit_code(results), 0)

    def test_stray_job_directory_is_diagnostic_not_tick_failure(self):
        stray = Path(self.cfg['jobs_dir']) / 'backup-copy'
        stray.mkdir()
        (stray / 'request.json').write_text('private backup')
        with patch.object(executor.bridge, 'Commands', return_value=self.commands):
            results = executor.collect_all(self.cfg)
        self.assertEqual(results[0]['state'], 'skipped_invalid_job_dirs')
        self.assertEqual(results[1]['job_id'], self.job_id)
        self.assertEqual(executor.exit_code(results), 0)
        self.assertEqual((stray / 'request.json').read_text(), 'private backup')


    def test_invalid_generation_record_withholds_newly_written_success(self):
        executor.bridge.generation_path(self.cfg, self.req['multica_issue_id']).write_text('[]')
        with self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')
        self.assertEqual(self.commands.updates, [])
        self.assertFalse((self.job_dir / 'published.json').exists())


    def test_missing_review_directory_after_launch_is_unknown_not_quiescent(self):
        self.review_dir.rename(self.root / 'moved-review-evidence')
        executor.atomic(self.job_dir / 'execution.json', {'job_id': self.job_id,
                        'runner_job_id': self.job_id, 'phase': 'RUNNER_LAUNCH_INTENT'})
        executor.atomic(self.job_dir / 'execution-result.json', {'job_id': self.job_id,
                        'runner_job_id': self.job_id, 'verdict': 'RUNNING_TIMEOUT'})
        with patch.object(executor, 'no_active_controller'), self.assertRaises(executor.JobError):
            executor.recover_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'recovery.json').exists())
        executor.atomic(self.job_dir / 'execution-result.json', {'job_id': self.job_id,
                        'runner_job_id': self.job_id, 'verdict': 'FAILED'})
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'no_active_controller'), self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertEqual(self.commands.statuses, [])

    def test_missing_review_directory_requires_explicit_predispatch_record(self):
        (self.review_dir / 'manifest.json').unlink()
        self.review_dir.rmdir()
        for record in ({'job_id': self.job_id}, {'job_id': self.job_id, 'phase': 'RUNNING'},
                       {'job_id': self.job_id, 'phase': 'NOT_DISPATCHED', 'runner_job_id': 'other'}):
            executor.atomic(self.job_dir / 'execution.json', record)
            with self.subTest(record=record), patch.object(executor, 'no_active_controller'), self.assertRaises(executor.JobError):
                executor.require_quiescent(self.cfg, self.req, self.job_id)
        executor.atomic(self.job_dir / 'execution.json', {'job_id': self.job_id, 'phase': 'PREPARING'})
        executor.atomic(self.job_dir / 'execution-result.json', {'job_id': self.job_id, 'verdict': 'FAILED'})
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'no_active_controller'), \
                patch.object(executor, '_run_attempt', return_value={'verdict': 'RUNNING_TIMEOUT'}) as dispatch:
            self.assertEqual(executor.retry_job(self.cfg, self.job_id)['verdict'], 'RUNNING_TIMEOUT')
        self.assertTrue(dispatch.call_args.kwargs['dispatch_reserved'])
        _, records = executor.active_attempt(self.cfg, self.req)
        self.assertEqual(json.loads((records / 'execution.json').read_text())['phase'], 'NOT_DISPATCHED')

    def test_retry_rechecks_target_inside_status_lock_before_selecting(self):
        newer = dict(self.req, base_sha='c' * 40)
        newer['job_id'] = executor.bridge.job_id_for(newer)
        def collected(directory, **kwargs):
            self.commands.pr['base']['sha'] = newer['base_sha']
            self.commands.gh('new-generation', executor.status_payload(newer, 'PASS'))
            return {'verdict': 'FAILED', 'reasons': []}
        self.collector.side_effect = collected
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'require_quiescent'), self.assertRaises(executor.JobError):
            executor.retry_job(self.cfg, self.job_id)
        self.assertEqual(len(self.commands.statuses), 1)
        self.assertEqual(self.commands.statuses[0][1]['state'], 'success')
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertFalse((self.job_dir / 'attempts').exists())

    def test_retry_rechecks_issue_generation_and_remote_owner_before_selecting(self):
        for change in ('generation', 'remote_status'):
            with self.subTest(change=change):
                newer = dict(self.req, job_id='pr-7-' + 'f' * 24)
                def collected(directory, **kwargs):
                    if change == 'generation':
                        with executor.bridge.issue_generation_lock(self.cfg, self.req['multica_issue_id']):
                            executor.bridge.set_generation(self.cfg, self.req['multica_issue_id'], newer['job_id'])
                    else:
                        self.commands.gh('new-policy', executor.status_payload(newer, 'PASS'))
                    return {'verdict': 'FAILED', 'reasons': []}
                self.collector.side_effect = collected
                with executor.bridge.issue_generation_lock(self.cfg, self.req['multica_issue_id']):
                    executor.bridge.set_generation(self.cfg, self.req['multica_issue_id'], self.job_id)
                self.commands.statuses.clear()
                with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                        patch.object(executor, 'require_quiescent'), self.assertRaises(executor.JobError):
                    executor.retry_job(self.cfg, self.job_id)
                self.assertFalse((self.job_dir / 'attempt.json').exists())
                self.assertFalse((self.job_dir / 'attempts').exists())
                self.assertFalse(any(payload['state'] == 'pending' for _, payload in self.commands.statuses))

    def test_retry_busy_status_lock_cannot_select_an_attempt(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        with executor.bridge.status_lock(self.cfg, self.req) as locked:
            self.assertTrue(locked)
            with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                    patch.object(executor, 'require_quiescent'), self.assertRaises(executor.JobError):
                executor.retry_job(self.cfg, self.job_id)
        self.assertFalse((self.job_dir / 'attempt.json').exists())
        self.assertFalse((self.job_dir / 'attempts').exists())

    def test_retry_crash_before_pending_has_recoverable_unused_reservation(self):
        self.collector.return_value = {'verdict': 'FAILED', 'reasons': []}
        original = self.commands.gh
        def crash(endpoint, payload=None):
            if payload is not None:
                raise KeyboardInterrupt('crash before remote request')
            return original(endpoint)
        with patch.object(executor.bridge, 'Commands', return_value=self.commands), \
                patch.object(executor, 'require_quiescent'), patch.object(self.commands, 'gh', side_effect=crash), \
                self.assertRaises(KeyboardInterrupt):
            executor.retry_job(self.cfg, self.job_id)
        runner_id, records = executor.active_attempt(self.cfg, self.req)
        self.assertEqual(json.loads((records / 'execution.json').read_text())['phase'], 'NOT_DISPATCHED')
        self.assertFalse((records / 'execution-result.json').exists())
        with patch.object(executor, 'no_active_controller'), patch.object(executor.subprocess, 'run') as launch:
            recovered = executor.recover_job(self.cfg, self.job_id)
        self.assertEqual(recovered['verdict'], 'FAILED')
        self.assertEqual(recovered['runner_job_id'], runner_id)
        launch.assert_not_called()

    def test_deep_json_publication_record_is_controlled_and_revokes_success(self):
        self.publish()
        (self.job_dir / 'published.json').write_text('[' * 2000 + 'null' + ']' * 2000)
        with self.assertRaises(executor.JobError):
            self.publish()
        self.assertEqual(self.commands.statuses[-1][1]['state'], 'pending')


    def test_retired_pointer_hash_or_verdict_mismatch_reports_unknown(self):
        self.cfg['policy_version'] = 'next'
        target = self.root / 'protected-attestation.json'
        reference = self.review_dir / 'attestation.json'
        target.write_text(json.dumps({'job_id': self.job_id, 'verdict': 'NEEDS_REVIEW',
                          'head_sha': self.head, 'base_sha': self.base}))
        record = {'job_id': self.job_id, 'verdict': 'NEEDS_REVIEW',
                  'attestation_path': str(target), 'sha256': executor.runner.digest(target)}
        reference.write_text(json.dumps(record))
        original_reference = reference.read_bytes()
        # Protected file committed first; local reference still names the old bytes.
        target.write_text(json.dumps({'job_id': self.job_id, 'verdict': 'PASS',
                          'head_sha': self.head, 'base_sha': self.base}))
        result = executor.collect_job(self.cfg, self.job_id)
        self.assertEqual(result['recorded_verdict'], 'UNKNOWN')
        self.assertNotIn('attestation_path', result)
        self.assertEqual(reference.read_bytes(), original_reference)
        # Even a current hash cannot authenticate a contradictory recorded verdict.
        record['sha256'] = executor.runner.digest(target)
        reference.write_text(json.dumps(record))
        self.assertEqual(executor.collect_job(self.cfg, self.job_id)['recorded_verdict'], 'UNKNOWN')
        self.collector.assert_not_called()

    def test_atomic_creates_every_new_parent_with_private_mode(self):
        target = self.root / 'new-state' / 'nested' / 'records' / 'record.json'
        previous_umask = os.umask(0o022)
        try:
            executor.atomic(target, {'value': 'fixture'})
        finally:
            os.umask(previous_umask)
        for parent in (target.parent, target.parent.parent, target.parent.parent.parent):
            self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)



class FetchEnvironmentTests(unittest.TestCase):
    """Real Git/file transport tests; no GitHub credentials or network are used."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='multica-fetch-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.clean = executor.runner.git_environment()
        self.author = self.root / 'author'
        self.author.mkdir()
        self.git(self.author, 'init', '--template=', '-q', '-b', 'main')
        self.git(self.author, 'config', 'user.name', 'Fixture')
        self.git(self.author, 'config', 'user.email', 'fixture@example.invalid')
        (self.author / 'initial.txt').write_text('initial blob')
        self.git(self.author, 'add', '.')
        self.git(self.author, 'commit', '-qm', 'initial')
        self.server = self.root / 'server.git'
        self.git(self.root, 'clone', '-q', '--bare', str(self.author), str(self.server))
        self.git(self.server, 'config', 'uploadpack.allowFilter', 'true')
        self.mirror = self.root / 'mirror.git'
        self.git(self.root, 'clone', '-q', '--bare', '--filter=blob:none', self.server.as_uri(), str(self.mirror))
        self.helper = self.root / 'trusted gh'
        self.helper.write_text('#!/bin/sh\nprintf "username=fixture\\npassword=fixture-secret\\n"\n')
        self.helper.chmod(0o700)
        self.cfg = {'gh_path': str(self.helper)}

    def git(self, repo, *args, env=None, input_text=None, check=True):
        return subprocess.run(['git', '-C', str(repo), *args], env=env or self.clean,
                              text=True, input=input_text, capture_output=True, check=check, timeout=20)

    def missing(self):
        output = self.git(self.mirror, 'rev-list', '--objects', '--all', '--missing=print').stdout
        return [row for row in output.splitlines() if row.startswith('?')]

    def test_real_fetch_ignores_injected_repo_global_rewrites_and_hooks(self):
        hook = self.root / 'hooks'
        hook.mkdir()
        marker = self.root / 'UNTRUSTED_HOOK_RAN'
        (hook / 'reference-transaction').write_text('#!/bin/sh\ntouch ' + str(marker) + '\n')
        (hook / 'reference-transaction').chmod(0o700)
        self.git(self.mirror, 'config', 'core.hooksPath', str(hook))
        global_config = self.root / 'hostile.gitconfig'
        global_config.write_text('[url "ext::false "]\n insteadOf = file://\n')
        inherited = {'GIT_DIR': str(self.author / '.git'), 'GIT_WORK_TREE': str(self.author),
                     'GIT_CONFIG_GLOBAL': str(global_config), 'GIT_CONFIG_COUNT': '1',
                     'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': str(hook),
                     'GIT_SSH_COMMAND': 'touch ' + str(marker), 'SSH_AUTH_SOCK': 'fixture-agent'}
        with patch.dict(os.environ, inherited):
            env = executor.fetch_git_environment(self.cfg)
        self.assertNotIn('GIT_DIR', env)
        self.assertNotIn('GIT_WORK_TREE', env)
        self.assertEqual(env['GIT_CONFIG_GLOBAL'], os.devnull)
        self.assertEqual(env['SSH_AUTH_SOCK'], 'fixture-agent')
        self.assertEqual(executor.fetch_origin(self.mirror, env), self.server.as_uri())
        # Only this isolated test permits file://. Production permits https/ssh.
        local_env = dict(env, GIT_ALLOW_PROTOCOL='file')
        self.git(self.mirror, 'fetch', '-q', '--no-filter', '--refetch', 'origin', 'main:main', env=local_env)
        self.assertEqual(self.missing(), [])
        self.assertFalse(marker.exists())
        (self.author / 'new.txt').write_text('new blob')
        self.git(self.author, 'add', '.')
        self.git(self.author, 'commit', '-qm', 'new')
        self.git(self.author, 'push', '-q', str(self.server), 'main')
        self.git(self.mirror, 'fetch', '-q', '--no-filter', 'origin', 'main:main', env=local_env)
        self.assertEqual(self.missing(), [])
        self.assertFalse(marker.exists())
        # Ordinary diffs also run: no invalid diff.external="" override.
        self.assertIn('new.txt', self.git(self.mirror, 'diff', '--stat', 'HEAD~1', 'HEAD', env=local_env).stdout)

    def test_real_git_credential_uses_only_explicit_trusted_helper(self):
        marker = self.root / 'UNTRUSTED_AUTH_RAN'
        hostile = '!touch ' + str(marker)
        self.git(self.mirror, 'config', 'credential.helper', hostile)
        self.git(self.mirror, 'config', 'credential.https://github.com.helper', hostile)
        env = executor.fetch_git_environment(self.cfg)
        response = self.git(self.mirror, 'credential', 'fill', env=env,
                            input_text='protocol=https\nhost=github.com\npath=owner/repo\n\n')
        self.assertIn('password=fixture-secret', response.stdout)
        self.assertFalse(marker.exists())
        self.assertEqual(env['GIT_ALLOW_PROTOCOL'], 'https:ssh')
        denied = self.git(self.mirror, 'ls-remote', 'ext::touch ' + str(marker), env=env, check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertFalse(marker.exists())

    def test_no_filter_does_not_pretend_to_rehydrate_known_partial_head(self):
        env = dict(executor.fetch_git_environment(self.cfg), GIT_ALLOW_PROTOCOL='file')
        self.assertTrue(self.missing())
        self.git(self.mirror, 'fetch', '-q', '--no-filter', 'origin', 'main:main', env=env)
        self.assertTrue(self.missing())
        self.git(self.mirror, 'fetch', '-q', '--no-filter', '--refetch', 'origin', 'main:main', env=env)
        self.assertEqual(self.missing(), [])



if __name__ == "__main__":
    unittest.main()
