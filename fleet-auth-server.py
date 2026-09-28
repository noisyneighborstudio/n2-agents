#!/usr/bin/env python3
"""Private token endpoint, called only after fleet envelope authentication."""
import importlib.util
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT/file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

transport = load('n2_server_transport', 'fleet-auth-transport.py')
owner = load('n2_server_owner', 'fleet-auth-owner.py')
native = load('n2_server_native', 'fleet-auth-native.py')
codec = transport.codec


def approved(root, sender):
    if not owner.peer_value(sender):
        raise ValueError('invalid sender')
    fleet = root/'fleet'
    revoked = transport.bounded_file(fleet/'revoked', 2*1024*1024).decode()
    if any(line.split() and line.split()[0] == sender for line in revoked.splitlines()):
        raise ValueError('revoked sender')
    slug = sender.replace('/', '_').replace('+', '_').replace(':', '_')
    peer = fleet/'peers'/slug
    fields = {}
    for line in transport.bounded_file(peer/'meta', 65536).decode().splitlines():
        key, separator, value = line.partition('=')
        if not separator or key in fields:
            raise ValueError('invalid peer metadata')
        fields[key] = value
    if fields.get('peer') != sender or fields.get('state') != 'approved':
        raise ValueError('unapproved sender')
    identity, _ = codec.public_identity(transport.bounded_file(peer/'key.pub', 1024))
    if identity != sender:
        raise ValueError('changed sender key')


def response(root, authenticated_sender, request_path):
    """Return secret reply bytes in memory. Sender must come from fleet_verify."""
    try:
        root = Path(root).resolve(strict=True)
        context = codec.decode_json(transport.bounded_file(request_path, 4096))
        codec.validate_context(context, time.time())
        key = root/'fleet/identity/id_ed25519'
        identity, _ = codec.public_identity(transport.bounded_file(Path(str(key)+'.pub'), 1024))
        if context['owner'] != identity or context['recipient'] != authenticated_sender:
            raise ValueError('wrong endpoint binding')
        approved(root, authenticated_sender)
        owner.private_directory(root/'fleet')
        deadline = time.monotonic() + min(9, context['expiresAt']-time.time())
        store = owner.OwnerStore(root/'fleet/auth-owners', identity)
        with store.locked(context['grantId'], deadline) as grant:
            token = native.NativeOwner().request(grant, authenticated_sender, context['ownershipGeneration'],
                                                context['accountHash'], context['rejectedTokenGeneration'])
            approved(root, authenticated_sender)
            result = codec.sign_response(context, token['tokenGeneration'], token['accessToken'],
                                         token['chatgptAccountId'], key, deadline)
            # Recheck after potentially slow signing, before exposing any bytes.
            approved(root, authenticated_sender)
            grant._check()
            return result
    except Exception:
        raise ValueError('owner request rejected') from None


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4 or not os.environ.get('SSH_CONNECTION'):
            raise ValueError('encrypted fleet carrier required')
        reply = response(sys.argv[1], sys.argv[2], sys.argv[3])
        sys.stdout.buffer.write(reply)
        sys.stdout.buffer.flush()
    except Exception:
        print('ERR owner-unavailable', file=sys.stderr)
        raise SystemExit(1)
