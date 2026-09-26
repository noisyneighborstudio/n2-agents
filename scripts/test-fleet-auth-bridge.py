#!/usr/bin/env python3
"""Account-bound app-server relay: auth isolation and provider route invariants."""
import importlib.util
import io
import json
from pathlib import Path
import queue
import os
import subprocess
import unittest
import time

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bridge',ROOT/'fleet-auth-bridge.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Provider:
    def __init__(self):
        self.initialization={'userAgent':'fixture'};self.cwd='/project';self.sent=[]
        self.verified=0;self.messages=queue.Queue();self.denied=False
    def send(self,value):self.sent.append(value)
    def validate_account_binding(self, deferred_messages=None):
        if self.denied:raise RuntimeError('owner unavailable')
        self.verified+=1

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.provider=Provider();self.out=[];self.bridge=m.Bridge(self.provider,self.out.append)
        self.bridge.frontend({'id':1,'method':'initialize'})
    def start(self):
        self.bridge.frontend({'id':1,'method':'thread/start','params':{}})
        key=self.provider.sent[-1]['id']
        self.bridge.backend({'id':key,'result':{'thread':{'id':'thread'},'modelProvider':'openai','cwd':'/project'}})
    def test_initialization_is_local_and_frontend_ids_do_not_collide_with_auth_ids(self):
        self.assertEqual(self.out,[{'id':1,'result':self.provider.initialization}])
        self.assertEqual(self.provider.sent,[])
        self.start();self.assertEqual(self.provider.verified,1)
        self.assertIsInstance(self.provider.sent[0]['id'],str)
        self.assertEqual(self.out[-1]['id'],1)
        self.bridge.frontend({'id':1,'method':'turn/start','params':{'threadId':'thread'}})
        self.assertNotEqual(self.provider.sent[-1]['id'],self.provider.sent[0]['id'])
        self.assertEqual(self.provider.verified,2)
    def test_auth_and_configuration_mutations_never_reach_provider(self):
        for method in ('account/login/start','account/logout','config/value/write'):
            self.bridge.frontend({'id':2,'method':method,'params':{'accessToken':'frontend-secret'}})
            self.assertIn('error',self.out[-1])
        self.assertEqual(self.provider.sent,[])
        self.assertNotIn('frontend-secret',json.dumps(self.out))
    def test_approval_round_trip_uses_separate_ids_and_rejects_replay(self):
        self.bridge.backend({'id':1,'method':'item/commandExecution/requestApproval','params':{}})
        key=self.out[-1]['id'];self.assertIsInstance(key,str)
        self.bridge.frontend({'id':key,'result':{'decision':'decline'}})
        self.assertEqual(self.provider.sent[-1],{'id':1,'result':{'decision':'decline'}})
        with self.assertRaises(ValueError):self.bridge.frontend({'id':key,'result':{}})
    def test_route_overrides_and_unknown_threads_are_refused(self):
        for method,params in [('thread/start',{'modelProvider':'other'}),('thread/start',{'config':{'openai_base_url':'https://other.invalid'}}),
                              ('thread/start',{'cwd':'/other'}),('thread/resume',{'threadId':'foreign'}),
                              ('turn/start',{'threadId':'foreign'}),('thread/archive',{'threadId':'foreign'})]:
            self.bridge.frontend({'id':2,'method':method,'params':params})
            self.assertIn('error',self.out[-1])
        self.assertEqual(self.provider.sent,[])
    def test_mismatched_thread_route_is_never_exposed(self):
        self.bridge.frontend({'id':2,'method':'thread/start'})
        key=self.provider.sent[-1]['id']
        with self.assertRaises(RuntimeError):
            self.bridge.backend({'id':key,'result':{'thread':{'id':'wrong'},'modelProvider':'other','cwd':'/project'}})
        self.assertEqual(len(self.out),1);self.assertEqual(self.bridge.threads,set())
    def test_authentication_failure_prevents_turn_dispatch(self):
        self.start();before=len(self.provider.sent);self.provider.denied=True
        with self.assertRaises(RuntimeError):self.bridge.frontend({'id':2,'method':'turn/start','params':{'threadId':'thread'}})
        self.assertEqual(len(self.provider.sent),before)
    def test_renewal_control_messages_never_reach_frontend(self):
        for method in ('account/chatgptAuthTokens/refresh','account/updated'):
            with self.assertRaises(RuntimeError):self.bridge.backend({'id':3,'method':method,'params':{'accessToken':'secret'}})
        self.assertNotIn('secret',json.dumps(self.out))
    def test_malformed_messages_and_unknown_ids_fail_closed(self):
        for raw in (b'{"id":1,"id":2}',b'[]',b'{"id":NaN}'):
            with self.assertRaises(ValueError):m.decode(raw)
        with self.assertRaises(ValueError):self.bridge.frontend({'method':'account/read','id':True})
        with self.assertRaises(ValueError):self.bridge.backend({'id':1,'result':{}})

class RealRPCMessageTests(unittest.TestCase):
    def setUp(self):
        rpc=m.load('bridge_rpc_regression','codex-rpc.py')
        self.provider=rpc.CodexRPC.__new__(rpc.CodexRPC)
        p=self.provider
        p.messages=queue.Queue();p.timeout=.1;p.next_id=1;p.failure=None
        p._initial_owner_account=None;p.account_generation=0;p._bound_generation=0
        p._binding_failed=False;p._custom_openai_endpoint=False;p.cwd='/project'
        p.initialization={'userAgent':'fixture'}
        self.account={'type':'chatgpt','email':'fixture@example.invalid','planType':'plus'}
        p._bound_account=p._account_key({'account':self.account,'workspaceRouting':None})
        self.sent=[]
        def send(message,deadline=None):
            self.sent.append(message)
            if 'method' not in message:return
            method=message['method']
            result={'config':{}} if method=='config/read' else ({'account':self.account} if method=='account/read' else {})
            if method=='thread/start':result={'thread':{'id':'thread'},'modelProvider':'openai','cwd':'/project'}
            p.messages.put((time.monotonic(),{'id':message['id'],'result':result}))
        p.send=send
        self.out=[];self.bridge=m.Bridge(p,self.out.append)
        self.bridge.frontend({'id':1,'method':'initialize'})
    def test_successful_renewal_yields_to_frontend_without_next_provider_message(self):
        renewed=[]
        self.provider._renew_external_account=lambda message,deadline:renewed.append(message['id'])
        self.provider.messages.put((time.monotonic(),{'id':99,'method':'account/chatgptAuthTokens/refresh'}))
        sink=io.BytesIO()
        m.serve(self.provider,io.BytesIO(b'{"id":1,"method":"initialize"}\n'),sink)
        self.assertEqual(renewed,[99])
        self.assertEqual(json.loads(sink.getvalue()),{'id':1,'result':self.provider.initialization})
    def test_verification_preserves_interleaved_notifications(self):
        notice={'method':'thread/name/updated','params':{'threadId':'thread','name':'updated'}}
        self.provider.messages.put((time.monotonic(),notice))
        self.bridge.frontend({'id':2,'method':'thread/start'})
        self.assertIn(notice,self.out)
        self.bridge.backend(self.provider.receive(time.monotonic()+.1))
        self.assertEqual(self.out[-1]['id'],2)
    def test_verification_preserves_approval_and_defers_new_execution(self):
        self.provider.messages.put((time.monotonic(),{'id':99,'method':'item/commandExecution/requestApproval','params':{}}))
        self.bridge.frontend({'id':2,'method':'thread/start'})
        approval=self.out[-2]
        self.assertEqual(approval['method'],'item/commandExecution/requestApproval')
        self.assertIn('error',self.out[-1])
        self.assertFalse(self.provider._binding_failed)
        self.assertFalse(any(msg.get('method')=='thread/start' for msg in self.sent))
        self.bridge.frontend({'id':approval['id'],'result':{'decision':'decline'}})
        self.assertEqual(self.sent[-1],{'id':99,'result':{'decision':'decline'}})

class BridgeIntegrationTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('bridge_fixture',ROOT/'scripts/test-fleet-auth-manage.py')
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        self.fixture=fixture.ManageTests('test_register_status_and_explicit_revision')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp();self.fixture.register()
        self.wire=self.fixture.fixture
        (self.wire.bin/'settings.json').write_text(json.dumps({'allowExternalHome':True}))
        self.root=self.wire.base/'client';profile=self.root/'Work';slot=profile/'codex';slot.mkdir(parents=True)
        (profile/'.n2-profile').write_bytes((self.fixture.slot.parent/'.n2-profile').read_bytes())
        (slot/'.n2-owner.json').write_bytes((self.fixture.slot/'.n2-owner.json').read_bytes());(slot/'.n2-owner.json').chmod(0o600)
    def run_cli(self,requests,args=('app-server',)):
        return subprocess.run([str(ROOT/'agents'),'run','Work','--vendor','codex',*args],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),input=''.join(json.dumps(r)+'\n' for r in requests),
            text=True,capture_output=True,timeout=20)
    def test_actual_cli_connects_to_remote_owner_without_forwarding_credentials(self):
        result=self.run_cli([{'id':10,'method':'initialize'}, {'method':'initialized'},
                             {'id':11,'method':'account/read','params':{'refreshToken':True}},
                             {'id':12,'method':'account/logout'}])
        self.assertEqual(result.returncode,0,result.stderr)
        rows=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r['id'] for r in rows],[10,11,12])
        self.assertEqual(rows[1]['result']['account']['email'],'fixture@example.invalid')
        self.assertIn('error',rows[2])
        self.assertNotIn('original-secret',result.stdout+result.stderr)
        self.assertFalse((self.root/'Work/codex/auth.json').exists())
        trace=[json.loads(line) for line in (self.wire.bin/'trace.jsonl').read_text().splitlines()]
        self.assertFalse(any(row['refresh'] for row in trace))
    def test_ordinary_terminal_launch_uses_private_socket_and_owner_account(self):
        executable=self.wire.bin/'codex';executable.rename(self.wire.bin/'provider')
        executable.write_bytes((ROOT/'tests/fake-owner-terminal.py').read_bytes());executable.chmod(0o700)
        result=self.run_cli([],args=())
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'terminal-connected')
        self.assertNotIn('original-secret',result.stdout+result.stderr)
        self.assertFalse((self.root/'Work/codex/auth.json').exists())
        result=self.run_cli([],args=('--remote','unix:///other'))
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('terminal-connected',result.stdout)

    def test_unknown_owner_and_unsupported_direct_login_never_fall_back(self):
        result=self.run_cli([],args=('login',))
        self.assertNotEqual(result.returncode,0)
        self.assertIn('owner-managed',result.stderr)
        self.fixture.command('deny','--peer',self.wire.identities['client'])
        result=self.run_cli([{'id':10,'method':'initialize'}])
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')
        self.assertFalse((self.root/'Work/codex/auth.json').exists())

if __name__=='__main__':unittest.main()
