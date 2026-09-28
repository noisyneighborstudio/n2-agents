#!/usr/bin/env python3
"""Disposable grant-state/crash fixtures. No provider calls or live credentials."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('owner', ROOT/'fleet-auth-owner.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
OWNER='SHA256:'+'A'*43
PEER='SHA256:'+'B'*43
ACCOUNT='a'*64


def write_credential(home, token):
    path=home/'auth.json'
    path.write_text(json.dumps({'tokens':{'access_token':token,'account_id':'workspace'}}))
    path.chmod(0o600)


class OwnerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.store=m.OwnerStore(self.base/'owners',OWNER)
        self.record=self.store.create(str(uuid.uuid4()),ACCOUNT)
        self.id=self.record['grantId']; self.directory=self.base/'owners'/self.id

    def lock(self, timeout=2):
        return self.store.locked(self.id,time.monotonic()+timeout)

    def activate(self):
        with self.lock() as grant:
            write_credential(grant.provider_home,'original-secret')
            revision=grant.credential_snapshot()['credentialRevision']
            record=grant.activate(ACCOUNT,revision)
            grant.consent(PEER,True)
            return record

    def test_new_grants_are_private_and_ineligible_until_verified(self):
        self.assertEqual(self.record['state'],'pending-login')
        self.assertFalse((self.directory/'codex/auth.json').exists())
        with self.lock() as grant:
            with self.assertRaises(ValueError): grant.token()
            with self.assertRaises(ValueError): grant.select(OWNER,self.record['ownershipGeneration'],ACCOUNT)
        active=self.activate()
        self.assertEqual(active['state'],'active')
        with self.lock() as grant:
            self.assertEqual(grant.token()['accessToken'],'original-secret')
            self.assertNotIn('credentialRevision',grant.public())
            self.assertNotIn('tokenDigest',grant.public())
        for path in (self.base/'owners',self.directory,self.directory/'codex',self.directory/'state.json',self.directory/'lock'):
            self.assertEqual(path.stat().st_mode & 0o077,0)

    def test_wrong_consent_generation_account_and_unknown_token_do_not_rotate(self):
        active=self.activate()
        with self.lock() as grant:
            for args in [('SHA256:'+'C'*43,active['ownershipGeneration'],ACCOUNT),
                         (PEER,str(uuid.uuid4()),ACCOUNT), (PEER,active['ownershipGeneration'],'b'*64)]:
                with self.assertRaises(ValueError): grant.select(*args)
            with self.assertRaises(ValueError): grant.select(PEER,active['ownershipGeneration'],ACCOUNT,str(uuid.uuid4()))
            self.assertEqual(grant.public()['state'],'active')
            self.assertEqual(grant.public()['tokenGeneration'],active['tokenGeneration'])
            grant.consent(PEER,False)
            with self.assertRaises(ValueError): grant.select(PEER,active['ownershipGeneration'],ACCOUNT)

    def test_stale_generation_coalesces_after_one_renewal(self):
        active=self.activate()
        with self.lock() as grant:
            self.assertEqual(grant.select(PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration']),'renew')
            persisted=json.loads((self.directory/'state.json').read_text())
            self.assertEqual(persisted['state'],'renewing')
            write_credential(grant.provider_home,'renewed-secret')
            new=grant.complete_renewal(ACCOUNT,grant.credential_snapshot()['credentialRevision'])
        with self.lock() as grant:
            self.assertEqual(grant.select(PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration']),'current')
            self.assertEqual(grant.token()['tokenGeneration'],new['tokenGeneration'])
            self.assertNotEqual(new['tokenGeneration'],active['tokenGeneration'])

    def test_changed_file_cannot_borrow_verification(self):
        with self.lock() as grant:
            write_credential(grant.provider_home,'first-secret')
            proof=grant.credential_snapshot()['credentialRevision']
            write_credential(grant.provider_home,'different-secret')
            with self.assertRaises(ValueError): grant.activate(ACCOUNT,proof)
            self.assertEqual(grant.public()['state'],'pending-login')
        active=self.activate()
        with self.lock() as grant:
            write_credential(grant.provider_home,'outside-change')
            with self.assertRaises(ValueError): grant.select(PEER,active['ownershipGeneration'],ACCOUNT)
            self.assertEqual(grant.public()['state'],'reauth-required')
            with self.assertRaises(ValueError): grant.token()

    def test_wrong_verified_account_requires_reauthentication(self):
        with self.lock() as grant:
            write_credential(grant.provider_home,'other-account-secret')
            with self.assertRaises(ValueError): grant.activate('b'*64,grant.credential_snapshot()['credentialRevision'])
            self.assertEqual(grant.public()['state'],'reauth-required')

    def test_creation_syncs_parent_entries_before_acknowledging(self):
        with patch.object(m, 'sync_directory', wraps=m.sync_directory) as sync:
            store=m.OwnerStore(self.base/'second-store', OWNER)
            record=store.create(str(uuid.uuid4()), ACCOUNT)
        self.assertEqual([call.args[0] for call in sync.call_args_list],
                         [self.base, store.directory/record['grantId'], store.directory])
        def fail_store_sync(path):
            if path == store.directory:
                raise OSError('simulated parent sync failure')
            return real_sync(path)
        real_sync=m.sync_directory
        with patch.object(m, 'sync_directory', side_effect=fail_store_sync):
            with self.assertRaisesRegex(OSError, 'parent sync failure'):
                store.create(str(uuid.uuid4()), ACCOUNT)
        with patch.object(m, 'sync_directory', side_effect=OSError('bootstrap sync failure')):
            with self.assertRaisesRegex(OSError, 'bootstrap sync failure'):
                m.OwnerStore(self.base/'third-store', OWNER)

    def test_invalid_account_identifiers_cannot_activate(self):
        with self.lock() as grant:
            for account in ('x'*1025, 'workspace\nother', 'workspace\x7f', ''):
                path=grant.provider_home/'auth.json'
                path.write_text(json.dumps({'tokens': {'access_token': 'secret', 'account_id': account}}))
                path.chmod(0o600)
                with self.assertRaisesRegex(ValueError, 'owner credential is invalid'):
                    grant.credential_snapshot()
                self.assertEqual(grant.public()['state'], 'pending-login')

    def test_failed_persistence_cannot_leave_usable_memory_state(self):
        with self.lock() as grant:
            write_credential(grant.provider_home,'secret')
            proof=grant.credential_snapshot()['credentialRevision']
            with patch.object(m.os,'replace',side_effect=OSError('simulated I/O failure')):
                with self.assertRaises(OSError): grant.activate(ACCOUNT,proof)
            with self.assertRaises(RuntimeError): grant.token()
        with self.lock() as grant:
            self.assertEqual(grant.public()['state'],'pending-login')

    def test_retirement_survives_restart_and_fences_old_binding(self):
        active=self.activate()
        with self.lock() as grant: grant.retire()
        self.store=m.OwnerStore(self.base/'owners',OWNER)
        with self.lock() as grant:
            self.assertEqual(grant.public()['state'],'retired')
            self.assertNotEqual(grant.public()['ownershipGeneration'],active['ownershipGeneration'])
            with self.assertRaises(ValueError): grant.select(PEER,active['ownershipGeneration'],ACCOUNT)
            with self.assertRaises(ValueError): grant.token()
            with self.assertRaises(ValueError): grant.activate(ACCOUNT,grant.credential_snapshot()['credentialRevision'])

    def test_closed_session_cannot_be_used_without_lock(self):
        self.activate()
        with self.lock() as grant: grant.public()
        with self.assertRaises(RuntimeError): grant.token()

    def test_unknown_schema_symlinks_and_nonprivate_state_are_rejected(self):
        state=self.directory/'state.json'; original=state.read_bytes()
        state.write_text('{"schemaVersion":999}')
        with self.assertRaises(ValueError):
            with self.lock(): pass
        state.write_bytes(original); state.chmod(0o644)
        with self.assertRaises(ValueError):
            with self.lock(): pass
        state.chmod(0o600); state.unlink(); state.symlink_to(self.base/'elsewhere')
        with self.assertRaises(OSError):
            with self.lock(): pass

    def test_lock_deadline_does_not_steal_live_owner(self):
        with self.lock():
            def attempt():
                with self.lock(.1): pass
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                with self.assertRaises(TimeoutError): pool.submit(attempt).result()

    def test_concurrent_processes_coalesce_one_provider_attempt(self):
        active=self.activate()
        program = r"""
import importlib.util,json,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('owner',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
base=Path(sys.argv[2]);s=m.OwnerStore(base/'owners',sys.argv[3])
while not (base/'go').exists(): time.sleep(.005)
with s.locked(sys.argv[4],time.monotonic()+4) as g:
    action=g.select(sys.argv[5],sys.argv[6],sys.argv[7],sys.argv[8])
    if action=='renew':
        with (base/'provider-attempts').open('a') as out: out.write('attempt\n')
        time.sleep(.05)
        path=g.provider_home/'auth.json'
        path.write_text(json.dumps({'tokens':{'access_token':'renewed-secret','account_id':'workspace'}}));path.chmod(0o600)
        g.complete_renewal(sys.argv[7],g.credential_snapshot()['credentialRevision'])
    print(g.public()['tokenGeneration'])
"""
        workers=[subprocess.Popen([sys.executable,'-c',program,str(ROOT/'fleet-auth-owner.py'),str(self.base),OWNER,self.id,
                                  PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration']],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(8)]
        try:
            (self.base/'go').touch()
            generations=[]
            for worker in workers:
                out,err=worker.communicate(timeout=6)
                self.assertEqual(worker.returncode,0,err)
                generations.append(out.strip())
            self.assertEqual(len(set(generations)),1)
            self.assertNotEqual(generations[0],active['tokenGeneration'])
            self.assertEqual((self.base/'provider-attempts').read_text(),'attempt\n')
            state=(self.directory/'state.json').read_text()
            self.assertNotIn('original-secret',state)
            self.assertNotIn('renewed-secret',state)
        finally:
            for worker in workers:
                if worker.poll() is None: worker.kill()
                worker.wait()

    def test_persisted_new_credential_can_complete_interrupted_renewal(self):
        active=self.activate()
        with self.lock() as grant:
            self.assertEqual(grant.select(PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration']),'renew')
            write_credential(grant.provider_home,'durably-rotated-secret')
        # A restarted owner must independently verify the new snapshot before
        # supplying the matching revision to completion. This fixture supplies
        # synthetic verification evidence, not a provider-authentication claim.
        self.store=m.OwnerStore(self.base/'owners',OWNER)
        with self.lock() as grant:
            snapshot=grant.credential_snapshot()
            record=grant.complete_renewal(ACCOUNT,snapshot['credentialRevision'])
            self.assertEqual(record['state'],'active')
            self.assertNotEqual(record['tokenGeneration'],active['tokenGeneration'])

    def test_crashed_renewal_is_not_automatically_repeated(self):
        active=self.activate()
        program='''
import importlib.util,os,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('owner',sys.argv[1]); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
s=m.OwnerStore(sys.argv[2],sys.argv[3])
with s.locked(sys.argv[4],time.monotonic()+2) as g:
    assert g.select(sys.argv[5],sys.argv[6],sys.argv[7],sys.argv[8])=='renew'
    os._exit(17)
'''
        result=subprocess.run([sys.executable,'-c',program,str(ROOT/'fleet-auth-owner.py'),str(self.base/'owners'),OWNER,self.id,PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration']])
        self.assertEqual(result.returncode,17)
        with self.lock() as grant:
            self.assertEqual(grant.public()['state'],'renewing')
            with self.assertRaises(ValueError): grant.select(PEER,active['ownershipGeneration'],ACCOUNT,active['tokenGeneration'])
            with self.assertRaises(ValueError): grant.complete_renewal(ACCOUNT,grant.credential_snapshot()['credentialRevision'])
            self.assertEqual(grant.public()['state'],'reauth-required')


if __name__=='__main__': unittest.main()
