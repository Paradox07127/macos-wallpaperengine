"""Supervision tests; no real subprocesses, daemons or network calls."""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts' / 'multica'
spec = importlib.util.spec_from_file_location('service_under_test', SCRIPTS / 'service.py')
service = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(SCRIPTS))
try:
    spec.loader.exec_module(service)
finally:
    sys.path.pop(0)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.cfg = {'enabled': True, 'state_path': str(Path(temp.name) / 'state.sqlite'),
                    'multica_path': '/example/multica', 'multica_profile': 'profile',
                    'workspace_id': 'workspace', 'workspaces_root': temp.name,
                    'python_path': '/example/python'}
        self.calls = []

    def invoke(self, status='{"status":"running"}', fail=None, exit_code=0):
        def run(command, **kwargs):
            self.calls.append(command)
            self.assertFalse(kwargs['shell'])
            stage = ('status' if 'status' in command else 'start' if 'start' in command
                     else 'collect' if 'collect-all' in command else 'poll')
            if stage == fail:
                if exit_code:
                    return subprocess.CompletedProcess(command, exit_code, '')
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            return subprocess.CompletedProcess(command, 0, status if stage == 'status' else '')
        with patch.object(service.github_bridge, 'load_config', return_value=self.cfg), \
             patch.object(service.subprocess, 'run', side_effect=run), \
             patch('sys.stdout', new_callable=io.StringIO), patch('sys.stderr', new_callable=io.StringIO):
            return service.main(['--config', '/example/config.json'])

    def test_running_json_does_not_restart_daemon(self):
        self.assertEqual(self.invoke(), 0)
        self.assertFalse(any('start' in call for call in self.calls))
        self.assertEqual(self.calls[-1][-1], 'collect-all')

    def test_actual_stopped_json_starts_daemon_before_poll(self):
        self.assertEqual(self.invoke(status='{"status":"stopped"}'), 0)
        self.assertIn('start', self.calls[1])
        self.assertIn('poll', self.calls[2])
        self.assertEqual(self.calls[-1][-1], 'collect-all')

    def test_poll_failure_or_timeout_still_collects(self):
        for code in (0, 1):
            with self.subTest(exit_code=code):
                self.calls = []
                self.assertEqual(self.invoke(fail='poll', exit_code=code), 1)
                self.assertEqual(self.calls[-1][-1], 'collect-all')

    def test_status_and_start_timeouts_still_collect(self):
        for stage in ('status', 'start'):
            with self.subTest(stage=stage):
                self.calls = []
                self.assertEqual(self.invoke(status='{"status":"stopped"}', fail=stage), 1)
                self.assertEqual(self.calls[-1][-1], 'collect-all')

    def test_nonobject_or_invalid_status_does_not_crash_or_spawn_daemon(self):
        for payload in ('[]', 'null', 'bad JSON'):
            with self.subTest(payload=payload):
                self.calls = []
                self.assertEqual(self.invoke(status=payload), 1)
                self.assertFalse(any('start' in call for call in self.calls))
                self.assertEqual(self.calls[-1][-1], 'collect-all')

    def test_enabled_requires_literal_boolean(self):
        for enabled, expected in ((False, 0), ('false', 1), (1, 1), (None, 1)):
            with self.subTest(enabled=enabled):
                self.calls = []
                self.cfg['enabled'] = enabled
                self.assertEqual(self.invoke(), expected)
                self.assertEqual(self.calls, [])

    def test_collection_timeout_is_reported_as_tick_failure(self):
        self.assertEqual(self.invoke(fail='collect'), 1)


if __name__ == '__main__':
    unittest.main()
