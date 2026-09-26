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
from unittest.mock import patch

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
    def test_peer_preparation_requires_consent_and_preserves_legacy_bytes(self):
        wire = self.fixture.fixture
        peer_root = wire.base/'client'; peer_slot = peer_root/'Renamed/codex'
        peer_slot.mkdir(parents=True)
        (peer_slot.parent/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        secret = b'synthetic-peer-migration-login'
        for slot in (self.slot, peer_slot): (slot/'auth.json').write_bytes(secret)
        (wire.bin/'ssh').write_text(fixture.fixture.SSH.replace("base/'owner'", "base/'client'"))
        peer = wire.identities['client']; coordinator = wire.identities['owner']
        def remote(action, *args, success=True):
            result = subprocess.run([str(ROOT/'agents'),'fleet','auth',action,'Renamed',*args],
                env=dict(os.environ,N2_AGENTS_ROOT=str(peer_root)),capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            return json.loads(result.stdout) if success else result
        initial = self.fixture.command('migration-begin'); revision = initial['migrationRevision']
        args = ('--peer',peer,'--expected-revision',revision)
        self.fixture.command('migration-prepare',*args,success=False)
        self.assertFalse((peer_slot/migration.MARKER).exists())
        remote('migration-allow','--peer',coordinator)
        prepared = self.fixture.command('migration-prepare',*args)
        self.assertEqual(prepared['status'],'peer-prepared')
        self.assertFalse(prepared['migrationComplete'])
        self.assertEqual(remote('migration-status')['migration'],initial['migration'])
        row = next(row for row in self.fixture.command('migration-status')['peers'] if row['peer']==peer)
        self.assertEqual(row['migrationBarrier'],'prepared')
        self.assertEqual(self.fixture.command('migration-prepare',*args),prepared)
        self.fixture.command('migration-prepare','--peer',peer,'--expected-revision','0'*64,success=False)
        remote('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        for slot in (self.slot, peer_slot): self.assertEqual((slot/'auth.json').read_bytes(),secret)
        run = subprocess.run([str(ROOT/'agents'),'run','Renamed','--vendor','codex'],
            env=dict(os.environ,N2_AGENTS_ROOT=str(peer_root)),capture_output=True,text=True,timeout=5)
        self.assertNotEqual(run.returncode,0);self.assertIn('migration is pending',run.stderr)
        original=(peer_slot/migration.MARKER).read_bytes()
        (peer_slot/migration.MARKER).write_bytes(original+b' ')
        self.fixture.command('migration-prepare',*args,success=False)
        (peer_slot/migration.MARKER).write_bytes(original)
        queued=wire.base/'queued-credential';queued.write_bytes(b'synthetic-queued-login')
        original_root=self.fixture.root
        try:
            self.fixture.root=peer_root
            self.fixture.sync_write('auth|Renamed|codex|auth.json',str(queued),success=False)
        finally:self.fixture.root=original_root
        self.assertEqual((peer_slot/'auth.json').read_bytes(),secret)
        remote('migration-deny','--peer',coordinator)
        self.fixture.command('migration-prepare',*args,success=False)
        self.assertTrue((peer_slot/migration.MARKER).exists())

    def test_lost_reply_keeps_coordinator_pending_without_fabricating_acknowledgement(self):
        wire=self.fixture.fixture;peer_root=wire.base/'client';peer_slot=peer_root/'Work/codex'
        peer_slot.mkdir(parents=True)
        (peer_slot.parent/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        coordinator=wire.identities['owner'];peer=wire.identities['client']
        consent=subprocess.run([str(ROOT/'agents'),'fleet','auth','migration-allow','Work','--peer',coordinator],
            env=dict(os.environ,N2_AGENTS_ROOT=str(peer_root)),capture_output=True,text=True,timeout=5)
        self.assertEqual(consent.returncode,0,consent.stderr)
        # The receiver installs its barrier, but the carrier drops its response.
        ssh=fixture.fixture.SSH.replace("base/'owner'","base/'client'")
        (wire.bin/'ssh').write_text('#!/bin/sh\nexit 7\n')
        initial=self.fixture.command('migration-begin');revision=initial['migrationRevision']
        self.fixture.command('migration-prepare','--peer',peer,'--expected-revision',revision,success=False)
        self.assertFalse((peer_slot/migration.MARKER).exists())
        row=next(row for row in self.fixture.command('migration-status')['peers'] if row['peer']==peer)
        self.assertEqual(row['migrationBarrier'],'unacknowledged')
        (wire.bin/'ssh').write_text(ssh.replace('sys.stdout.buffer.write(result.stdout);sys.exit(result.returncode)','sys.exit(7)'))
        self.fixture.command('migration-prepare','--peer',peer,'--expected-revision',revision,success=False)
        self.assertTrue((peer_slot/migration.MARKER).exists())
        row=next(row for row in self.fixture.command('migration-status')['peers'] if row['peer']==peer)
        self.assertEqual(row['migrationBarrier'],'unacknowledged')
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        (wire.bin/'ssh').write_text(ssh)
        self.assertEqual(self.fixture.command('migration-prepare','--peer',peer,'--expected-revision',revision)['status'],'peer-prepared')

    def test_receiver_refuses_wrong_recipient_conflicting_marker_and_stale_ack(self):
        wire=self.fixture.fixture;peer=wire.identities['client']
        initial=self.fixture.command('migration-begin');revision=initial['migrationRevision']
        request=migration.request(self.root,'Work',self.slot,peer,revision)
        payload=wire.base/'migration-payload';payload.write_bytes(migration.canonical(request))
        with self.assertRaisesRegex(ValueError,'invalid migration request'):
            migration.accept(self.root,'Work',self.slot,wire.identities['owner'],payload)
        reply={'request':dict(request,requestId='00000000-0000-4000-8000-000000000001'),
               'result':{'status':'peer-prepared','peer':peer,'migrationComplete':False}}
        response=wire.base/'migration-response';response.write_bytes(migration.canonical(reply))
        with self.assertRaisesRegex(ValueError,'wrong migration acknowledgement'):
            migration.record(self.root,'Work',self.slot,peer,revision,response,payload)
        peer_root=wire.base/'client';peer_slot=peer_root/'Work/codex';peer_slot.mkdir(parents=True)
        (peer_slot.parent/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        migration.permission(peer_root,self.fixture.profile,wire.identities['owner'],True)
        migration.begin(peer_root,'Work',peer_slot)
        with self.assertRaisesRegex(ValueError,'conflicting migration'):
            migration.accept(peer_root,'Work',peer_slot,wire.identities['owner'],payload)

    def test_migration_consent_cannot_be_redirected_through_a_directory_symlink(self):
        wire=self.fixture.fixture;peer_root=wire.base/'client';peer_slot=peer_root/'Work/codex'
        peer_slot.mkdir(parents=True)
        (peer_slot.parent/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        outside=wire.base/'outside-consent';outside.mkdir(mode=0o700)
        consent=outside/(self.fixture.profile+'.consent.json')
        consent.write_text(json.dumps([wire.identities['owner']]));consent.chmod(0o600)
        (peer_root/'fleet/auth-migrations').symlink_to(outside,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'not private'):
            migration.permission(peer_root,self.fixture.profile,wire.identities['owner'])

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
    def test_explicit_abandon_preserves_credentials_and_can_reconcile_a_retry(self):
        secret=b'untouched-private-login';(self.slot/'auth.json').write_bytes(secret)
        initial=self.fixture.command('migration-begin');revision=initial['migrationRevision']
        self.fixture.command('migration-abandon','--expected-revision',revision,success=False)
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision','0'*64,success=False)
        self.assertEqual(self.fixture.command('status')['status'],'migration-pending')
        result=self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision)
        self.assertEqual(result['status'],'legacy-unmanaged');self.assertFalse(result['migrationComplete'])
        self.assertEqual((self.slot/'auth.json').read_bytes(),secret)
        self.assertFalse((self.slot/migration.MARKER).exists())
        self.assertEqual(self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision),result)
        history=self.root/'fleet/auth-migration-history'/(revision+'.json')
        self.assertNotIn(secret.decode(),history.read_text())
        self.assertEqual(history.stat().st_mode & 0o777,0o600)
        newer=self.fixture.command('migration-begin')
        self.assertNotEqual(newer['migrationRevision'],revision)
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        self.assertEqual(self.fixture.command('migration-status')['migrationRevision'],newer['migrationRevision'])

    def test_abandon_recovers_interruption_before_and_after_barrier_removal(self):
        initial=self.fixture.command('migration-begin');revision=initial['migrationRevision']
        original_sync=migration.manage.binding.owner.sync_directory
        def fail_before_removal(path):
            if Path(path).name=='auth-migration-history':raise OSError('interrupted after history publication')
            return original_sync(path)
        with patch.object(migration.manage.binding.owner,'sync_directory',side_effect=fail_before_removal):
            with self.assertRaises(OSError):migration.abandon(self.root,'Work',self.slot,revision,True)
        self.assertTrue((self.slot/migration.MARKER).exists())
        history=self.root/'fleet/auth-migration-history'/(revision+'.json')
        self.assertEqual(history.stat().st_nlink,1)
        def fail_after_removal(path):
            if Path(path).resolve()==self.slot.resolve():raise OSError('interrupted after barrier removal')
            return original_sync(path)
        with patch.object(migration.manage.binding.owner,'sync_directory',side_effect=fail_after_removal):
            with self.assertRaises(OSError):migration.abandon(self.root,'Work',self.slot,revision,True)
        self.assertFalse((self.slot/migration.MARKER).exists())
        self.assertEqual(self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision)['status'],'legacy-unmanaged')

    def test_abandon_refuses_corrupt_marker_and_new_owner_intent(self):
        initial=self.fixture.command('migration-begin');revision=initial['migrationRevision']
        marker=self.slot/migration.MARKER;raw=marker.read_bytes()
        marker.write_text('{}')
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        self.assertEqual(marker.read_text(),'{}')
        marker.write_bytes(raw)
        (self.slot/'.n2-owner.json').write_text('{}')
        self.fixture.command('migration-abandon','--allow-legacy','--expected-revision',revision,success=False)
        self.assertEqual(marker.read_bytes(),raw)

    def test_registered_profile_cannot_enter_legacy_migration(self):
        self.fixture.register()
        self.fixture.command('migration-begin',success=False)
        self.assertEqual(self.fixture.command('status')['status'],'active')

if __name__=='__main__':unittest.main()
