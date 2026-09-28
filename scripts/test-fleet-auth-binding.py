#!/usr/bin/env python3
"""Disposable public ownership-record validation and replacement tests."""
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import tempfile
import time
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('binding',ROOT/'fleet-auth-binding.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class BindingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.home=Path(self.temp.name);self.profile=str(uuid.uuid4())
        self.record={'schemaVersion':1,'provider':'codex','profileId':self.profile,
                     'grantId':str(uuid.uuid4()),'owner':'SHA256:'+'A'*43,
                     'ownershipGeneration':str(uuid.uuid4()),'accountHash':'a'*64,'credentialStore':'owner-file'}
    def test_roundtrip_and_explicit_replacement(self):
        revision=m.publish(self.home,self.record,self.profile)
        self.assertEqual(m.read(self.home,self.profile),(self.record,revision))
        replacement=dict(self.record,grantId=str(uuid.uuid4()),ownershipGeneration=str(uuid.uuid4()))
        with self.assertRaises(ValueError):m.publish(self.home,replacement,self.profile)
        self.assertEqual(m.read(self.home,self.profile)[0],self.record)
        next_revision=m.publish(self.home,replacement,self.profile,revision)
        self.assertNotEqual(next_revision,revision)
        with self.assertRaises(ValueError):m.publish(self.home,self.record,self.profile,revision)
    def test_unknown_schema_duplicates_and_profile_mismatch_preserve_bytes(self):
        path=self.home/m.MARKER
        for raw in (b'{"schemaVersion":2}',json.dumps(dict(self.record,profileId=str(uuid.uuid4()))).encode(),
                    json.dumps(self.record).replace('"schemaVersion": 1','"schemaVersion":1,"schemaVersion":1').encode()):
            path.write_bytes(raw);path.chmod(0o600)
            with self.assertRaises(ValueError):m.read(self.home,self.profile)
            import hashlib
            with self.assertRaises(ValueError):m.publish(self.home,self.record,self.profile,hashlib.sha256(raw).hexdigest())
            self.assertEqual(path.read_bytes(),raw)
    def test_cli_created_profile_accepts_public_binding_without_chmod(self):
        binary=self.home/'bin';binary.mkdir()
        (binary/'codex').write_text('#!/bin/sh\nexit 0\n');(binary/'codex').chmod(0o700)
        root=self.home/'profiles'
        result=subprocess.run([str(ROOT/'agents'),'new','Work','--vendors','codex'],
                              env=dict(os.environ,HOME=str(self.home),N2_AGENTS_ROOT=str(root),
                                       PATH=str(binary)+os.pathsep+os.environ['PATH']),
                              capture_output=True,umask=0o022)
        self.assertEqual(result.returncode,0,result.stderr)
        slot=root/'Work'/'codex'
        self.assertEqual(slot.stat().st_mode & 0o777,0o755)
        m.publish(slot,self.record,self.profile)
        self.assertEqual(slot.stat().st_mode & 0o777,0o755)
        self.assertEqual((slot/m.MARKER).stat().st_mode & 0o777,0o600)
        slot.chmod(0o777)
        with self.assertRaises(ValueError):m.read(slot,self.profile)
        with self.assertRaises(ValueError):m.publish(slot,self.record,self.profile)
        slot.chmod(0o755)

    def test_symlink_and_nonprivate_records_fail(self):
        path=self.home/m.MARKER;path.symlink_to(self.home/'elsewhere')
        with self.assertRaises(OSError):m.publish(self.home,self.record,self.profile)
        path.unlink();m.publish(self.home,self.record,self.profile);path.chmod(0o644)
        with self.assertRaises(ValueError):m.read(self.home,self.profile)
    def test_only_active_grant_can_publish_and_public_record_has_no_token_data(self):
        store=m.owner.OwnerStore(self.home/'owners',self.record['owner'])
        record=store.create(self.profile,self.record['accountHash'])
        with store.locked(record['grantId'],time.monotonic()+2) as grant:
            with self.assertRaises(ValueError):m.from_grant(grant,self.profile)
            path=grant.provider_home/'auth.json'
            path.write_text(json.dumps({'tokens':{'access_token':'synthetic-secret','account_id':'workspace'}}));path.chmod(0o600)
            grant.activate(self.record['accountHash'],grant.credential_snapshot()['credentialRevision'])
            public=m.from_grant(grant,self.profile)
            self.assertEqual(set(public),m.FIELDS)
            self.assertNotIn('synthetic-secret',json.dumps(public))
            with self.assertRaises(ValueError):m.from_grant(grant,str(uuid.uuid4()))
            grant.retire()
            with self.assertRaises(ValueError):m.from_grant(grant,self.profile)
if __name__=='__main__':unittest.main()
