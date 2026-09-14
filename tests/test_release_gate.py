"""Release gate regression tests; all Git changes stay in temporary fixtures."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
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
import review_runner as runner


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "--template=")
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
        (self.artifact_root / "run.meta").write_text(
            f"runid=evidence\nmode=review\nworkdir={self.repo}\nmodels=codex,grok\nsession=fixture-session\n")
        self.evidence = {
            "schema_version": 1, "kind": "release", "verdict": "PASS", "version": "1.2.3",
            "repo": str(self.repo), "base_sha": self.base, "head_sha": self.head,
            "tree_sha": self.git("rev-parse", "HEAD^{tree}"),
            "artifact_root": str(self.artifact_root), "mmrun_run_id": "evidence",
            "provenance": {"mmrun_home": str(self.root), "session": "fixture-session"},
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
        self.refresh_contract()
        self.save()

    def refresh_contract(self):
        # A fresh complete synthetic attempt; production baselines are never reset.
        executable = self.root / 'fixture-mmrun'; executable.write_text('fixture executable')
        inputs = {}
        for name in ('schema', 'fence', 'notes', 'codex_profile', 'codex_profile_snapshot'):
            path = self.root / ('input-' + name); path.write_text('fixture ' + name)
            inputs[name] = {'path': str(path), 'sha256': gate.file_hash(path)}
        helper = Path(runner.__file__).with_name('runner_dispatch.py')
        self.evidence['provenance'].update(mmrun_kind='upstream', mmrun_path=str(executable),
            mmrun_sha256=gate.file_hash(executable), models=self.evidence['policy']['models'], input_files=inputs,
            review_runner_path=str(Path(runner.__file__).resolve()), review_runner_sha256=gate.file_hash(Path(runner.__file__)),
            dispatch_helper=str(helper), dispatch_helper_sha256=gate.file_hash(helper),
            codex_home=str(self.root), mmrun_d_snapshot=str(self.root))
        request = {'schema_version': 1, 'job_id': self.evidence['job_id'], 'argv': [str(executable)],
                   'provenance': self.evidence['provenance'], 'executable_sha256': gate.file_hash(executable),
                   'candidate': runner.candidate_identity(self.evidence)}
        runner.write_json(self.root / 'dispatch-request.json', request)
        hashed = gate.file_hash(self.root / 'dispatch-request.json')
        self.evidence['dispatch_request_sha256'] = hashed
        self.evidence['dispatch_result']['request_sha256'] = hashed
        runner.write_json(self.root / 'dispatch-result.json', self.evidence['dispatch_result'])
        self.evidence['dispatch_receipt_sha256'] = gate.file_hash(self.root / 'dispatch-result.json')
        (self.root / 'terminal-evidence.json').unlink(missing_ok=True)
        self.evidence.pop('terminal_evidence_path', None); self.evidence.pop('terminal_evidence_sha256', None)
        runner.validate_terminal_evidence(self.root, self.evidence, self.evidence['artifacts'], create=True)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True, env=runner.git_environment()).stdout.strip()

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
            with self.subTest(argument=argument), contextlib.redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit) as caught:
                    gate.main(["check", "--repo", str(self.repo), "--attestation", str(self.attestation),
                               "--base-sha", self.base, "--head-sha", self.head, argument])
                self.assertEqual(caught.exception.code, 2)
                self.assertIn("unrecognized arguments: " + argument, stderr.getvalue())
                self.assertNotIn("required", stderr.getvalue().split("error:")[-1])

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
                self.refresh_contract()
                self.save()
                expected = {"status": "not DONE", "meta": "one successful exit", "out": "ARTIFACT_OUTPUT_EMPTY"}[suffix]
                with self.assertRaisesRegex((gate.GateError, gate.ReviewError), expected):
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
                self.refresh_contract()
                self.save()
                with self.assertRaisesRegex(gate.GateError, "model review requires human resolution: codex"):
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
        self.evidence["policy"]["models"] = ["claude", "codex"]
        for artifact in self.evidence["artifacts"]:
            if artifact["path"].startswith("grok."):
                old = self.artifact_root / artifact["path"]
                artifact["path"] = artifact["path"].replace("grok.", "claude.")
                old.rename(self.artifact_root / artifact["path"])
        meta = self.artifact_root / "run.meta"
        meta.write_text(meta.read_text().replace("models=codex,grok", "models=" + ",".join(self.evidence["policy"]["models"])))
        for artifact in self.evidence["artifacts"]:
            if artifact["path"] == "run.meta":
                artifact["sha256"] = hashlib.sha256(meta.read_bytes()).hexdigest()
        self.refresh_contract()
        self.save()
        self.assertEqual(self.validate()["status"], "STATIC_REVIEW_VERIFIED")
        self.evidence["policy"]["models"].append("grok")
        meta.write_text(meta.read_text().replace("models=claude,codex", "models=claude,codex,grok"))
        for artifact in self.evidence["artifacts"]:
            if artifact["path"] == "run.meta":
                artifact["sha256"] = hashlib.sha256(meta.read_bytes()).hexdigest()
        self.refresh_contract()
        self.save()
        with self.assertRaisesRegex(gate.GateError, "required model evidence missing"):
            self.validate()

    def test_fifo_and_oversize_attestation_rejected_before_open_or_hash(self):
        fifo = self.root / "attestation.fifo"
        os.mkfifo(fifo)
        oversized = self.root / "oversized.json"
        with oversized.open("wb") as stream:
            stream.truncate(gate.MAX_ATTESTATION_BYTES + 1)
        for path in (fifo, oversized):
            with self.subTest(path=path), patch.object(os, "open") as opened, patch.object(gate, "file_hash") as hashed:
                with self.assertRaisesRegex(gate.ReviewError, "NOT_REGULAR_OR_OVERSIZED"):
                    gate.validate(self.repo, path, self.base, self.head)
            opened.assert_not_called()
            hashed.assert_not_called()

    def test_json_snapshot_reads_hashes_and_parses_one_bounded_descriptor(self):
        original = os.open
        with patch.object(os, "open", wraps=original) as opened:
            value, hashed, identity = gate.read_json_snapshot(self.attestation, max_bytes=gate.MAX_ATTESTATION_BYTES)
        opened.assert_called_once()
        self.assertEqual(value, self.evidence)
        self.assertEqual(hashed, hashlib.sha256(self.attestation.read_bytes()).hexdigest())
        self.assertEqual(identity.st_ino, self.attestation.stat().st_ino)
        self.assertTrue(opened.call_args.args[1] & os.O_NOFOLLOW)
        self.assertTrue(opened.call_args.args[1] & os.O_NONBLOCK)


class V6ArtifactBoundaryTests(unittest.TestCase):
    setUp = ReleaseGateTests.setUp
    refresh_contract = ReleaseGateTests.refresh_contract
    git = ReleaseGateTests.git
    save = ReleaseGateTests.save
    validate = ReleaseGateTests.validate

    def test_oversized_text_artifacts_fail_before_their_hash(self):
        original_hash = gate.file_hash
        for suffix in ('.status', '.meta', '.out'):
            path = self.artifact_root / ('codex' + suffix)
            original = path.read_bytes()
            with self.subTest(suffix=suffix):
                with path.open('wb') as stream:
                    stream.truncate(gate.TEXT_LIMITS[suffix] + 1)
                def guarded_hash(candidate):
                    self.assertNotEqual(candidate, path, 'oversized artifact must not be hashed')
                    return original_hash(candidate)
                with patch.object(gate, 'file_hash', side_effect=guarded_hash):
                    with self.assertRaisesRegex(gate.GateError, 'OVERSIZED'):
                        self.validate()
                path.write_bytes(original)

    def test_streamed_output_requires_text_and_complete_utf8(self):
        path = self.artifact_root / 'codex.out'
        for data, expected in ((b' \n' * 40000, False),
                               (b' ' * 65535 + '\u4e2d'.encode(), True)):
            path.write_bytes(data)
            self.assertIs(gate.output_has_text(path), expected)
        path.write_bytes(b'valid prefix\xff')
        with self.assertRaisesRegex(gate.ReviewError, "INVALID_UTF8"):
            gate.output_has_text(path)

    def test_artifact_root_and_rehashed_run_metadata_remain_bound(self):
        original = copy.deepcopy(self.evidence)
        for field, value in (('mmrun_run_id', 'different-run'),
                             ('provenance', {'mmrun_home': str(self.root / 'other'), 'session': 'fixture-session'})):
            with self.subTest(field=field):
                self.evidence = dict(original, **{field:value}); self.save()
                with self.assertRaises(gate.GateError):
                    self.validate()
        self.evidence = copy.deepcopy(original)
        path = self.artifact_root / 'run.meta'; content = path.read_text()
        for key in ('runid', 'session', 'workdir', 'models', 'mode'):
            with self.subTest(key=key):
                path.write_text('\n'.join(key + '=different' if line.startswith(key + '=') else line
                                          for line in content.splitlines()) + '\n')
                next(a for a in self.evidence['artifacts'] if a['path'] == 'run.meta')['sha256'] = gate.file_hash(path)
                self.save()
                with self.assertRaisesRegex(gate.GateError, 'TERMINAL_EVIDENCE_CHANGED'):
                    self.validate()

    def test_git_fixture_ignores_inherited_repository_and_global_hooks(self):
        sentinel = self.repo
        head = self.git('rev-parse', 'HEAD')
        config = (sentinel / '.git/config').read_bytes()
        hooks = self.root / 'evil-hooks'; hooks.mkdir()
        marker = self.root / 'hook-ran'
        hook = hooks / 'pre-commit'; hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n'); hook.chmod(0o700)
        global_config = self.root / 'global.config'
        global_config.write_text('[core]\n hooksPath = ' + str(hooks) + '\n')
        self.repo = self.root / 'other-fixture'; self.repo.mkdir()
        with patch.dict(os.environ, {'GIT_DIR': str(sentinel / '.git'), 'GIT_WORK_TREE': str(sentinel),
                                    'GIT_CONFIG_GLOBAL': str(global_config), 'GIT_TEMPLATE_DIR': str(hooks),
                                    'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath',
                                    'GIT_CONFIG_VALUE_0': str(hooks)}):
            self.git('init', '-q', '--template=')
            (self.repo / 'new.txt').write_text('fixture')
            self.git('add', '.')
            self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        self.assertTrue((self.repo / '.git').is_dir())
        self.repo = sentinel
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual((sentinel / '.git/config').read_bytes(), config)
        self.assertFalse(marker.exists())

    def test_plan_requires_separate_writable_packaging_checkout(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = gate.main(['plan', '--repo', str(self.repo), '--attestation', str(self.attestation),
                              '--base-sha', self.base, '--head-sha', self.head, '--sku', 'pro', '--version', '1.2.3'])
        self.assertEqual(code, 0)
        result = json.loads(output.getvalue())
        self.assertIn('<CLEAN_WRITABLE_CHECKOUT>', result['manual_packaging_command'])
        self.assertNotIn(str(self.repo), result['manual_packaging_command'])
        self.assertEqual(result['packaging_checkout_head'], self.head)


class V7GateContractTests(unittest.TestCase):
    setUp = ReleaseGateTests.setUp
    refresh_contract = ReleaseGateTests.refresh_contract
    git = ReleaseGateTests.git
    save = ReleaseGateTests.save
    validate = ReleaseGateTests.validate

    def test_gate_requires_actual_request_and_every_execution_input(self):
        paths = [self.root / 'dispatch-request.json'] + [Path(item['path']) for item in self.evidence['provenance']['input_files'].values()]
        for path in paths:
            with self.subTest(path=path.name):
                self.assertEqual(self.validate()['status'], 'STATIC_REVIEW_VERIFIED')
                original = path.read_bytes(); path.unlink()
                with self.assertRaises(gate.GateError):
                    self.validate()
                path.write_bytes(original)
                path.write_bytes(original + b'changed')
                with self.assertRaises(gate.GateError):
                    self.validate()
                path.write_bytes(original)

    def test_gate_requires_immutable_terminal_baseline(self):
        self.assertEqual(self.validate()['status'], 'STATIC_REVIEW_VERIFIED')
        (self.root / 'terminal-evidence.json').unlink()
        with self.assertRaisesRegex(gate.GateError, 'BASELINE_MISSING'):
            self.validate()

    def test_gate_semantic_snapshot_cannot_disagree_with_hash(self):
        original = gate.read_text_snapshot
        changed = False
        def interleave(path):
            nonlocal changed
            if path.name == 'codex.status' and not changed:
                changed = True; path.write_text('FAIL:1')
            return original(path)
        with patch.object(gate, 'read_text_snapshot', side_effect=interleave):
            with self.assertRaisesRegex(gate.GateError, 'SEMANTIC_SNAPSHOT_CHANGED'):
                self.validate()

    def test_deep_attestation_is_controlled(self):
        self.attestation.write_text('[' * 2000 + '0' + ']' * 2000)
        with self.assertRaisesRegex(gate.ReviewError, 'JSON_(INVALID|TOO_DEEP)'):
            self.validate()


class V8GateIdentityTests(unittest.TestCase):
    setUp = ReleaseGateTests.setUp
    refresh_contract = ReleaseGateTests.refresh_contract
    git = ReleaseGateTests.git
    save = ReleaseGateTests.save
    validate = ReleaseGateTests.validate

    def test_attestation_version_cannot_relabel_an_existing_release_review(self):
        self.assertEqual(self.validate()['status'], 'STATIC_REVIEW_VERIFIED')
        self.evidence['version'] = '9.9.9'; self.save()
        with self.assertRaisesRegex(gate.GateError, 'DISPATCH_REQUEST_CONTRACT_MISMATCH'):
            self.validate()

    def test_gate_reuses_collector_ignored_file_cleanliness_rule(self):
        self.assertEqual(self.validate()['status'], 'STATIC_REVIEW_VERIFIED')
        (self.repo / '.git/info').mkdir(exist_ok=True)
        (self.repo / '.git/info/exclude').write_text('ignored-artifact\n')
        (self.repo / 'ignored-artifact').write_text('unreviewed')
        with self.assertRaisesRegex(gate.GateError, 'unreviewed ignored files'):
            self.validate()


if __name__ == "__main__":
    unittest.main()
