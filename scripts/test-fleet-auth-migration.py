#!/usr/bin/env python3
"""Migration inventory and barriers with synthetic profiles and credentials."""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
fixture=load('migration_fixture',ROOT/'scripts/test-fleet-auth-manage.py')
migration=load('migration',ROOT/'fleet-auth-migration.py')

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.ManageTests('test_register_status_and_explicit_revision')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.root=self.fixture.root;self.slot=self.fixture.slot
    def test_inventory_preserves_credentials_and_reports_unobserved_peers(self):
        secret=b'{"access_token":"synthetic-migration-secret"}'
        (self.slot/'auth.json').write_bytes(secret)
        result=self.fixture.command('migration-status')
        self.assertEqual(result['status'],'inventory-only')
        self.assertFalse(result['inventoryComplete'])
        self.assertEqual(result['keychain'],'not-inspected')
        self.assertEqual(result['peers'][0]['credentialCopies'],'unobserved')
        self.assertIn({'name':'auth.json','state':'file'},result['credentialFiles'])
        self.assertNotIn('synthetic-migration-secret',json.dumps(result))
        self.assertEqual((self.slot/'auth.json').read_bytes(),secret)
        self.assertFalse((self.slot/migration.MARKER).exists())
    def test_pending_is_durable_idempotent_and_blocks_consumers_and_writers(self):
        secret=b'preserved-legacy-login';(self.slot/'auth.json').write_bytes(secret)
        first=self.fixture.command('migration-begin')
        self.assertEqual(first['status'],'migration-pending')
        self.assertEqual(self.fixture.command('migration-begin')['migration'],first['migration'])
        self.assertEqual(self.fixture.command('status')['status'],'migration-pending')
        binding=migration.manage.binding
        self.assertTrue(binding.has_intent(self.root,'Work',self.slot))
        with self.assertRaisesRegex(ValueError,'migration pending'):binding.read(self.slot,self.fixture.profile)
        metadata=migration.manage.metadata.owner_route(self.root,'Work',self.slot)
        self.assertEqual(metadata['status'],'migration-pending')
        for action in ('run','login'):
            result=subprocess.run([str(ROOT/'agents'),action,'Work','--vendor','codex'],
                env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('migration is pending',result.stderr)
        usage=subprocess.run([sys.executable,str(ROOT/'usage.py'),'codex','Work='+str(self.slot)],
            env=dict(os.environ,N2_USAGE_ROOT=str(self.root)),capture_output=True,text=True,timeout=5)
        self.assertEqual(usage.returncode,0,usage.stderr)
        self.assertIn('migration-pending',usage.stdout)
        routes=migration.manage.metadata.routing_report(self.root,migration.manage.identity(self.root))
        row=next(row for row in routes['profiles'] if row['name']=='Work')
        self.assertIsNone(row['configurationRevision'])
        self.fixture.command('login',success=False)
        self.fixture.register(success=False)
        incoming=self.fixture.fixture.base/'incoming';incoming.write_text('new-secret')
        self.fixture.sync_write('auth|Work|codex|auth.json',incoming,success=False)
        self.fixture.sync_write('mcp|Work|codex|mcp.json',incoming,success=False)
        incoming.write_text('{"access_token":"new-secret"}')
        self.fixture.sync_write('settings|Work|codex|config.json',incoming,success=False)
        self.assertEqual((self.slot/'auth.json').read_bytes(),secret)
        self.assertEqual((self.slot/migration.MARKER).stat().st_mode & 0o777,0o600)
    def test_marker_corruption_never_restores_legacy_route(self):
        (self.slot/migration.MARKER).symlink_to(self.slot/'missing')
        self.assertEqual(self.fixture.command('status')['status'],'migration-invalid')
        self.assertTrue(migration.manage.binding.has_intent(self.root,'Work',self.slot))
        self.fixture.command('migration-begin',success=False)
        self.fixture.command('login',success=False)
    def test_retained_conflict_bytes_are_reported_without_reading_them(self):
        address='auth|Work|codex|auth.json'
        directory=self.root/'fleet/sync/conflicts'/hashlib.sha256(address.encode()).hexdigest()[:12]
        directory.mkdir(parents=True)
        (directory/'meta').write_text('addr='+address+'\npeer=unobserved\n')
        (directory/'local').write_text('private-old-grant')
        (directory/'remote').symlink_to('/does-not-exist')
        result=self.fixture.command('migration-status')
        self.assertEqual(result['retainedSyncCopies'],[{'category':'auth','local':'file','remote':'symlink','credentialContent':'not-inspected'}])
        self.assertNotIn('private-old-grant',json.dumps(result))
        (directory/'meta').write_text('malformed')
        self.assertIn('conflict-metadata-unavailable',self.fixture.command('migration-status')['unknowns'])
    def test_registered_profile_cannot_enter_legacy_migration(self):
        self.fixture.register()
        self.fixture.command('migration-begin',success=False)
        self.assertEqual(self.fixture.command('status')['status'],'active')

if __name__=='__main__':unittest.main()
