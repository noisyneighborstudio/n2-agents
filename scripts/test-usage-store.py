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

    def test_paginated_snapshot_is_complete_immutable_and_atomically_published(self):
        old = time.time() - 40 * 86400
        for i in range(1005):
            self.a.append('codex', 'P' + str(i), 'quota-rejected', {'status': 'restricted'}, old + i)
        with self.assertRaises(ValueError):
            self.a.events(own=True)
        first = self.a.export_page('peer-b')
        self.assertEqual(len(first['events']), 1000)
        self.assertEqual(first['total'], 1005)
        cursor = self.b.import_page(first, 'peer-a')
        self.assertEqual(self.b.active_rejections(), [], 'partial snapshot cannot affect scheduling')
        self.a.append('codex', 'New', 'quota-rejected', {'status': 'restricted'})
        last = self.a.export_page('peer-b', cursor)
        self.assertEqual(len(last['events']), 5)
        self.assertIsNone(self.b.import_page(last, 'peer-a', cursor))
        self.assertEqual(len(self.b.active_rejections()), 1005)
        self.assertNotIn('New', {event['profile'] for event in self.b.active_rejections()})
        self.assertEqual(self.a.export_page('peer-b')['total'], 1006)
        self.assertEqual(self.b.export_page('peer-a')['total'], 0, 'no relabeling remote evidence')

    def test_paginated_recovery_never_publishes_without_later_rejection(self):
        now = time.time()
        old = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 20)
        self.b.import_events([old], 'peer-a')
        success = self.a.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': now - 10}, now - 5)
        rejection = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now)
        token = 'a' * 32
        first = {'schemaVersion': 1, 'snapshot': token, 'offset': 0, 'total': 2,
                 'nextCursor': token + ':1', 'events': [success]}
        last = dict(first, offset=1, nextCursor=None, events=[rejection])
        with self.assertRaises(ValueError): self.b.import_page(last, 'peer-a', token + ':1')
        self.b.import_page(first, 'peer-a')
        with self.assertRaises(ValueError): self.b.import_page(first, 'peer-a', token + ':1')
        with self.assertRaises(ValueError): self.b.import_page(first, 'peer-a')
        self.assertEqual(self.b.exchange_cursor('peer-a'), token + ':1')
        self.assertEqual(self.b.active_rejections()[0]['id'], old['id'])
        self.b.import_page(last, 'peer-a', token + ':1')
        self.assertEqual([event['id'] for event in self.b.active_rejections()], [rejection['id']])

    def test_snapshot_cursor_recipient_bounds_and_page_spoof(self):
        self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'})
        fingerprint = 'SHA256:2xSk+qxDpnRMReWRitqoXtc2MqHt7WRSAP1EY/k0SQs'
        self.assertEqual(self.a.export_page(fingerprint)['total'], 1)
        page = self.a.export_page('peer-b')
        token = page['snapshot']
        for cursor in ['bad', token + ':2']:
            with self.assertRaises(ValueError): self.a.export_page('peer-b', cursor)
        with self.assertRaises(ValueError): self.a.export_page('impostor', token + ':0')
        with self.assertRaises(ValueError): self.b.import_page(page, 'impostor')
        with self.assertRaises(ValueError): self.b.import_page(dict(page, total=2), 'peer-a')
        with self.assertRaises(ValueError): self.b.import_page(dict(page, offset=True), 'peer-a')
        self.assertEqual(self.b.active_rejections(), [])

    def test_pages_respect_encoded_byte_limit(self):
        from unittest.mock import patch
        for i in range(40):
            self.a.append('codex', 'P' + str(i), 'quota-rejected', {'status': 'restricted', 'source': 'é' * 200})
        with patch.object(u, 'MAX_BYTES', 4096):
            cursor, count, pages = '', 0, 0
            while True:
                page = self.a.export_page('peer-b', cursor)
                self.assertLessEqual(len((u.canonical(page) + '\n').encode()), 4096)
                count += len(page['events'])
                pages += 1
                cursor = self.b.import_page(page, 'peer-a', cursor)
                if cursor is None: break
            self.assertEqual(count, 40)
            self.assertGreater(pages, 1)
        self.assertEqual(len(self.b.active_rejections()), 40)

    def test_evicted_snapshot_discards_only_matching_staging(self):
        from unittest.mock import patch
        self.a.append('codex', 'One', 'quota-rejected', {'status': 'restricted'})
        self.a.append('codex', 'Two', 'quota-rejected', {'status': 'restricted'})
        with patch.object(u, 'MAX_BATCH', 1):
            first = self.a.export_page('peer-b')
            cursor = self.b.import_page(first, 'peer-a')
            for _ in range(4): self.a.export_page('peer-b')
            with self.assertRaises(u.SnapshotUnavailable): self.a.export_page('peer-b', cursor)
            unavailable = {'schemaVersion': 1, 'error': 'snapshot-unavailable', 'snapshot': first['snapshot']}
            with self.assertRaises(ValueError): self.b.import_page(unavailable, 'peer-a', 'f' * 32 + ':1')
            self.b.import_page(unavailable, 'peer-a', cursor)
            self.assertEqual(self.b.exchange_cursor('peer-a'), '')
            replacement = self.a.export_page('peer-b')
            next_cursor = self.b.import_page(replacement, 'peer-a')
            self.b.import_page(unavailable, 'peer-a', cursor)
            self.assertEqual(self.b.exchange_cursor('peer-a'), next_cursor, 'late stale response cannot discard replacement')
            last = self.a.export_page('peer-b', next_cursor)
            self.b.import_page(last, 'peer-a', next_cursor)
            self.assertEqual(len(self.b.active_rejections()), 2)

    def test_import_locks_before_receipt_validation(self):
        import sqlite3
        from types import SimpleNamespace
        from unittest.mock import patch
        now = time.time()
        old = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 30)
        newer = self.a.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 1)
        success = self.a.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': now - 10}, now)
        self.b.import_events([old], 'peer-a')
        token = 'a' * 32
        first = {'schemaVersion': 1, 'snapshot': token, 'offset': 0, 'total': 2,
                 'nextCursor': token + ':1', 'events': [newer]}
        last = dict(first, offset=1, nextCursor=None, events=[success])
        other_first = dict(first, snapshot='b' * 32, nextCursor='b' * 32 + ':1', events=[old])
        self.b.import_page(first, 'peer-a')
        other = u.Journal(Path(self.temp.name) / 'b', 'peer-b')
        self.addCleanup(other.db.close)
        other.db.execute('PRAGMA busy_timeout=50')
        raw = self.b.db
        attempts = []
        class Interleaving:
            def __enter__(self):
                raw.__enter__()
                return self
            def __exit__(self, *args): return raw.__exit__(*args)
            def execute(self, sql, args=()):
                result = raw.execute(sql, args)
                if sql.startswith('SELECT token, next_position, total'):
                    rows = result.fetchall()
                    try:
                        other.import_page(other_first, 'peer-a')
                    except sqlite3.OperationalError as error:
                        attempts.append(str(error))
                    return SimpleNamespace(fetchone=lambda: rows[0] if rows else None)
                return result
        with patch.object(self.b, 'db', Interleaving()):
            self.b.import_page(last, 'peer-a', token + ':1')
        self.assertEqual(len(attempts), 1, 'concurrent replacement must be locked before receipt validation')
        self.assertIn('locked', attempts[0])
        self.assertEqual([event['id'] for event in self.b.active_rejections()], [newer['id']])

    def test_enrollment_transfers_immutable_events_and_recovery(self):
        root = Path(self.temp.name) / 'before-fleet'
        local = u.Journal(root)
        original_origin = local.origin
        now = time.time()
        rejected = local.append('codex', 'Default', 'quota-rejected', {'status': 'restricted'}, now - 40 * 86400)
        task = local.append('codex', 'Tokens', 'execution-succeeded',
                            {'status': 'ok', 'attribution': {'task': 'one', 'totalTokens': 60}}, now - 10)
        local.db.close()
        enrolled = u.Journal(root, 'new-peer')
        self.addCleanup(enrolled.db.close)
        page = enrolled.export_page('peer-b')
        self.assertEqual(page['aliases'], [original_origin])
        self.assertIn(rejected, page['events'])
        self.assertIn(task, page['events'])
        self.b.import_page(page, 'new-peer')
        self.assertEqual(self.b.active_rejections(), [rejected], 'old ID, origin and time stay unchanged')
        summary = self.b.token_summary()
        self.assertEqual(summary['uniqueTasks'], 1)
        self.assertEqual(summary['groups'][0]['reportedTotalTokens'], 60)
        self.assertEqual(summary['groups'][0]['bindings'][0]['origin'], 'new-peer')
        self.assertEqual(summary['groups'][0]['bindings'][0]['observationOrigin'], original_origin)
        self.assertEqual(self.b.export_page('new-peer')['total'], 0, 'foreign legacy origins cannot be relabeled')
        enrolled.append('codex', 'Default', 'execution-succeeded', {'status': 'ok', 'startedAt': time.time()})
        self.b.import_page(enrolled.export_page('peer-b'), 'new-peer')
        self.assertEqual(self.b.active_rejections(), [])
        self.b.import_page(page, 'new-peer')
        self.assertEqual(self.b.active_rejections(), [], 'replaying pre-enrollment state cannot undo recovery')
        self.assertEqual(sum(g['reportedTotalTokens'] for g in self.b.token_summary()['groups']), 60)

    def test_local_alias_claims_are_scoped_and_cannot_change_owner(self):
        page = self.a.export_page('peer-b')
        self.b.import_page(page, 'peer-a')
        alias = page['aliases'][0]
        for aliases in [['peer-c'], [self.b.local_origin], [alias, alias]]:
            bad = dict(page, snapshot='a' * 32, aliases=aliases)
            with self.assertRaises(ValueError): self.b.import_page(bad, 'peer-c')
        with self.assertRaises(ValueError): self.b.import_page(page, 'peer-c')
        self.assertEqual(self.b.owner_origin(alias), 'peer-a')

    def test_alias_registration_waits_for_complete_consistent_snapshot(self):
        from unittest.mock import patch
        self.a.append('codex', 'One', 'quota-rejected', {'status': 'restricted'})
        self.a.append('codex', 'Two', 'quota-rejected', {'status': 'restricted'})
        with patch.object(u, 'MAX_BATCH', 1):
            first = self.a.export_page('peer-b')
            alias = first['aliases'][0]
            cursor = self.b.import_page(first, 'peer-a')
            self.assertEqual(self.b.owner_origin(alias), alias)
            last = self.a.export_page('peer-b', cursor)
            with self.assertRaises(ValueError): self.b.import_page(dict(last, aliases=[]), 'peer-a', cursor)
            self.assertEqual(self.b.owner_origin(alias), alias)
            self.b.import_page(last, 'peer-a', cursor)
            self.assertEqual(self.b.owner_origin(alias), 'peer-a')

    def test_symlink_database_refused(self):
        root = Path(self.temp.name) / 'linked'
        root.mkdir()
        (root / '.usage').symlink_to(Path(self.temp.name) / 'a' / '.usage')
        with self.assertRaises(ValueError): u.Journal(root)

if __name__ == '__main__': unittest.main()
