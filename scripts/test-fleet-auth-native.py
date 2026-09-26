#!/usr/bin/env python3
"""Native owner protocol tests with disposable synthetic app-server processes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
import uuid

ROOT=Path(__file__).resolve().parents[1]
def load(name, file):
    spec=importlib.util.spec_from_file_location(name, ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
owner=load('owner','fleet-auth-owner.py')
native=load('native','fleet-auth-native.py')
OWNER='SHA256:'+'A'*43
ACCOUNT=hashlib.sha256(json.dumps(['codex','https://chatgpt.com','workspace','fixture@example.invalid'],separators=(',',':')).encode()).hexdigest()

class NativeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.binary=self.base/'codex'
        self.binary.write_bytes((ROOT/'tests/fake-owner-codex.py').read_bytes());self.binary.chmod(0o700)
        self.mode('')
        self.store=owner.OwnerStore(self.base/'owners',OWNER)
        self.record=self.store.create(str(uuid.uuid4()),ACCOUNT)
        self.native=native.NativeOwner(str(self.binary))
        with self.lock() as grant:
            path=grant.provider_home/'auth.json'
            path.write_text(json.dumps({'tokens':{'access_token':'original-secret','account_id':'workspace'}}));path.chmod(0o600)
    def mode(self, mode): (self.base/'settings.json').write_text(json.dumps({'mode':mode}))
    def lock(self, seconds=5): return self.store.locked(self.record['grantId'],time.monotonic()+seconds)
    def activate(self):
        with self.lock() as grant: self.record=self.native.activate(grant)
    def request(self, grant, rejected=None):
        return self.native.request(grant,OWNER,self.record['ownershipGeneration'],ACCOUNT,rejected)
    def trace(self): return [json.loads(line) for line in (self.base/'trace.jsonl').read_text().splitlines()]
    def refreshes(self): return [r for r in self.trace() if r['refresh'] is True]

    def test_activation_renewal_and_stale_request_use_native_verified_account(self):
        with patch.dict(os.environ,{key:'must-not-inherit' for key in ('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','HTTPS_PROXY')}):
            self.activate()
            with self.lock() as grant:
                first=self.request(grant)
                next_token=self.request(grant,first['tokenGeneration'])
                again=self.request(grant,first['tokenGeneration'])
        self.assertEqual(next_token,again)
        self.assertEqual(next_token['accessToken'],'rotated-secret')
        self.assertNotEqual(next_token['tokenGeneration'],first['tokenGeneration'])
        self.assertEqual(len(self.refreshes()),1)
        for row in self.trace():
            if not row['managed']: self.assertFalse(Path(row['home']).exists())
        self.assertNotIn('secret',(self.base/'trace.jsonl').read_text())

    def test_changed_account_is_not_released(self):
        self.activate();self.mode('wrong-account')
        with self.lock() as grant:
            with self.assertRaisesRegex(RuntimeError,'^owner token request failed$'):
                self.request(grant,self.record['tokenGeneration'])
            self.assertEqual(grant.public()['state'],'reauth-required')
            with self.assertRaises(ValueError): grant.token()

    def test_uncertain_saved_result_can_be_reconciled_without_second_refresh(self):
        self.activate();self.mode('error-after-save')
        with self.lock() as grant:
            with self.assertRaisesRegex(RuntimeError,'^owner token request failed$'):
                self.request(grant,self.record['tokenGeneration'])
            self.assertEqual(grant.public()['state'],'renewing')
        self.mode('')
        with self.lock() as grant:
            with self.assertRaises(RuntimeError): self.request(grant,self.record['tokenGeneration'])
            self.native.reconcile(grant)
            self.assertEqual(grant.token()['accessToken'],'rotated-secret')
        self.assertEqual(len(self.refreshes()),1)

    def test_unchanged_token_requires_reauthentication(self):
        self.activate();self.mode('unchanged')
        with self.lock() as grant:
            with self.assertRaises(RuntimeError): self.request(grant,self.record['tokenGeneration'])
            self.assertEqual(grant.public()['state'],'reauth-required')
        self.assertEqual(len(self.refreshes()),1)

    def test_wrong_provider_does_not_send_refresh(self):
        self.activate();self.mode('wrong-provider')
        with self.lock() as grant:
            with self.assertRaises(RuntimeError): self.request(grant,self.record['tokenGeneration'])
        self.assertEqual(len(self.refreshes()),0)

    def test_failed_verification_does_not_activate(self):
        self.mode('verification-error')
        with self.lock() as grant:
            with self.assertRaisesRegex(RuntimeError,'^owner activation failed$'): self.native.activate(grant)
            self.assertEqual(grant.public()['state'],'pending-login')
            with self.assertRaises(ValueError): grant.token()

    def test_killed_owner_retains_lock_until_native_deadline(self):
        self.activate();self.mode('orphan')
        program = """
import importlib.util,sys,time
from pathlib import Path
root=Path(sys.argv[1])
def load(name,file):
 s=importlib.util.spec_from_file_location(name,root/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
owner=load('owner','fleet-auth-owner.py');native=load('native','fleet-auth-native.py')
store=owner.OwnerStore(sys.argv[2],sys.argv[3])
with store.locked(sys.argv[4],time.monotonic()+2) as grant:
 native.NativeOwner(sys.argv[5]).request(grant,sys.argv[3],sys.argv[6],sys.argv[7],sys.argv[8])
"""
        child=subprocess.Popen([sys.executable,'-c',program,str(ROOT),str(self.base/'owners'),OWNER,
                                self.record['grantId'],str(self.binary),self.record['ownershipGeneration'],
                                ACCOUNT,self.record['tokenGeneration']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            end=time.monotonic()+3
            while not (self.base/'refresh-started').exists():
                self.assertIsNone(child.poll())
                self.assertLess(time.monotonic(),end)
                time.sleep(.01)
            child.kill();child.wait(timeout=2)
            with self.assertRaises(TimeoutError):
                with self.lock(.2): pass
            # The supervisor owns the lock through the original operation's
            # deadline even after its caller dies, then kills the native group.
            self.mode('')
            with self.lock(4) as grant:
                self.assertEqual(grant.public()['state'],'renewing')
                self.native.reconcile(grant)
                self.assertEqual(grant.token()['accessToken'],'rotated-secret')
            self.assertEqual(len(self.refreshes()),1)
        finally:
            if child.poll() is None: child.kill()
            child.wait()

    def test_timed_out_refresh_remains_uncertain_and_cannot_retry(self):
        self.activate();self.mode('timeout')
        started=time.monotonic()
        with self.lock(.3) as grant:
            with self.assertRaises(RuntimeError): self.request(grant,self.record['tokenGeneration'])
        self.assertLess(time.monotonic()-started,4)
        with self.lock() as grant:
            self.assertEqual(grant.public()['state'],'renewing')
            with self.assertRaises(RuntimeError): self.request(grant,self.record['tokenGeneration'])
        self.assertEqual(len(self.refreshes()),1)

if __name__=='__main__': unittest.main()
