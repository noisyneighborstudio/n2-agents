#!/usr/bin/env python3
"""Codex native managed renewal, followed by independent exact-token verification.

Internal integration only. Callers hold the grant lock for the whole operation.
No login import, command-line interface, or token logging is provided.
"""
import importlib.util
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rpc = load('n2_owner_rpc', 'codex-rpc.py')
usage = load('n2_owner_usage', 'usage.py')


def environment(home):
    # Do not let inherited API keys, bearer tokens, endpoints, proxies or other
    # CLI homes redirect an owner operation. Private HOME also isolates tools
    # that consult ~/.config instead of CODEX_HOME.
    result = {key: os.environ[key] for key in ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'SYSTEMROOT') if key in os.environ}
    result['HOME'] = str(home)
    return result


class NativeOwner:
    def __init__(self, executable='codex'):
        self.executable = executable

    def _verify(self, grant):
        snapshot = grant.credential_snapshot()
        with tempfile.TemporaryDirectory(prefix='n2-owner-verify-') as directory:
            with rpc.CodexRPC(directory, directory, executable=self.executable,
                              ephemeral_auth=True, environment=environment(directory)) as client:
                client.initialize(deadline=grant.deadline)
                observation = client.pin_external_account(snapshot['accessToken'], snapshot['chatgptAccountId'],
                                                          deadline=grant.deadline)
                identity = usage.details('codex', observation)['identity']
                if identity.get('status') != 'verified':
                    raise ValueError('owner account could not be verified')
        return identity['accountHash'], snapshot['credentialRevision']

    def _durable_credential(self, grant):
        # Provider persistence must finish before publishing a usable generation.
        # The grant validates permissions/contents before and after this sync;
        # activation/completion also compare the exact verified revision.
        before = grant.credential_snapshot()
        fd = os.open(grant.provider_home / 'auth.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        fd = os.open(grant.provider_home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        if before != grant.credential_snapshot():
            raise ValueError('credential changed while persisting')

    def activate(self, grant):
        try:
            if grant.public()['state'] != 'pending-login':
                raise ValueError('grant is not pending')
            self._durable_credential(grant)
            return grant.activate(*self._verify(grant))
        except Exception:
            raise RuntimeError('owner activation failed') from None

    def reconcile(self, grant):
        """Verify already-persisted results only. Never repeat native refresh."""
        try:
            if grant.public()['state'] != 'renewing':
                raise ValueError('grant is not renewing')
            self._durable_credential(grant)
            return grant.complete_renewal(*self._verify(grant))
        except Exception:
            raise RuntimeError('owner reconciliation failed') from None

    def request(self, grant, requester, ownership_generation, account_hash, rejected_generation=None):
        try:
            action = grant.select(requester, ownership_generation, account_hash, rejected_generation)
            if action == 'renew':
                home = str(grant.provider_home)
                with rpc.CodexRPC(home, home, executable=self.executable, managed_file_auth=True,
                                  environment=environment(home), lifetime_lock_fd=grant.lifetime_lock_fd,
                                  lifetime_deadline=grant.deadline) as client:
                    client.initialize(deadline=grant.deadline)
                    if client._subscription_provider(grant.deadline) != 'openai':
                        raise ValueError('owner provider is not supported')
                    client.call('account/read', {'refreshToken': True}, deadline=grant.deadline)
                self.reconcile(grant)
            return grant.token()
        except Exception:
            # Provider diagnostics may contain credentials. Uncertain renewal
            # remains renewing until explicit reconciliation, never auto-retry.
            raise RuntimeError('owner token request failed') from None
