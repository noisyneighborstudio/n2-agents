#!/usr/bin/env python3
"""Use disposable signing keys and synthetic tokens; no provider access."""
import base64
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('auth_response', ROOT / 'fleet-auth-response.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class ResponseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.key = self.root / 'owner'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.public = Path(str(self.key) + '.pub').read_bytes()
        self.identity = m.public_identity(self.public)[0]
        self.context = {'schemaVersion': 1, 'owner': self.identity, 'recipient': 'SHA256:' + 'A'*43,
                        'nonce': secrets.token_hex(32), 'grantId': str(uuid.uuid4()),
                        'ownershipGeneration': str(uuid.uuid4()), 'accountHash': 'b'*64,
                        'expiresAt': time.time()+20, 'rejectedTokenGeneration': None}
        self.generation = str(uuid.uuid4()); self.token = 'SYNTHETIC-PRIVATE-ACCESS-TOKEN'

    def signed(self, context=None):
        return m.sign_response(context or self.context, self.generation, self.token, 'workspace', self.key, time.monotonic()+2)

    def verifier(self, context=None):
        return m.ResponseVerifier(context or self.context, self.public, time.monotonic()+2)

    def test_real_signatures_and_one_response_only(self):
        fp = subprocess.check_output(['ssh-keygen', '-lf', str(self.key)+'.pub'], text=True).split()[1]
        self.assertEqual(self.identity, fp)
        verifier = self.verifier(); response = self.signed()
        self.assertEqual(verifier.verify(response), {'tokenGeneration': self.generation, 'accessToken': self.token, 'chatgptAccountId': 'workspace'})
        with self.assertRaises(ValueError): verifier.verify(response)

    def test_every_request_binding_must_match(self):
        response = self.signed()
        for key, replacement in [('recipient', 'SHA256:'+'B'*43), ('nonce', 'c'*64),
                                  ('grantId', str(uuid.uuid4())), ('ownershipGeneration', str(uuid.uuid4())),
                                  ('accountHash', 'c'*64), ('rejectedTokenGeneration', str(uuid.uuid4())), ('expiresAt', self.context['expiresAt']-1)]:
            with self.subTest(key=key):
                changed = dict(self.context, **{key: replacement})
                with self.assertRaisesRegex(ValueError, 'response rejected'):
                    self.verifier(changed).verify(response)

    def test_rejected_generation_is_explicit_and_signed(self):
        self.context['rejectedTokenGeneration']=str(uuid.uuid4())
        self.assertEqual(self.verifier().verify(self.signed())['accessToken'],self.token)
        for value in ('', True, 1, 'unknown-generation'):
            with self.assertRaises(ValueError): self.verifier(dict(self.context,rejectedTokenGeneration=value))
        missing=dict(self.context); del missing['rejectedTokenGeneration']
        with self.assertRaises(ValueError): self.verifier(missing)

    def test_renewal_cannot_return_the_rejected_generation(self):
        self.context['rejectedTokenGeneration']=self.generation
        with self.assertRaises(ValueError): self.signed()
        # Model a buggy owner that signs a stale cache entry. The receiving
        # verifier must reject it independently of the owner's validation.
        with patch.object(m,'validate_payload',return_value=None):
            response=self.signed()
        with self.assertRaisesRegex(ValueError,'response rejected'):
            self.verifier().verify(response)

    def test_payload_tampering_and_failed_attempt_consume_request(self):
        response = self.signed(); tampered = json.loads(response)
        payload = json.loads(base64.b64decode(tampered['payload']))
        payload['accessToken'] = 'SUBSTITUTED-TOKEN'
        tampered['payload'] = base64.b64encode(m.canonical(payload)).decode()
        verifier = self.verifier()
        with self.assertRaises(ValueError): verifier.verify(m.canonical(tampered))
        with self.assertRaises(ValueError): verifier.verify(response)

    def test_expiry_and_monotonic_deadline(self):
        response = self.signed(); verifier = self.verifier()
        with patch.object(m.time, 'time', return_value=self.context['expiresAt']+1):
            with self.assertRaises(ValueError): verifier.verify(response)
        verifier = self.verifier()
        with patch.object(m.time, 'monotonic', return_value=verifier.deadline+1):
            with self.assertRaises(ValueError): verifier.verify(response)
        for expiry in (True, float('nan'), float('inf'), time.time()-1, time.time()+60):
            with self.assertRaises(ValueError): self.verifier(dict(self.context, expiresAt=expiry))

    def test_frozen_context_and_concurrent_replay(self):
        verifier = self.verifier(); response = self.signed()
        self.context['nonce'] = 'a'*64
        def attempt(_):
            try: verifier.verify(response); return True
            except ValueError: return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(attempt, range(8))), 1)

    def test_unknown_schema_invalid_owner_and_duplicate_envelope_fields(self):
        with self.assertRaises(ValueError): self.verifier(dict(self.context, schemaVersion=True))
        with self.assertRaises(ValueError): self.verifier(dict(self.context, owner='SHA256:'+'C'*43))
        for response in (b'{"payload":"x","payload":"y","signature":"z"}', b'[]', b'x'* (2*m.MAX_BYTES+1)):
            with self.assertRaises(ValueError): self.verifier().verify(response)
        with self.assertRaises(ValueError): m.public_identity(b'command="bad" '+self.public)
        with self.assertRaises(ValueError): m.public_identity(self.public+b'other-key\n')

    def test_secret_never_reaches_file_or_subprocess_arguments(self):
        written = []; commands = []
        real_write, real_run = Path.write_bytes, m.subprocess.run
        def write(path, data):
            written.append(data); return real_write(path, data)
        def run(command, **kwargs):
            commands.append(command); return real_run(command, **kwargs)
        with patch.object(Path, 'write_bytes', write), patch.object(m.subprocess, 'run', run):
            response = self.signed(); self.verifier().verify(response)
        self.assertEqual(len(written), 2)
        self.assertTrue(all(self.token.encode() not in value for value in written))
        self.assertNotIn(self.token, str(commands))
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['owner', 'owner.pub'])

    def test_malformed_signature_is_rejected_before_any_public_spool(self):
        response = json.loads(self.signed())
        response['signature'] = base64.b64encode(self.token.encode()).decode()
        with patch.object(Path, 'write_bytes', side_effect=AssertionError('must not write')) as write:
            with self.assertRaises(ValueError): self.verifier().verify(m.canonical(response))
            write.assert_not_called()

    def test_signing_deadline_cannot_be_unbounded(self):
        for deadline in (float('nan'), float('inf'), True, time.monotonic()-1):
            with self.assertRaises(ValueError):
                m.sign_response(self.context, self.generation, self.token, 'workspace', self.key, deadline)

    def test_errors_never_echo_provider_or_subprocess_secret(self):
        with patch.object(m.subprocess, 'run', side_effect=ValueError(self.token)):
            with self.assertRaises(ValueError) as error: self.signed()
        self.assertNotIn(self.token, str(error.exception))


if __name__ == '__main__': unittest.main()
