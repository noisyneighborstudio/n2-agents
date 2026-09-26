#!/usr/bin/env python3
"""Session-pinned client and owner-backed execution using synthetic providers."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch
import uuid

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path)
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
fixture=load('server_tests',ROOT/'scripts/test-fleet-auth-server.py')
client_module=load('client',ROOT/'fleet-auth-client.py')
bound=load('bound',ROOT/'codex-run.py')

class ClientTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.ServerTests('test_endpoint_fetch_and_native_renewal')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.base=self.fixture.base
        with self.fixture.store.locked(self.fixture.grant,time.monotonic()+2) as grant:
            self.record=client_module.binding.from_grant(grant,grant.public()['profileId'])
        self.profile=self.record['profileId'];self.account=self.record['accountHash']
    def client(self,local=False):
        return client_module.OwnerClient(self.base/('owner' if local else 'client'),self.record,self.profile,self.account)
    def test_remote_fetch_and_renewal_keep_one_generation_chain(self):
        client=self.client();first=client.start(time.monotonic()+4)
        generation=client.generation
        replacement=client.renew(first['chatgptAccountId'],time.monotonic()+5)
        self.assertEqual(first['accessToken'],'original-secret')
        self.assertEqual(replacement['accessToken'],'rotated-secret')
        self.assertNotEqual(client.generation,generation)
    def test_local_owner_uses_same_grant_without_ssh(self):
        client=self.client(True);first=client.start(time.monotonic()+3)
        replacement=client.renew(first['chatgptAccountId'],time.monotonic()+4)
        self.assertEqual(replacement['accessToken'],'rotated-secret')
    def test_binding_is_frozen_and_wrong_account_poisons_session(self):
        client=self.client();self.record['grantId']=str(uuid.uuid4())
        first=client.start(time.monotonic()+3)
        with self.assertRaisesRegex(RuntimeError,'^owner authentication unavailable$'):
            client.renew('other-workspace',time.monotonic()+2)
        with self.assertRaises(RuntimeError):client.renew(first['chatgptAccountId'],time.monotonic()+2)
    def test_timeout_contender_prevents_inflight_result_from_escaping(self):
        client=self.client();entered=threading.Event();release=threading.Event();out=[]
        def delayed(deadline):
            entered.set();release.wait(2)
            return {'accessToken':'late-secret','chatgptAccountId':'workspace','tokenGeneration':str(uuid.uuid4())}
        def initial():
            try:out.append(client.start(time.monotonic()+2))
            except RuntimeError:out.append('rejected')
        with patch.object(client,'_request',side_effect=delayed):
            worker=threading.Thread(target=initial);worker.start()
            try:
                self.assertTrue(entered.wait(1))
                with self.assertRaises(RuntimeError):client.start(time.monotonic()+.02)
            finally:release.set();worker.join(3)
        self.assertEqual(out,['rejected'])
    def prepare_profile(self):
        root=self.base/'client';profile=root/'Work';slot=profile/'codex';slot.mkdir(parents=True)
        (profile/'.n2-profile').write_text(json.dumps({'schemaVersion':1,'profileId':self.profile}))
        client_module.binding.publish(slot,self.record,self.profile)
        # It is deliberately unusable: broker execution must not read it.
        (slot/'auth.json').write_text('invalid legacy credential bytes')
        binary=self.base/'bound-codex';binary.write_bytes((ROOT/'tests/fake-bound-codex.py').read_bytes());binary.chmod(0o700)
        return root,slot,binary
    def test_bound_turn_renews_through_signed_endpoint_with_same_account_receipt(self):
        root,slot,binary=self.prepare_profile()
        (self.fixture.bin/'settings.json').write_text(json.dumps({'replacementToken':'renewed-token'}))
        trace=self.base/'bound-trace';output=io.StringIO()
        with patch.dict(os.environ,{'N2_BOUND_FIXTURE':'renew-mid','N2_BOUND_TRACE':str(trace)}),contextlib.redirect_stdout(output):
            code=bound.run(str(slot),self.account,'medium','Synthetic turn',executable=str(binary),
                           owner_root=str(root),profile_name='Work',timeout=8)
        self.assertEqual(code,0)
        receipt=json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(receipt['identity']['accountHash'],self.account)
        self.assertEqual(receipt['tokens']['totalTokens'],60)
        self.assertNotIn('renewed-token',output.getvalue())
        self.assertEqual((slot/'auth.json').read_text(),'invalid legacy credential bytes')
        methods=[json.loads(line)['method'] for line in trace.read_text().splitlines()]
        self.assertEqual(methods.count('turn/start'),1)
    def test_conflicted_missing_record_never_falls_back_to_legacy_usage_or_execution(self):
        import hashlib
        root,slot,binary=self.prepare_profile()
        (slot/'.n2-owner.json').unlink()
        key=hashlib.sha256(b'settings|Work|codex|.n2-owner.json').hexdigest()[:12]
        conflict=root/'fleet/sync/conflicts'/('.resolving-'+key+'.999999')
        conflict.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError,'conflict'):
            bound.run(str(slot),self.account,'medium','No turn',executable=str(binary),
                      owner_root=str(root),profile_name='Work',timeout=2)
        usage=load('conflict_usage',ROOT/'usage.py')
        with patch.dict(os.environ,{'N2_USAGE_ROOT':str(root),'N2_CODEX_USAGE_URL':''}):
            status,fetch=usage.codex('Work',str(slot))
            self.assertEqual(status,'ok')
            with self.assertRaises(usage.OwnerUnavailable):fetch()
        self.assertEqual((slot/'auth.json').read_text(),'invalid legacy credential bytes')

    def test_agents_bound_launch_forwards_profile_context(self):
        root,slot,binary=self.prepare_profile()
        native_binary=self.fixture.bin/'native-codex'
        native_binary.write_bytes((ROOT/'tests/fake-owner-codex.py').read_bytes())
        dispatcher=self.fixture.bin/'codex'
        dispatcher.write_text('#!'+sys.executable+'\nimport os,sys\n'
                              +'target='+repr(str(binary))+' if os.environ.get("N2_BOUND_TRACE") else '+repr(str(native_binary))+'\n'
                              +'os.execv(sys.executable,[sys.executable,target]+sys.argv[1:])\n')
        dispatcher.chmod(0o700)
        (self.fixture.bin/'settings.json').write_text(json.dumps({'replacementToken':'renewed-token'}))
        result=subprocess.run([str(ROOT/'agents'),'run','Work','--vendor','codex','--bound-account',self.account],
                              input='Synthetic CLI turn',text=True,capture_output=True,timeout=15,
                              env=dict(os.environ,N2_AGENTS_ROOT=str(root),N2_BOUND_FIXTURE='renew-mid',
                                       N2_BOUND_TRACE=str(self.base/'cli-bound-trace')))
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        receipt=json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(receipt['identity']['accountHash'],self.account)
        self.assertEqual(receipt['tokens']['totalTokens'],60)
        self.assertNotIn('renewed-token',result.stdout+result.stderr)

    def measure(self,root,slot,extra=None):
        settings=self.fixture.bin/'settings.json'
        value=json.loads(settings.read_text());value['allowExternalHome']=True;settings.write_text(json.dumps(value))
        env=dict(os.environ,N2_USAGE_ROOT=str(root),N2_USAGE_FORMAT='json',N2_USAGE_ORIGIN=self.fixture.identities['client'])
        if extra:env.update(extra)
        result=subprocess.run([sys.executable,str(ROOT/'usage.py'),'codex','Work='+str(slot)],
                              env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('original-secret',result.stdout+result.stderr)
        return json.loads(result.stdout)

    def test_usage_measures_owner_account_without_legacy_credentials(self):
        root,slot,_=self.prepare_profile()
        observed=self.measure(root,slot)
        self.assertEqual(observed['status'],'ok')
        self.assertEqual(observed['identity']['accountHash'],self.account)
        self.assertEqual(observed['windows'][0]['usedPercent'],12)
        self.assertEqual((slot/'auth.json').read_text(),'invalid legacy credential bytes')

    def test_usage_owner_denial_and_identity_drift_never_show_headroom(self):
        root,slot,_=self.prepare_profile()
        with self.fixture.store.locked(self.fixture.grant,time.monotonic()+2) as grant:
            grant.consent(self.fixture.identities['client'],False)
        observed=self.measure(root,slot)
        self.assertEqual(observed['status'],'owner-unavailable')
        self.assertEqual(observed['windows'],[])
        self.assertEqual(observed['identity']['status'],'unknown')
        with self.fixture.store.locked(self.fixture.grant,time.monotonic()+2) as grant:
            grant.consent(self.fixture.identities['client'],True)
        record=dict(self.record,accountHash='f'*64)
        revision=client_module.binding.read(slot,self.profile)[1]
        client_module.binding.publish(slot,record,self.profile,revision)
        observed=self.measure(root,slot)
        self.assertEqual(observed['status'],'owner-unavailable')
        self.assertEqual(observed['windows'],[])

    def test_idle_expiry_renews_once_before_usage_and_reuses_replacement(self):
        root,slot,_=self.prepare_profile()
        (self.fixture.bin/'settings.json').write_text(json.dumps({'rejectInitial':True}))
        first=self.measure(root,slot);second=self.measure(root,slot)
        self.assertEqual(first['status'],'ok')
        self.assertEqual(second['status'],'ok')
        self.assertEqual(first['identity']['accountHash'],self.account)
        trace=[json.loads(line) for line in (self.fixture.bin/'trace.jsonl').read_text().splitlines()]
        self.assertEqual(sum(row['refresh'] is True for row in trace),1)

    def test_failed_replacement_verification_does_not_loop_initial_refresh(self):
        root,slot,_=self.prepare_profile()
        (self.fixture.bin/'settings.json').write_text(json.dumps({'rejectInitial':True,'rejectEveryToken':True}))
        observed=self.measure(root,slot)
        self.assertEqual(observed['status'],'owner-unavailable')
        self.assertEqual(observed['windows'],[])
        trace=[json.loads(line) for line in (self.fixture.bin/'trace.jsonl').read_text().splitlines()]
        self.assertEqual(sum(row['refresh'] is True for row in trace),1)

    def test_idle_expiry_bound_turn_verifies_replacement_before_execution(self):
        root,slot,binary=self.prepare_profile()
        (self.fixture.bin/'settings.json').write_text(json.dumps({'replacementToken':'renewed-token'}))
        trace=self.base/'initial-bound-trace';output=io.StringIO()
        with patch.dict(os.environ,{'N2_BOUND_FIXTURE':'initial-expired','N2_BOUND_TRACE':str(trace)}),contextlib.redirect_stdout(output):
            code=bound.run(str(slot),self.account,'medium','Synthetic',executable=str(binary),
                           owner_root=str(root),profile_name='Work',timeout=8)
        self.assertEqual(code,0)
        rows=[json.loads(line) for line in trace.read_text().splitlines()]
        self.assertEqual(sum(row['method']=='turn/start' for row in rows),1)
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['identity']['accountHash'],self.account)

    def test_initial_replacement_wrong_account_never_starts_turn(self):
        root,slot,binary=self.prepare_profile()
        (self.fixture.bin/'settings.json').write_text(json.dumps({'replacementToken':'renewed-token'}))
        trace=self.base/'initial-mismatch-trace'
        with patch.dict(os.environ,{'N2_BOUND_FIXTURE':'initial-expired-wrong-account','N2_BOUND_TRACE':str(trace)}):
            with self.assertRaisesRegex(RuntimeError,'owner connection account mismatch'):
                bound.run(str(slot),self.account,'medium','Synthetic',executable=str(binary),
                          owner_root=str(root),profile_name='Work',timeout=8)
        rows=[json.loads(line) for line in trace.read_text().splitlines()]
        self.assertFalse(any(row['method']=='turn/start' for row in rows))

    def test_usage_override_cannot_bypass_owner_binding(self):
        root,slot,_=self.prepare_profile()
        observed=self.measure(root,slot,{'N2_CODEX_USAGE_URL':'http://127.0.0.1:1/forbidden'})
        self.assertEqual(observed['status'],'credential-override')
        self.assertEqual(observed['windows'],[])

    def test_malformed_record_never_falls_back_to_legacy_credentials(self):
        root,slot,binary=self.prepare_profile()
        (slot/client_module.binding.MARKER).write_text('{"schemaVersion":999}')
        with self.assertRaises(ValueError):bound.run(str(slot),self.account,'medium','Synthetic',executable=str(binary),owner_root=str(root),profile_name='Work')
        (slot/client_module.binding.MARKER).unlink()
        (slot/client_module.binding.MARKER).symlink_to(slot/'missing-record')
        with self.assertRaises(OSError):bound.run(str(slot),self.account,'medium','Synthetic',executable=str(binary),owner_root=str(root),profile_name='Work')

if __name__=='__main__':unittest.main()
