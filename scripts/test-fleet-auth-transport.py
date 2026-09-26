#!/usr/bin/env python3
"""Exercise real fleet framing with a synthetic SSH carrier and disposable keys."""
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('transport', ROOT / 'fleet-auth-transport.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

SSH = '''#!/usr/bin/env python3
import base64, importlib.util, json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
repo = pathlib.Path(os.environ['FIXTURE_REPO'])
args = sys.argv[1:]
(root/'ssh-args').write_text(json.dumps(args))
assert 'StrictHostKeyChecking=yes' in args
assert 'GlobalKnownHostsFile=/dev/null' in args
assert 'KnownHostsCommand=none' in args
assert 'ControlPath=none' in args
assert 'IdentitiesOnly=yes' in args
mode = os.environ.get('FIXTURE_MODE', '')
if mode == 'timeout': time.sleep(30)
if mode == 'large':
    sys.stdout.write('x' * 300000); sys.stdout.flush(); sys.exit(0)
if mode == 'descendant':
    if os.fork() == 0:
        (root/'descendant').write_text(str(os.getpid())); time.sleep(30); os._exit(0)
    time.sleep(.03); os._exit(0)
request = sys.stdin.buffer.read()
with tempfile.TemporaryDirectory(dir=root) as temp:
    temp = pathlib.Path(temp); (temp/'request').write_bytes(request)
    script = 'root=$1; scripts_dir=$2; . "$scripts_dir/fleet.sh"; fleet_verify "$3" "$4"'
    checked = subprocess.run(['sh','-c',script,'fixture',str(root/'owner'),str(repo),str(temp/'request'),str(temp/'verified')],capture_output=True,check=True)
    signed = (temp/'verified/signed').read_bytes()
    payload = base64.b64decode(signed.split(b'\\n--\\n')[1])
    context = json.loads(payload)
    assert checked.stdout.decode().strip() == context['recipient']
    assert b'verb=auth-token\\n' in signed
spec = importlib.util.spec_from_file_location('codec', repo/'fleet-auth-response.py')
codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(codec)
response = codec.sign_response(context, '00000000-0000-4000-8000-000000000001',
    'SYNTHETIC-TRANSPORT-TOKEN', 'workspace', root/'owner/fleet/identity/id_ed25519', time.monotonic()+2)
if mode == 'revoke':
    peer = root/'client/fleet/revoked'; peer.write_text(context['owner']+' removed\\n')
if mode == 'bad-response': response = b'private-provider-error-not-for-user'
sys.stdout.buffer.write(response); sys.stdout.flush()
if mode == 'nonzero': sys.exit(7)
'''


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='n2-auth-wire-'); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name); self.identities = {}
        fixture_home = self.base/'home'; fixture_home.mkdir()
        self.env = patch.dict(os.environ, {'FIXTURE_ROOT': str(self.base), 'FIXTURE_REPO': str(ROOT), 'N2_FLEET_QA': '', 'HOME': str(fixture_home)})
        self.env.start(); self.addCleanup(self.env.stop)
        for name in ('client','owner'):
            root = self.base/name
            subprocess.run([str(ROOT/'agents'),'fleet','init','--machine',name],
                           env=dict(os.environ,N2_AGENTS_ROOT=str(root)),stdout=subprocess.DEVNULL,check=True)
            self.identities[name] = m.codec.public_identity((root/'fleet/identity/id_ed25519.pub').read_bytes())[0]
        for name, other in (('client','owner'),('owner','client')):
            identity = self.identities[other]
            peer = self.base/name/'fleet/peers'/identity.replace('/','_').replace('+','_').replace(':','_')
            peer.mkdir()
            public = (self.base/other/'fleet/identity/id_ed25519.pub').read_bytes()
            (peer/'key.pub').write_bytes(public); (peer/'host.pub').write_bytes(public)
            (peer/'meta').write_text('peer='+identity+'\nstate=approved\ntransport=ssh\naddress=fixture.invalid\nuser=fixture\ncommand=agents\nmachine='+other+'\n')
        self.bin = self.base/'bin'; self.bin.mkdir()
        (self.bin/'ssh').write_text(SSH); (self.bin/'ssh').chmod(0o700)
        self.path = patch.dict(os.environ, {'PATH':str(self.bin)+os.pathsep+os.environ['PATH']})
        self.path.start(); self.addCleanup(self.path.stop)
        self.context = {'schemaVersion':1,'owner':self.identities['owner'],'recipient':self.identities['client'],
                        'nonce':secrets.token_hex(32),'grantId':str(uuid.uuid4()),'ownershipGeneration':str(uuid.uuid4()),
                        'accountHash':'a'*64,'expiresAt':time.time()+20, 'rejectedTokenGeneration':None}
        self.public = (self.base/'owner/fleet/identity/id_ed25519.pub').read_bytes()
        self.peer = self.base/'client/fleet/peers'/self.identities['owner'].replace('/','_').replace('+','_').replace(':','_')

    def exchange(self, mode='', timeout=3):
        with patch.dict(os.environ, {'FIXTURE_MODE':mode}):
            return m.exchange(self.base/'client',self.context,self.public,time.monotonic()+timeout)

    def test_signed_request_and_memory_only_verified_response(self):
        result = self.exchange()
        self.assertEqual(result['accessToken'],'SYNTHETIC-TRANSPORT-TOKEN')
        for path in self.base.rglob('*'):
            if path.is_file() and path.name != 'ssh':
                self.assertNotIn(b'SYNTHETIC-TRANSPORT-TOKEN',path.read_bytes(),str(path))
        args = json.loads((self.base/'ssh-args').read_text())
        self.assertIn('ControlMaster=no',args)
        self.assertIn('ControlPersist=no',args)
        self.assertNotIn('SYNTHETIC-TRANSPORT-TOKEN',str(args))

    def test_unapproved_or_unencrypted_route_never_dials(self):
        original = (self.peer/'meta').read_text()
        for replacement in (original.replace('state=approved','state=pending'), original.replace('transport=ssh','transport=exec'),original+'bootstrap=1\n'):
            (self.peer/'meta').write_text(replacement)
            with self.assertRaises(ValueError): self.exchange()
            self.assertFalse((self.base/'ssh-args').exists())

    def test_revocation_and_failed_carrier_reject_valid_token(self):
        for mode in ('nonzero','revoke'):
            (self.base/'client/fleet/revoked').write_text('')
            self.context['nonce']=secrets.token_hex(32)
            with self.assertRaisesRegex(ValueError,'owner unavailable or response rejected'):
                self.exchange(mode)

    def test_large_error_and_hung_carriers_are_bounded_and_redacted(self):
        for mode in ('large','bad-response','timeout'):
            self.context['nonce']=secrets.token_hex(32)
            started=time.monotonic()
            with self.assertRaises(ValueError) as error: self.exchange(mode,timeout=.5)
            self.assertEqual(str(error.exception),'fleet authentication owner unavailable or response rejected')
            self.assertLess(time.monotonic()-started,2)

    def test_descendant_inheriting_stdout_is_reaped(self):
        with self.assertRaises(ValueError): self.exchange('descendant',timeout=.7)
        pid=int((self.base/'descendant').read_text())
        result=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
        self.assertTrue(not result or result.startswith('Z'))

    def test_route_changes_after_precheck_cannot_change_carrier(self):
        payload=self.base/'request'; payload.write_bytes(m.codec.canonical(self.context))
        original=(self.peer/'meta').read_text()
        sentinel=self.base/'unexpected-carrier'
        carrier=self.base/'unexpected-exec'
        carrier.write_text('#!/bin/sh\ntouch "$FIXTURE_ROOT/unexpected-carrier"\n')
        carrier.chmod(0o700)
        script = r"""
        root=$1; scripts_dir=$2; peer_dir=$3; payload=$4; owner=$5; replacement=$6; carrier=$7; sentinel=$8
        . "$scripts_dir/fleet.sh"
        fleet_envelope() { printf request; printf '%s' "$replacement" > "$peer_dir/meta"; }
        fleet_agents_cmd() { printf '%s\n' "$carrier"; }
        fleet_ssh_run() { touch "$sentinel"; }
        fleet_auth_call "$owner" "$payload"
        """
        for replacement in (original.replace('transport=ssh','transport=exec')+'home='+str(self.base/'owner')+'\n', original+'bootstrap=1\n'):
            (self.peer/'meta').write_text(original)
            result=subprocess.run(['sh','-c',script,'fixture',str(self.base/'client'),str(ROOT),str(self.peer),str(payload),
                                   self.identities['owner'],replacement,str(carrier),str(sentinel)],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(sentinel.exists())

    def test_wrong_recipient_never_dials(self):
        self.context['recipient']=self.identities['owner']
        with self.assertRaises(ValueError): self.exchange()
        self.assertFalse((self.base/'ssh-args').exists())


if __name__ == '__main__': unittest.main()
