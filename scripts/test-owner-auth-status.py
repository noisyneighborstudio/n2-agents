#!/usr/bin/env python3
"""Authentication presence is an owner observation, not a local credential-file test."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
PARSER=sys.argv.pop(1) if len(sys.argv)>1 and not sys.argv[1].startswith('-') else None
spec=importlib.util.spec_from_file_location('fixture',ROOT/'scripts/test-fleet-auth-bridge.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)

class OwnerAuthTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixture.BridgeIntegrationTests('test_restart_resumes_persisted_history_without_credentials')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp()
        self.wire=self.fixture.wire;self.root=self.wire.base/'owner'
        self.slot=self.root/'Work/codex'
    def check_status(self,root,expected):
        trace=self.wire.bin/'trace.jsonl';before=trace.read_bytes() if trace.exists() else None
        files=list((self.root/'fleet/auth-owners').rglob('*.json'))+list(root.glob('Work/codex/.n2-*.json'))
        saved={path:hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        snapshots=[]
        for args in [('authed','Work'),('porcelain',)]:
            result=subprocess.run([str(ROOT/'agents'),*args],env=dict(os.environ,N2_AGENTS_ROOT=str(root)),
                                  capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            rows=[line.split('\t') for line in result.stdout.splitlines()]
            values=[row[1] for row in rows if row[0]=='codex'] if args[0]=='authed' else [row[5] for row in rows if row[:3]==['S','Work','codex']]
            self.assertEqual(values,[expected],result.stdout)
            self.assertNotIn('original-secret',result.stdout+result.stderr)
            snapshots.append(result.stdout)
        self.assertEqual(trace.read_bytes() if trace.exists() else None,before,'status contacted provider')
        self.assertEqual({path:hashlib.sha256(path.read_bytes()).hexdigest() for path in files},saved)
        if PARSER:
            result=subprocess.run([PARSER,expected],input=json.dumps(snapshots),capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
    def test_active_and_retired_owner_without_local_credentials(self):
        self.assertFalse((self.slot/'auth.json').exists())
        self.check_status(self.root,'yes')
        self.fixture.fixture.command('retire','--grant',self.wire.grant)
        self.check_status(self.root,'no')
    def test_remote_owner_is_unverified_even_when_offline(self):
        self.check_status(self.fixture.root,'unknown')
        (self.wire.bin/'ssh').write_text('#!/bin/sh\nexit 99\n')
        self.check_status(self.fixture.root,'unknown')
    def test_invalid_and_pending_never_fall_back_to_local_file(self):
        (self.slot/'auth.json').write_text('{"synthetic":true}')
        marker=self.slot/'.n2-owner.json';marker.write_text('{}')
        self.check_status(self.root,'unknown')
        marker.unlink();(self.slot/'.n2-migration.json').write_text('{}')
        self.check_status(self.root,'unknown')
    def test_conflict_without_binding_never_falls_back(self):
        (self.slot/'.n2-owner.json').unlink();(self.slot/'auth.json').write_text('{}')
        conflict=self.root/'fleet/sync/conflicts'/hashlib.sha256(b'settings|Work|codex|.n2-owner.json').hexdigest()[:12]
        conflict.mkdir(parents=True)
        self.check_status(self.root,'unknown')
    def test_unmanaged_presence_stays_compatible(self):
        (self.slot/'.n2-owner.json').unlink()
        self.check_status(self.root,'no')
        (self.slot/'auth.json').write_text('{"synthetic":true}')
        self.check_status(self.root,'yes')
    def test_missing_or_changed_owner_credential_is_unknown(self):
        with self.wire.store.locked(self.wire.grant,time.monotonic()+2) as grant:
            credential=grant.provider_home/'auth.json'
        original=credential.read_bytes();credential.unlink()
        self.check_status(self.root,'unknown')
        credential.write_bytes(original+b' ');credential.chmod(0o600)
        self.check_status(self.root,'unknown')
    def test_uncertain_and_reauth_owner_states(self):
        for state,expected in [('renewing','unknown'),('reauth-required','no')]:
            with self.wire.store.locked(self.wire.grant,time.monotonic()+2) as grant:
                grant.state['state']=state;grant._save()
            self.check_status(self.root,expected)

if __name__=='__main__':unittest.main()
