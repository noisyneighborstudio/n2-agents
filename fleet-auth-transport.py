#!/usr/bin/env python3
"""Bounded in-memory owner reply transport over fleet-pinned SSH."""
import importlib.util
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('n2_auth_response', ROOT / 'fleet-auth-response.py')
codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(codec)


def bounded_file(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError('not a regular file')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            raw = stream.read(maximum + 1)
        if len(raw) > maximum:
            raise ValueError('file too large')
        return raw
    finally:
        os.close(descriptor)


def validate_request(root, peer, path):
    context = codec.decode_json(bounded_file(path, 4096))
    codec.validate_context(context, time.time())
    identity, _ = codec.public_identity(bounded_file(Path(root) / 'fleet/identity/id_ed25519.pub', 1024))
    if context['owner'] != peer or context['recipient'] != identity:
        raise ValueError('request belongs to another machine')
    return context


def exchange(root, context, owner_public_key, deadline, agents=None):
    """Return a verified token reply, never raw carrier output.

    Consent for the grant is enforced by its owner. The carrier checks approved
    peer state at both ends of its local request. Caller must bind the returned
    token to the provider account before execution.
    """
    process = None
    try:
        verifier = codec.ResponseVerifier(context, owner_public_key, deadline)
        context = verifier.context
        root = str(Path(root).resolve(strict=True))
        with tempfile.TemporaryDirectory(prefix='n2-auth-request-') as directory:
            payload = Path(directory) / 'request'
            # Whitelisted public request context only. Never spool the response.
            payload.write_bytes(codec.canonical(context))
            validate_request(root, context['owner'], payload)
            process = subprocess.Popen([str(agents or ROOT / 'agents'), '_fleet-auth-call', context['owner'], str(payload)],
                                       env=dict(os.environ, N2_AGENTS_ROOT=root, N2_FLEET_DEBUG=''),
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       start_new_session=True, bufsize=0)
            descriptor = process.stdout.fileno()
            os.set_blocking(descriptor, False)
            reply = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
                    raise TimeoutError('owner reply deadline expired')
                try:
                    chunk = os.read(descriptor, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    break
                reply.extend(chunk)
                if len(reply) > 2 * codec.MAX_BYTES:
                    raise ValueError('owner reply too large')
            remaining = deadline - time.monotonic()
            if remaining <= 0 or process.wait(timeout=remaining) != 0:
                raise ValueError('owner request failed')
            return verifier.verify(bytes(reply))
    except Exception:
        raise ValueError('fleet authentication owner unavailable or response rejected') from None
    finally:
        if process is not None:
            # A carrier may exit while descendants retain the output pipe.
            # The dedicated group belongs to this request, including on timeout.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                if process.poll() is None:
                    raise
            process.wait()
            process.stdout.close()


if __name__ == '__main__':
    try:
        if len(sys.argv) != 5 or sys.argv[1] != 'validate-request':
            raise ValueError('invalid arguments')
        validate_request(*sys.argv[2:])
    except Exception:
        print('agents: invalid fleet authentication request', file=sys.stderr)
        sys.exit(1)
