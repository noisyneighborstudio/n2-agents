#!/usr/bin/env python3
"""Parent-process death must leave recoverable account-bound planner work."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PlannerRecoveryTests(unittest.TestCase):
    def exercise(self, marker_only, live_pause=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'profiles/Test/codex'; home.mkdir(parents=True)
            (home / 'auth.json').write_text(json.dumps({'tokens': {'access_token': 'synthetic', 'account_id': 'workspace'}}))
            other = root / 'profiles/Other/codex'; other.mkdir(parents=True)
            (other / 'auth.json').write_bytes((home / 'auth.json').read_bytes())
            binary = root / 'codex'; binary.write_bytes((ROOT / 'tests/fake-bound-codex.py').read_bytes()); binary.chmod(0o700)
            repo = root / 'repo'; repo.mkdir()
            git = ['git', '-c', 'user.name=dougbot-agent', '-c', 'user.email=269356667+dougbot-agent@users.noreply.github.com']
            subprocess.run(git + ['init', '-q'], cwd=repo, check=True)
            (repo / 'README').write_text('Synthetic planner fixture\n')
            subprocess.run(git + ['add', 'README'], cwd=repo, check=True)
            subprocess.run(git + ['commit', '-qm', 'Create planner fixture'], cwd=repo, check=True)
            started = root / 'started'
            env = dict(os.environ, HOME=str(root), N2_AGENTS_ROOT=str(root / 'profiles'), N2_LOOP_HOME=str(root / 'loops'),
                       PATH=str(root) + ':/usr/bin:/bin:/usr/sbin:/sbin', N2_BOUND_FIXTURE='slow',
                       N2_BOUND_TRACE=str(root / 'trace'), N2_BOUND_STARTED=str(started))
            for name in ('N2_CODEX_USAGE_URL', 'OPENAI_BASE_URL', 'CODEX_HOME'):
                env.pop(name, None)
            process = subprocess.Popen([str(ROOT / 'agents'), 'loop', 'plan', 'Synthetic task', '--budget', '1h', '--cwd', str(repo)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            group = None
            try:
                deadline = time.monotonic() + 20
                while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(started.exists(), 'planner did not start the bound fixture')
                server = int(started.read_text())
                states = list((root / 'loops').glob('*/state.json')); self.assertEqual(len(states), 1)
                state = json.loads(states[0].read_text()); turn = state['turns'][-1]
                group = turn['pgid']
                self.assertEqual(os.getpgid(server), group)
                self.assertNotEqual(group, process.pid)
                if not live_pause:
                    process.kill(); process.wait(timeout=5)
                if marker_only:
                    state['turns'][-1].pop('pgid')
                    states[0].write_text(json.dumps(state))
                paused = subprocess.run([str(ROOT / 'agents'), 'loop', 'pause', state['id']], capture_output=True, text=True, env=env, timeout=20)
                self.assertEqual(paused.returncode, 0, paused.stderr)
                recovered = json.loads(states[0].read_text())
                self.assertEqual(recovered['status'], 'DRAFT', 'an interrupted draft must not become resumable unapproved work')
                self.assertEqual(recovered['turns'][-1]['outcome'], 'aborted' if live_pause else 'interrupted')
                if live_pause:
                    process.wait(timeout=5)
                    calls = [json.loads(line) for line in (root / 'trace').read_text().splitlines()]
                    self.assertEqual(sum(call['method'] == 'turn/start' for call in calls), 1, 'pausing must not launch another available profile')
                self.assertIsNotNone(recovered['turns'][-1].get('endedAt'))
                status = subprocess.run(['/bin/ps', '-p', str(server), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'))
                self.assertFalse(list(states[0].parent.glob('turns/*.codex-home')))
            finally:
                if process.poll() is None: process.kill(); process.wait()
                if group is not None:
                    try: os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError: pass
                process.stdout.close(); process.stderr.close()

    def test_planner_group_is_persisted_and_recoverable_after_parent_death(self):
        self.exercise(False)

    def test_live_planner_pause_does_not_fail_over_to_second_profile(self):
        self.exercise(False, live_pause=True)

    def test_marker_recovers_group_before_state_update(self):
        self.exercise(True)

if __name__ == '__main__':
    unittest.main()
