#!/usr/bin/env python3
"""Private, process-serialized state for N2-owned Codex login grants.

This module never imports an existing profile login or starts provider refresh.
Only the owner integration may activate/complete a grant after authenticating
its exact stored access token. No command-line secret output is provided.
"""
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
import time
import uuid

MAX_CREDENTIAL = 2 * 1024 * 1024
MAX_HISTORY = 128
STATES = {'pending-login', 'active', 'renewing', 'reauth-required', 'retired'}
FIELDS = {'schemaVersion', 'grantId', 'profileId', 'owner', 'ownershipGeneration',
          'accountHash', 'state', 'tokenGeneration', 'previousGenerations',
          'credentialRevision', 'tokenDigest', 'allowedPeers', 'revision'}


def uuid_value(value):
    return isinstance(value, str) and str(uuid.UUID(value)) == value


def peer_value(value):
    return isinstance(value, str) and re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', value) is not None


def hash_value(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def private_directory(path, create=False):
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('owner directory is not private')


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def private_file(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            raise ValueError('owner file is not private')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise ValueError('owner file too large')
        return raw
    finally:
        os.close(fd)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate state key')
        result[key] = value
    return result


def validate(state):
    if not isinstance(state, dict) or set(state) != FIELDS or type(state['schemaVersion']) is not int or state['schemaVersion'] != 1:
        raise ValueError('invalid owner state schema')
    if any(not uuid_value(state[key]) for key in ('grantId', 'profileId', 'ownershipGeneration')) or not peer_value(state['owner']):
        raise ValueError('invalid owner identity')
    if not isinstance(state['state'], str) or state['state'] not in STATES or type(state['revision']) is not int or not 0 <= state['revision'] < 2**63:
        raise ValueError('invalid owner state')
    if state['accountHash'] is not None and not hash_value(state['accountHash']):
        raise ValueError('invalid account binding')
    peers, history = state['allowedPeers'], state['previousGenerations']
    if not isinstance(peers, list) or len(peers) > 1024 or any(not peer_value(p) for p in peers) or peers != sorted(set(peers)):
        raise ValueError('invalid grant consent')
    if not isinstance(history, list) or len(history) > MAX_HISTORY or any(not uuid_value(v) for v in history) or len(set(history)) != len(history):
        raise ValueError('invalid token history')
    for key in ('credentialRevision', 'tokenDigest'):
        if state[key] is not None and not hash_value(state[key]):
            raise ValueError('invalid private credential revision')
    if state['tokenGeneration'] is not None and not uuid_value(state['tokenGeneration']):
        raise ValueError('invalid token generation')
    if state['tokenGeneration'] in history:
        raise ValueError('current token duplicated in history')
    if state['state'] in ('active', 'renewing') and any(state[key] is None for key in ('accountHash', 'tokenGeneration', 'credentialRevision', 'tokenDigest')):
        raise ValueError('active grant has no verified credential')


class OwnerStore:
    def __init__(self, directory, owner):
        if not peer_value(owner):
            raise ValueError('invalid owner identity')
        self.directory = Path(directory)
        private_directory(self.directory, create=True)
        # Persist the store entry too, including recovery after an interrupted
        # constructor that created it but never acknowledged successful setup.
        sync_directory(self.directory.parent)
        self.owner = owner

    def create(self, profile_id, expected_account=None):
        if not uuid_value(profile_id) or (expected_account is not None and not hash_value(expected_account)):
            raise ValueError('invalid profile binding')
        grant_id = str(uuid.uuid4())
        directory = self.directory / grant_id
        directory.mkdir(mode=0o700)
        (directory / 'codex').mkdir(mode=0o700)
        state = {'schemaVersion': 1, 'grantId': grant_id, 'profileId': profile_id,
                 'owner': self.owner, 'ownershipGeneration': str(uuid.uuid4()),
                 'accountHash': expected_account, 'state': 'pending-login',
                 'tokenGeneration': None, 'previousGenerations': [],
                 'credentialRevision': None, 'tokenDigest': None,
                 'allowedPeers': [self.owner], 'revision': 0}
        with self.locked(grant_id, time.monotonic()+2, initial=state) as grant:
            grant._save()
            # The grant directory entry lives in the store, not in the grant.
            sync_directory(self.directory)
            return grant.public()

    @contextlib.contextmanager
    def locked(self, grant_id, deadline, initial=None):
        if not uuid_value(grant_id) or type(deadline) not in (int, float) or not math.isfinite(deadline):
            raise ValueError('invalid owner request')
        private_directory(self.directory)
        directory = self.directory / grant_id
        private_directory(directory)
        private_directory(directory / 'codex')
        fd = os.open(directory / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
        session = None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
                raise ValueError('invalid owner lock')
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError('owner is busy')
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(min(.02, max(0, deadline-time.monotonic())))
            if initial is None:
                state = json.loads(private_file(directory / 'state.json', 128*1024), object_pairs_hook=unique)
            else:
                if (directory / 'state.json').exists():
                    raise ValueError('owner grant already exists')
                state = initial
            validate(state)
            if state['grantId'] != grant_id or state['owner'] != self.owner:
                raise ValueError('owner grant identity mismatch')
            session = Grant(directory, state, deadline, fd)
            yield session
        finally:
            if session is not None:
                session.closed = True
            os.close(fd)


class Grant:
    def __init__(self, directory, state, deadline, lock_fd):
        self._lock_fd = lock_fd
        self.directory, self.state, self.deadline = directory, state, deadline
        self.closed = False

    def _check(self):
        if self.closed or time.monotonic() >= self.deadline:
            raise RuntimeError('owner operation is no longer active')

    def _save(self):
        self._check()
        temporary = None
        try:
            self.state['revision'] += 1
            validate(self.state)
            raw = json.dumps(self.state, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
            fd, temporary = tempfile.mkstemp(prefix='.state-', dir=self.directory)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, self.directory / 'state.json')
            sync_directory(self.directory)
        except Exception:
            # An uncommitted in-memory transition cannot issue a token even if
            # the caller catches an I/O failure while still holding the lock.
            self.closed = True
            raise
        finally:
            if temporary is not None and os.path.exists(temporary): os.unlink(temporary)

    def public(self):
        self._check()
        return {key: self.state[key] for key in ('schemaVersion', 'grantId', 'profileId', 'owner',
                'ownershipGeneration', 'accountHash', 'state', 'tokenGeneration', 'revision')}

    @property
    def lifetime_lock_fd(self):
        self._check()
        return self._lock_fd

    @property
    def provider_home(self):
        self._check()
        return self.directory / 'codex'

    def _credential(self):
        self._check()
        raw = private_file(self.provider_home / 'auth.json', MAX_CREDENTIAL)
        try:
            saved = json.loads(raw, object_pairs_hook=unique)
            tokens = saved['tokens']
            token, account = tokens['access_token'], tokens['account_id']
            if not isinstance(token, str) or not token or len(token.encode()) > 65536 or not isinstance(account, str) or not account or len(account.encode()) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in account):
                raise ValueError()
            return token, account, hashlib.sha256(raw).hexdigest(), hashlib.sha256(token.encode()).hexdigest()
        except Exception:
            raise ValueError('owner credential is invalid') from None

    def credential_snapshot(self):
        self._check()
        if self.state['state'] not in ('pending-login', 'active', 'renewing'):
            raise ValueError('grant cannot expose a credential for verification')
        token, account, revision, _ = self._credential()
        return {'accessToken': token, 'chatgptAccountId': account, 'credentialRevision': revision}

    def _bind(self, verified_account, verified_revision, renewal=False):
        self._check()
        if not hash_value(verified_account) or not hash_value(verified_revision):
            raise ValueError('invalid verified account')
        if self.state['accountHash'] not in (None, verified_account):
            self.state['state'] = 'reauth-required'; self._save()
            raise ValueError('owner account changed')
        token, account, revision, digest = self._credential()
        if revision != verified_revision:
            raise ValueError('credential changed after account verification')
        if renewal and (revision == self.state['credentialRevision'] or digest == self.state['tokenDigest']):
            self.state['state'] = 'reauth-required'; self._save()
            raise ValueError('renewal outcome cannot be established')
        previous = self.state['tokenGeneration']
        if previous is not None:
            self.state['previousGenerations'] = (self.state['previousGenerations'] + [previous])[-MAX_HISTORY:]
        self.state.update(accountHash=verified_account, credentialRevision=revision, tokenDigest=digest,
                          tokenGeneration=str(uuid.uuid4()), state='active')
        self._save()
        return self.public()

    def activate(self, verified_account, verified_revision):
        self._check()
        if self.state['state'] != 'pending-login':
            raise ValueError('grant is not awaiting login')
        return self._bind(verified_account, verified_revision)

    def consent(self, peer, allowed):
        self._check()
        if not peer_value(peer) or type(allowed) is not bool or self.state['state'] == 'retired':
            raise ValueError('invalid grant consent change')
        peers = set(self.state['allowedPeers'])
        if allowed: peers.add(peer)
        else: peers.discard(peer)
        self.state['allowedPeers'] = sorted(peers)
        self._save()

    def select(self, requester, ownership_generation, account_hash, rejected_generation=None):
        """Return current or renew. Only renew permits one native refresh attempt."""
        self._check()
        if (requester not in self.state['allowedPeers'] or ownership_generation != self.state['ownershipGeneration']
                or account_hash != self.state['accountHash'] or self.state['state'] != 'active'):
            raise ValueError('grant is not available for this binding')
        if rejected_generation is not None and not uuid_value(rejected_generation):
            raise ValueError('invalid rejected generation')
        _, _, revision, digest = self._credential()
        if revision != self.state['credentialRevision'] or digest != self.state['tokenDigest']:
            self.state['state'] = 'reauth-required'; self._save()
            raise ValueError('owner credential changed outside its operation')
        if rejected_generation is None or rejected_generation in self.state['previousGenerations']:
            return 'current'
        if rejected_generation != self.state['tokenGeneration']:
            raise ValueError('unknown rejected generation')
        self.state['state'] = 'renewing'
        self._save()  # Durable before the caller starts a provider-side operation.
        return 'renew'

    def complete_renewal(self, verified_account, verified_revision):
        self._check()
        if self.state['state'] != 'renewing':
            raise ValueError('no renewal operation to complete')
        return self._bind(verified_account, verified_revision, renewal=True)

    def token(self):
        self._check()
        if self.state['state'] != 'active':
            raise ValueError('grant has no usable token')
        token, account, revision, digest = self._credential()
        if revision != self.state['credentialRevision'] or digest != self.state['tokenDigest']:
            raise ValueError('owner credential changed')
        return {'accessToken': token, 'chatgptAccountId': account, 'tokenGeneration': self.state['tokenGeneration']}

    def retire(self):
        self._check()
        if self.state['state'] != 'retired':
            self.state.update(state='retired', ownershipGeneration=str(uuid.uuid4()), allowedPeers=[])
            self._save()
