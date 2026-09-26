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
import tempfile
import select

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

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
        store=m.load('receipt_store_tests','usage-store.py')
        self.journal=store.Journal(directory.name)
        self.addCleanup(self.journal.db.close)
        self.receipts=m.Receipts(self.journal,'Work','a'*64)
        self.receipts.thread('thread','model-a',True)
    def start(self,identifier='turn'):
        self.receipts.begin('thread');self.receipts.acknowledge({'id':identifier})
    def usage(self,total,identifier='turn'):
        self.receipts.observe('thread/tokenUsage/updated',{'threadId':'thread','turnId':identifier,
            'tokenUsage':{'total':{'inputTokens':total-10,'cachedInputTokens':5,'outputTokens':10,'totalTokens':total}}})
    def complete(self,identifier='turn',status='completed',error=None):
        self.receipts.observe('turn/completed',{'threadId':'thread','turn':{'id':identifier,'status':status,'error':error}})
    def test_cumulative_thread_tokens_count_each_turn_once(self):
        self.start();self.usage(60);self.complete();self.receipts.finish()
        self.start('second');self.usage(90,'second');self.complete('second');self.receipts.finish()
        result=self.journal.token_summary()
        self.assertEqual(result['uniqueTasks'],2)
        self.assertEqual(result['groups'][0]['reportedTotalTokens'],90)
        self.assertEqual(result['groups'][0]['accountHash'],'a'*64)
        self.assertEqual(result['groups'][0]['usageScope'],'provider-turn')
    def test_missing_boundary_does_not_attribute_previous_turn_tokens(self):
        self.start();self.complete();self.receipts.finish()
        self.start('second');self.usage(90,'second');self.complete('second');self.receipts.finish()
        group=self.journal.token_summary()['groups'][0]
        self.assertEqual(group['knownTokenTasks'],0);self.assertEqual(group['unknownTokenTasks'],2)
    def test_quota_failure_is_durable_and_has_no_raw_error(self):
        self.start();self.complete(status='failed',error={'codexErrorInfo':'usageLimitExceeded','message':'private error secret'})
        self.receipts.finish()
        events=self.journal.events();self.assertEqual(events[0]['kind'],'quota-rejected')
        self.assertFalse(events[0]['data']['resetKnown'])
        self.assertNotIn('private error secret',json.dumps(events))
        self.assertTrue(self.journal.active_rejections())
    def test_early_notifications_and_foreign_completion_are_correlated(self):
        self.receipts.begin('thread');self.usage(60);self.complete('foreign');self.complete()
        self.receipts.acknowledge({'id':'turn'})
        self.assertEqual(self.receipts.current['completion']['id'],'turn')
        self.receipts.finish();self.assertEqual(self.journal.token_summary()['groups'][0]['reportedTotalTokens'],60)
    def test_reroute_and_disconnection_do_not_invent_attribution(self):
        self.start();self.usage(60)
        self.receipts.observe('model/rerouted',{'threadId':'thread','turnId':'turn','toModel':'other'})
        self.complete();self.receipts.finish(verified=False)
        event=self.journal.events()[0]
        self.assertEqual(event['kind'],'execution-failed');self.assertIsNone(event['data']['model'])
        self.assertEqual(event['data']['identity'],{'status':'unknown'})
        self.assertIsNone(event['data']['attribution']['totalTokens'])
    def test_persistent_model_override_allows_later_success_to_clear_rejection(self):
        self.receipts.begin('thread','model-b');self.receipts.acknowledge({'id':'turn'})
        self.complete(status='failed',error={'codexErrorInfo':'usageLimitExceeded'})
        self.receipts.finish();self.assertEqual(len(self.journal.active_rejections()),1)
        self.start('second');self.complete('second');self.receipts.finish()
        self.assertEqual(self.journal.active_rejections(),[])
        events=self.journal.events()
        self.assertEqual({event['data']['requestedModel'] for event in events},{'model-b'})
        self.assertTrue(all(event['data']['model'] is None for event in events))

    def test_rejected_turn_request_does_not_change_effective_model(self):
        provider=Provider();bridge=m.Bridge(provider,lambda _:None,self.receipts)
        bridge.frontend({'id':1,'method':'initialize'});bridge.threads.add('thread')
        bridge.frontend({'id':2,'method':'turn/start','params':{'threadId':'thread','model':'model-b'}})
        key=provider.sent[-1]['id']
        bridge.backend({'id':key,'error':{'code':-32602,'message':'invalid parameters'}})
        self.start('second')
        self.assertIsNone(self.receipts.current['requestedModel'])
        self.assertEqual(self.receipts.current['model'],'model-a')
        self.usage(60,'second');self.complete('second');self.receipts.finish()
        events=self.journal.events()
        success=next(event for event in events if event['kind']=='execution-succeeded')
        self.assertIsNone(success['data']['requestedModel'])
        self.assertEqual(success['data']['attribution']['totalTokens'],60)

    def test_counter_reset_remains_unknown(self):
        self.start();self.usage(60);self.complete();self.receipts.finish()
        self.start('second');self.usage(30,'second');self.complete('second');self.receipts.finish()
        group=self.journal.token_summary()['groups'][0]
        self.assertEqual(group['reportedTotalTokens'],60);self.assertEqual(group['unknownTokenTasks'],1)
    def test_bridge_completion_checks_binding_and_records_once(self):
        provider=Provider();out=[];bridge=m.Bridge(provider,out.append,self.receipts)
        bridge.frontend({'id':1,'method':'initialize'});bridge.threads.add('thread')
        bridge.frontend({'id':2,'method':'turn/start','params':{'threadId':'thread'}})
        key=provider.sent[-1]['id']
        bridge.backend({'method':'thread/tokenUsage/updated','params':{'threadId':'thread','turnId':'turn',
            'tokenUsage':{'total':dict(inputTokens=50,cachedInputTokens=30,outputTokens=10,totalTokens=60)}}})
        bridge.backend({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'completed'}}})
        bridge.backend({'id':key,'result':{'turn':{'id':'turn'}}})
        bridge.flush_receipts();bridge.flush_receipts()
        self.assertEqual(provider.verified,2);self.assertFalse(bridge.active)
        self.assertEqual(len(self.journal.events()),1)
        self.assertEqual(self.journal.token_summary()['groups'][0]['reportedTotalTokens'],60)

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
    def test_actual_frontend_turns_record_tokens_and_share_quota_rejection(self):
        (self.wire.bin/'settings.json').write_text(json.dumps({'allowExternalHome':True,'quotaTurn':3}))
        process=subprocess.Popen([str(ROOT/'agents'),'run','Work','--vendor','codex','app-server'],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        def cleanup():
            if process.poll() is None:process.kill()
            process.wait(timeout=5)
            for stream in (process.stdin,process.stdout,process.stderr):stream.close()
        self.addCleanup(cleanup)
        def send(value):process.stdin.write(json.dumps(value).encode()+b'\n');process.stdin.flush()
        def until(predicate):
            deadline=time.monotonic()+10;raw=b''
            while time.monotonic()<deadline:
                ready,_,_=select.select([process.stdout],[],[],max(0,deadline-time.monotonic()))
                self.assertTrue(ready,'frontend response timed out')
                byte=process.stdout.read(1);self.assertTrue(byte,'frontend closed unexpectedly')
                raw+=byte
                if byte==b'\n':
                    message=json.loads(raw);raw=b''
                    if predicate(message):return message
            self.fail('frontend response timed out')
        send({'id':1,'method':'initialize'});until(lambda x:x.get('id')==1)
        send({'id':2,'method':'thread/start'});until(lambda x:x.get('id')==2)
        for turn in range(3):
            send({'id':3+turn,'method':'turn/start','params':{'threadId':'fixture-thread','input':[]}})
            until(lambda x:x.get('method')=='turn/completed')
        send({'id':9,'method':'account/read'});until(lambda x:x.get('id')==9)
        process.stdin.close();self.assertEqual(process.wait(timeout=5),0)
        store=m.load('receipt_integration_store','usage-store.py');journal=store.Journal(self.root)
        self.addCleanup(journal.db.close)
        summary=journal.token_summary()
        self.assertEqual(summary['uniqueTasks'],3)
        self.assertEqual(sum(g['reportedTotalTokens'] for g in summary['groups']),180)
        self.assertEqual({g['accountHash'] for g in summary['groups']},{self.wire.context['accountHash']})
        self.assertEqual(len(journal.active_rejections()),1)
        self.assertNotIn('private quota diagnostic',json.dumps(journal.events()))
        peer_dir=self.wire.base/'receipt-peer';peer=store.Journal(peer_dir)
        self.addCleanup(peer.db.close)
        events=journal.events();peer.import_events(events,events[0]['origin'])
        self.assertEqual(len(peer.active_rejections()),1)
        self.assertEqual(peer.token_summary()['uniqueTasks'],3)

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
