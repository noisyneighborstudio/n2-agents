#!/usr/bin/env python3
"""Saved-session transfer through signed fleet requests and real CLI resume."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
fixture=load('session_fixture','scripts/test-fleet-auth-bridge.py')
m=load('session_transfer','fleet-session.py')

class TransferTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.BridgeIntegrationTests('test_restart_resumes_persisted_history_without_credentials')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.source=self.fixture.root;self.wire=self.fixture.wire
        self.destination=self.wire.base/'owner';self.cwd=self.wire.base/'destination-project';self.cwd.mkdir()
        self.record=json.loads((self.source/'Work/codex/.n2-owner.json').read_text())
        self.thread='01990000-0000-7000-8000-000000000001'
        self.sessions=m.bridge.Sessions(self.source)
        self.sessions.remember(self.thread,self.record,os.getcwd());self.sessions.model(self.thread,'chosen-model')
        home=Path(self.sessions.home(self.record,os.getcwd(),self.source/'Work/codex'))
        directory=home/'sessions/2026/09/26';directory.mkdir(parents=True,mode=0o700)
        for parent in (directory.parent,directory.parent.parent):parent.chmod(0o700)
        self.rollout=directory/('rollout-2026-09-26T17-39-29-'+self.thread+'.jsonl')
        self.history=(json.dumps({'type':'session_meta','payload':{'id':self.thread,'cwd':os.getcwd()}})+'\n'+
                      json.dumps({'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'transferred marker'}]}})+'\n').encode()
        self.rollout.write_bytes(self.history);self.rollout.chmod(0o644)
        self.dest=m.bridge.Sessions(self.destination)
    def cli(self,*args,root=None):
        return subprocess.run([str(ROOT/'agents'),*args],env=dict(os.environ,N2_AGENTS_ROOT=str(root or self.source)),
                              capture_output=True,text=True,timeout=25)
    def send(self):
        return self.cli('fleet','session','send',self.thread,'--peer',self.wire.identities['owner'],'--cwd',str(self.cwd))
    def bundle(self):return m.snapshot(self.source,self.thread,str(self.cwd))
    def test_signed_transfer_discovery_resume_and_original_account(self):
        result=self.send();self.assertEqual(result.returncode,0,result.stderr)
        saved=self.dest.read(self.thread)
        self.assertEqual(saved['record'],self.record);self.assertEqual(saved['cwd'],str(self.cwd.resolve()))
        self.assertEqual(self.dest.model(self.thread),'chosen-model')
        result=self.cli('sessions','Work',root=self.destination)
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn(self.thread,result.stdout)
        self.assertEqual(self.send().returncode,0,'identical delivery must be idempotent')
        (self.wire.bin/'settings.json').write_text(json.dumps({'allowExternalHome':True,'nativeRollout':True}))
        executable=self.wire.bin/'codex';executable.rename(self.wire.bin/'provider')
        executable.write_bytes((ROOT/'tests/fake-owner-terminal.py').read_bytes());executable.chmod(0o700)
        # A later profile replacement must not retarget the imported session.
        marker=self.destination/'Work/codex/.n2-owner.json'
        marker.write_text(json.dumps(dict(self.record,accountHash='f'*64)))
        result=self.cli('run','--start-from-session='+self.thread,root=self.destination)
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('terminal-connected',result.stdout)
        for root in (self.source,self.destination):
            self.assertFalse(list((root/'codex-sessions').rglob('auth.json')))
        self.fixture.fixture.command('retire','--grant',self.record['grantId'])
        result=self.cli('run','--start-from-session='+self.thread,root=self.destination)
        self.assertNotEqual(result.returncode,0);self.assertNotIn('terminal-connected',result.stdout)
    def test_missing_malformed_symlink_and_wrong_binding_refuse(self):
        bundle=self.bundle()
        self.rollout.unlink()
        with self.assertRaises((ValueError,OSError)):self.bundle()
        other=self.wire.base/'outside';other.write_bytes(self.history);other.chmod(0o600)
        self.rollout.symlink_to(other)
        with self.assertRaises((ValueError,OSError)):self.bundle()
        self.rollout.unlink();os.link(other,self.rollout)
        with self.assertRaises((ValueError,OSError)):self.bundle()
        self.rollout.unlink();self.rollout.write_bytes(self.history);self.rollout.chmod(0o600)
        with patch.object(m,'LIMIT',32):
            with self.assertRaises(ValueError):self.bundle()
        self.rollout.write_text('{broken}\n')
        with self.assertRaises(ValueError):self.bundle()
        for changed in (dict(bundle,history='not-json\n'),dict(bundle,record=dict(self.record,profileId='00000000-0000-4000-8000-000000000099')),
                        dict(bundle,thread='other'),dict(bundle,cwd='../relative')):
            with self.assertRaises((ValueError,OSError)):m.receive(self.destination,changed)
        self.assertFalse(self.dest.thread_path(self.thread).exists())
    def test_interrupted_import_is_invisible_and_retryable(self):
        bundle=self.bundle()
        real=m.publish
        def interrupted(path,raw):
            if path==self.dest.thread_path(self.thread):raise OSError('before publication')
            return real(path,raw)
        with patch.object(m,'publish',side_effect=interrupted):
            with self.assertRaises(OSError):m.receive(self.destination,bundle)
        self.assertEqual(m.bridge.session_rows(self.destination),[])
        m.receive(self.destination,bundle)
        self.assertEqual(self.dest.read(self.thread)['record'],self.record)
        with self.assertRaises(ValueError):m.receive(self.destination,dict(bundle,model='other-model'))
        self.assertEqual(self.dest.model(self.thread),'chosen-model')
    def test_existing_history_and_symlink_destination_are_never_overwritten(self):
        bundle=self.bundle();home=Path(self.dest.home(self.record,str(self.cwd),self.destination/'Work/codex'))
        target=home/'sessions';outside=self.wire.base/'outside';outside.mkdir();target.symlink_to(outside)
        with self.assertRaises((ValueError,OSError)):m.receive(self.destination,bundle)
        self.assertEqual(list(outside.iterdir()),[]);target.unlink()
        m.receive(self.destination,bundle)
        with self.assertRaises(ValueError):m.receive(self.destination,dict(bundle,history=bundle['history']+json.dumps({'type':'event_msg','payload':{}})+'\n'))
    def test_link_publication_interruptions_reconcile_history_model_and_record(self):
        bundle=self.bundle();real=m.os.link
        for boundary in ('rollout','model','record'):
            with self.subTest(boundary=boundary):
                # Use a fresh destination cwd/home and thread per boundary.
                current=dict(bundle,thread=self.thread+'-'+boundary)
                current['history']=bundle['history'].replace(self.thread,current['thread'])
                record_path=self.dest.thread_path(current['thread'])
                def interrupted(source,target):
                    real(source,target)
                    target=Path(target)
                    hit=(boundary=='rollout' and target.name.startswith('rollout-') or
                         boundary=='model' and target.suffix=='.model' or
                         boundary=='record' and target==record_path)
                    if hit:raise OSError('after link before unlink')
                with patch.object(m.os,'link',side_effect=interrupted):
                    with self.assertRaises(OSError):m.receive(self.destination,current)
                if boundary!='record':self.assertFalse(record_path.exists())
                m.receive(self.destination,current)
                self.assertEqual(self.dest.read(current['thread'])['record'],self.record)
                self.assertFalse(list(self.dest.base.rglob('.import-*')))

    def test_unapproved_sender_cannot_publish(self):
        peer=self.destination/'fleet/peers'/self.wire.identities['client'].replace('/','_').replace('+','_').replace(':','_')
        path=peer/'meta';path.write_text(path.read_text().replace('state=approved','state=pending'))
        self.assertNotEqual(self.send().returncode,0)
        self.assertEqual(m.bridge.session_rows(self.destination),[])

if __name__=='__main__':unittest.main()
