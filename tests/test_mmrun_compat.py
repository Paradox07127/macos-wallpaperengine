"""Transport-only tests; no model process or installed mmrun is invoked."""

import importlib.util
import json
from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("mmrun_compat", Path(__file__).resolve().parents[1] / "scripts/multica/mmrun_compat.py")
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


REPORT = {"verdict": "request_changes", "summary": "Still gathering evidence.", "findings": [], "not_expanded": 0}


class NormalizationTests(unittest.TestCase):
    def test_claude_requires_explicit_successful_terminal_envelope(self):
        envelope = {'type': 'result', 'subtype': 'success', 'is_error': False,
                    'structured_output': REPORT}
        self.assertEqual(compat.normalize(json.dumps(envelope), 'claude')['structured_output'], REPORT)
        for fields in ({'type': 'assistant'}, {'subtype': 'error_max_turns'},
                       {'is_error': True}, {'is_error': None}):
            with self.subTest(fields=fields), self.assertRaises(compat.CompatibilityError):
                compat.normalize(json.dumps(dict(envelope, **fields)), 'claude')
        del envelope['is_error']
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize(json.dumps(envelope), 'claude')

    def test_camel_case_mixed_prefix_preserves_nonapproval(self):
        text = "warning: diagnostic prefix\n" + json.dumps({"text": "", "structuredOutput": REPORT, "stopReason": "end_turn", "thought": "not public", "usage": {"input_tokens": 1}})
        result = compat.normalize(text)
        self.assertEqual(result["structured_output"], REPORT)
        self.assertEqual(result["usage"], {"input_tokens": 1})
        self.assertNotIn("thought", result)
        self.assertNotIn("text", result)

    def test_pretty_snake_case_envelope(self):
        result = compat.normalize(json.dumps({"structured_output": REPORT, "stop_reason": "completed"}, indent=2))
        self.assertEqual(result["structured_output"]["verdict"], "request_changes")

    def test_json_text_legacy_envelope(self):
        result = compat.normalize(json.dumps({"text": json.dumps(REPORT), "stopReason": "stop"}))
        self.assertEqual(result["structured_output"], REPORT)

    def test_diagnostic_brackets_and_indented_envelope(self):
        for prefix in ("[warn] diagnostic\n", "warning: diagnostic\n  ", "  ",
                       "[info] model ready\n[debug] result follows\n\t"):
            with self.subTest(prefix=prefix):
                result = compat.normalize(prefix + json.dumps({"structuredOutput": REPORT, "stopReason": "end_turn"}))
                self.assertEqual(result["structured_output"], REPORT)

    def test_unknown_prefix_or_missing_completion_is_rejected(self):
        terminal = json.dumps({"structuredOutput": REPORT, "stopReason": "end_turn"})
        for text in ("arbitrary prefix\n" + terminal, "[warn] " + terminal,
                     "[\n" + terminal, json.dumps({"structuredOutput": REPORT}),
                     json.dumps({"structuredOutput": REPORT, "completed": True})):
            with self.subTest(text=text), self.assertRaises(compat.CompatibilityError):
                compat.normalize(text)

    def test_conflicting_aliases_fail(self):
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize(json.dumps({"structuredOutput": REPORT, "structured_output": {"verdict": "approve"}, "stopReason": "end_turn"}))

    def test_duplicate_report_key_fails(self):
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize('{"stopReason":"end_turn","structuredOutput":{"verdict":"approve","verdict":"request_changes"}}')

    def test_explicit_error_and_nonterminal_stop_fail(self):
        for extra in ({"isError": True}, {"error": "failed"}, {"stopReason": "max_turns"}, {"stop_reason": "cancelled"}):
            with self.subTest(extra=extra), self.assertRaises(compat.CompatibilityError):
                compat.normalize(json.dumps(dict(structuredOutput=REPORT, **extra)))

    def test_trailing_log_or_plain_text_fail_closed(self):
        for text in (json.dumps({"structuredOutput": REPORT}) + "\nwarning", "Session ID already in use", json.dumps({"text": "starting review"})):
            with self.subTest(text=text), self.assertRaises(compat.CompatibilityError):
                compat.normalize(text)

    def test_missing_and_empty_result_fail(self):
        for data in ({}, {"structuredOutput": {}}, {"structuredOutput": []}, {"structuredOutput": None}):
            with self.subTest(data=data), self.assertRaises(compat.CompatibilityError):
                compat.normalize(json.dumps(dict(data, stopReason="end_turn")))

    def test_multiple_result_envelopes_are_ambiguous(self):
        text = json.dumps({"structuredOutput": REPORT}) + "\n" + json.dumps({"structuredOutput": dict(REPORT, verdict="approve")})
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize(text)

    def test_truncated_error_wrapper_cannot_salvage_inner_approval(self):
        inner = json.dumps({'structuredOutput': dict(REPORT, verdict='approve'), 'stopReason': 'end_turn'})
        for text in ('{"isError":true,"result":' + inner, '[' + inner,
                     '{"broken":\n' + inner, 'warning {broken\n' + inner):
            with self.subTest(text=text), self.assertRaises(compat.CompatibilityError):
                compat.normalize(text)

    def test_conflicting_or_null_completion_aliases_fail(self):
        for fields in ({'stopReason': 'end_turn', 'stop_reason': 'cancelled'},
                       {'stopReason': 'end_turn', 'stop_reason': 'completed'},
                       {'stopReason': None}):
            with self.subTest(fields=fields), self.assertRaises(compat.CompatibilityError):
                compat.normalize(json.dumps(dict(structuredOutput=REPORT, **fields)))


class LocalCopyTests(unittest.TestCase):
    def source(self):
        anchors = compat.CLAUDE_ANCHORS
        return ('#!/usr/bin/env bash\n# --tools read_file,grep,list_dir\n# sandbox-exec original guard\n'
                + anchors['binary'] + '\n' + anchors['models']
                + '\nrun_once() {\n  case "$m" in\n    grok)\n'
                + compat.SESSION_ANCHOR + '\n      env "${GROK_ENV[@]}" "$SELF" __fence "$w" "$HOME/.grok" "$rd/prompt.md" "$ro" \\\n'
                + compat.OUTPUT_ANCHOR + '\n      ;;\n' + anchors['case']
                + '      :\n      ;;\n  esac\n}\nstart_fixture() {\n'
                + anchors['workdir'] + '\n    ' + anchors['start']
                + '\n}\nrun_fixture() {\n  ' + anchors['run'] + '\n}\n')

    def test_claude_adapter_is_fenced_static_only_and_parseable(self):
        text = compat.add_claude_provider(self.source(), '/helper with spaces.py', '/usr/bin/python3')
        self.assertIn('--restricted --safe-mode', text)
        self.assertIn('--tools "Read,Grep,Glob" --permission-mode plan', text)
        self.assertIn('--no-session-persistence', text)
        self.assertIn('--strict-mcp-config --mcp-config', text)
        self.assertIn('"$SELF" __fence "$ROOT/.no-write" "$HOME/.claude"', text)
        self.assertNotIn('--dangerously-skip-permissions', text)
        self.assertIn('Claude adapter supports static review only', text)
        result = subprocess.run(['bash', '-n'], input=text, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_claude_anchor_mismatch_refuses_partial_patch(self):
        for key, anchor in compat.CLAUDE_ANCHORS.items():
            with self.subTest(anchor=key), self.assertRaises(compat.CompatibilityError):
                compat.add_claude_provider(self.source().replace(anchor, ''), '/helper', '/python')

    def test_only_expected_grok_changes(self):
        original = self.source()
        patched = compat.patched_source(original, "/helper with spaces.py", "/usr/bin/python3")
        self.assertIn('sid=$(uuidgen', patched)
        self.assertIn('printf \'%s\\n\' "$sid" > "$rd/grok.session"', patched)
        self.assertIn('"$SELF" __fence "$w" "$HOME/.grok" "$rd/prompt.md" "$ro"', patched)
        self.assertIn("# --tools read_file,grep,list_dir", patched)
        self.assertIn("'/helper with spaces.py' normalize", patched)
        self.assertIn('> "$rd/grok.stdout" 2> "$rd/grok.raw"', patched)
        self.assertNotIn("--always-approve", patched)
        self.assertNotIn("--no-plan", patched)

    def test_changed_upstream_refuses_to_guess(self):
        for text in (self.source().replace(compat.SESSION_ANCHOR, "changed"), self.source() + compat.OUTPUT_ANCHOR):
            with self.assertRaises(compat.CompatibilityError):
                compat.patched_source(text, "/helper", "/python")

    def test_prepare_leaves_original_unchanged_and_records_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "original"
            output = Path(tmp) / "copy"
            source.write_text(self.source())
            provenance = compat.prepare(source, output)
            self.assertEqual(source.read_text(), self.source())
            self.assertEqual(provenance["source_sha256"], compat.file_hash(source))
            self.assertEqual(provenance["output_sha256"], compat.file_hash(output))
            self.assertFalse(provenance["security_flags_changed"])
            self.assertTrue(output.stat().st_mode & 0o100)
            self.assertEqual(compat.prepare(source, output), provenance)

    def test_same_path_and_different_copy_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "original"
            output = Path(tmp) / "copy"
            source.write_text(self.source())
            with self.assertRaises(compat.CompatibilityError):
                compat.prepare(source, source)
            output.write_text("existing unrelated content")
            with self.assertRaises(compat.CompatibilityError):
                compat.prepare(source, output)

    def test_source_alias_records_the_exact_canonical_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target, alias, output = root / 'original', root / 'alias', root / 'copy'
            target.write_text(self.source())
            alias.symlink_to(target)
            result = compat.prepare(alias, output)
            self.assertEqual(result['source'], str(target.resolve()))
            self.assertEqual(result['source_sha256'], compat.file_hash(target))
            newer = root / 'newer'
            newer.write_text(self.source() + '# newer\n')
            alias.unlink()
            alias.symlink_to(newer)
            # A repointed alias cannot change this already frozen copy or its source.
            self.assertEqual(result['source_sha256'], compat.file_hash(Path(result['source'])))
            self.assertEqual(result['output_sha256'], compat.file_hash(output))

    def test_sidecar_and_lock_cannot_overlap_source_or_helper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for suffix in ('.provenance.json', '.prepare.lock'):
                source, output = root / ('copy' + suffix), root / 'copy'
                source.write_text(self.source())
                with self.subTest(suffix=suffix), self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, output)
                self.assertEqual(source.read_text(), self.source())
                self.assertFalse(output.exists())
            source = root / 'original'
            source.write_text(self.source())
            output = root / 'hardlink'
            os.link(source, output)
            with self.assertRaises(compat.CompatibilityError):
                compat.prepare(source, output)
            self.assertEqual(source.read_text(), self.source())

    def test_source_change_between_render_and_publish_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / 'original', Path(tmp) / 'copy'
            source.write_text(self.source())
            real_render = compat.add_claude_provider
            def change_source(*args):
                rendered = real_render(*args)
                source.write_text(self.source() + '# newer source\n')
                return rendered
            with mock.patch.object(compat, 'add_claude_provider', side_effect=change_source):
                with self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + '.provenance.json').exists())

    def test_source_change_after_copy_never_publishes_wrong_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / 'original', Path(tmp) / 'copy'
            source.write_text(self.source())
            real_atomic = compat.atomic_text
            def change_source(path, text, mode):
                real_atomic(path, text, mode)
                source.write_text(self.source() + '# newer source\n')
            with mock.patch.object(compat, 'atomic_text', side_effect=change_source):
                with self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, output)
            self.assertTrue(output.exists())
            self.assertFalse(output.with_name(output.name + '.provenance.json').exists())

    def test_racing_destination_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'copy'
            real_link = compat.os.link
            def competing_link(source, destination):
                target.write_text('other writer')
                return real_link(source, destination)
            with mock.patch.object(compat.os, 'link', side_effect=competing_link):
                with self.assertRaises(FileExistsError):
                    compat.atomic_text(target, 'our copy', 0o700)
            self.assertEqual(target.read_text(), 'other writer')

    def test_destination_created_after_precheck_cannot_claim_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / 'original', Path(tmp) / 'copy'
            source.write_text(self.source())
            real_snapshot = compat.input_snapshot
            helper_reads = 0
            def late_writer(path):
                nonlocal helper_reads
                result = real_snapshot(path)
                if path == Path(compat.__file__).resolve():
                    helper_reads += 1
                    if helper_reads == 2:
                        output.write_text('other writer after precheck')
                return result
            with mock.patch.object(compat, 'input_snapshot', side_effect=late_writer):
                with self.assertRaises(compat.CompatibilityError):
                    compat.prepare(source, output)
            self.assertEqual(output.read_text(), 'other writer after precheck')
            self.assertFalse(output.with_name(output.name + '.provenance.json').exists())

    def test_concurrent_prepare_preserves_one_matching_pair(self):
        from concurrent.futures import ThreadPoolExecutor
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / 'original', Path(tmp) / 'copy'
            source.write_text(self.source())
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: compat.prepare(source, output), range(2)))
            self.assertEqual(results[0], results[1])
            self.assertEqual(json.loads(output.with_name(output.name + '.provenance.json').read_text()), results[0])
            self.assertEqual(compat.file_hash(output), results[0]['output_sha256'])

    def test_directory_sync_failure_does_not_claim_prepared_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / 'original', Path(tmp) / 'copy'
            source.write_text(self.source())
            real_fsync = os.fsync

            def fail_directory(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError('simulated directory sync failure')
                real_fsync(fd)

            with mock.patch.object(compat.os, 'fsync', side_effect=fail_directory):
                with self.assertRaises(OSError):
                    compat.prepare(source, output)
            self.assertFalse(output.with_name(output.name + '.provenance.json').exists())
            self.assertEqual(source.read_text(), self.source())


if __name__ == "__main__":
    unittest.main()
