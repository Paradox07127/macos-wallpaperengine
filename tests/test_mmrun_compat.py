"""Transport-only tests; no model process or installed mmrun is invoked."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("mmrun_compat", Path(__file__).resolve().parents[1] / "scripts/multica/mmrun_compat.py")
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


REPORT = {"verdict": "request_changes", "summary": "Still gathering evidence.", "findings": [], "not_expanded": 0}


class NormalizationTests(unittest.TestCase):
    def test_camel_case_mixed_prefix_preserves_nonapproval(self):
        text = "warning: diagnostic prefix\n" + json.dumps({"text": "", "structuredOutput": REPORT, "stopReason": "end_turn", "thought": "not public", "usage": {"input_tokens": 1}})
        result = compat.normalize(text)
        self.assertEqual(result["structured_output"], REPORT)
        self.assertEqual(result["usage"], {"input_tokens": 1})
        self.assertNotIn("thought", result)
        self.assertNotIn("text", result)

    def test_pretty_snake_case_envelope(self):
        result = compat.normalize(json.dumps({"structured_output": REPORT}, indent=2))
        self.assertEqual(result["structured_output"]["verdict"], "request_changes")

    def test_json_text_legacy_envelope(self):
        result = compat.normalize(json.dumps({"text": json.dumps(REPORT)}))
        self.assertEqual(result["structured_output"], REPORT)

    def test_conflicting_aliases_fail(self):
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize(json.dumps({"structuredOutput": REPORT, "structured_output": {"verdict": "approve"}}))

    def test_duplicate_report_key_fails(self):
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize('{"structuredOutput":{"verdict":"approve","verdict":"request_changes"}}')

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
                compat.normalize(json.dumps(data))

    def test_multiple_result_envelopes_are_ambiguous(self):
        text = json.dumps({"structuredOutput": REPORT}) + "\n" + json.dumps({"structuredOutput": dict(REPORT, verdict="approve")})
        with self.assertRaises(compat.CompatibilityError):
            compat.normalize(text)

    def test_truncated_error_wrapper_cannot_salvage_inner_approval(self):
        inner = json.dumps({'structuredOutput': dict(REPORT, verdict='approve')})
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
        return '#!/usr/bin/env bash\n# --tools read_file,grep,list_dir\n# sandbox-exec original guard\n' + compat.SESSION_ANCHOR + '\n      env "${GROK_ENV[@]}" "$SELF" __fence "$w" "$HOME/.grok" "$rd/prompt.md" "$ro" \\\n' + compat.OUTPUT_ANCHOR + '\n'

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


if __name__ == "__main__":
    unittest.main()
