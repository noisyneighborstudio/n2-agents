#!/usr/bin/env python3
"""Signed remote login with disposable keys, roots and a synthetic provider."""
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from unittest.mock import patch
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
fixture=load('manage_fixture',ROOT/'scripts/test-fleet-auth-manage.py')
login=load('remote_login',ROOT/'fleet-auth-login.py')

class RemoteLoginTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.ManageTests('test_register_status_and_explicit_revision')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.root=self.fixture.root;self.wire=self.fixture.fixture
        self.registered=self.fixture.register();record=self.registered['binding']
        self.context={key:record[key] for key in ('owner','profileId','grantId','ownershipGeneration','accountHash')}
        self.context.update(schemaVersion=1,recipient=self.wire.identities['client'],nonce=secrets.token_hex(32),
            operationId=str(uuid.uuid4()),action='start',expiresAt=time.time()+20,
            bindingRevision=self.registered['revision'],replaceAccount=False)
        self.fixture.command('allow-login','--peer',self.wire.identities['client'])
        self.operations=login.Operations(self.root)
    def call(self,action):
        self.context.update(action=action,nonce=secrets.token_hex(32),expiresAt=time.time()+20)
        return login.manage.server.transport.exchange(self.wire.base/'client',self.context,self.wire.public,
                                                       time.monotonic()+15,protocol='login')
    def wait_for(self,status):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            result=self.call('status')
            if result['status']==status:return result
            if result['status'] in ('failed','cancelled'):self.fail(str(result))
            time.sleep(.05)
        self.fail('operation did not reach '+status)
    def test_remote_login_requires_finish_and_preserves_old_grant(self):
        original=(self.fixture.slot/'.n2-owner.json').read_bytes()
        self.assertEqual(self.call('start')['status'],'starting')
        self.wait_for('verified')
        self.assertEqual((self.fixture.slot/'.n2-owner.json').read_bytes(),original)
        self.assertEqual(self.call('start')['status'],'verified')
        self.assertEqual(len(self.fixture.command('grants')['grants']),2)
        result=self.call('finish');self.assertEqual(result['status'],'completed')
        new=result['binding'];self.assertNotEqual(new['grantId'],self.wire.grant)
        self.assertEqual(new['accountHash'],self.registered['binding']['accountHash'])
        self.assertEqual(self.call('finish'),result)
        self.assertEqual(self.call('cancel'),result)
        with self.wire.store.locked(self.wire.grant,time.monotonic()+2) as grant:
            self.assertEqual(grant.public()['state'],'active')
        self.assertFalse((self.fixture.slot/'auth.json').exists())
    def test_remote_cli_syncs_replacement_and_preserves_account_access(self):
        client=self.wire.base/'client';profile=client/'Work';profile.mkdir()
        (profile/'.n2-profile').write_bytes((self.fixture.slot.parent/'.n2-profile').read_bytes())
        env=dict(os.environ,N2_AGENTS_ROOT=str(client))
        sync=subprocess.run([str(ROOT/'agents'),'fleet','sync','now','--peer',self.wire.identities['owner']],
                            env=env,capture_output=True,text=True,timeout=30)
        self.assertEqual(sync.returncode,0,sync.stderr)
        result=subprocess.run([str(ROOT/'agents'),'fleet','auth','login','Work',
                               '--expected-revision',self.registered['revision'],'--timeout','30'],
                              env=env,capture_output=True,text=True,timeout=40)
        self.assertEqual(result.returncode,0,result.stderr)
        final=json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(final['status'],'registered',final)
        self.assertEqual(final['localBinding'],'current')
        self.assertNotEqual(final['binding']['grantId'],self.wire.grant)
        broker=load('new_login_client',ROOT/'fleet-auth-client.py').for_profile(client,profile/'codex','Work')
        token=broker.start(time.monotonic()+5)
        self.assertTrue(token['accessToken'])
        self.assertNotIn(token['accessToken'],result.stdout+result.stderr)
        self.assertFalse((profile/'codex/auth.json').exists())

    def test_cancelled_challenge_never_publishes(self):
        (self.wire.bin/'settings.json').write_text(json.dumps({'mode':'login-cancel'}))
        original=(self.fixture.slot/'.n2-owner.json').read_bytes()
        self.call('start');challenge=self.wait_for('login-required')
        self.assertEqual(challenge['challenge']['userCode'],'TEST-1234')
        self.assertEqual(self.call('cancel')['status'],'cancelled')
        with self.assertRaises(ValueError):self.call('finish')
        time.sleep(.4)
        self.assertEqual((self.fixture.slot/'.n2-owner.json').read_bytes(),original)
    def test_renewal_contention_keeps_login_alive_and_returns_signed_busy(self):
        (self.wire.bin/'settings.json').write_text(json.dumps({'mode':'login-cancel'}))
        self.call('start');self.wait_for('login-required')
        with self.wire.store.locked(self.wire.grant,time.monotonic()+2):
            self.assertEqual(self.call('status')['status'],'busy')
            time.sleep(1)
        self.assertEqual(self.call('status')['status'],'login-required')
        self.assertEqual(self.call('cancel')['status'],'cancelled')

    def test_final_authorization_retries_contention_but_rejects_revocation(self):
        self.call('start');self.wait_for('verified')
        row=self.operations.read(self.context['operationId'])
        with patch.object(self.operations,'authorize',side_effect=[TimeoutError(),['peer']]) as authorize:
            self.assertEqual(self.operations.await_authorization(row),['peer'])
            self.assertEqual(authorize.call_count,2)
        with patch.object(self.operations,'authorize',side_effect=ValueError('revoked')) as authorize:
            with self.assertRaises(ValueError):self.operations.await_authorization(row)
            self.assertEqual(authorize.call_count,1)
        self.call('cancel')

    def test_client_retries_busy_and_reports_completed_owner_when_sync_fails(self):
        self.call('start');self.wait_for('verified');completed=self.call('finish')
        busy={'status':'busy','challenge':None,'binding':None}
        with patch.object(login.manage.server.transport,'exchange',side_effect=[busy,completed]) as exchange:
            with patch.object(login.subprocess,'run',side_effect=OSError('sync unavailable')):
                result=login.client_login(self.wire.base/'client','Work',self.fixture.slot,
                    self.registered['binding'],self.registered['revision'],False,5)
        self.assertEqual(exchange.call_count,2)
        self.assertEqual(result['status'],'owner-completed')
        self.assertEqual(result['localBinding'],'pending-sync')
        self.assertIsNone(result['revision'])

    def test_management_revocation_stops_pending_worker(self):
        (self.wire.bin/'settings.json').write_text(json.dumps({'mode':'login-cancel'}))
        self.call('start');self.wait_for('login-required')
        self.fixture.command('deny-login','--peer',self.wire.identities['client'])
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if self.operations.read(self.context['operationId'])['status']=='failed':break
            time.sleep(.05)
        self.assertEqual(self.operations.read(self.context['operationId'])['status'],'failed')
        self.assertEqual(json.loads((self.fixture.slot/'.n2-owner.json').read_text()),self.registered['binding'])
        with self.assertRaises(ValueError):self.call('finish')

    def test_use_permission_does_not_grant_login_management(self):
        self.fixture.command('deny-login','--peer',self.wire.identities['client'])
        self.assertEqual(self.wire.exchange()['accessToken'],'original-secret')
        with self.assertRaises(ValueError):self.call('start')
        self.assertEqual(len(self.fixture.command('grants')['grants']),1)
    def test_finish_refuses_profile_change_and_changed_operation_intent(self):
        self.call('start');self.wait_for('verified')
        self.context['replaceAccount']=True
        with self.assertRaises(ValueError):self.call('status')
        self.context['replaceAccount']=False
        record=dict(self.registered['binding'],ownershipGeneration=str(uuid.uuid4()))
        (self.fixture.slot/'.n2-owner.json').write_text(json.dumps(record))
        with self.assertRaises(ValueError):self.call('finish')
        self.assertEqual(json.loads((self.fixture.slot/'.n2-owner.json').read_text()),record)

if __name__=='__main__':unittest.main()
