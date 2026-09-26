#!/usr/bin/env python3
"""Run the native-generated command against disposable owner login endpoints."""
import importlib.util
import json
import os
import select
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
PLAN=sys.argv.pop(1)
spec=importlib.util.spec_from_file_location('fixture',ROOT/'scripts/test-fleet-auth-bridge.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)

class NativeCommandTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.BridgeIntegrationTests('test_restart_resumes_persisted_history_without_credentials')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.wire=self.fixture.wire
    def command(self,root):
        result=subprocess.run([PLAN,'--plan',str(ROOT/'agents'),'Work'],env=dict(os.environ,N2_AGENTS_ROOT=str(root)),
                              capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        args=json.loads(result.stdout)
        self.assertEqual(args[:4],['fleet','auth','login','Work']);self.assertNotIn('--replace-account',args)
        return args
    def execute(self,root,args):
        return subprocess.run([str(ROOT/'agents'),*args,'--timeout','15'],env=dict(os.environ,N2_AGENTS_ROOT=str(root)),
                              capture_output=True,text=True,timeout=25)
    def assert_original_active(self):
        with self.wire.store.locked(self.wire.grant,time.monotonic()+2) as grant:
            self.assertEqual(grant.public()['state'],'active')
    def test_generated_local_command_checks_revision_and_preserves_account(self):
        root=self.wire.base/'owner';args=self.command(root)
        stale=list(args);stale[-1]='f'*64
        before=(root/'Work/codex/.n2-owner.json').read_bytes()
        self.assertNotEqual(self.execute(root,stale).returncode,0)
        self.assertEqual((root/'Work/codex/.n2-owner.json').read_bytes(),before)
        result=self.execute(root,args);self.assertEqual(result.returncode,0,result.stderr)
        rows=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(rows[0]['status'],'login-required');self.assertEqual(rows[-1]['status'],'registered')
        self.assertEqual(rows[-1]['binding']['accountHash'],json.loads(before)['accountHash'])
        self.assert_original_active();self.assertFalse((root/'Work/codex/auth.json').exists())
    def test_generated_remote_command_requires_explicit_consent(self):
        root=self.fixture.root
        (root/'Work/codex/.n2-owner.json').unlink()
        synced=subprocess.run([str(ROOT/'agents'),'fleet','sync','now','--peer',self.wire.identities['owner']],
                              env=dict(os.environ,N2_AGENTS_ROOT=str(root)),capture_output=True,text=True,timeout=30)
        self.assertEqual(synced.returncode,0,synced.stderr)
        args=self.command(root)
        before=(root/'Work/codex/.n2-owner.json').read_bytes()
        self.assertNotEqual(self.execute(root,args).returncode,0)
        self.assertEqual((root/'Work/codex/.n2-owner.json').read_bytes(),before)
        self.fixture.fixture.command('allow-login','--peer',self.wire.identities['client'])
        gate=self.wire.base/'login-gate';os.mkfifo(gate)
        (self.wire.bin/'settings.json').write_text(json.dumps({'loginGate':str(gate)}))
        process=subprocess.Popen([str(ROOT/'agents'),*args,'--timeout','20'],env=dict(os.environ,N2_AGENTS_ROOT=str(root)),
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        try:
            line=b'';deadline=time.monotonic()+15
            while not line.endswith(b'\n'):
                self.assertTrue(select.select([process.stdout],[],[],max(0,deadline-time.monotonic()))[0],'challenge timed out')
                byte=process.stdout.read(1);self.assertTrue(byte,'login exited before challenge');line+=byte
            self.assertEqual(json.loads(line)['status'],'login-required')
            fd=os.open(gate,os.O_WRONLY|os.O_NONBLOCK);os.write(fd,b'g');os.close(fd)
            output,error=process.communicate(timeout=20)
            self.assertEqual(process.returncode,0,error)
            self.assertEqual(json.loads(output.splitlines()[-1])['localBinding'],'current')
        finally:
            if process.poll() is None:process.terminate();process.wait(timeout=10)
            process.stdout.close();process.stderr.close()
        saved=json.loads((root/'Work/codex/.n2-owner.json').read_text())
        self.assertEqual(saved['accountHash'],json.loads(before)['accountHash'])
        self.assertNotEqual(saved['grantId'],json.loads(before)['grantId'])
        self.assert_original_active();self.assertFalse((root/'Work/codex/auth.json').exists())

if __name__=='__main__':unittest.main()
