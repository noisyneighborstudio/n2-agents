#!/usr/bin/env python3
"""Public profile-to-grant records. Contains no provider credential material.

Writers must hold the profile's fleet resource lock, shared with sync writers.
Reading a record establishes routing intent, never provider authentication.
"""
import hashlib
import importlib.util
import json
import os
import stat
from pathlib import Path
import tempfile

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('n2_binding_owner',ROOT/'fleet-auth-owner.py')
owner=importlib.util.module_from_spec(spec);spec.loader.exec_module(owner)
MARKER='.n2-owner.json'
FIELDS={'schemaVersion','provider','profileId','grantId','owner','ownershipGeneration','accountHash','credentialStore'}
MAX_BYTES=4096


def validate(record, profile_id):
    if not isinstance(record,dict) or set(record)!=FIELDS or type(record['schemaVersion']) is not int or record['schemaVersion']!=1:
        raise ValueError('invalid ownership schema')
    if record['provider']!='codex' or record['credentialStore']!='owner-file':
        raise ValueError('unsupported ownership mode')
    if any(not owner.uuid_value(record[k]) for k in ('profileId','grantId','ownershipGeneration')):
        raise ValueError('invalid ownership identity')
    if record['profileId']!=profile_id or not owner.peer_value(record['owner']) or not owner.hash_value(record['accountHash']):
        raise ValueError('ownership binding mismatch')
    return record


def from_grant(grant, profile_id):
    # Call while holding the private owner's lock and only after independent
    # provider verification activated the grant. Never expose private digests,
    # token generations, consent lists or credentials in the public record.
    public=grant.public()
    if public['state']!='active':
        raise ValueError('owner grant is not active')
    record={k:public[k] for k in ('profileId','grantId','owner','ownershipGeneration','accountHash')}
    record.update(schemaVersion=1,provider='codex',credentialStore='owner-file')
    return validate(record,profile_id)


def controlled_directory(directory):
    directory=Path(directory)
    info=directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o022:
        raise ValueError('ownership directory is not owner-controlled')
    return directory


def read(directory, profile_id):
    # The resource is public, but require private ownership to avoid letting a
    # permissive replacement silently redirect a local profile's account route.
    path=controlled_directory(directory)/MARKER
    raw=owner.private_file(path,MAX_BYTES)
    record=json.loads(raw,object_pairs_hook=owner.unique)
    validate(record,profile_id)
    return record,hashlib.sha256(raw).hexdigest()


def publish(directory, record, profile_id, expected_revision=None):
    """Compare-and-replace under the caller's existing sync resource lock.

    None means the resource must not exist. Existing, legacy or malformed files
    cannot be overwritten implicitly; explicit replacement names their revision.
    """
    validate(record,profile_id)
    directory=controlled_directory(directory)
    path=directory/MARKER
    try:
        raw=owner.private_file(path,MAX_BYTES)
        current=hashlib.sha256(raw).hexdigest()
    except FileNotFoundError:
        current=None
    if current!=expected_revision:
        raise ValueError('ownership record changed')
    # Refuse unknown schemas even when the caller knows their bytes. Future
    # versions need their own migration, not replacement by an older writer.
    if current is not None:
        validate(json.loads(raw,object_pairs_hook=owner.unique),profile_id)
    encoded=json.dumps(record,sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n'
    fd,temporary=tempfile.mkstemp(prefix='.n2sync.',dir=directory)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(encoded);out.flush();os.fsync(out.fileno())
        os.replace(temporary,path)
        owner.sync_directory(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    return hashlib.sha256(encoded).hexdigest()
