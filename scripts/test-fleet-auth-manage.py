#!/usr/bin/env python3
"""Exercise registration and consent through the actual CLI with isolated roots."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import signal
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fixture',ROOT/'scripts/test-fleet-auth-server.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)

class ManageTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.ServerTests('test_endpoint_fetch_and_native_renewal')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.root=self.fixture.base/'owner'
        self.slot=self.root/'Work/codex';self.slot.mkdir(parents=True)
        with self.fixture.store.locked(self.fixture.grant,time.monotonic()+2) as grant:
            self.profile=grant.public()['profileId']
        (self.slot.parent/'.n2-profile').write_text(json.dumps({'schemaVersion':1,'profileId':self.profile}))
    def command(self,action,*args,success=True):
        result=subprocess.run([str(ROOT/'agents'),'fleet','auth',action,'Work',*args],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),capture_output=True,text=True,timeout=15)
        if success:self.assertEqual(result.returncode,0,result.stderr)
        else:self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertNotIn('original-secret',result.stdout+result.stderr)
        return json.loads(result.stdout) if success else result
    def register(self,**kwargs):
        return self.command('register','--grant',self.fixture.grant,**kwargs)
    def sync_write(self,address,payload,success=True):
        script = '''root=$1; scripts_dir=$2; shift 2
. "$scripts_dir/vendors.sh"
. "$scripts_dir/fleet.sh"
. "$scripts_dir/fleet-sync.sh"
config_dir() { printf '%s/%s/%s' "$root" "$1" "$2"; }
sync_need
sync_secret_shareable() { return 0; }
sync_res_lock "$1" || exit 1
trap 'sync_res_unlock "$1"' EXIT
sync_write "$1" "$2"
'''
        result=subprocess.run(['sh','-c',script,'fixture',str(self.root),str(ROOT),address,str(payload)],
                              capture_output=True,text=True,timeout=15)
        if success:self.assertEqual(result.returncode,0,result.stderr)
        else:self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertEqual(result.stdout,'')
        return result
    def test_sync_installs_private_binding_and_fences_queued_credentials(self):
        record=self.register()['binding']
        (self.slot/'.n2-owner.json').unlink()
        payload=self.fixture.base/'binding-payload';payload.write_text(json.dumps(record))
        address='settings|Work|codex|.n2-owner.json'
        self.sync_write(address,payload)
        self.assertEqual(self.command('status')['status'],'active')
        self.assertEqual((self.slot/'.n2-owner.json').stat().st_mode & 0o777,0o600)
        secret=self.fixture.base/'secret-payload';secret.write_text('{"access_token":"synthetic"}')
        self.sync_write('auth|Work|codex|auth.json',secret,success=False)
        self.sync_write('settings|Work|codex|config.json',secret,success=False)
        self.sync_write('mcp|Work|codex|mcp.json',secret,success=False)
        self.sync_write(address,'',success=False)
        self.assertTrue((self.slot/'.n2-owner.json').exists())
        self.assertFalse((self.slot/'auth.json').exists())
        public=self.fixture.base/'public-payload';public.write_text('model = "synthetic-model"')
        self.sync_write('settings|Work|codex|config.toml',public)
        self.assertEqual((self.slot/'config.toml').read_text(),public.read_text())
    def test_sync_refuses_wrong_profile_and_existing_legacy_credentials(self):
        record=self.register()['binding'];(self.slot/'.n2-owner.json').unlink()
        payload=self.fixture.base/'binding-payload'
        wrong=dict(record,profileId='00000000-0000-4000-8000-000000000001')
        payload.write_text(json.dumps(wrong))
        self.sync_write('settings|Work|codex|.n2-owner.json',payload,success=False)
        payload.write_text(json.dumps(record));(self.slot/'auth.json').write_text('existing')
        self.sync_write('settings|Work|codex|.n2-owner.json',payload,success=False)
        self.assertEqual((self.slot/'auth.json').read_text(),'existing')
        self.assertFalse((self.slot/'.n2-owner.json').exists())

    def test_public_binding_replication_then_owner_authenticated_fetch(self):
        record=self.register()['binding']
        client=self.fixture.base/'client'
        profile=client/'Work';profile.mkdir()
        (profile/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        result=subprocess.run([str(ROOT/'agents'),'fleet','sync','now','--peer',self.fixture.identities['owner']],
            env=dict(os.environ,N2_AGENTS_ROOT=str(client)),capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((profile/'codex/.n2-owner.json').exists(),result.stdout+result.stderr)
        self.assertEqual(json.loads((profile/'codex/.n2-owner.json').read_text()),record)
        self.assertFalse((profile/'codex/auth.json').exists())
        self.assertEqual((profile/'codex/.n2-owner.json').stat().st_mode & 0o777,0o600)
        spec=importlib.util.spec_from_file_location('owner_client',ROOT/'fleet-auth-client.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        broker=module.for_profile(client,profile/'codex','Work')
        self.assertEqual(broker.start(time.monotonic()+5)['accessToken'],'original-secret')
        self.assertNotIn('original-secret',result.stdout+result.stderr)

    def test_absent_local_record_conflict_blocks_credentials_and_consumers(self):
        self.register()
        conflict=self.root/'fleet/sync/conflicts'/hashlib.sha256(b'settings|Work|codex|.n2-owner.json').hexdigest()[:12]
        conflict.mkdir(parents=True)
        spec=importlib.util.spec_from_file_location('broker',ROOT/'fleet-auth-client.py')
        broker=importlib.util.module_from_spec(spec);spec.loader.exec_module(broker)
        for present in (True,False):
            if not present:(self.slot/'.n2-owner.json').unlink()
            with self.assertRaisesRegex(ValueError,'conflict'):
                broker.for_profile(self.root,self.slot,'Work')
            self.assertTrue(broker.binding.has_intent(self.root,'Work',self.slot))
            self.assertEqual(self.command('status')['status'],'conflicting')
            self.command('allow','--peer',self.fixture.identities['client'],success=False)
            secret=self.fixture.base/'credential';secret.write_text('{"tokens":{}}')
            self.sync_write('auth|Work|codex|auth.json',secret,success=False)
        stage=conflict.with_name('.resolving-'+conflict.name+'.999999')
        conflict.rename(stage)
        with self.assertRaisesRegex(ValueError,'conflict'):
            broker.for_profile(self.root,self.slot,'Work')
        self.sync_write('auth|Work|codex|auth.json',secret,success=False)
        self.register(success=False)
        self.assertFalse((self.slot/'auth.json').exists())

    def test_registration_waits_for_slot_writer_and_rechecks_credentials(self):
        gate='settings|Work|codex|.n2-owner-gate'
        lock=self.root/'fleet/sync/res.lock'/hashlib.sha256(gate.encode()).hexdigest()
        lock.mkdir(parents=True);(lock/'pid').write_text(str(os.getpid()))
        process=subprocess.Popen([str(ROOT/'agents'),'fleet','auth','register','Work','--grant',self.fixture.grant],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            time.sleep(.3)
            self.assertIsNone(process.poll())
            (self.slot/'auth.json').write_text('queued-legacy-write')
            (lock/'pid').unlink();lock.rmdir()
            stdout,stderr=process.communicate(timeout=10)
            self.assertNotEqual(process.returncode,0)
            self.assertFalse((self.slot/'.n2-owner.json').exists())
        finally:
            if process.poll() is None:process.kill();process.communicate()
            if lock.exists():(lock/'pid').unlink();lock.rmdir()

    def login_command(self,*args):
        return subprocess.run([str(ROOT/'agents'),'fleet','auth','login','Work',*args],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),capture_output=True,text=True,timeout=20)
    def test_cli_fresh_login_publishes_verified_grant(self):
        result=self.login_command('--timeout','5')
        self.assertEqual(result.returncode,0,result.stderr)
        challenge,registered=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(challenge['status'],'login-required')
        self.assertEqual(registered['status'],'registered')
        self.assertEqual(challenge['grantId'],registered['binding']['grantId'])
        self.assertEqual(self.command('status')['status'],'active')
        self.assertFalse((self.slot/'auth.json').exists())
        self.assertNotIn('original-secret',result.stdout+result.stderr)
    def test_cli_login_replacement_preserves_old_grant_and_requires_explicit_account_change(self):
        old=self.register();old_bytes=(self.slot/'.n2-owner.json').read_bytes()
        self.assertNotEqual(self.login_command('--timeout','5').returncode,0)
        (self.fixture.bin/'settings.json').write_text(json.dumps({'mode':'login-other-account'}))
        failed=self.login_command('--timeout','5','--expected-revision',old['revision'])
        self.assertNotEqual(failed.returncode,0)
        self.assertEqual((self.slot/'.n2-owner.json').read_bytes(),old_bytes)
        replaced=self.login_command('--timeout','5','--expected-revision',old['revision'],'--replace-account')
        self.assertEqual(replaced.returncode,0,replaced.stderr)
        new=json.loads(replaced.stdout.splitlines()[-1])['binding']
        self.assertNotEqual(new['accountHash'],old['binding']['accountHash'])
        self.assertNotEqual(new['grantId'],old['binding']['grantId'])
        with self.fixture.store.locked(self.fixture.grant,time.monotonic()+2) as grant:
            self.assertEqual(grant.public()['state'],'active')
            self.assertEqual(grant.public()['accountHash'],old['binding']['accountHash'])
    def test_login_does_not_take_over_a_remote_owner(self):
        old=self.register();record=old['binding']
        record['owner']=self.fixture.identities['client']
        marker=self.slot/'.n2-owner.json';marker.write_text(json.dumps(record));marker.chmod(0o600)
        revision=hashlib.sha256(marker.read_bytes()).hexdigest()
        result=self.login_command('--expected-revision',revision,'--timeout','5')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')
        self.assertEqual(json.loads(marker.read_text()),record)

    def cancel_waiting_publication(self,cancel_signal):
        gate='settings|Work|codex|.n2-owner-gate'
        lock=self.root/'fleet/sync/res.lock'/hashlib.sha256(gate.encode()).hexdigest()
        lock.mkdir(parents=True);(lock/'pid').write_text(str(os.getpid()))
        process=subprocess.Popen(
            [os.sys.executable,str(ROOT/'fleet-auth-manage.py'),'login',str(self.root),'Work',str(self.slot),'--timeout','5'],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            event=json.loads(process.stdout.readline());grant_id=event['grantId']
            deadline=time.monotonic()+5
            state=self.root/'fleet/auth-owners'/grant_id/'state.json'
            while time.monotonic()<deadline:
                if json.loads(state.read_text())['state']=='active':break
                time.sleep(.02)
            self.assertEqual(json.loads(state.read_text())['state'],'active')
            # Registration holds its record lock before waiting on the gate.
            record_lock=self.root/'fleet/sync/res.lock'/hashlib.sha256(b'settings|Work|codex|.n2-owner.json').hexdigest()
            while not record_lock.exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(record_lock.exists())
            process.send_signal(cancel_signal);process.communicate(timeout=5)
            self.assertEqual(process.returncode,130)
            (lock/'pid').unlink();lock.rmdir()
            time.sleep(.3)
            self.assertFalse((self.slot/'.n2-owner.json').exists())
        finally:
            if process.poll() is None:process.kill();process.communicate()
            if lock.exists():(lock/'pid').unlink();lock.rmdir()

    def test_cancelling_waiting_publication_leaves_no_orphan_writer(self):
        self.cancel_waiting_publication(signal.SIGINT)

    def test_terminating_waiting_publication_leaves_no_orphan_writer(self):
        self.cancel_waiting_publication(signal.SIGTERM)

    def test_late_login_cannot_overwrite_changed_profile_identity(self):
        (self.fixture.bin/'settings.json').write_text(json.dumps({'loginDelay':.5}))
        process=subprocess.Popen([str(ROOT/'agents'),'fleet','auth','login','Work','--timeout','5'],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            event=json.loads(process.stdout.readline())
            self.assertEqual(event['status'],'login-required')
            import uuid
            (self.slot.parent/'.n2-profile').write_text(json.dumps({'schemaVersion':1,'profileId':str(uuid.uuid4())}))
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode,0)
            self.assertFalse((self.slot/'.n2-owner.json').exists())
        finally:
            if process.poll() is None:process.kill();process.communicate()

    def test_register_status_and_explicit_revision(self):
        first=self.register()
        self.assertEqual(self.command('status')['status'],'active')
        self.assertEqual((self.slot/'.n2-owner.json').stat().st_mode & 0o777,0o600)
        self.register(success=False)
        self.command('register','--grant',self.fixture.grant,'--expected-revision','0'*64,success=False)
        second=self.command('register','--grant',self.fixture.grant,'--expected-revision',first['revision'])
        self.assertEqual(first['binding'],second['binding'])
    def test_consent_controls_authenticated_endpoint(self):
        self.register();peer=self.fixture.identities['client']
        self.command('deny','--peer',peer)
        with self.assertRaises(ValueError):self.fixture.exchange()
        self.command('allow','--peer',peer)
        self.assertEqual(self.fixture.exchange()['accessToken'],'original-secret')
        (self.root/'fleet/revoked').write_text(peer+' removed\n')
        self.command('allow','--peer',peer,success=False)
        self.command('deny','--peer',peer)
    def test_legacy_file_and_dangling_symlink_refuse_registration(self):
        auth=self.slot/'auth.json';auth.write_text('legacy')
        self.register(success=False);self.assertEqual(auth.read_text(),'legacy')
        auth.unlink();auth.symlink_to(self.slot/'missing')
        self.register(success=False)
        self.assertFalse((self.slot/'.n2-owner.json').exists())
    def test_duplicate_profile_and_pending_binding_conflict_refuse(self):
        other=self.root/'Other';other.mkdir()
        (other/'.n2-profile').write_bytes((self.slot.parent/'.n2-profile').read_bytes())
        self.register(success=False)
        (other/'.n2-profile').unlink()
        address='settings|Work|codex|.n2-owner.json'
        conflict=self.root/'fleet/sync/conflicts'/hashlib.sha256(address.encode()).hexdigest()[:12]
        conflict.mkdir(parents=True)
        self.register(success=False)
        self.assertFalse((self.slot/'.n2-owner.json').exists())

if __name__=='__main__':unittest.main()
