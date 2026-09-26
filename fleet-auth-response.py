#!/usr/bin/env python3
"""Private owner-response codec. Secret payloads never enter a temporary file.

Use only over an authenticated encrypted carrier. Signatures authenticate these
bytes; they do not encrypt them. This module has no command-line secret output.
"""
import base64
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile
import time
import threading
import uuid

NAMESPACE = 'n2-agents-auth-response-v1'
MAX_BYTES = 128 * 1024
CONTEXT_KEYS = {'schemaVersion', 'owner', 'recipient', 'nonce', 'grantId',
                'ownershipGeneration', 'accountHash', 'expiresAt', 'rejectedTokenGeneration'}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate field')
        result[key] = value
    return result


def decode_json(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def valid_uuid(value):
    return isinstance(value, str) and str(uuid.UUID(value)) == value


def validate_context(context, now):
    if not isinstance(context, dict) or set(context) != CONTEXT_KEYS:
        raise ValueError('invalid request context')
    if type(context['schemaVersion']) is not int or context['schemaVersion'] != 1:
        raise ValueError('invalid schema')
    for field in ('owner', 'recipient'):
        if not isinstance(context[field], str) or not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', context[field]):
            raise ValueError('invalid peer identity')
    for field in ('nonce', 'accountHash'):
        if not isinstance(context[field], str) or not re.fullmatch('[0-9a-f]{64}', context[field]):
            raise ValueError('invalid request binding')
    if not valid_uuid(context['grantId']) or not valid_uuid(context['ownershipGeneration']):
        raise ValueError('invalid grant identity')
    rejected = context['rejectedTokenGeneration']
    if rejected is not None and not valid_uuid(rejected):
        raise ValueError('invalid rejected token generation')
    expiry = context['expiresAt']
    if type(expiry) not in (int, float) or not math.isfinite(expiry) or not now < expiry <= now + 30:
        raise ValueError('expired request')


def public_identity(public_key):
    """Accept an OpenSSH Ed25519 public key, never an authorized_keys option."""
    if not isinstance(public_key, bytes) or len(public_key) > 1024:
        raise ValueError('invalid public key')
    fields = public_key.strip().split()
    if len(fields) < 2 or fields[0] != b'ssh-ed25519' or b'\n' in public_key.strip():
        raise ValueError('invalid public key')
    blob = base64.b64decode(fields[1], validate=True)
    # SSH wire encoding: length-prefixed algorithm and 32-byte Ed25519 key.
    if len(blob) != 51 or blob[:19] != b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20':
        raise ValueError('invalid Ed25519 public key')
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip('=')
    return fingerprint, b'ssh-ed25519 ' + fields[1]


def public_signature(signature, public_key):
    # Never write an arbitrary response field to a temporary file. Parse the
    # public SSHSIG structure, then rebuild its armor before verification.
    lines = signature.strip().splitlines()
    if len(lines) < 3 or lines[0] != b'-----BEGIN SSH SIGNATURE-----' or lines[-1] != b'-----END SSH SIGNATURE-----':
        raise ValueError('invalid signature armor')
    blob = base64.b64decode(b''.join(lines[1:-1]), validate=True)
    if blob[:10] != b'SSHSIG\x00\x00\x00\x01':
        raise ValueError('invalid signature header')
    def field(data, offset):
        if offset + 4 > len(data):
            raise ValueError('truncated signature')
        size = int.from_bytes(data[offset:offset+4], 'big')
        end = offset + 4 + size
        if end > len(data):
            raise ValueError('truncated signature field')
        return data[offset+4:end], end
    key, offset = field(blob, 10)
    namespace, offset = field(blob, offset)
    reserved, offset = field(blob, offset)
    algorithm, offset = field(blob, offset)
    signed, offset = field(blob, offset)
    kind, inner = field(signed, 0)
    value, inner = field(signed, inner)
    if (offset != len(blob) or inner != len(signed) or kind != b'ssh-ed25519' or len(value) != 64
            or key != base64.b64decode(public_key.split()[1], validate=True)
            or namespace != NAMESPACE.encode() or reserved or algorithm not in (b'sha256', b'sha512')):
        raise ValueError('invalid signature structure')
    encoded = base64.b64encode(blob)
    return b'-----BEGIN SSH SIGNATURE-----\n' + b'\n'.join(encoded[i:i+70] for i in range(0, len(encoded), 70)) + b'\n-----END SSH SIGNATURE-----\n'


def validate_payload(payload, expected, now):
    if not isinstance(payload, dict) or set(payload) != {'context', 'tokenGeneration', 'accessToken', 'chatgptAccountId'}:
        raise ValueError('invalid response')
    validate_context(payload['context'], now)
    if canonical(payload['context']) != canonical(expected):
        raise ValueError('response does not match request')
    if not valid_uuid(payload['tokenGeneration']):
        raise ValueError('invalid token generation')
    if payload['tokenGeneration'] == expected['rejectedTokenGeneration']:
        raise ValueError('owner returned the rejected token generation')
    token, account = payload['accessToken'], payload['chatgptAccountId']
    if not isinstance(token, str) or not token or len(token.encode()) > 65536:
        raise ValueError('invalid access token')
    if not isinstance(account, str) or not account or len(account.encode()) > 1024 or any(ord(c) < 32 for c in account):
        raise ValueError('invalid account')


def sign_response(context, token_generation, token, account_id, key_path, deadline):
    """Owner-side response. The key path is a private local configuration input."""
    try:
        context = decode_json(canonical(context))
        if type(deadline) not in (int, float) or not math.isfinite(deadline) or deadline <= time.monotonic():
            raise ValueError('invalid signing deadline')
        now = time.time()
        validate_context(context, now)
        identity, _ = public_identity(Path(str(key_path) + '.pub').read_bytes())
        if identity != context['owner']:
            raise ValueError('wrong signing owner')
        payload = {'context': context, 'tokenGeneration': token_generation,
                   'accessToken': token, 'chatgptAccountId': account_id}
        validate_payload(payload, context, now)
        raw = canonical(payload)
        if len(raw) > MAX_BYTES or deadline <= time.monotonic():
            raise ValueError('response too large or expired')
        # ssh-keygen signs stdin to stdout when no input filename is supplied.
        # The only filesystem input is the owner's existing private signing key.
        result = subprocess.run(['ssh-keygen', '-Y', 'sign', '-q', '-f', str(key_path), '-n', NAMESPACE],
                                input=raw, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=deadline - time.monotonic(), check=True)
        if len(result.stdout) > 4096 or time.monotonic() >= deadline:
            raise ValueError('invalid signature response')
        validate_context(context, time.time())
        return canonical({'payload': base64.b64encode(raw).decode(),
                          'signature': base64.b64encode(result.stdout).decode()})
    except Exception:
        raise ValueError('fleet authentication response could not be signed') from None


class ResponseVerifier:
    """One request, one accepted response. Never log exceptions from a carrier.

    The caller retains this instance for its outstanding request and drops it
    after success or error. Nonces must be freshly generated for every request.
    """
    def __init__(self, context, owner_public_key, deadline):
        try:
            # Freeze the context so caller mutation cannot redirect acceptance.
            self.context = decode_json(canonical(context))
            validate_context(self.context, time.time())
            identity, self.public_key = public_identity(owner_public_key)
            if identity != self.context['owner']:
                raise ValueError('wrong owner key')
            if not math.isfinite(deadline) or deadline <= time.monotonic():
                raise ValueError('expired deadline')
            self.deadline = deadline
            self.used = False
            self.lock = threading.Lock()
        except Exception:
            raise ValueError('invalid fleet authentication request') from None

    def verify(self, response):
        try:
            with self.lock:
                if self.used:
                    raise ValueError('response already consumed')
                self.used = True
            if not isinstance(response, bytes) or len(response) > 2 * MAX_BYTES or time.monotonic() >= self.deadline:
                raise ValueError('invalid response size or deadline')
            validate_context(self.context, time.time())
            envelope = decode_json(response)
            if not isinstance(envelope, dict) or set(envelope) != {'payload', 'signature'}:
                raise ValueError('invalid envelope')
            raw = base64.b64decode(envelope['payload'], validate=True)
            signature = base64.b64decode(envelope['signature'], validate=True)
            if len(raw) > MAX_BYTES or not 0 < len(signature) <= 4096:
                raise ValueError('invalid envelope size')
            # ssh-keygen requires files for signature and allowed signers. They
            # contain only public material; secret-bearing signed bytes use stdin.
            with tempfile.TemporaryDirectory(prefix='n2-auth-verify-') as temp:
                sig = Path(temp) / 'signature'
                signers = Path(temp) / 'allowed-signers'
                sig.write_bytes(public_signature(signature, self.public_key))
                signers.write_bytes(self.context['owner'].encode() + b' ' + self.public_key + b'\n')
                subprocess.run(['ssh-keygen', '-Y', 'verify', '-f', str(signers), '-I', self.context['owner'],
                                '-n', NAMESPACE, '-s', str(sig)], input=raw, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=max(.001, self.deadline - time.monotonic()), check=True)
            if time.monotonic() >= self.deadline:
                raise ValueError('verification expired')
            payload = decode_json(raw)
            validate_payload(payload, self.context, time.time())
            return {key: payload[key] for key in ('tokenGeneration', 'accessToken', 'chatgptAccountId')}
        except Exception:
            raise ValueError('fleet authentication response rejected') from None
