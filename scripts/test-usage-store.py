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

    def test_token_summary_deduplicates_tasks_and_keeps_unknown_accounts_separate(self):
        one = {'status': 'ok', 'identity': {'status': 'unknown'}, 'attribution': {'task': 'one', 'totalTokens': 60}}
        self.a.append('codex', 'Default', 'execution-succeeded', one, time.time() - 10)
        self.a.append('codex', 'Default', 'execution-succeeded', one)
        self.b.append('codex', 'Default', 'execution-failed', {'status': 'execution-failed', 'attribution': {'task': 'two', 'totalTokens': None}})
        self.b.import_events(self.a.events(own=True), 'peer-a')
        groups = self.b.token_summary()['groups']
        self.assertEqual(len(groups), 2, 'matching profile names do not establish one account')
        self.assertEqual(sum(g['reportedTotalTokens'] for g in groups), 60)
        self.assertEqual(sum(g['unknownTokenTasks'] for g in groups), 1)
        self.assertEqual(sum(g['tasks'] for g in groups), 2)

    def test_mixed_model_summary_splits_buckets_without_adding_aggregate_again(self):
        self.a.append('claude', 'Default', 'execution-succeeded', {
            'status': 'ok', 'usageScope': 'invocation-tree',
            'attribution': {'task': 'one', 'totalTokens': 30},
            'modelUsage': {'parent': {'totalTokens': 10}, 'child': {'totalTokens': 20}}})
        summary = self.a.token_summary()
        self.assertEqual(summary['uniqueTasks'], 1)
        self.assertEqual({g['model']: g['reportedTotalTokens'] for g in summary['groups']}, {'parent': 10, 'child': 20})

    def test_rejection_survives_polls_retention_and_exchange(self):
        at = time.time() - 40 * 86400
        rejected = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, at)
        self.assertEqual(self.a.events(), [], 'diagnostic retention still applies')
        self.a.append('codex', 'Default', 'measurement', {'status': 'ok'})
        healthy = {'status': 'ok', 'identity': {'status': 'unknown'}, 'restrictions': []}
        self.assertEqual(self.a.effective('codex', 'Default', healthy)['status'], 'restricted')
        self.assertEqual(healthy['status'], 'ok', 'provider evidence remains unmodified')
        self.b.import_events(self.a.events(own=True), 'peer-a')
        self.assertEqual(self.b.active_rejections()[0]['id'], rejected['id'])
        self.assertEqual(self.b.effective('codex', 'Default', healthy)['status'], 'ok', 'same name is not account identity')

    def test_verified_account_rejection_crosses_profile_names(self):
        identity = {'status': 'verified', 'accountHash': 'a' * 64}
        self.a.append('codex', 'Work', 'quota-rejected', {'status': 'restricted', 'identity': identity})
        self.b.import_events(self.a.events(own=True), 'peer-a')
        self.assertEqual(self.b.effective('codex', 'Default', {'status': 'ok', 'identity': identity})['status'], 'restricted')
        different = {'status': 'verified', 'accountHash': 'b' * 64}
        self.assertEqual(self.b.effective('codex', 'Work', {'status': 'ok', 'identity': different})['status'], 'ok')
        self.assertEqual(self.a.effective('codex', 'Work', {'status': 'ok', 'identity': different})['status'], 'ok')
        self.assertEqual(self.b.effective('claude', 'Default', {'status': 'ok', 'identity': identity})['status'], 'ok')

    def test_matching_recovery_is_durable_and_replay_cannot_resurrect(self):
        at = time.time() - 40 * 86400
        rejection = self.a.append('claude', 'Default', 'quota-rejected',
                                  {'status': 'restricted', 'requestedModel': 'opus'}, at)
        self.a.append('claude', 'Default', 'execution-succeeded',
                      {'status': 'ok', 'requestedModel': 'sonnet', 'startedAt': at + 0.5}, at + 1)
        self.assertEqual(len(self.a.active_rejections()), 1, 'another model is not recovery')
        self.a.append('claude', 'Default', 'execution-succeeded',
                      {'status': 'ok', 'requestedModel': 'opus', 'model': 'resolved-opus-version', 'startedAt': at + 1.5}, at + 2)
        self.assertEqual(self.a.active_rejections(), [])
        self.b.import_events(self.a.events(own=True), 'peer-a')
        self.b.import_events([rejection], 'peer-a')
        self.assertEqual(self.b.active_rejections(), [], 'old replay cannot defeat recovery tombstone')
        self.assertEqual(self.b.events(own=True), [], 'foreign recovery cannot be relabeled')

    def test_enrollment_does_not_forget_local_rejection(self):
        root = Path(self.temp.name) / 'enrolling'
        local = u.Journal(root)
        local.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'})
        local.db.close()
        enrolled = u.Journal(root, 'new-fleet-id')
        self.addCleanup(enrolled.db.close)
        self.assertEqual(enrolled.effective('codex', 'Default', {'status': 'ok'})['status'], 'restricted')
        enrolled.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': time.time()})
        self.assertEqual(enrolled.active_rejections(), [])

    def test_preexisting_invocation_cannot_clear_rejection_in_either_arrival_order(self):
        now = time.time()
        rejection = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 5)
        success = self.a.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': now - 10}, now)
        self.assertEqual(len(self.a.active_rejections()), 1)
        self.b.import_events([success, rejection], 'peer-a')
        self.assertEqual(len(self.b.active_rejections()), 1)
        later = self.a.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': now - 1}, now + 0.1)
        self.b.import_events([later], 'peer-a')
        self.assertEqual(self.b.active_rejections(), [])

    def test_independent_rejections_survive_newer_short_reset_in_any_order(self):
        now = time.time()
        unknown = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 10)
        known = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted', 'resetKnown': True, 'recheckAt': now + 10}, now - 5)
        self.assertEqual([e['id'] for e in self.a.active_rejections(now + 11)], [unknown['id']])
        self.b.import_events([known, unknown], 'peer-a')
        self.assertEqual([e['id'] for e in self.b.active_rejections(now + 11)], [unknown['id']])
        effective = self.a.effective('codex', 'Default', {'status': 'ok'})
        self.assertIsNone(effective['restrictions'][0]['resetsAt'])

    def test_only_explicit_reset_expires_rejection(self):
        now = time.time()
        self.a.append('codex', 'Known', 'quota-rejected', {'status': 'restricted', 'resetKnown': True, 'recheckAt': now + 10})
        self.a.append('codex', 'Unknown', 'quota-rejected', {'status': 'restricted', 'resetKnown': False, 'recheckAt': now + 10})
        self.assertEqual(len(self.a.active_rejections(now + 5)), 2)
        self.assertEqual([e['profile'] for e in self.a.active_rejections(now + 11)], ['Unknown'])

    def test_exchange_prioritizes_rejection_over_measurement_volume(self):
        event = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, time.time() - 10000)
        for i in range(1001):
            self.a.append('codex', 'Default', 'measurement', {'status': 'ok'}, time.time() - i)
        exported = self.a.events(own=True)
        self.assertEqual(len(exported), 1000)
        self.assertEqual(exported[0]['id'], event['id'])
        self.b.import_events(exported, 'peer-a')
        self.assertEqual(len(self.b.active_rejections()), 1)

    def test_symlink_database_refused(self):
        root = Path(self.temp.name) / 'linked'
        root.mkdir()
        (root / '.usage').symlink_to(Path(self.temp.name) / 'a' / '.usage')
        with self.assertRaises(ValueError): u.Journal(root)

if __name__ == '__main__': unittest.main()
