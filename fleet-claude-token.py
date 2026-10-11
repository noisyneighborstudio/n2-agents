#!/usr/bin/env python3
"""Share a Claude slot's long-lived token with the same account on approved peers.

Same account means a cached sign-in whose email and organization both match,
whatever the profile is called: a team organization has many members.
Requests and replies ride fleet-auth-transport, the private carrier built for Codex owner
tokens: pinned ssh only, a fresh nonce, exact owner and recipient binding, a
short expiry and one accepted reply. The token exists only in memory and in
each slot's settings.json. Nothing here prints it.
"""
import base64
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


transport = load('n2_claude_share_transport', 'fleet-auth-transport.py')
claude = load('n2_claude_share_token', 'claude-token.py')
metadata = load('n2_claude_share_metadata', 'profile-metadata.py')
codec = transport.codec
NAMESPACE = 'n2-agents-claude-token-v1'
FIELDS = {'schemaVersion', 'owner', 'recipient', 'nonce', 'expiresAt', 'accountHash'}
NO_GRANT = '00000000-0000-0000-0000-000000000000'
MAX_BYTES = 8192


def account_hash(cfg):
    """The slot's cached sign-in as one value, or None without one."""
    try:
        with open(os.path.join(cfg, '.claude.json')) as f:
            account = json.load(f).get('oauthAccount') or {}
        email, org = account.get('emailAddress'), account.get('organizationUuid')
    except (OSError, ValueError, AttributeError):
        return None
    if not (isinstance(email, str) and email and isinstance(org, str) and org):
        return None
    return hashlib.sha256(f'n2-claude-account-v1\0{email.lower()}\0{org}'.encode()).hexdigest()


def slots(root, account):
    """Every Claude slot on this Mac signed in to `account`."""
    found = []
    for row in metadata.report(root, None)['profiles']:
        cfg = Path(root) / row['name'] / 'claude'
        if cfg.is_dir() and account_hash(cfg) == account:
            found.append(cfg)
    return found


def identity(root):
    return codec.public_identity(transport.bounded_file(Path(root) / 'fleet/identity/id_ed25519.pub', 1024))[0]


def validate_context(context):
    if not isinstance(context, dict) or set(context) != FIELDS:
        raise ValueError('invalid claude token request')
    codec.validate_context(dict(context, grantId=NO_GRANT, ownershipGeneration=NO_GRANT,
                                rejectedTokenGeneration=None), time.time())


def sign(context, token, key, deadline):
    raw = codec.canonical({'context': context, 'token': token})
    signature = subprocess.run(['ssh-keygen', '-Y', 'sign', '-q', '-f', str(key), '-n', NAMESPACE], input=raw,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=deadline - time.monotonic(), check=True).stdout
    if len(raw) > MAX_BYTES or len(signature) > 4096 or time.monotonic() >= deadline:
        raise ValueError('reply too large or expired')
    return codec.canonical({'payload': base64.b64encode(raw).decode(), 'signature': base64.b64encode(signature).decode()})


class Verifier:
    """One request, one accepted reply, from the owner it was sent to."""
    def __init__(self, context, public_key, deadline):
        self.context = codec.decode_json(codec.canonical(context)); validate_context(self.context)
        owner, self.key = codec.public_identity(public_key)
        if owner != self.context['owner'] or not math.isfinite(deadline) or deadline <= time.monotonic():
            raise ValueError('invalid claude token verifier')
        self.deadline = deadline; self.used = False; self.lock = threading.Lock()

    def verify(self, response):
        try:
            with self.lock:
                if self.used:
                    raise ValueError('reply already consumed')
                self.used = True
            if not isinstance(response, bytes) or len(response) > 2 * MAX_BYTES or time.monotonic() >= self.deadline:
                raise ValueError('invalid reply size or deadline')
            validate_context(self.context)
            envelope = codec.decode_json(response)
            if not isinstance(envelope, dict) or set(envelope) != {'payload', 'signature'}:
                raise ValueError('invalid envelope')
            raw = base64.b64decode(envelope['payload'], validate=True)
            signature = base64.b64decode(envelope['signature'], validate=True)
            if len(raw) > MAX_BYTES or not 0 < len(signature) <= 4096:
                raise ValueError('invalid envelope size')
            # Only public material touches a file; the signed bytes go on stdin.
            with tempfile.TemporaryDirectory(prefix='n2-claude-verify-') as directory:
                sig = Path(directory) / 'signature'; signers = Path(directory) / 'signers'
                sig.write_bytes(codec.public_signature(signature, self.key, NAMESPACE))
                signers.write_bytes(self.context['owner'].encode() + b' ' + self.key + b'\n')
                subprocess.run(['ssh-keygen', '-Y', 'verify', '-f', str(signers), '-I', self.context['owner'],
                                '-n', NAMESPACE, '-s', str(sig)], input=raw, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=max(.001, self.deadline - time.monotonic()), check=True)
            payload = codec.decode_json(raw)
            if (not isinstance(payload, dict) or set(payload) != {'context', 'token'}
                    or codec.canonical(payload['context']) != codec.canonical(self.context)):
                raise ValueError('reply belongs to another request')
            if not isinstance(payload['token'], str) or not claude.SHAPE.fullmatch(payload['token']):
                raise ValueError('invalid token')
            return payload['token']
        except Exception:
            raise ValueError('claude token reply rejected') from None


def serve(root, sender, request):
    """Owner side: the reply bytes, only for the same account on an approved peer."""
    server = load('n2_claude_share_server', 'fleet-auth-server.py')
    root = Path(root).resolve(strict=True)
    context = codec.decode_json(transport.bounded_file(request, 4096)); validate_context(context)
    if context['owner'] != identity(root) or context['recipient'] != sender:
        raise ValueError('wrong endpoint binding')
    server.approved(root, sender)
    for cfg in slots(root, context['accountHash']):
        token = claude.read(cfg)
        if token and claude.organization(token) == claude.login_organization(cfg):
            break
    else:
        raise ValueError('no working token for that account')
    reply = sign(context, token, root / 'fleet/identity/id_ed25519', time.monotonic() + min(9, context['expiresAt'] - time.time()))
    server.approved(root, sender)
    return reply


def pull(root, name, peer):
    """Save the token `peer` holds for this slot's account."""
    account = account_hash(Path(root) / name / 'claude')
    if account is None:
        raise ValueError('this slot has no cached sign-in')
    fetch(root, peer, account)


def fetch(root, peer, account):
    """Fetch the token `peer` holds for `account`, re-check it, and save it in
    every slot here signed in to that account."""
    root = Path(root).resolve(strict=True)
    slug = peer.replace('/', '_').replace('+', '_').replace(':', '_')
    key = transport.bounded_file(root / 'fleet/peers' / slug / 'key.pub', 1024)
    context = {'schemaVersion': 1, 'owner': peer, 'recipient': identity(root), 'nonce': secrets.token_hex(32),
               'expiresAt': time.time() + 20, 'accountHash': account}
    token = transport.exchange(root, context, key, time.monotonic() + 20, protocol='claude')
    targets = slots(root, account)  # after the exchange, so a sign-in that changed meanwhile is skipped
    if not targets or claude.organization(token) != claude.login_organization(targets[0]):
        raise ValueError('the shared token belongs to another account')
    for cfg in targets:
        claude.write(cfg, token)


def announce(root, name):
    """The public notice for a token this Mac just saved."""
    cfg = Path(root) / name / 'claude'
    account = account_hash(cfg)
    if not claude.read(cfg) or account is None:
        raise ValueError('this slot has no token to share')
    return codec.canonical({'accountHash': account})


def notice(root, sender, payload):
    """A peer saved a token. Pull it when a slot here is signed in to that account."""
    value = codec.decode_json(transport.bounded_file(payload, 1024))
    if not isinstance(value, dict) or set(value) != {'accountHash'} or not isinstance(value['accountHash'], str):
        raise ValueError('invalid notice')
    if not slots(root, value['accountHash']):
        return 'skipped other-account'
    fetch(root, sender, value['accountHash'])
    return 'saved'


def main():
    verb, args = sys.argv[1], sys.argv[2:]
    if verb == 'serve':  # serve <root> <verified sender> <request>
        try:
            if not os.environ.get('SSH_CONNECTION'):
                raise ValueError('encrypted fleet carrier required')
            reply = serve(*args)
            sys.stdout.buffer.write(reply); sys.stdout.buffer.flush()
        except Exception:
            print('ERR claude-token-unavailable', file=sys.stderr)
            sys.exit(1)
        return
    try:
        if verb == 'pull':  # pull <root> <profile> <peer>
            pull(*args)
        elif verb == 'announce':  # announce <root> <profile>
            sys.stdout.buffer.write(announce(*args))
        elif verb == 'notice':  # notice <root> <verified sender> <payload>
            print(notice(*args))
        else:
            raise ValueError('usage: fleet-claude-token.py serve|pull|announce|notice ...')
    except Exception as error:
        # The carrier's errors are already redacted; local reasons hold no secret.
        print(f'agents: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
