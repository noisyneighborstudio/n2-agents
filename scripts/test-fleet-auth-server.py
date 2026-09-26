#!/usr/bin/env python3
"""Signed fleet endpoint integration with synthetic SSH and provider processes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
from unittest.mock import patch
import uuid

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path)
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
wire=load('wire',ROOT/'scripts/test-fleet-auth-transport.py')
server=load('server',ROOT/'fleet-auth-server.py')
native_tests=load('native_tests',ROOT/'scripts/test-fleet-auth-native.py')

SSH='''#!/usr/bin/env python3
import os,subprocess,sys
from pathlib import Path
base=Path(os.environ['FIXTURE_ROOT']);repo=Path(os.environ['FIXTURE_REPO'])
env=dict(os.environ,N2_AGENTS_ROOT=str(base/'owner'),SSH_CONNECTION='127.0.0.1 12345 127.0.0.1 22')
if os.environ.get('NO_SSH'): env.pop('SSH_CONNECTION')
result=subprocess.run([str(repo/'agents'),'fleet','serve'],input=sys.stdin.buffer.read(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
sys.stdout.buffer.write(result.stdout);sys.exit(result.returncode)
'''

class ServerTests(wire.TransportTests):
    # Reuse setup only; transport-specific fixture mutation tests belong to its
    # own suite and are deliberately excluded below.
    def setUp(self):
        super().setUp()
        (self.bin/'ssh').write_text(SSH)
        (self.bin/'codex').write_bytes((ROOT/'tests/fake-owner-codex.py').read_bytes());(self.bin/'codex').chmod(0o700)
        (self.bin/'settings.json').write_text('{}')
        self.store=server.owner.OwnerStore(self.base/'owner/fleet/auth-owners',self.identities['owner'])
        record=self.store.create(str(uuid.uuid4()),native_tests.ACCOUNT)
        self.grant=record['grantId']
        with self.store.locked(self.grant,time.monotonic()+3) as grant:
            path=grant.provider_home/'auth.json'
            path.write_text(json.dumps({'tokens':{'access_token':'original-secret','account_id':'workspace'}}));path.chmod(0o600)
            record=grant.activate(native_tests.ACCOUNT,grant.credential_snapshot()['credentialRevision'])
            grant.consent(self.identities['client'],True)
        self.context.update(grantId=self.grant,ownershipGeneration=record['ownershipGeneration'],accountHash=native_tests.ACCOUNT)
        self.payload=self.base/'public-request';self.payload.write_text(json.dumps(self.context))

    def test_endpoint_fetch_and_native_renewal(self):
        first=self.exchange(timeout=5)
        self.assertEqual(first['accessToken'],'original-secret')
        self.context['rejectedTokenGeneration']=first['tokenGeneration']
        replacement=self.exchange(timeout=5)
        self.assertEqual(replacement['accessToken'],'rotated-secret')
        self.assertNotEqual(first['tokenGeneration'],replacement['tokenGeneration'])
        self.assertEqual(self.exchange(timeout=5),replacement)
        for path in self.base.rglob('*'):
            if path.is_file() and path.name not in ('auth.json','codex'):
                self.assertNotIn(b'rotated-secret',path.read_bytes(),str(path))

    def test_generic_send_refuses_token_verb_before_carrier(self):
        (self.bin/'ssh').write_text('#!/bin/sh\ntouch "$FIXTURE_ROOT/was-dialed"\nexit 99\n')
        for verb in ('auth-token', 'auth-token\nextra=x', r'auth-token\nextra=x', 'auth-token\r'):
            result=subprocess.run([str(ROOT/'agents'),'fleet','send',self.identities['owner'],
                                   '--verb',verb,'--payload-file',str(self.payload)],
                                  env=dict(os.environ,N2_AGENTS_ROOT=str(self.base/'client')),
                                  capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn(b'private-carrier-required' if verb == 'auth-token' else b'malformed-verb',result.stderr)
            self.assertFalse((self.base/'was-dialed').exists())

    def test_exec_carrier_clears_inherited_ssh_session(self):
        peer=self.base/'exec-peer';peer.mkdir()
        (peer/'meta').write_text('transport=exec\nhome='+str(self.base)+'\n')
        command=self.base/'capture-env'
        command.write_text('#!/bin/sh\n[ -z "$SSH_CONNECTION$SSH_CLIENT$SSH_TTY" ]\n')
        command.chmod(0o700)
        # Pass the executable through a dedicated fixture function without
        # changing the real private-carrier admission check.
        script='scripts_dir=$1; agent_path=$2; peer_path=$3; . "$scripts_dir/fleet.sh"; fleet_agents_cmd() { printf "%s\n" "$agent_path"; }; fleet_carry "$peer_path"'
        result=subprocess.run(['sh','-c',script,'fixture',str(ROOT),str(command),str(peer)],
                              env=dict(os.environ,SSH_CONNECTION='inherited',SSH_CLIENT='inherited',SSH_TTY='inherited'),capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_endpoint_requires_grant_consent_and_account(self):
        with self.store.locked(self.grant,time.monotonic()+2) as grant:
            grant.consent(self.identities['client'],False)
        with self.assertRaises(ValueError): self.exchange()
        with self.store.locked(self.grant,time.monotonic()+2) as grant:
            grant.consent(self.identities['client'],True)
        self.context['accountHash']='f'*64
        with self.assertRaises(ValueError): self.exchange()

    def test_endpoint_rejects_nonssh_delivery(self):
        with patch.dict(os.environ,{'NO_SSH':'1'}):
            with self.assertRaises(ValueError): self.exchange()

    def test_revocation_during_signing_releases_no_response(self):
        original=server.codec.sign_response
        def revoke(*args,**kwargs):
            result=original(*args,**kwargs)
            (self.base/'owner/fleet/revoked').write_text(self.identities['client']+' removed\n')
            return result
        with patch.object(server.codec,'sign_response',side_effect=revoke):
            with self.assertRaisesRegex(ValueError,'^owner request rejected$'):
                server.response(self.base/'owner',self.identities['client'],self.payload)

    def test_endpoint_rejects_spoofed_recipient_and_unknown_grant(self):
        with self.assertRaises(ValueError): server.response(self.base/'owner',self.identities['owner'],self.payload)
        self.context['grantId']=str(uuid.uuid4())
        with self.assertRaises(ValueError): self.exchange()

# Inherit the useful setup/helpers without duplicating the transport's tests.
for name in list(wire.TransportTests.__dict__):
    if name.startswith('test_') and name not in ServerTests.__dict__:
        setattr(ServerTests,name,None)

if __name__=='__main__': unittest.main()
