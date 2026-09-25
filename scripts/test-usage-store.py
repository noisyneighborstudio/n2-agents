#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('usage_store', Path(__file__).resolve().parents[1] / 'usage-store.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)

class JournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.a = u.Journal(Path(self.temp.name) / 'a', 'peer-a')
        self.b = u.Journal(Path(self.temp.name) / 'b', 'peer-b')
        self.addCleanup(self.a.db.close)
        self.addCleanup(self.b.db.close)

    def test_signed_source_replay_and_age(self):
        at = time.time() - 600
        event = self.a.append('codex', 'Default', 'measurement', {'status': 'ok'}, at)
        self.b.import_events([event], 'peer-a')
        self.b.import_events([event], 'peer-a')
        self.assertEqual(len(self.b.events()), 1)
        self.assertEqual(self.b.events()[0]['at'], at)
        self.assertEqual(self.b.events(own=True), [], 'remote observations are not relabeled as local')

    def test_spoof_and_partial_batch_rejected(self):
        event = self.a.append('codex', 'Default', 'measurement', {'status': 'ok'})
        with self.assertRaises(ValueError): self.b.import_events([event], 'impostor')
        bad = dict(event, profile='Changed')
        with self.assertRaises(ValueError): self.b.import_events([event, bad], 'peer-a')
        self.assertEqual(self.b.events(), [])

    def test_same_name_does_not_merge_accounts(self):
        self.a.append('codex', 'Default', 'measurement', {'status': 'ok'})
        self.b.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'})
        self.b.import_events(self.a.events(own=True), 'peer-a')
        self.assertEqual(self.b.latest('codex', 'Default')['kind'], 'quota-rejected')
        self.assertEqual(len(self.b.events()), 2)

    def test_future_and_raw_credentials_rejected(self):
        with self.assertRaises(ValueError):
            self.a.append('claude', 'Default', 'measurement', {'status': 'ok'}, time.time() + 600)
        with self.assertRaises(ValueError):
            self.a.append('claude', 'Default', 'measurement', {'accessToken': 'synthetic'})

    def test_nested_credentials_and_invalid_limits_rejected(self):
        for data in ({'identity': {'accessToken': 'synthetic'}},
                     {'credits': {'codex': {'token': 'synthetic'}}},
                     {'windows': [{'scope': 'codex', 'usedPercent': 101}]},
                     {'identity': {'status': 'verified'}},
                     {'display': {'shortUsed': {'accessToken': 'synthetic'}}},
                     {'session': {'transcript': 'synthetic'}},
                     {'credits': {'codex': {'balance': {'refreshToken': 'synthetic'}}}}):
            with self.assertRaises(ValueError):
                self.a.append('codex', 'Default', 'measurement', data)

    def test_export_is_bounded_by_bytes_and_long_profile_is_supported(self):
        profile = 'A' * 150
        windows = [{'scope': 'codex:' + str(i), 'usedPercent': 12,
                    'durationSeconds': 18000, 'resetsAt': 1790411072} for i in range(32)]
        for i in range(1000):
            self.a.append('codex', profile, 'measurement', {'status': 'ok', 'windows': windows}, time.time() - i)
        exported = self.a.events(own=True)
        self.assertLess(len(exported), 1000)
        self.assertLessEqual(len((u.canonical(exported) + '\n').encode()), u.MAX_BYTES)
        self.b.import_events(exported, 'peer-a')
        self.assertEqual(len(self.b.events()), len(exported))

    def test_symlink_database_refused(self):
        root = Path(self.temp.name) / 'linked'
        root.mkdir()
        (root / '.usage').symlink_to(Path(self.temp.name) / 'a' / '.usage')
        with self.assertRaises(ValueError): u.Journal(root)

if __name__ == '__main__': unittest.main()
