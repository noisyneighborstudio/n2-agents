#!/usr/bin/env python3
import copy
import importlib.util
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'profile-metadata.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='n2 routes\t'); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'profiles'; self.profile = self.root / 'Work'; self.profile.mkdir(parents=True)
        m.ensure(self.profile)
        self.home = self.base / 'home'; self.home.mkdir()
        self.bin = self.base / 'bin'; self.bin.mkdir()
        self.sentinel = self.base / 'provider-was-run'
        for vendor in ('codex', 'muse', 'opencode'):
            executable = self.bin / vendor
            executable.write_text('#!/bin/sh\ntouch "$N2_ROUTE_SENTINEL"\nexit 99\n'); executable.chmod(0o700)
        (self.profile / 'codex').mkdir()
        self.environ = patch.dict(os.environ, {'HOME': str(self.home), 'PATH': str(self.bin) + ':/usr/bin:/bin', 'N2_ROUTE_SENTINEL': str(self.sentinel), 'N2_FLEET_QA': ''})
        self.environ.start(); self.addCleanup(self.environ.stop)
        self.machine = subprocess.check_output([str(ROOT / 'agents'), 'fleet', 'init', '--machine', 'fixture'],
                                               env=dict(os.environ, N2_AGENTS_ROOT=str(self.root)), text=True).split()[1]

    def snapshot(self, name='Work', machine=None):
        if machine is None: machine = self.machine
        return next(row for row in m.routing_report(self.root, machine)['profiles'] if row['name'] == name)

    def route(self, row, vendor='codex'):
        return next(route for route in row['routes'] if route['provider'] == vendor)

    def test_stable_revision_and_no_provider_invocation_or_credential_read(self):
        initial = self.snapshot()
        self.assertEqual(initial, self.snapshot())
        self.assertEqual(len(initial['configurationRevision']), 64)
        self.assertEqual(initial['routingStatus'], 'stable')
        route = self.route(initial)
        self.assertEqual(route['status'], 'available')
        self.assertEqual(route['environment'], {'CODEX_HOME': str(self.profile / 'codex')})
        self.assertEqual(route['accountIdentity'], {'status': 'unknown'})
        self.assertFalse(self.sentinel.exists())
        (self.profile / 'codex/auth.json').write_text('synthetic-secret-not-an-account-proof')
        (self.profile / 'codex/config.toml').write_text('model = "changed-provider-setting"')
        self.assertEqual(initial['configurationRevision'], self.snapshot()['configurationRevision'])
        self.assertNotIn('synthetic-secret', str(self.snapshot()))

    def test_owner_binding_changes_revision_and_invalid_binding_prevents_admission(self):
        import uuid
        original = self.snapshot()
        spec = importlib.util.spec_from_file_location('binding', ROOT / 'fleet-auth-binding.py')
        binding = importlib.util.module_from_spec(spec); spec.loader.exec_module(binding)
        record = {'schemaVersion': 1, 'provider': 'codex', 'credentialStore': 'owner-file',
                  'profileId': original['profileId'], 'grantId': str(uuid.uuid4()),
                  'ownershipGeneration': str(uuid.uuid4()), 'accountHash': 'a' * 64,
                  'owner': self.machine}
        slot = self.profile / 'codex'
        revision = binding.publish(slot, record, original['profileId'])
        registered = self.snapshot()
        self.assertNotEqual(original['configurationRevision'], registered['configurationRevision'])
        self.assertEqual(self.route(registered)['ownerBinding']['binding'], record)
        self.assertEqual(self.route(registered)['accountIdentity'], {'status': 'unknown'})
        record['ownershipGeneration'] = str(uuid.uuid4())
        binding.publish(slot, record, original['profileId'], revision)
        self.assertNotEqual(registered['configurationRevision'], self.snapshot()['configurationRevision'])
        import hashlib
        address = 'settings|Work|codex|.n2-owner.json'
        conflict = self.root / 'fleet/sync/conflicts' / hashlib.sha256(address.encode()).hexdigest()[:12]
        conflict.mkdir(parents=True)
        self.assertIsNone(self.snapshot()['configurationRevision'])
        self.assertEqual(self.route(self.snapshot())['ownerBinding']['status'], 'conflicting')
        saved = (slot / '.n2-owner.json').read_bytes()
        (slot / '.n2-owner.json').unlink()
        self.assertIsNone(self.snapshot()['configurationRevision'])
        self.assertEqual(self.route(self.snapshot())['ownerBinding']['status'], 'conflicting')
        stage = conflict.with_name('.resolving-' + conflict.name + '.999999')
        conflict.rename(stage)
        self.assertIsNone(self.snapshot()['configurationRevision'])
        stage.rename(conflict)
        (slot / '.n2-owner.json').write_bytes(saved); (slot / '.n2-owner.json').chmod(0o600)
        conflict.rmdir()
        marker = slot / '.n2-owner.json'
        marker.write_text('{}')
        self.assertIsNone(self.snapshot()['configurationRevision'])
        marker.unlink(); marker.symlink_to(slot / 'missing')
        self.assertIsNone(self.snapshot()['configurationRevision'])
        self.assertFalse(self.sentinel.exists())

    def test_relative_environment_matches_actual_launch(self):
        executable = self.bin / 'codex'
        executable.write_text('#!/bin/sh\nprintf "%s" "$CODEX_HOME"\n')
        previous = os.getcwd()
        try:
            os.chdir(self.base)
            row = next(row for row in m.routing_report(Path('profiles'), self.machine)['profiles'] if row['name'] == 'Work')
            route = self.route(row)
            actual = subprocess.check_output([str(ROOT / 'agents'), 'run', 'Work', '--vendor', 'codex'],
                env=dict(os.environ, N2_AGENTS_ROOT='profiles'), text=True)
            self.assertEqual(route['environment']['CODEX_HOME'], actual)
            self.assertEqual(actual, 'profiles/Work/codex')
            self.assertEqual(route['configDir'], actual)
            self.assertEqual(route['workingDirectory'], os.getcwd())
            self.assertEqual(route['resolvedConfigDir'], str((self.profile / 'codex').resolve()))
        finally:
            os.chdir(previous)

    def test_home_and_executable_retargets_change_revision(self):
        original = self.snapshot()
        (self.profile / 'codex').rmdir()
        target = self.base / 'other-home'; target.mkdir()
        (self.profile / 'codex').symlink_to(target)
        redirected = self.snapshot()
        self.assertEqual(original['profileId'], redirected['profileId'])
        self.assertNotEqual(original['configurationRevision'], redirected['configurationRevision'])
        self.assertEqual(self.route(redirected)['resolvedConfigDir'], str(target.resolve()))
        actual = self.bin / 'actual'; (self.bin / 'codex').rename(actual)
        (self.bin / 'codex').symlink_to(actual)
        self.assertNotEqual(redirected['configurationRevision'], self.snapshot()['configurationRevision'])

    def test_default_fallback_and_xdg_routes_use_authoritative_vendor_table(self):
        default = self.root / 'Default'; default.mkdir(); m.ensure(default)
        (self.home / '.codex').mkdir()
        row = self.snapshot('Default')
        self.assertEqual(self.route(row)['configDir'], str(self.home / '.codex'))
        self.assertEqual(row['scope'], 'machine-local')
        (default / 'codex').mkdir()
        changed = self.snapshot('Default')
        self.assertNotEqual(row['configurationRevision'], changed['configurationRevision'])
        self.assertEqual(self.route(changed)['configDir'], str(default / 'codex'))
        for vendor in ('muse', 'opencode'):
            (self.profile / vendor / vendor).mkdir(parents=True)
        row = self.snapshot()
        for vendor in ('muse', 'opencode'):
            self.assertEqual(self.route(row, vendor)['environment']['XDG_CONFIG_HOME'], str(self.profile / vendor))
        self.assertEqual(self.route(row, 'muse')['environment']['TBH_CREDENTIAL_BACKEND'], 'file')
        self.assertNotIn('TBH_CREDENTIAL_BACKEND', self.route(changed, 'muse')['environment'])

    def test_missing_routes_and_unknown_metadata_cannot_claim_ready_binding(self):
        row = self.snapshot()
        self.assertEqual(self.route(row, 'claude')['status'], 'missing-config')
        (self.profile / 'claude').mkdir()
        self.assertEqual(self.route(self.snapshot(), 'claude')['status'], 'missing-executable')
        self.assertIsNone(self.snapshot(machine='')['configurationRevision'])
        (self.profile / m.MARKER).unlink()
        self.assertIsNone(self.snapshot()['configurationRevision'])

    def test_changes_during_inventory_read_have_no_revision(self):
        first = m.routing_inventory(self.root)
        second = copy.deepcopy(first)
        second[1][('Work', 'codex')]['resolvedConfigDir'] = '/changed'
        with patch.object(m, 'routing_inventory', side_effect=[first, second]):
            row = self.snapshot()
        self.assertEqual(row['routingStatus'], 'changed-during-read')
        self.assertIsNone(row['configurationRevision'])
        before = m.report(self.root, self.machine); after = copy.deepcopy(before)
        after['profiles'][-1]['profileId'] = 'changed'
        with patch.object(m, 'report', side_effect=[before, after]):
            row = self.snapshot()
        self.assertIsNone(row['configurationRevision'])

    def test_changed_machine_identity_or_wrong_root_never_publishes_revision(self):
        before = m.routing_inventory(self.root)
        changed = (before[0], before[1], 'different-machine')
        with patch.object(m, 'routing_inventory', side_effect=[before, changed]):
            self.assertIsNone(self.snapshot()['configurationRevision'])
        wrong = b'n2-profile-routes-v1\0codex\0/wrong-root\0machine\0'
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=wrong)):
            with self.assertRaisesRegex(ValueError, 'another profile root'):
                m.routing_inventory(self.root)

    def test_rename_keeps_profile_identity_but_changes_binding_revision(self):
        original = self.snapshot()
        self.profile.rename(self.root / 'Renamed')
        renamed = self.snapshot('Renamed')
        self.assertEqual(original['profileId'], renamed['profileId'])
        self.assertNotEqual(original['configurationRevision'], renamed['configurationRevision'])

if __name__ == '__main__': unittest.main()
