#!/usr/bin/env python3
"""Session-pinned owner token source for account-bound Codex execution."""
import importlib.util
import contextlib
import math
from pathlib import Path
import secrets
import threading
import time

ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

binding=load('n2_client_binding','fleet-auth-binding.py')
transport=load('n2_client_transport','fleet-auth-transport.py')
native=load('n2_client_native','fleet-auth-native.py')


class OwnerClient:
    """One binding and one token-generation chain; failures poison the session.

    This returns credentials only to an in-memory consumer. The consumer must
    authenticate the initial token and every replacement before execution.
    Existing sessions intentionally retain their original record after a profile
    is edited or replaced. New sessions must resolve a fresh routing snapshot.
    """
    def __init__(self,root,record,profile_id,expected_account):
        self.record=transport.codec.decode_json(transport.codec.canonical(record))
        binding.validate(self.record,profile_id)
        if self.record['accountHash']!=expected_account:
            raise ValueError('selected owner account mismatch')
        self.root=Path(root).resolve(strict=True)
        self.recipient=self._identity()
        self.local=self.recipient==self.record['owner']
        self.owner_key=None
        if not self.local:
            slug=self.record['owner'].replace('/','_').replace('+','_').replace(':','_')
            self.owner_key=transport.bounded_file(self.root/'fleet/peers'/slug/'key.pub',1024)
            if transport.codec.public_identity(self.owner_key)[0]!=self.record['owner']:
                raise ValueError('owner identity mismatch')
        self.generation=None
        self.account_id=None
        self.failed=False
        self.lock=threading.Lock()

    def _identity(self):
        return transport.codec.public_identity(transport.bounded_file(self.root/'fleet/identity/id_ed25519.pub',1024))[0]

    def _request(self,deadline):
        if self._identity()!=self.recipient:
            raise ValueError('requester identity changed')
        if self.local:
            store=binding.owner.OwnerStore(self.root/'fleet/auth-owners',self.recipient)
            with store.locked(self.record['grantId'],deadline) as grant:
                if grant.public()['profileId']!=self.record['profileId']:
                    raise ValueError('owner grant profile mismatch')
                return native.NativeOwner().request(grant,self.recipient,self.record['ownershipGeneration'],
                                                    self.record['accountHash'],self.generation)
        remaining=deadline-time.monotonic()
        if remaining<=0:
            raise TimeoutError('owner deadline expired')
        context={'schemaVersion':1,'owner':self.record['owner'],'recipient':self.recipient,
                 'nonce':secrets.token_hex(32),'grantId':self.record['grantId'],
                 'ownershipGeneration':self.record['ownershipGeneration'],'accountHash':self.record['accountHash'],
                 'expiresAt':time.time()+min(remaining,30),'rejectedTokenGeneration':self.generation}
        return transport.exchange(self.root,context,self.owner_key,deadline)

    def _fetch(self,account_id,deadline,initial):
        acquired=False
        try:
            if type(deadline) not in (int,float) or not math.isfinite(deadline):
                raise ValueError('invalid owner deadline')
            acquired=self.lock.acquire(timeout=max(0,deadline-time.monotonic()))
            if not acquired or time.monotonic()>=deadline or self.failed:
                raise ValueError('owner session unavailable')
            if initial:
                if self.generation is not None:
                    raise ValueError('owner session already started')
            elif self.generation is None or account_id!=self.account_id:
                raise ValueError('renewal account mismatch')
            result=self._request(deadline)
            if (self.failed or time.monotonic()>=deadline or not isinstance(result,dict)
                    or set(result)!={'accessToken','chatgptAccountId','tokenGeneration'}
                    or not binding.owner.uuid_value(result['tokenGeneration'])
                    or result['tokenGeneration']==self.generation
                    or not isinstance(result['accessToken'],str) or not result['accessToken']
                    or len(result['accessToken'].encode())>65536
                    or not isinstance(result['chatgptAccountId'],str) or not result['chatgptAccountId']
                    or (not initial and result['chatgptAccountId']!=self.account_id)):
                raise ValueError('invalid owner token reply')
            self.generation=result['tokenGeneration']
            self.account_id=result['chatgptAccountId']
            return {'accessToken':result['accessToken'],'chatgptAccountId':self.account_id}
        except Exception:
            self.failed=True
            raise RuntimeError('owner authentication unavailable') from None
        finally:
            if acquired:self.lock.release()

    @contextlib.contextmanager
    def connection(self,home,cwd,deadline,executable='codex',own_process_group=True):
        rpc=load('n2_client_connection','codex-rpc.py')
        supplied=self.start(deadline)
        provider=None
        try:
            for attempt in range(2):
                provider=rpc.CodexRPC(home,cwd,executable=executable,ephemeral_auth=True,
                                      own_process_group=own_process_group)
                provider.initialize(deadline=deadline)
                try:
                    observation=provider.pin_external_account(supplied['accessToken'],supplied['chatgptAccountId'],
                        renewal_source=self.renew,deadline=deadline,allow_initial_rejection=attempt==0)
                    break
                except rpc.InitialTokenRejected as rejected:
                    provider.close();provider=None
                    supplied=self.renew(supplied['chatgptAccountId'],min(deadline,rejected.deadline))
            else:
                raise RuntimeError('initial owner authentication failed')
            # Authenticate the exact replacement before exposing either the
            # connection or its observation, including initial expiry recovery.
            identity=native.usage.details('codex',observation)['identity']
            if identity.get('status')!='verified' or identity.get('accountHash')!=self.record['accountHash']:
                raise RuntimeError('owner connection account mismatch')
            yield provider,observation
        finally:
            if provider is not None:provider.close()

    def start(self,deadline):
        return self._fetch(None,deadline,True)

    def renew(self,account_id,deadline):
        return self._fetch(account_id,deadline,False)


def for_profile(root, config, profile_name, expected_account=None):
    if root is None or profile_name is None:
        raise ValueError('owner profile context unavailable')
    if binding.conflicted(root,profile_name):
        raise ValueError('owner binding conflict requires resolution')
    metadata=load('n2_client_metadata','profile-metadata.py')
    candidates=[row for row in metadata.report(root,None)['profiles'] if row['name']==profile_name]
    if len(candidates)!=1 or candidates[0]['metadataStatus']!='ready':
        raise ValueError('owner profile identity unavailable')
    profile_id=candidates[0]['profileId']
    record,_=binding.read(Path(config).resolve(strict=True),profile_id)
    return OwnerClient(root,record,profile_id,record['accountHash'] if expected_account is None else expected_account)
