#!/usr/bin/env python3
"""Claude token sharing over the private fleet carrier, with synthetic SSH.

organization() is the only network call. Each side stubs it in its own
process: this test in-process, the fake ssh in the owner's serve process.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


wire = load('wire', ROOT / 'scripts/test-fleet-auth-transport.py')
share = load('share', ROOT / 'fleet-claude-token.py')

SSH = '''#!/usr/bin/env python3
import hashlib, importlib.util, json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(os.environ['FIXTURE_ROOT']); repo = pathlib.Path(os.environ['FIXTURE_REPO'])
(root/'dialed').touch()
request = sys.stdin.buffer.read()
with tempfile.TemporaryDirectory(dir=root) as temp:
    temp = pathlib.Path(temp); (temp/'request').write_bytes(request)
    script = 'root=$1; scripts_dir=$2; . "$scripts_dir/fleet.sh"; fleet_verify "$3" "$4"'
    sender = subprocess.run(['sh','-c',script,'fixture',str(root/'owner'),str(repo),str(temp/'request'),str(temp/'verified')],
                            capture_output=True,check=True).stdout.decode().strip()
    assert b'verb=claude-token\\n' in (temp/'verified/signed').read_bytes()
    spec = importlib.util.spec_from_file_location('share', repo/'fleet-claude-token.py')
    share = importlib.util.module_from_spec(spec); spec.loader.exec_module(share)
    orgs = json.loads((root/'orgs.json').read_text())
    share.claude.organization = lambda token: orgs.get(hashlib.sha256(token.encode()).hexdigest())
    reply = share.serve(root/'owner', sender, temp/'verified/payload')
sys.stdout.buffer.write(reply)
'''
ORG = '11111111-1111-4111-8111-111111111111'


def token():
    return share.claude.PREFIX + secrets.token_urlsafe(70)[:93] + 'AA'


class ClaudeTokenShareTests(wire.TransportTests):
    def setUp(self):
        super().setUp()
        (self.bin / 'ssh').write_text(SSH)
        self.profile_id = str(uuid.uuid4())
        self.token = token()
        self.orgs({self.token: ORG})
        self.owner_slot = self.slot('owner', 'seth@example.com')
        self.client_slot = self.slot('client', 'Seth@Example.com')
        share.claude.write(self.owner_slot, self.token)

    def orgs(self, mapping):
        (self.base / 'orgs.json').write_text(json.dumps({hashlib.sha256(t.encode()).hexdigest(): o for t, o in mapping.items()}))

    def slot(self, name, email, org=ORG):
        profile = self.base / name / 'Work'
        (profile / 'claude').mkdir(parents=True, exist_ok=True)
        (profile / '.n2-profile').write_text(json.dumps({'schemaVersion': 1, 'profileId': self.profile_id}))
        (profile / 'claude/.claude.json').write_text(json.dumps({'oauthAccount': {'emailAddress': email, 'organizationUuid': org}}))
        return profile / 'claude'

    def pull(self, organization=ORG):
        with patch.object(share.claude, 'organization', return_value=organization):
            share.pull(self.base / 'client', 'Work', self.identities['owner'])

    def assertNothingSaved(self):
        self.assertIsNone(share.claude.read(self.client_slot))

    def test_same_account_pull_saves_token(self):
        self.pull()
        self.assertEqual(share.claude.read(self.client_slot), self.token)
        allowed = {self.owner_slot / 'settings.json', self.client_slot / 'settings.json'}
        for path in self.base.rglob('*'):
            if path.is_file() and path not in allowed:
                self.assertNotIn(self.token.encode(), path.read_bytes(), str(path))

    def test_other_member_of_the_organization_gets_nothing(self):
        self.slot('client', 'someone-else@example.com')
        with self.assertRaises(ValueError): self.pull()
        self.assertNothingSaved()

    def test_slot_without_cached_signin_never_dials(self):
        (self.client_slot / '.claude.json').unlink()
        with self.assertRaisesRegex(ValueError, 'no cached sign-in'): self.pull()
        self.assertFalse((self.base / 'dialed').exists())
        self.assertNothingSaved()

    def test_owner_refuses_a_token_of_another_organization(self):
        self.orgs({self.token: '22222222-2222-4222-8222-222222222222'})
        with self.assertRaises(ValueError): self.pull()
        self.assertTrue((self.base / 'dialed').exists())
        self.assertNothingSaved()

    def test_receiver_rechecks_the_organization(self):
        with self.assertRaisesRegex(ValueError, 'another account'):
            self.pull('22222222-2222-4222-8222-222222222222')
        self.assertNothingSaved()

    def test_pending_or_revoked_requester_gets_nothing(self):
        peer = self.base / 'owner/fleet/peers' / self.identities['client'].replace('/', '_').replace('+', '_').replace(':', '_')
        original = (peer / 'meta').read_text()
        (peer / 'meta').write_text(original.replace('state=approved', 'state=pending'))
        with self.assertRaises(ValueError): self.pull()
        (peer / 'meta').write_text(original)
        (self.base / 'owner/fleet/revoked').write_text(self.identities['client'] + ' removed\n')
        with self.assertRaises(ValueError): self.pull()
        self.assertNothingSaved()

    def request_context(self, **change):
        value = {'schemaVersion': 1, 'owner': self.identities['owner'], 'recipient': self.identities['client'],
                 'nonce': secrets.token_hex(32), 'expiresAt': time.time() + 20, 'profileId': self.profile_id,
                 'accountHash': share.account_hash(self.client_slot)}
        value.update(change)
        return value

    def test_replayed_or_misbound_reply_is_refused(self):
        context = self.request_context()
        reply = share.sign(context, self.token, self.base / 'owner/fleet/identity/id_ed25519', time.monotonic() + 5)
        verifier = share.Verifier(context, self.public, time.monotonic() + 5)
        self.assertEqual(verifier.verify(reply), self.token)
        with self.assertRaises(ValueError): verifier.verify(reply)
        with self.assertRaises(ValueError):  # the same reply to a fresh request
            share.Verifier(self.request_context(), self.public, time.monotonic() + 5).verify(reply)
        with self.assertRaises(ValueError):  # addressed to another machine
            share.Verifier(dict(context, recipient=self.identities['owner']), self.public, time.monotonic() + 5).verify(reply)
        # An owner never answers a request naming a recipient other than its sender.
        request = self.base / 'request'; request.write_bytes(share.codec.canonical(context))
        with patch.object(share.claude, 'organization', return_value=ORG):
            self.assertTrue(share.serve(self.base / 'owner', self.identities['client'], request))
            with self.assertRaises(ValueError): share.serve(self.base / 'owner', self.identities['owner'], request)

    def test_notice_pulls_only_for_the_same_account(self):
        notice = self.base / 'notice'
        notice.write_bytes(share.announce(self.base / 'owner', 'Work'))
        self.assertNotIn(self.token.encode(), notice.read_bytes())
        def run():
            with patch.object(share.claude, 'organization', return_value=ORG):
                return share.notice(self.base / 'client', self.identities['owner'], notice)
        self.slot('client', 'someone-else@example.com')
        self.assertEqual(run(), 'skipped other-account')
        (self.client_slot / '.claude.json').unlink()
        self.assertEqual(run(), 'skipped not-signed-in')
        self.assertFalse((self.base / 'dialed').exists())
        self.slot('client', 'SETH@example.com')
        self.assertEqual(run(), 'saved')
        self.assertEqual(share.claude.read(self.client_slot), self.token)
        (self.base / 'client/Work/.n2-profile').write_text(json.dumps({'schemaVersion': 1, 'profileId': str(uuid.uuid4())}))
        self.assertEqual(run(), 'skipped no-profile')

    def test_serve_needs_the_encrypted_carrier_and_send_cannot_carry_it(self):
        request = self.base / 'request'; request.write_bytes(share.codec.canonical(self.request_context()))
        env = {key: value for key, value in os.environ.items() if key != 'SSH_CONNECTION'}
        result = subprocess.run(['/usr/bin/python3', str(ROOT / 'fleet-claude-token.py'), 'serve', str(self.base / 'owner'),
                                 self.identities['client'], str(request)], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, b'')
        result = subprocess.run([str(ROOT / 'agents'), 'fleet', 'send', self.identities['owner'], '--verb', 'claude-token',
                                 '--payload-file', str(request)], env=dict(os.environ, N2_AGENTS_ROOT=str(self.base / 'client')),
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'private-carrier-required', result.stderr)
        self.assertFalse((self.base / 'dialed').exists())


# Inherit the transport fixture without rerunning the transport's own tests.
for name in list(wire.TransportTests.__dict__):
    if name.startswith('test_') and name not in ClaudeTokenShareTests.__dict__:
        setattr(ClaudeTokenShareTests, name, None)

if __name__ == '__main__': unittest.main()
