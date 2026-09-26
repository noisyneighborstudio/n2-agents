#!/usr/bin/env python3
"""Stable N2 profile metadata. Profile IDs are not provider account identities."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

MARKER = '.n2-profile'
LEGACY = b'n2-agents profile\n'
MAX_BYTES = 4096
MAX_ROUTE_BYTES = 2 * 1024 * 1024
REVISION_SCOPE = 'n2-profile-routing-v2'
ROOT = Path(__file__).resolve().parent


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



def owner_route(root, name, directory):
    """Capture public owner intent, without reading credentials or contacting it."""
    marker = Path(directory) / '.n2-owner.json'
    address = 'settings|' + name + '|codex|.n2-owner.json'
    conflict = Path(root) / 'fleet/sync/conflicts' / hashlib.sha256(address.encode()).hexdigest()[:12]
    if os.path.lexists(conflict) or any(conflict.parent.glob('.resolving-'+conflict.name+'.*')):
        return {'status': 'conflicting'}
    if not os.path.lexists(marker):
        return {'status': 'unmanaged'}
    try:
        spec = importlib.util.spec_from_file_location('n2_routing_binding', ROOT / 'fleet-auth-binding.py')
        binding = importlib.util.module_from_spec(spec); spec.loader.exec_module(binding)
        profile = read_marker(Path(root) / name / MARKER)
        if profile is None:
            raise ValueError('legacy profile')
        record, revision = binding.read(directory, profile['profileId'])
        return {'status': 'registered', 'revision': revision, 'binding': record}
    except (OSError, ValueError, TypeError, RuntimeError):
        return {'status': 'invalid'}


def routing_inventory(root):
    result = subprocess.run([str(ROOT / 'agents'), '_profile-routes'],
                            env=dict(os.environ, N2_AGENTS_ROOT=str(root)),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=15, check=True)
    if len(result.stdout) > MAX_ROUTE_BYTES or not result.stdout.endswith(b'\0'):
        raise ValueError('invalid routing inventory')
    fields = result.stdout[:-1].decode('utf-8').split('\0')
    if len(fields) < 4 or fields[0] != 'n2-profile-routes-v1' or (len(fields) - 4) % 8:
        raise ValueError('invalid routing inventory')
    if os.path.realpath(fields[2]) != os.path.realpath(root):
        raise ValueError('routing inventory belongs to another profile root')
    inventory_machine = fields[3]
    vendors = fields[1].split()
    if not vendors or len(set(vendors)) != len(vendors) or any(not re.fullmatch('[a-z][a-z0-9-]*', v) for v in vendors):
        raise ValueError('invalid routing vendors')
    routes = {}
    for offset in range(4, len(fields), 8):
        name, vendor, home, key, value, extra, cli, executable = fields[offset:offset + 8]
        if vendor not in vendors or not re.fullmatch('[A-Za-z0-9]+', name) or not home or not value:
            raise ValueError('invalid routing record')
        if not re.fullmatch('[A-Z][A-Z0-9_]*', key) or not re.fullmatch('[a-z][a-z0-9-]*', cli):
            raise ValueError('invalid launch configuration')
        environment = {key: value}
        for extra in extra.split():
            extra_key, separator, extra_value = extra.partition('=')
            if not separator or not re.fullmatch('[A-Z][A-Z0-9_]*', extra_key) or extra_key in environment:
                raise ValueError('invalid extra launch configuration')
            environment[extra_key] = extra_value
        # Keep the configured spelling for launches; resolving is independent
        # evidence used to detect a symlink retarget. Do not normalize away '..'
        # before the filesystem has resolved its preceding symlink component.
        relative = not os.path.isabs(home) or not os.path.isabs(value) or (executable and not os.path.isabs(executable))
        route = {'provider': vendor, 'configDir': home, 'resolvedConfigDir': None,
                 'environment': environment, 'cli': cli, 'executable': executable or None,
                 'resolvedExecutable': None, 'workingDirectory': os.getcwd() if relative else None,
                 'status': 'unavailable',
                 'accountIdentity': {'status': 'unknown'}}
        try:
            resolved_home = str(Path(home).resolve(strict=True))
            if not Path(resolved_home).is_dir():
                raise ValueError('invalid configuration directory')
            route['resolvedConfigDir'] = resolved_home
            route['status'] = 'missing-executable'
            if executable:
                resolved_executable = str(Path(executable).resolve(strict=True))
                if not Path(resolved_executable).is_file() or not os.access(resolved_executable, os.X_OK):
                    raise ValueError('invalid executable')
                route['resolvedExecutable'] = resolved_executable
                route['status'] = 'available'
        except FileNotFoundError:
            route['status'] = 'missing-config' if route['resolvedConfigDir'] is None else 'missing-executable'
        except (OSError, ValueError, RuntimeError):
            route['status'] = 'invalid'
        if vendor == 'codex':
            route['ownerBinding'] = owner_route(root, name, home)
            if route['ownerBinding']['status'] in ('invalid', 'conflicting'):
                route['status'] = 'invalid-owner-binding'
        key = (name, vendor)
        if key in routes:
            raise ValueError('duplicate routing record')
        routes[key] = route
    return vendors, routes, inventory_machine


def routing_report(root, machine):
    before = report(root, machine)
    vendors, first, first_machine = routing_inventory(root)
    later_vendors, second, second_machine = routing_inventory(root)
    after = report(root, machine)
    names = {row['name'] for row in before['profiles']}
    expected = {(name, vendor) for name in names for vendor in vendors}
    stable = (before == after and vendors == later_vendors and first == second
              and first_machine == second_machine == machine and set(first) == expected)
    for row in after['profiles']:
        row['routingStatus'] = 'stable' if stable else 'changed-during-read'
        row['revisionScope'] = REVISION_SCOPE
        row['configurationRevision'] = None
        row['routes'] = [second[(row['name'], v)] for v in sorted(later_vendors) if (row['name'], v) in second]
        if (stable and machine and row['metadataStatus'] == 'ready'
                and all(route['status'] != 'invalid-owner-binding' for route in row['routes'])):
            # This revision is for N2's binding inputs, not a digest of provider
            # credentials or every project/user setting the provider may load.
            payload = {k: row[k] for k in ('name', 'profileId', 'scope', 'machineId', 'revisionScope', 'routes')}
            row['configurationRevision'] = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('ensure'); init.add_argument('directory'); init.add_argument('--migrate-legacy', action='store_true')
    validate = sub.add_parser('validate'); validate.add_argument('file')
    show = sub.add_parser('report'); show.add_argument('root'); show.add_argument('--machine', default=''); show.add_argument('--with-routes', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'ensure':
            ensure(args.directory, args.migrate_legacy)
        elif args.command == 'validate':
            read_marker(args.file)
        else:
            value = routing_report(args.root, args.machine) if args.with_routes else report(args.root, args.machine)
            print(json.dumps(value, sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, UnicodeError, subprocess.SubprocessError):
        print('agents: profile metadata is unavailable or invalid; existing bytes were preserved', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
