#!/usr/bin/env python3
"""Stable N2 profile metadata. Profile IDs are not provider account identities."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid

MARKER = '.n2-profile'
LEGACY = b'n2-agents profile\n'
MAX_BYTES = 4096


def read_marker(path):
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('profile metadata must be a regular file')
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('profile metadata too large')
    if raw == LEGACY:
        return None
    value = json.loads(raw)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'profileId'}
            or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1
            or not isinstance(value['profileId'], str)
            or str(uuid.UUID(value['profileId'])) != value['profileId']):
        raise ValueError('invalid profile metadata')
    return value


def ensure(directory, migrate_legacy=False):
    # The caller holds the same resource lock as fleet sync writers. Reads are
    # bounded and refuse symlinks; a legacy existence marker is the only schema
    # that may be migrated explicitly. Unknown versions stay untouched.
    path = Path(directory) / MARKER
    try:
        existing = read_marker(path)
        if existing is None and not migrate_legacy:
            return None
    except FileNotFoundError:
        existing = None
    if existing is not None:
        return existing
    value = {'schemaVersion': 1, 'profileId': str(uuid.uuid4())}
    fd, temporary = tempfile.mkstemp(prefix='.n2sync.', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True, separators=(',', ':'))
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return value


def report(root, machine):
    root = Path(root)
    names = {'Default'}
    if root.is_dir():
        names.update(p.name for p in root.iterdir() if p.is_dir()
                     and re.fullmatch('[A-Za-z0-9]+', p.name) and p.name.lower() not in ('default', 'fleet'))
    rows = []
    for name in sorted(names, key=str.lower):
        row = {'name': name, 'profileId': None, 'metadataStatus': 'missing',
               'scope': 'machine-local' if name == 'Default' else 'fleet', 'machineId': machine or None}
        try:
            value = read_marker(root / name / MARKER)
            row['metadataStatus'] = 'legacy' if value is None else 'ready'
            if value is not None:
                row['profileId'] = value['profileId']
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, UnicodeError):
            row['metadataStatus'] = 'invalid'
        addr = 'profile|' + name + '|-|' + MARKER
        conflict = root / 'fleet/sync/conflicts' / hashlib.sha256(addr.encode()).hexdigest()[:12]
        if conflict.exists():
            row['metadataStatus'] = 'conflicting'
        rows.append(row)
    ids = {}
    for row in rows:
        if row['profileId']:
            ids.setdefault(row['profileId'], []).append(row)
    for matches in ids.values():
        if len(matches) > 1:
            for row in matches:
                row['metadataStatus'] = 'duplicate'
    return {'schemaVersion': 1, 'profiles': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('ensure'); init.add_argument('directory'); init.add_argument('--migrate-legacy', action='store_true')
    validate = sub.add_parser('validate'); validate.add_argument('file')
    show = sub.add_parser('report'); show.add_argument('root'); show.add_argument('--machine', default='')
    args = parser.parse_args()
    try:
        if args.command == 'ensure':
            ensure(args.directory, args.migrate_legacy)
        elif args.command == 'validate':
            read_marker(args.file)
        else:
            print(json.dumps(report(args.root, args.machine), sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, UnicodeError):
        print('agents: profile metadata is unavailable or invalid; existing bytes were preserved', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
